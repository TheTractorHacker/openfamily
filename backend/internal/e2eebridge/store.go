package e2eebridge

// On-disk state: a 0700 directory with 0600 files, written atomically. Secrets
// (identity seed, circle keys, refresh token) are optionally sealed with a
// passphrase (Argon2id + XChaCha20-Poly1305). Nothing here logs secrets.

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
)

// Argon2id parameters for new sealed files (stored in each file, so tests and
// future versions can change them). 64 MiB, 3 passes, 1 lane.
var (
	kdfMemKiB uint32 = 64 * 1024
	kdfTime   uint32 = 3
)

const (
	fileIdentity = "identity.json"
	fileKeys     = "circlekeys.json"
	fileSession  = "session.json"
	fileState    = "state.json"
)

var (
	errLocked   = errors.New("the state is encrypted: set E2EE_BRIDGE_PASSPHRASE (or --passphrase-file)")
	errBadPass  = errors.New("wrong passphrase or corrupted state file")
	errNotFound = errors.New("not found")
)

// sealedBlob is a passphrase-sealed payload.
type sealedBlob struct {
	KDF   string `json:"kdf"`
	Mem   uint32 `json:"m"`
	Time  uint32 `json:"t"`
	Lanes uint8  `json:"p"`
	Salt  string `json:"salt"`
	Nonce string `json:"nonce"`
	CT    string `json:"ct"`
}

// box holds a secret either in the clear (no passphrase configured) or sealed.
type box struct {
	Plain  json.RawMessage `json:"plain,omitempty"`
	Sealed *sealedBlob     `json:"sealed,omitempty"`
}

type store struct {
	dir  string
	pass []byte

	mu    sync.Mutex
	keys  map[string][]byte // salt (raw string) -> derived key; Argon2 runs once per salt
	salts map[string][]byte // file label -> salt in use, so a rewrite reuses the cached key
}

func openStore(dir string, pass []byte) (*store, error) {
	if dir == "" {
		return nil, errors.New("no state directory")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	return &store{dir: dir, pass: pass, keys: map[string][]byte{}, salts: map[string][]byte{}}, nil
}

func (s *store) path(name string) string { return filepath.Join(s.dir, name) }

func (s *store) derive(salt []byte, mem, t uint32, lanes uint8) []byte {
	ck := fmt.Sprintf("%x/%d/%d/%d", salt, mem, t, lanes)
	s.mu.Lock()
	defer s.mu.Unlock()
	if k, ok := s.keys[ck]; ok {
		return k
	}
	k := argon2.IDKey(s.pass, salt, t, mem, lanes, 32)
	s.keys[ck] = k
	return k
}

// seal wraps plain for the file `label` (the label is the AAD, so a sealed
// blob cannot be moved between files).
func (s *store) seal(label string, plain []byte) (box, error) {
	if len(s.pass) == 0 {
		return box{Plain: json.RawMessage(plain)}, nil
	}
	s.mu.Lock()
	salt := s.salts[label]
	if salt == nil {
		salt = make([]byte, 16)
		if _, err := io.ReadFull(rand.Reader, salt); err != nil {
			s.mu.Unlock()
			return box{}, err
		}
		s.salts[label] = salt
	}
	s.mu.Unlock()
	key := s.derive(salt, kdfMemKiB, kdfTime, 1)
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return box{}, err
	}
	nonce := make([]byte, chacha20poly1305.NonceSizeX)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return box{}, err
	}
	ct := aead.Seal(nil, nonce, plain, []byte("e2ee-bridge/"+label))
	e := base64.StdEncoding.EncodeToString
	return box{Sealed: &sealedBlob{KDF: "argon2id", Mem: kdfMemKiB, Time: kdfTime, Lanes: 1,
		Salt: e(salt), Nonce: e(nonce), CT: e(ct)}}, nil
}

func (s *store) open(label string, b box) ([]byte, error) {
	if b.Sealed == nil {
		if b.Plain == nil {
			return nil, errBadPass
		}
		return []byte(b.Plain), nil
	}
	if len(s.pass) == 0 {
		return nil, errLocked
	}
	d := base64.StdEncoding.DecodeString
	salt, e1 := d(b.Sealed.Salt)
	nonce, e2 := d(b.Sealed.Nonce)
	ct, e3 := d(b.Sealed.CT)
	if err := errors.Join(e1, e2, e3); err != nil || b.Sealed.KDF != "argon2id" || len(nonce) != chacha20poly1305.NonceSizeX ||
		b.Sealed.Mem > 1<<20 || b.Sealed.Time > 20 || b.Sealed.Lanes == 0 {
		return nil, errBadPass
	}
	key := s.derive(salt, b.Sealed.Mem, b.Sealed.Time, b.Sealed.Lanes)
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	pt, err := aead.Open(nil, nonce, ct, []byte("e2ee-bridge/"+label))
	if err != nil {
		return nil, errBadPass
	}
	s.mu.Lock()
	s.salts[label] = salt
	s.mu.Unlock()
	return pt, nil
}

// writeAtomic writes data to name with mode 0600: temp file in the same
// directory, fsync, rename, fsync of the directory.
func (s *store) writeAtomic(name string, data []byte) error {
	tmp, err := os.CreateTemp(s.dir, "."+name+".tmp*")
	if err != nil {
		return err
	}
	tn := tmp.Name()
	cleanup := func() { _ = os.Remove(tn) }
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tn, s.path(name)); err != nil {
		cleanup()
		return err
	}
	if d, err := os.Open(s.dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

func (s *store) readFile(name string) ([]byte, error) {
	b, err := os.ReadFile(s.path(name))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, errNotFound
	}
	return b, err
}

func (s *store) exists(name string) bool {
	_, err := os.Stat(s.path(name))
	return err == nil
}

func (s *store) remove(name string) { _ = os.Remove(s.path(name)) }

// writeJSON stores v as plain JSON (non-secret files).
func (s *store) writeJSON(name string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return s.writeAtomic(name, b)
}

func (s *store) readJSON(name string, v any) error {
	b, err := s.readFile(name)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// writeSecret stores v sealed (when a passphrase is set) in a box file.
func (s *store) writeSecret(name string, v any) error {
	plain, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b, err := s.seal(name, plain)
	if err != nil {
		return err
	}
	return s.writeJSON(name, b)
}

func (s *store) readSecret(name string, v any) error {
	var b box
	if err := s.readJSON(name, &b); err != nil {
		return err
	}
	pt, err := s.open(name, b)
	if err != nil {
		return err
	}
	return json.Unmarshal(pt, v)
}
