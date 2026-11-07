package backup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const tsLayout = "20060102T150405Z"

var (
	manifestRe = regexp.MustCompile(`^(openfamily-(\d{8}T\d{6}Z))\.manifest\.json$`)
	objectRe   = regexp.MustCompile(`^openfamily-\d{8}T\d{6}Z\.dump(\.age)?$`)
)

// Manifest is uploaded next to every dump. It is written last, so its
// presence means the dump upload completed.
type Manifest struct {
	Format        int       `json:"format"`
	Name          string    `json:"name"`
	Object        string    `json:"object"`
	CreatedAt     time.Time `json:"created_at"`
	SizeBytes     int64     `json:"size_bytes"`
	SHA256        string    `json:"sha256"`
	Encryption    string    `json:"encryption"`
	PGDump        string    `json:"pg_dump,omitempty"`
	SchemaVersion int64     `json:"schema_version,omitempty"`
	Service       string    `json:"service,omitempty"`
}

// RunRecord is one row of backup_runs.
type RunRecord struct {
	Status      string // success | failed
	Destination string // local | s3
	Encrypted   bool
	ObjectKey   string
	SizeBytes   int64
	Duration    time.Duration
	Error       string
	Trigger     string // schedule | manual | script
}

// Recorder persists run records (the database in production, memory in tests).
type Recorder interface {
	RecordRun(ctx context.Context, r RunRecord) error
	SchemaVersion(ctx context.Context) int64
}

// Runner performs backups.
type Runner struct {
	Cfg     *Config
	Stores  []Store
	Rec     Recorder
	DumpCmd string // default "pg_dump"
	Log     *slog.Logger
	Now     func() time.Time
	Backoff time.Duration // base retry delay (default 2s)
}

func (r *Runner) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *Runner) log() *slog.Logger {
	if r.Log != nil {
		return r.Log
	}
	return slog.Default()
}

func (r *Runner) scrub(s string) string { return Scrub(s, r.Cfg.DatabaseSecrets()) }

func retry(ctx context.Context, attempts int, base time.Duration, fn func() error) error {
	var err error
	for i := 0; i < attempts; i++ {
		if err = fn(); err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return err
		}
		if i < attempts-1 {
			select {
			case <-ctx.Done():
				return err
			case <-time.After(base << uint(i)):
			}
		}
	}
	return err
}

type limitedBuf struct {
	b bytes.Buffer
}

func (l *limitedBuf) Write(p []byte) (int, error) {
	if l.b.Len() < 4096 {
		l.b.Write(p)
	}
	return len(p), nil
}

type hashCount struct {
	w io.Writer
	h interface{ Write([]byte) (int, error) }
	n int64
}

func (c *hashCount) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.h.Write(p[:n])
	c.n += int64(n)
	return n, err
}

// pgEnv turns DATABASE_URL into libpq environment variables so the password
// never appears on a command line.
func pgEnv(databaseURL string) ([]string, error) {
	cc, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return nil, errors.New("DATABASE_URL is not valid")
	}
	env := []string{
		"PATH=" + os.Getenv("PATH"),
		"PGHOST=" + cc.Host, fmt.Sprintf("PGPORT=%d", cc.Port),
		"PGUSER=" + cc.User, "PGDATABASE=" + cc.Database, "PGCONNECT_TIMEOUT=30",
	}
	if cc.Password != "" {
		env = append(env, "PGPASSWORD="+cc.Password)
	}
	if u, err := url.Parse(databaseURL); err == nil {
		if m := u.Query().Get("sslmode"); m != "" {
			env = append(env, "PGSSLMODE="+m)
		}
	}
	return env, nil
}

// dump streams pg_dump through the encryptor into outPath and returns the size
// and SHA-256 of the bytes written (the ciphertext when encrypting). No
// plaintext ever touches the disk.
func (r *Runner) dump(ctx context.Context, outPath string, enc encryptFn) (size int64, sum string, err error) {
	env, err := pgEnv(r.Cfg.DatabaseURL)
	if err != nil {
		return 0, "", err
	}
	bin := r.DumpCmd
	if bin == "" {
		bin = "pg_dump"
	}
	f, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, "", err
	}
	defer f.Close()
	h := sha256.New()
	hc := &hashCount{w: f, h: h}
	ew, err := enc(hc)
	if err != nil {
		return 0, "", err
	}
	cmd := exec.CommandContext(ctx, bin, "--format=custom", "--no-owner")
	cmd.Env = env
	var stderr limitedBuf
	cmd.Stderr = &stderr
	cmd.Stdout = ew
	if err := cmd.Run(); err != nil {
		return 0, "", fmt.Errorf("pg_dump failed: %v: %s", err, strings.TrimSpace(stderr.b.String()))
	}
	if err := ew.Close(); err != nil {
		return 0, "", err
	}
	if err := f.Sync(); err != nil {
		return 0, "", err
	}
	if hc.n == 0 {
		return 0, "", errors.New("pg_dump produced an empty backup")
	}
	return hc.n, hex.EncodeToString(h.Sum(nil)), nil
}

func (r *Runner) pgDumpVersion(ctx context.Context) string {
	bin := r.DumpCmd
	if bin == "" {
		bin = "pg_dump"
	}
	out, err := exec.CommandContext(ctx, bin, "--version").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Run takes one backup and delivers it to every configured store. It records
// one backup_runs row per destination and prunes each destination that
// succeeded. The returned error is non-nil if any destination failed.
func (r *Runner) Run(ctx context.Context, trigger string) ([]RunRecord, error) {
	start := r.now()
	if len(r.Stores) == 0 {
		return nil, errors.New("no backup destination is configured (set BACKUP_S3_BUCKET and/or BACKUP_LOCAL_DIR)")
	}
	enc, mode, err := newEncryptor(r.Cfg)
	if err != nil {
		return nil, err
	}
	ts := start.UTC().Format(tsLayout)
	name := "openfamily-" + ts
	object := name + ".dump"
	if mode != EncNone {
		object += ".age"
	}
	if err := os.MkdirAll(r.Cfg.WorkDir, 0o700); err != nil {
		return nil, err
	}
	tmp := filepath.Join(r.Cfg.WorkDir, object+".partial")
	defer os.Remove(tmp)

	dumpStart := time.Now()
	size, sum, derr := r.dump(ctx, tmp, enc)
	if derr != nil {
		msg := r.scrub(derr.Error())
		var recs []RunRecord
		for _, st := range r.Stores {
			rec := RunRecord{Status: "failed", Destination: st.Kind(), Encrypted: mode != EncNone, Duration: time.Since(start), Error: msg, Trigger: trigger}
			recs = append(recs, rec)
			r.record(ctx, rec)
		}
		return recs, errors.New(msg)
	}
	r.log().Info("dump complete", "bytes", size, "encryption", mode, "took", time.Since(dumpStart).Round(time.Millisecond).String())

	man := Manifest{Format: 1, Name: name, Object: object, CreatedAt: start.UTC(), SizeBytes: size, SHA256: sum, Encryption: mode,
		PGDump: r.pgDumpVersion(ctx), SchemaVersion: r.schemaVersion(ctx), Service: r.Cfg.Version}
	mb, _ := json.MarshalIndent(man, "", "  ")

	var recs []RunRecord
	var failed []string
	for _, st := range r.Stores {
		t0 := time.Now()
		perr := retry(ctx, 3, r.backoff(), func() error {
			if err := st.PutFile(ctx, object, tmp); err != nil {
				return err
			}
			n, err := st.Size(ctx, object)
			if err != nil {
				return err
			}
			if n != size {
				return fmt.Errorf("uploaded object is %d bytes, expected %d", n, size)
			}
			return nil
		})
		if perr == nil {
			perr = retry(ctx, 3, r.backoff(), func() error { return st.Put(ctx, name+".manifest.json", mb) })
		}
		rec := RunRecord{Status: "success", Destination: st.Kind(), Encrypted: mode != EncNone, SizeBytes: size, Trigger: trigger,
			ObjectKey: st.Target() + "/" + object}
		if perr != nil {
			rec.Status, rec.SizeBytes = "failed", 0
			rec.Error = r.scrub(fmt.Sprintf("upload to %s failed: %v", st.Target(), perr))
			failed = append(failed, st.Kind())
		}
		rec.Duration = time.Since(start)
		_ = t0
		recs = append(recs, rec)
		r.record(ctx, rec)
		if perr != nil {
			r.log().Error("backup destination failed", "destination", st.Kind(), "error", rec.Error)
			continue
		}
		r.log().Info("backup stored", "destination", st.Kind(), "object", object, "bytes", size)
		if deleted, err := r.Prune(ctx, st, r.Cfg.Retention.DryRun); err != nil {
			r.log().Warn("retention pruning failed", "destination", st.Kind(), "error", r.scrub(err.Error()))
		} else if len(deleted) > 0 {
			r.log().Info("retention", "destination", st.Kind(), "dry_run", r.Cfg.Retention.DryRun, "removed", len(deleted))
		}
	}
	if len(failed) > 0 {
		return recs, fmt.Errorf("backup failed for: %s", strings.Join(failed, ", "))
	}
	return recs, nil
}

func (r *Runner) backoff() time.Duration {
	if r.Backoff > 0 {
		return r.Backoff
	}
	return 2 * time.Second
}

func (r *Runner) schemaVersion(ctx context.Context) int64 {
	if r.Rec == nil {
		return 0
	}
	return r.Rec.SchemaVersion(ctx)
}

func (r *Runner) record(ctx context.Context, rec RunRecord) {
	if r.Rec == nil {
		return
	}
	// The run context may already be cancelled (shutdown); still try to record.
	c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	if err := r.Rec.RecordRun(c, rec); err != nil {
		r.log().Warn("could not record backup run in the database", "error", r.scrub(err.Error()))
	}
}

// ListBackups returns the complete backups (those with a manifest) in a store.
func ListBackups(ctx context.Context, st Store) ([]Entry, map[string]Object, error) {
	objs, err := st.List(ctx)
	if err != nil {
		return nil, nil, err
	}
	var es []Entry
	byKey := map[string]Object{}
	for _, o := range objs {
		byKey[o.Key] = o
		m := manifestRe.FindStringSubmatch(o.Key)
		if m == nil {
			continue
		}
		t, err := time.Parse(tsLayout, m[2])
		if err != nil {
			continue
		}
		es = append(es, Entry{Name: m[1], Time: t})
	}
	sort.Slice(es, func(i, j int) bool { return es[i].Time.After(es[j].Time) })
	return es, byKey, nil
}

// Prune applies the retention policy to one store. It only ever touches
// objects named openfamily-<timestamp>.dump[.age] and their manifest, never
// the newest complete backup, and does nothing when all keep counts are 0.
// With dry set it reports what it would delete and deletes nothing.
func (r *Runner) Prune(ctx context.Context, st Store, dry bool) ([]string, error) {
	es, byKey, err := ListBackups(ctx, st)
	if err != nil {
		return nil, err
	}
	var removed []string
	for _, e := range SelectPrune(es, r.Cfg.Retention, r.Cfg.Location) {
		var keys []string
		for _, ext := range []string{".dump", ".dump.age"} {
			if _, ok := byKey[e.Name+ext]; ok && objectRe.MatchString(e.Name+ext) {
				keys = append(keys, e.Name+ext)
			}
		}
		keys = append(keys, e.Name+".manifest.json") // manifest last
		for _, k := range keys {
			if !dry {
				if err := st.Delete(ctx, k); err != nil {
					return removed, err
				}
			}
			removed = append(removed, k)
		}
		r.log().Info("retention: expired backup", "destination", st.Kind(), "name", e.Name, "dry_run", dry)
	}
	return removed, nil
}

// Fetch downloads a backup, verifies its SHA-256 and size against the
// manifest, and decrypts it to outPath (mode 0600). which is "latest", a
// backup name (openfamily-<timestamp>) or any of its object names.
func Fetch(ctx context.Context, st Store, which, outPath, identityFile, passphraseFile string) (*Manifest, error) {
	es, _, err := ListBackups(ctx, st)
	if err != nil {
		return nil, err
	}
	if len(es) == 0 {
		return nil, errors.New("no complete backups (with a manifest) found in " + st.Target())
	}
	name := es[0].Name
	if which != "" && which != "latest" {
		name = strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(filepath.Base(which), ".manifest.json"), ".age"), ".dump")
		found := false
		for _, e := range es {
			if e.Name == name {
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("backup %q has no manifest in %s", name, st.Target())
		}
	}
	rc, err := st.Get(ctx, name+".manifest.json")
	if err != nil {
		return nil, fmt.Errorf("cannot read manifest: %w", err)
	}
	var man Manifest
	err = json.NewDecoder(io.LimitReader(rc, 1<<20)).Decode(&man)
	rc.Close()
	if err != nil {
		return nil, errors.New("manifest is not valid JSON")
	}
	if man.Name != name || !objectRe.MatchString(man.Object) || !strings.HasPrefix(man.Object, name+".dump") || len(man.SHA256) != 64 {
		return nil, errors.New("manifest is inconsistent (name/object/sha256); refusing to use it")
	}
	if (man.Encryption == EncNone) != !strings.HasSuffix(man.Object, ".age") {
		return nil, errors.New("manifest encryption does not match the object name; refusing to use it")
	}

	dir := filepath.Dir(outPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	dl, err := os.CreateTemp(dir, ".dl-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(dl.Name())
	src, err := st.Get(ctx, man.Object)
	if err != nil {
		dl.Close()
		return nil, fmt.Errorf("cannot download %s: %w", man.Object, err)
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(dl, h), src)
	src.Close()
	if cerr := dl.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, fmt.Errorf("download failed: %w", err)
	}
	if n != man.SizeBytes || hex.EncodeToString(h.Sum(nil)) != man.SHA256 {
		return nil, fmt.Errorf("CHECKSUM MISMATCH for %s: the stored object does not match its manifest (corrupted or tampered); refusing to restore", man.Object)
	}
	tmpOut := outPath + ".partial"
	out, err := os.OpenFile(tmpOut, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	in, err := os.Open(dl.Name())
	if err != nil {
		out.Close()
		return nil, err
	}
	defer in.Close()
	if man.Encryption == EncNone {
		_, err = io.Copy(out, in)
	} else {
		err = Decrypt(out, in, identityFile, passphraseFile)
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmpOut)
		return nil, err
	}
	if err := os.Rename(tmpOut, outPath); err != nil {
		return nil, err
	}
	return &man, nil
}
