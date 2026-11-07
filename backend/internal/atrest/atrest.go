// Package atrest protects a small set of SECRET columns in the database with
// envelope encryption (see docs/design/PRIVACY_PROCESSING.md section 21).
//
//   - A random 256-bit data key (DEK) encrypts the values (AES-256-GCM).
//   - The DEK is stored in the database only WRAPPED (AES-256-GCM) by a key
//     encryption key (KEK) derived from OPENFAMILY_DATA_KEY (env) or
//     OPENFAMILY_DATA_KEY_FILE. The KEK never touches the database.
//   - A stolen disk, volume snapshot or SQL dump therefore holds only
//     ciphertext for these columns; the running server can still use them.
//
// What this does NOT do: it does not encrypt locations, positions, trips or
// history. Those must stay queryable by PostGIS and TimescaleDB while the
// server runs (geofences, nearby, history maps, trip detection), so a process
// with the key, or a database administrator on the live server, sees them.
package atrest

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"

	"golang.org/x/crypto/hkdf"
)

// Prefix marks a sealed value. A value without it is legacy plaintext.
const Prefix = "ofenc1:"


// ErrNoKey means a sealed value was met but no usable data key is loaded.
var ErrNoKey = errors.New("a protected value needs OPENFAMILY_DATA_KEY, which is not set or is wrong")

// Keyring holds the unwrapped DEK. The zero value (or nil) is "off": Seal
// returns its input, Open only accepts plaintext.
type Keyring struct {
	dek []byte
}

var (
	mu      sync.RWMutex
	current *Keyring
)

// SetDefault installs the process-wide keyring (nil switches protection off).
func SetDefault(k *Keyring) { mu.Lock(); current = k; mu.Unlock() }

// Default returns the process-wide keyring (possibly nil).
func Default() *Keyring { mu.RLock(); defer mu.RUnlock(); return current }

// Enabled reports whether new values are sealed.
func Enabled() bool { return Default() != nil }

// Seal encrypts v bound to label (for example "dawarich_settings.api_key") so a
// sealed value cannot be moved to another column. Empty values and a disabled
// keyring return v unchanged. Already sealed values are not sealed twice.
func Seal(label, v string) (string, error) { return Default().Seal(label, v) }

// Open reverses Seal. Plaintext (legacy) values pass through.
func Open(label, v string) (string, error) { return Default().Open(label, v) }

func (k *Keyring) Seal(label, v string) (string, error) {
	if k == nil || v == "" || strings.HasPrefix(v, Prefix) {
		return v, nil
	}
	return Prefix + b64(sealBytes(k.dek, []byte(v), []byte(label))), nil
}

func (k *Keyring) Open(label, v string) (string, error) {
	if !strings.HasPrefix(v, Prefix) {
		return v, nil
	}
	if k == nil {
		return "", ErrNoKey
	}
	raw, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(v, Prefix))
	if err != nil {
		return "", errors.New("protected value is malformed")
	}
	pt, err := openBytes(k.dek, raw, []byte(label))
	if err != nil {
		return "", errors.New("protected value cannot be decrypted (wrong data key or moved value)")
	}
	return string(pt), nil
}

func b64(b []byte) string { return base64.RawStdEncoding.EncodeToString(b) }

func gcm(key []byte) cipher.AEAD {
	b, err := aes.NewCipher(key)
	if err != nil {
		panic("atrest: " + err.Error()) // key length is checked by every caller
	}
	g, err := cipher.NewGCM(b)
	if err != nil {
		panic("atrest: " + err.Error())
	}
	return g
}

func sealBytes(key, pt, aad []byte) []byte {
	g := gcm(key)
	nonce := make([]byte, g.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic("atrest: no randomness: " + err.Error())
	}
	return g.Seal(nonce, nonce, pt, aad)
}

func openBytes(key, raw, aad []byte) ([]byte, error) {
	g := gcm(key)
	if len(raw) < g.NonceSize()+g.Overhead() {
		return nil, errors.New("short")
	}
	return g.Open(nil, raw[:g.NonceSize()], raw[g.NonceSize():], aad)
}

// DeriveKEK turns the operator's secret into the 32-byte wrapping key. The
// secret must be at least 32 characters (use `openssl rand -base64 32`).
func DeriveKEK(secret string) ([]byte, error) {
	secret = strings.TrimSpace(secret)
	if len(secret) < 32 {
		return nil, errors.New("OPENFAMILY_DATA_KEY must be at least 32 characters (generate one with: openssl rand -base64 32)")
	}
	r := hkdf.New(sha256.New, []byte(secret), []byte("openfamily/at-rest/v1"), []byte("kek"))
	k := make([]byte, 32)
	if _, err := io.ReadFull(r, k); err != nil {
		return nil, err
	}
	return k, nil
}

// EnvSecret returns the configured data key (file wins), or "" when unset.
func EnvSecret() (string, error) {
	if f := strings.TrimSpace(os.Getenv("OPENFAMILY_DATA_KEY_FILE")); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", fmt.Errorf("OPENFAMILY_DATA_KEY_FILE: %w", err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return strings.TrimSpace(os.Getenv("OPENFAMILY_DATA_KEY")), nil
}

const kekCheckAAD = "openfamily/at-rest/dek"

// Wrap encrypts a DEK with the KEK.
func Wrap(kek, dek []byte) []byte { return sealBytes(kek, dek, []byte(kekCheckAAD)) }

// Unwrap reverses Wrap; an error means the data key is wrong.
func Unwrap(kek, wrapped []byte) ([]byte, error) {
	dek, err := openBytes(kek, wrapped, []byte(kekCheckAAD))
	if err != nil || len(dek) != 32 {
		return nil, errors.New("the data key does not open the stored data key (wrong OPENFAMILY_DATA_KEY?)")
	}
	return dek, nil
}

// NewKeyring builds a keyring from a raw DEK (tests and Load).
func NewKeyring(dek []byte) *Keyring { return &Keyring{dek: append([]byte(nil), dek...)} }

// NewDEK returns a fresh random data key.
func NewDEK() []byte {
	d := make([]byte, 32)
	if _, err := rand.Read(d); err != nil {
		panic("atrest: no randomness: " + err.Error())
	}
	return d
}
