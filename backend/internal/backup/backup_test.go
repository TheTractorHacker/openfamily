package backup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestCronNext(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	c, err := ParseCron("15 3 * * *")
	if err != nil {
		t.Fatal(err)
	}
	got := c.Next(time.Date(2026, 11, 7, 3, 15, 0, 0, loc))
	if want := time.Date(2026, 11, 8, 3, 15, 0, 0, loc); !got.Equal(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if got := c.Next(time.Date(2026, 11, 7, 1, 0, 0, 0, loc)); got.Hour() != 3 || got.Day() != 7 {
		t.Fatalf("same-day next wrong: %v", got)
	}
	c2, _ := ParseCron("*/20 1-2 * * 1,3")
	n := c2.Next(time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)) // Saturday -> Monday 9th
	if n.Weekday() != time.Monday || n.Hour() != 1 || n.Minute() != 0 {
		t.Fatalf("got %v", n)
	}
	// DST spring forward (Berlin 2027-03-28 02:00 -> 03:00): 02:30 does not exist; next run is the following day.
	c3, _ := ParseCron("30 2 * * *")
	n = c3.Next(time.Date(2027, 3, 27, 12, 0, 0, 0, loc))
	if n.IsZero() || n.Before(time.Date(2027, 3, 27, 12, 0, 0, 0, loc)) {
		t.Fatalf("dst: %v", n)
	}
	for _, bad := range []string{"", "* * * *", "61 * * * *", "* 25 * * *", "a b c d e", "*/0 * * * *", "5-1 * * * *"} {
		if _, err := ParseCron(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestSelectPrune(t *testing.T) {
	loc := time.UTC
	var es []Entry
	base := time.Date(2026, 11, 7, 3, 0, 0, 0, time.UTC)
	for i := 0; i < 120; i++ { // daily for 120 days
		ts := base.AddDate(0, 0, -i)
		es = append(es, Entry{Name: "openfamily-" + ts.Format(tsLayout), Time: ts})
	}
	del := SelectPrune(es, Retention{Daily: 7, Weekly: 4, Monthly: 6}, loc)
	deleted := map[string]bool{}
	for _, d := range del {
		deleted[d.Name] = true
	}
	if deleted[es[0].Name] {
		t.Fatal("newest backup selected for deletion")
	}
	kept := len(es) - len(del)
	if kept < 7 || kept > 7+4+6 {
		t.Fatalf("kept %d, want between 7 and 17", kept)
	}
	for i := 0; i < 7; i++ {
		if deleted[es[i].Name] {
			t.Fatalf("one of the 7 newest daily backups (%d) deleted", i)
		}
	}
	if got := SelectPrune(es, Retention{}, loc); len(got) != 0 {
		t.Fatal("0/0/0 must keep everything")
	}
	if got := SelectPrune(es[:1], Retention{Daily: 1}, loc); len(got) != 0 {
		t.Fatal("single backup deleted")
	}
	// Even daily=1 keeps the newest.
	if d := SelectPrune(es, Retention{Daily: 1}, loc); len(d) != len(es)-1 {
		t.Fatalf("daily=1 deleted %d of %d", len(d), len(es))
	}
	// Unordered input gives the same answer.
	rev := make([]Entry, len(es))
	for i := range es {
		rev[len(es)-1-i] = es[i]
	}
	if a, b := SelectPrune(es, Retention{Daily: 7, Weekly: 4, Monthly: 6}, loc), SelectPrune(rev, Retention{Daily: 7, Weekly: 4, Monthly: 6}, loc); len(a) != len(b) {
		t.Fatal("order dependent")
	}
}

func TestConfigValidation(t *testing.T) {
	base := map[string]string{"BACKUP_S3_BUCKET": "b", "BACKUP_S3_ACCESS_KEY_ID": "AKIAEXAMPLE", "BACKUP_S3_SECRET_ACCESS_KEY": "s3cr3t-value-123"}
	with := func(kv ...string) func(string) string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return env(m)
	}
	_, pub, err := GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	priv, _, _ := GenerateKeyPair()

	if _, err := LoadConfig(with()); err == nil || !strings.Contains(err.Error(), "unencrypted") {
		t.Fatalf("unencrypted S3 must be refused: %v", err)
	}
	if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub)); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if _, err := LoadConfig(with("BACKUP_ALLOW_UNENCRYPTED", "true")); err != nil {
		t.Fatalf("explicit unencrypted rejected: %v", err)
	}
	_, err = LoadConfig(with("BACKUP_AGE_RECIPIENT", priv))
	if err == nil || strings.Contains(err.Error(), priv) {
		t.Fatalf("private key must be refused without echoing it: %v", err)
	}
	if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", "not-a-key")); err == nil {
		t.Fatal("garbage recipient accepted")
	}
	if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_S3_ENDPOINT", "http://minio:9000")); err == nil || !strings.Contains(err.Error(), "TLS") {
		t.Fatalf("plain http must need the insecure flag: %v", err)
	}
	c, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_S3_ENDPOINT", "http://minio:9000", "BACKUP_S3_INSECURE", "true"))
	if err != nil {
		t.Fatal(err)
	}
	if h, sec, _ := c.S3.hostAndTLS(); h != "minio:9000" || sec {
		t.Fatalf("insecure endpoint: %v %v", h, sec)
	}
	c, err = LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_S3_ENDPOINT", "https://s3.example.com", "BACKUP_S3_INSECURE", "true"))
	if err != nil {
		t.Fatal(err)
	}
	if h, sec, _ := c.S3.hostAndTLS(); h != "s3.example.com" || !sec {
		t.Fatalf("explicit https must never be downgraded by the insecure flag: %v %v", h, sec)
	}
	for _, ep := range []string{"https://user:pw@host", "ftp://host", "https://host/path"} {
		if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_S3_ENDPOINT", ep)); err == nil {
			t.Errorf("endpoint %q accepted", ep)
		}
	}
	if _, err := LoadConfig(env(map[string]string{"BACKUP_S3_BUCKET": "b"})); err == nil {
		t.Fatal("missing credentials accepted")
	}
	if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_SCHEDULE", "nope")); err == nil {
		t.Fatal("bad schedule accepted")
	}
	if _, err := LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_TZ", "Mars/Base")); err == nil {
		t.Fatal("bad tz accepted")
	}
	// Credentials via *_FILE.
	dir := t.TempDir()
	kf := filepath.Join(dir, "k")
	_ = os.WriteFile(kf, []byte("FILEKEYID\n"), 0o600)
	c, err = LoadConfig(with("BACKUP_AGE_RECIPIENT", pub, "BACKUP_S3_ACCESS_KEY_ID_FILE", kf))
	if err != nil || c.S3.AccessKeyID != "FILEKEYID" {
		t.Fatalf("file secret: %v", err)
	}
	// The summary never contains secrets.
	b := fmt.Sprintf("%+v", c.Summary())
	for _, s := range []string{"s3cr3t-value-123", "FILEKEYID", "AKIAEXAMPLE"} {
		if strings.Contains(b, s) {
			t.Fatalf("summary leaks %q", s)
		}
	}
}

func TestScrub(t *testing.T) {
	priv, _, _ := GenerateKeyPair()
	in := "failed: key=AKIAEXAMPLE secret=s3cr3t-value-123 " + priv + " postgres://u:hunter2pw@db:5432/x"
	out := Scrub(in, []string{"s3cr3t-value-123", "AKIAEXAMPLE"})
	for _, s := range []string{"s3cr3t-value-123", "AKIAEXAMPLE", priv, "hunter2pw"} {
		if strings.Contains(out, s) {
			t.Fatalf("scrub left %q in %q", s, out)
		}
	}
	if len(Scrub(strings.Repeat("x", 2000), nil)) > 504 {
		t.Fatal("not truncated")
	}
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	dir := t.TempDir()
	priv, pub, _ := GenerateKeyPair()
	idf := filepath.Join(dir, "id.txt")
	_ = os.WriteFile(idf, []byte("# comment\n"+priv+"\n"), 0o600)
	plain := bytes.Repeat([]byte("location history "), 100000)

	cfg := &Config{Recipients: []string{pub}}
	enc, mode, err := newEncryptor(cfg)
	if err != nil || mode != EncX25519 {
		t.Fatal(err, mode)
	}
	var ct bytes.Buffer
	w, _ := enc(&ct)
	_, _ = w.Write(plain)
	_ = w.Close()
	if bytes.Contains(ct.Bytes(), []byte("location history")) {
		t.Fatal("ciphertext contains plaintext")
	}
	var out bytes.Buffer
	if err := Decrypt(&out, bytes.NewReader(ct.Bytes()), idf, ""); err != nil || !bytes.Equal(out.Bytes(), plain) {
		t.Fatalf("round trip failed: %v", err)
	}
	// Wrong key.
	other, _, _ := GenerateKeyPair()
	of := filepath.Join(dir, "other.txt")
	_ = os.WriteFile(of, []byte(other), 0o600)
	if err := Decrypt(io.Discard, bytes.NewReader(ct.Bytes()), of, ""); err == nil {
		t.Fatal("wrong key accepted")
	}
	// Truncated / bit-flipped.
	if err := Decrypt(io.Discard, bytes.NewReader(ct.Bytes()[:ct.Len()-100]), idf, ""); err == nil {
		t.Fatal("truncated accepted")
	}
	flipped := append([]byte(nil), ct.Bytes()...)
	flipped[len(flipped)/2] ^= 1
	if err := Decrypt(io.Discard, bytes.NewReader(flipped), idf, ""); err == nil {
		t.Fatal("tampered accepted")
	}

	// Passphrase mode.
	pf := filepath.Join(dir, "pass")
	_ = os.WriteFile(pf, []byte("correct horse battery staple\n"), 0o600)
	enc, mode, err = newEncryptor(&Config{PassphraseFile: pf})
	if err != nil || mode != EncScrypt {
		t.Fatal(err, mode)
	}
	ct.Reset()
	w, _ = enc(&ct)
	_, _ = w.Write(plain[:1000])
	_ = w.Close()
	out.Reset()
	if err := Decrypt(&out, bytes.NewReader(ct.Bytes()), "", pf); err != nil || !bytes.Equal(out.Bytes(), plain[:1000]) {
		t.Fatalf("passphrase round trip: %v", err)
	}
	_ = os.WriteFile(pf, []byte("short"), 0o600)
	if _, _, err := newEncryptor(&Config{PassphraseFile: pf}); err == nil {
		t.Fatal("short passphrase accepted")
	}
}

type memRec struct {
	mu   sync.Mutex
	runs []RunRecord
}

func (m *memRec) RecordRun(_ context.Context, r RunRecord) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.runs = append(m.runs, r)
	return nil
}
func (m *memRec) SchemaVersion(context.Context) int64 { return 185 }

// flaky wraps a store and fails the first n PutFile calls.
type flaky struct {
	Store
	fails int
	calls int
}

func (f *flaky) PutFile(ctx context.Context, k, p string) error {
	f.calls++
	if f.calls <= f.fails {
		return errors.New("temporary failure with secret s3cr3t-value-123")
	}
	return f.Store.PutFile(ctx, k, p)
}

func fakePgDump(t *testing.T, payload string, exit int) string {
	p := filepath.Join(t.TempDir(), "pg_dump")
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'pg_dump (PostgreSQL) 16.0'; exit 0; fi\n" +
		"printf '%s' '" + payload + "'\necho \"boom $PGPASSWORD\" >&2\nexit " + fmt.Sprint(exit) + "\n"
	_ = os.WriteFile(p, []byte(script), 0o755)
	return p
}

func newRunner(t *testing.T, stores []Store, cfg *Config, dump string) (*Runner, *memRec) {
	rec := &memRec{}
	cfg.DatabaseURL = "postgres://u:dbpass-secret@db:5432/x?sslmode=disable"
	cfg.WorkDir = t.TempDir()
	cfg.Location = time.UTC
	return &Runner{Cfg: cfg, Stores: stores, Rec: rec, DumpCmd: dump, Backoff: time.Millisecond}, rec
}

func TestRunEncryptedTwoDestinationsAndFetch(t *testing.T) {
	ctx := context.Background()
	priv, pub, _ := GenerateKeyPair()
	idf := filepath.Join(t.TempDir(), "id")
	_ = os.WriteFile(idf, []byte(priv), 0o600)
	local := &DirStore{Dir: t.TempDir()}
	remote := &flaky{Store: &DirStore{Dir: t.TempDir()}, fails: 2} // succeeds on the 3rd attempt
	cfg := &Config{Recipients: []string{pub}, Retention: Retention{Daily: 7}}
	r, rec := newRunner(t, []Store{local, remote}, cfg, fakePgDump(t, "PGDMP-fake-dump-bytes", 0))
	recs, err := r.Run(ctx, "manual")
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 2 || remote.calls != 3 {
		t.Fatalf("recs=%d calls=%d", len(recs), remote.calls)
	}
	for _, x := range rec.runs {
		if x.Status != "success" || !x.Encrypted || x.SizeBytes == 0 || x.Trigger != "manual" || !strings.Contains(x.ObjectKey, ".dump.age") {
			t.Fatalf("bad record %+v", x)
		}
	}
	// Nothing in the stores holds the plaintext.
	objs, _ := local.List(ctx)
	if len(objs) != 2 {
		t.Fatalf("objects: %+v", objs)
	}
	for _, o := range objs {
		rc, _ := local.Get(ctx, o.Key)
		b, _ := io.ReadAll(rc)
		rc.Close()
		if bytes.Contains(b, []byte("PGDMP")) {
			t.Fatalf("%s contains plaintext", o.Key)
		}
	}
	out := filepath.Join(t.TempDir(), "out.dump")
	man, err := Fetch(ctx, local, "latest", out, idf, "")
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "PGDMP-fake-dump-bytes" {
		t.Fatalf("restored %q", b)
	}
	if st, _ := os.Stat(out); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if man.SchemaVersion != 185 || man.Encryption != EncX25519 || man.PGDump == "" {
		t.Fatalf("manifest %+v", man)
	}

	// Tamper with the stored object: checksum mismatch before any decrypt.
	p := filepath.Join(local.Dir, man.Object)
	b, _ := os.ReadFile(p)
	b[len(b)-1] ^= 1
	_ = os.WriteFile(p, b, 0o600)
	if _, err := Fetch(ctx, local, "latest", out+"2", idf, ""); err == nil || !strings.Contains(err.Error(), "CHECKSUM MISMATCH") {
		t.Fatalf("tamper not detected: %v", err)
	}
	if _, err := os.Stat(out + "2"); err == nil {
		t.Fatal("output left behind after failed fetch")
	}
	// Wrong key.
	other, _, _ := GenerateKeyPair()
	of := filepath.Join(t.TempDir(), "o")
	_ = os.WriteFile(of, []byte(other), 0o600)
	remote.calls = 100
	if _, err := Fetch(ctx, remote, "latest", out+"3", of, ""); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("wrong key: %v", err)
	}
}

func TestRunFailureIsRecordedAndScrubbed(t *testing.T) {
	ctx := context.Background()
	_, pub, _ := GenerateKeyPair()
	st := &DirStore{Dir: t.TempDir()}
	cfg := &Config{Recipients: []string{pub}, S3: &S3Config{SecretKey: "s3cr3t-value-123", AccessKeyID: "AKIAEXAMPLE"}}
	r, rec := newRunner(t, []Store{st}, cfg, fakePgDump(t, "partial", 1))
	if _, err := r.Run(ctx, "schedule"); err == nil {
		t.Fatal("pg_dump failure not reported")
	}
	if len(rec.runs) != 1 || rec.runs[0].Status != "failed" || rec.runs[0].Error == "" {
		t.Fatalf("%+v", rec.runs)
	}
	if strings.Contains(rec.runs[0].Error, "dbpass-secret") {
		t.Fatalf("db password leaked into run record: %s", rec.runs[0].Error)
	}
	objs, _ := st.List(ctx)
	if len(objs) != 0 {
		t.Fatalf("failed dump left objects: %+v", objs)
	}

	// Upload failure after all retries: failed record, secret scrubbed, no manifest.
	fl := &flaky{Store: st, fails: 99}
	r, rec = newRunner(t, []Store{fl}, cfg, fakePgDump(t, "ok-bytes", 0))
	if _, err := r.Run(ctx, "schedule"); err == nil {
		t.Fatal("expected failure")
	}
	if rec.runs[0].Status != "failed" || strings.Contains(rec.runs[0].Error, "s3cr3t-value-123") {
		t.Fatalf("%+v", rec.runs[0])
	}
}

func TestPruneKeepsNewestAndOnlyOurObjects(t *testing.T) {
	ctx := context.Background()
	st := &DirStore{Dir: t.TempDir()}
	base := time.Date(2026, 11, 7, 3, 0, 0, 0, time.UTC)
	for i := 0; i < 20; i++ {
		n := "openfamily-" + base.AddDate(0, 0, -i).Format(tsLayout)
		_ = st.Put(ctx, n+".dump.age", []byte("x"))
		_ = st.Put(ctx, n+".manifest.json", []byte("{}"))
	}
	_ = st.Put(ctx, "unrelated.txt", []byte("keep me"))
	_ = st.Put(ctx, "openfamily-20260101T000000Z.dump.enc", []byte("legacy local backup from scripts/backup.sh"))
	_ = st.Put(ctx, "openfamily-20250101T000000Z.dump.age", []byte("orphan without manifest"))
	r := &Runner{Cfg: &Config{Retention: Retention{Daily: 3}, Location: time.UTC}}

	dry, err := r.Prune(ctx, st, true)
	if err != nil || len(dry) != 2*17 {
		t.Fatalf("dry run: %v %d", err, len(dry))
	}
	if objs, _ := st.List(ctx); len(objs) != 20*2+3 {
		t.Fatalf("dry run deleted something: %d", len(objs))
	}
	del, err := r.Prune(ctx, st, false)
	if err != nil || len(del) != 34 {
		t.Fatalf("%v %d", err, len(del))
	}
	objs, _ := st.List(ctx)
	have := map[string]bool{}
	for _, o := range objs {
		have[o.Key] = true
	}
	newest := "openfamily-" + base.Format(tsLayout)
	for _, k := range []string{newest + ".dump.age", newest + ".manifest.json", "unrelated.txt", "openfamily-20260101T000000Z.dump.enc", "openfamily-20250101T000000Z.dump.age"} {
		if !have[k] {
			t.Errorf("%s was deleted", k)
		}
	}
	if len(objs) != 3*2+3 {
		t.Fatalf("remaining %d", len(objs))
	}
}

func TestProbeAndKeyValidation(t *testing.T) {
	ctx := context.Background()
	st := &DirStore{Dir: t.TempDir()}
	steps, err := Probe(ctx, st)
	if err != nil || len(steps) != 5 {
		t.Fatalf("%v %v", steps, err)
	}
	if objs, _ := st.List(ctx); len(objs) != 0 {
		t.Fatal("probe object left behind")
	}
	for _, k := range []string{"", "..", "a/b", "../x", `a\b`} {
		if _, err := st.Get(ctx, k); err == nil {
			t.Errorf("key %q accepted", k)
		}
	}
}
