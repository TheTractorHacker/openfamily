package auth

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
	"strings"

	"golang.org/x/crypto/hkdf"
)

// DeriveKey returns a 32-byte subkey bound to purpose (HKDF-SHA256 over the
// JWT signing secret). Distinct purposes yield independent keys, so the TOTP
// encryption key, recovery-code MAC key and reset-code MAC key never equal
// the JWT key or each other. Rotating JWT_SECRET changes every derived key:
// see SealSecret for the consequence for stored TOTP secrets.
func (m *TokenManager) DeriveKey(purpose string) []byte {
	r := hkdf.New(sha256.New, m.secret, []byte("openfamily/v1"), []byte(purpose))
	k := make([]byte, 32)
	if _, err := io.ReadFull(r, k); err != nil {
		panic("hkdf: " + err.Error()) // unreachable: 32 bytes is far below the HKDF limit
	}
	return k
}

const sealedPrefix = "enc:v1:"

// SealSecret encrypts a TOTP secret with AES-256-GCM for storage. The output
// is "enc:v1:" + base64(nonce||ciphertext). Rotating JWT_SECRET makes sealed
// secrets undecryptable; affected users must re-enroll (an operator can clear
// users.totp_secret/totp_enabled).
func SealSecret(key []byte, plaintext string) (string, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	out := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return sealedPrefix + base64.RawStdEncoding.EncodeToString(out), nil
}

// OpenSecret reverses SealSecret. A value without the "enc:v1:" prefix is a
// legacy plaintext secret and is returned unchanged.
func OpenSecret(key []byte, stored string) (string, error) {
	if !strings.HasPrefix(stored, sealedPrefix) {
		return stored, nil
	}
	raw, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(stored, sealedPrefix))
	if err != nil {
		return "", err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize() {
		return "", errors.New("sealed secret too short")
	}
	pt, err := gcm.Open(nil, raw[:gcm.NonceSize()], raw[gcm.NonceSize():], nil)
	if err != nil {
		return "", errors.New("cannot decrypt secret")
	}
	return string(pt), nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// MACCode returns the hex HMAC-SHA256 of a normalized one-time code under
// key. One-time codes (recovery, password reset) are stored only in this form.
func MACCode(key []byte, code string) string {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(code))
	return base64.RawStdEncoding.EncodeToString(h.Sum(nil))
}

// codeAlphabet is Crockford-style base32 without I, L, O, U (no look-alikes).
const codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// RandomCode returns n random characters from the unambiguous alphabet.
func RandomCode(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = codeAlphabet[int(b[i])&31] // 256 % 32 == 0: no modulo bias
	}
	return string(b), nil
}

// NormalizeCode upper-cases a user-typed code and drops separators and
// spaces, mapping the usual look-alikes (O to 0, I/L to 1).
func NormalizeCode(s string) string {
	var sb strings.Builder
	for _, r := range strings.ToUpper(s) {
		switch {
		case r == '-' || r == ' ':
			continue
		case r == 'O':
			r = '0'
		case r == 'I' || r == 'L':
			r = '1'
		}
		sb.WriteRune(r)
	}
	return sb.String()
}

// FormatCode renders a code as groups of five for display (ABCDE-FGHJK).
func FormatCode(c string) string {
	var parts []string
	for len(c) > 5 {
		parts = append(parts, c[:5])
		c = c[5:]
	}
	parts = append(parts, c)
	return strings.Join(parts, "-")
}
