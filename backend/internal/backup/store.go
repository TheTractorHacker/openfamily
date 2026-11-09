package backup

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Object is a stored file. Key is relative to the store root.
type Object struct {
	Key      string
	Size     int64
	Modified time.Time
}

// Store is a place backups can be written to and read back from.
type Store interface {
	Kind() string   // "local" | "s3"
	Target() string // human description, never contains credentials
	PutFile(ctx context.Context, key, filePath string) error
	Put(ctx context.Context, key string, data []byte) error
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Size(ctx context.Context, key string) (int64, error)
	List(ctx context.Context) ([]Object, error)
	Delete(ctx context.Context, key string) error
}

func validKey(key string) error {
	if key == "" || strings.ContainsAny(key, "/\\") || key == "." || key == ".." || strings.Contains(key, "\x00") {
		return errors.New("invalid object name")
	}
	return nil
}

// ---------------------------------------------------------------- local dir

// DirStore keeps backups in a flat directory (mode 0700 / files 0600).
type DirStore struct{ Dir string }

func (d *DirStore) Kind() string   { return "local" }
func (d *DirStore) Target() string { return d.Dir }

func (d *DirStore) path(key string) (string, error) {
	if err := validKey(key); err != nil {
		return "", err
	}
	return filepath.Join(d.Dir, key), nil
}

// explain turns "permission denied" on the backup folder into the fix. The
// usual cause: Docker created ./backups as root because it did not exist.
func (d *DirStore) explain(err error) error {
	if !errors.Is(err, fs.ErrPermission) {
		return err
	}
	return fmt.Errorf("the backup folder %s is not writable by the backup service (user %d): on the server run "+
		"`mkdir -p backups && sudo chown %d:%d backups` next to docker-compose.yml, or set BACKUP_UID/BACKUP_GID in .env "+
		"to the folder's owner, then docker compose up -d", d.Dir, os.Getuid(), os.Getuid(), os.Getgid())
}

func (d *DirStore) PutFile(ctx context.Context, key, filePath string) error {
	dst, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(d.Dir, 0o700); err != nil {
		return d.explain(err)
	}
	in, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".partial"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return d.explain(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func (d *DirStore) Put(ctx context.Context, key string, data []byte) error {
	p, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(d.Dir, 0o700); err != nil {
		return err
	}
	tmp := p + ".partial"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func (d *DirStore) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	p, err := d.path(key)
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

func (d *DirStore) Size(ctx context.Context, key string) (int64, error) {
	p, err := d.path(key)
	if err != nil {
		return 0, err
	}
	st, err := os.Stat(p)
	if err != nil {
		return 0, err
	}
	return st.Size(), nil
}

func (d *DirStore) List(ctx context.Context) ([]Object, error) {
	ents, err := os.ReadDir(d.Dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []Object
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, Object{Key: e.Name(), Size: info.Size(), Modified: info.ModTime()})
	}
	return out, nil
}

func (d *DirStore) Delete(ctx context.Context, key string) error {
	p, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// ---------------------------------------------------------------------- S3

// S3Store talks to any S3-compatible service (AWS S3, Backblaze B2, Wasabi,
// Cloudflare R2, MinIO, ...) through minio-go, which handles SigV4, multipart
// uploads and per-request retries.
type S3Store struct {
	cfg *S3Config
	cl  *minio.Client
}

// PartSize is the multipart part size. 16 MiB keeps a 160 GB dump under the
// 10,000-part S3 limit; minio-go grows it automatically for larger objects.
const PartSize = 16 << 20

func NewS3Store(cfg *S3Config) (*S3Store, error) {
	host, secure, err := cfg.hostAndTLS()
	if err != nil {
		return nil, err
	}
	lookup := minio.BucketLookupAuto
	if cfg.PathStyle {
		lookup = minio.BucketLookupPath
	}
	// Every connection is re-checked after DNS resolution: link-local/metadata
	// addresses are always refused, private ones unless allowed.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second,
		Control: backupsettings.GuardedDialControl(cfg.AllowPrivate)}).DialContext
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	cl, err := minio.New(host, &minio.Options{
		Transport:    tr,
		Creds:        credentials.NewStaticV4(cfg.AccessKeyID, cfg.SecretKey, ""),
		Secure:       secure,
		Region:       cfg.Region,
		BucketLookup: lookup,
		MaxRetries:   5,
	})
	if err != nil {
		return nil, errors.New("invalid S3 configuration")
	}
	return &S3Store{cfg: cfg, cl: cl}, nil
}

func (s *S3Store) Kind() string { return "s3" }
func (s *S3Store) Target() string {
	t := "s3://" + s.cfg.Bucket
	if s.cfg.Prefix != "" {
		t += "/" + s.cfg.Prefix
	}
	return t
}

func (s *S3Store) full(key string) (string, error) {
	if err := validKey(key); err != nil {
		return "", err
	}
	if s.cfg.Prefix == "" {
		return key, nil
	}
	return s.cfg.Prefix + "/" + key, nil
}

func (s *S3Store) PutFile(ctx context.Context, key, filePath string) error {
	k, err := s.full(key)
	if err != nil {
		return err
	}
	f, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	_, err = s.cl.PutObject(ctx, s.cfg.Bucket, k, f, st.Size(), minio.PutObjectOptions{
		ContentType:  "application/octet-stream",
		StorageClass: s.cfg.StorageClass,
		PartSize:     PartSize,
	})
	return err
}

func (s *S3Store) Put(ctx context.Context, key string, data []byte) error {
	k, err := s.full(key)
	if err != nil {
		return err
	}
	_, err = s.cl.PutObject(ctx, s.cfg.Bucket, k, bytes.NewReader(data), int64(len(data)), minio.PutObjectOptions{
		ContentType:  "application/json",
		StorageClass: s.cfg.StorageClass,
	})
	return err
}

func (s *S3Store) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	k, err := s.full(key)
	if err != nil {
		return nil, err
	}
	o, err := s.cl.GetObject(ctx, s.cfg.Bucket, k, minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	// GetObject is lazy; surface "not found"/"forbidden" now.
	if _, err := o.Stat(); err != nil {
		o.Close()
		return nil, err
	}
	return o, nil
}

func (s *S3Store) Size(ctx context.Context, key string) (int64, error) {
	k, err := s.full(key)
	if err != nil {
		return 0, err
	}
	st, err := s.cl.StatObject(ctx, s.cfg.Bucket, k, minio.StatObjectOptions{})
	if err != nil {
		return 0, err
	}
	return st.Size, nil
}

func (s *S3Store) List(ctx context.Context) ([]Object, error) {
	prefix := ""
	if s.cfg.Prefix != "" {
		prefix = s.cfg.Prefix + "/"
	}
	var out []Object
	for o := range s.cl.ListObjects(ctx, s.cfg.Bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: false}) {
		if o.Err != nil {
			return nil, o.Err
		}
		rel := strings.TrimPrefix(o.Key, prefix)
		if rel == "" || strings.Contains(rel, "/") {
			continue
		}
		out = append(out, Object{Key: rel, Size: o.Size, Modified: o.LastModified})
	}
	return out, nil
}

func (s *S3Store) Delete(ctx context.Context, key string) error {
	k, err := s.full(key)
	if err != nil {
		return err
	}
	return s.cl.RemoveObject(ctx, s.cfg.Bucket, k, minio.RemoveObjectOptions{})
}

// ------------------------------------------------------------------- probe

// Probe exercises exactly the permissions a backup needs: list, write, read,
// stat and delete of one small throw-away object under the configured prefix.
// It returns one line per step so the admin panel can show what failed.
func Probe(ctx context.Context, st Store) (steps []string, err error) {
	var rnd [6]byte
	_, _ = rand.Read(rnd[:])
	key := ".openfamily-probe-" + hex.EncodeToString(rnd[:])
	payload := []byte("openfamily backup connection test " + time.Now().UTC().Format(time.RFC3339))
	step := func(name string, e error) error {
		if e != nil {
			steps = append(steps, name+": FAILED")
			return fmt.Errorf("%s failed: %w", name, e)
		}
		steps = append(steps, name+": ok")
		return nil
	}
	if err = step("list", func() error { _, e := st.List(ctx); return e }()); err != nil {
		return
	}
	if err = step("write", st.Put(ctx, key, payload)); err != nil {
		return
	}
	// From here on always try to remove the probe object.
	defer func() {
		if derr := st.Delete(ctx, key); derr != nil {
			steps = append(steps, "delete: FAILED")
			if err == nil {
				err = fmt.Errorf("delete failed (the probe object %s was left behind): %w", key, derr)
			}
		} else {
			steps = append(steps, "delete: ok")
		}
	}()
	if err = step("stat", func() error {
		n, e := st.Size(ctx, key)
		if e == nil && n != int64(len(payload)) {
			e = errors.New("size mismatch")
		}
		return e
	}()); err != nil {
		return
	}
	err = step("read", func() error {
		rc, e := st.Get(ctx, key)
		if e != nil {
			return e
		}
		defer rc.Close()
		b, e := io.ReadAll(io.LimitReader(rc, 1<<16))
		if e != nil {
			return e
		}
		if !bytes.Equal(b, payload) {
			return errors.New("content mismatch")
		}
		return nil
	}())
	return
}
