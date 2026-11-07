package backupsettings

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"

	"golang.org/x/crypto/hkdf"
)

const kdfInfo = "openfamily/backup-settings/v1"
const aad = "openfamily:backup_settings:credentials:v1"

// DeriveKey derives the 32-byte envelope key from a server secret with HKDF-
// SHA256 and a label distinct from any other use of that secret. The API and
// the backup service must be given the same input secret.
func DeriveKey(secret string) ([]byte, error) {
	if len(secret) < 16 {
		return nil, errors.New("settings key secret must be at least 16 characters")
	}
	k := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, []byte(secret), nil, []byte(kdfInfo)), k); err != nil {
		return nil, err
	}
	return k, nil
}

// Seal encrypts credentials with AES-256-GCM (random nonce, bound to this table
// column through the AAD). Format: 0x01 || nonce(12) || ciphertext.
func Seal(key []byte, c Credentials) ([]byte, error) {
	pt, _ := json.Marshal(c)
	return sealWith(key, aad, pt)
}

// SealPayload / OpenPayload protect the transient "test unsaved settings"
// request payload; a different AAD keeps the two uses from being swapped.
func SealPayload(key, pt []byte) ([]byte, error)   { return sealWith(key, aadPayload, pt) }
func OpenPayload(key, blob []byte) ([]byte, error) { return openWith(key, aadPayload, blob) }

const aadPayload = "openfamily:backup_requests:payload:v1"

func sealWith(key []byte, aad string, pt []byte) ([]byte, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	g, err := cipher.NewGCM(blk)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, g.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return append(append([]byte{1}, nonce...), g.Seal(nil, nonce, pt, []byte(aad))...), nil
}

// Open decrypts what Seal produced. The error never contains key material.
func Open(key, blob []byte) (*Credentials, error) {
	pt, err := openWith(key, aad, blob)
	if err != nil {
		return nil, err
	}
	var c Credentials
	if err := json.Unmarshal(pt, &c); err != nil {
		return nil, errors.New("stored credentials are unreadable")
	}
	return &c, nil
}

func openWith(key []byte, aad string, blob []byte) ([]byte, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	g, err := cipher.NewGCM(blk)
	if err != nil {
		return nil, err
	}
	if len(blob) < 1+g.NonceSize()+g.Overhead() || blob[0] != 1 {
		return nil, errors.New("stored credentials are unreadable")
	}
	pt, err := g.Open(nil, blob[1:1+g.NonceSize()], blob[1+g.NonceSize():], []byte(aad))
	if err != nil {
		return nil, errors.New("stored credentials cannot be decrypted with the current key (was BACKUP_SETTINGS_KEY or JWT_SECRET changed?); enter them again")
	}
	return pt, nil
}
