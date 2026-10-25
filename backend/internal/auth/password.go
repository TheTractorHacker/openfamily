// Package auth implements password hashing, JWT tokens, and TOTP.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"runtime"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters. These are reasonable defaults for a self-hosted service.
const (
	argonTime    = 1
	argonMemory  = 64 * 1024 // 64 MiB
	argonThreads = 4
	argonKeyLen  = 32
	argonSaltLen = 16
)

// MaxPasswordLength bounds accepted passwords (bytes). Longer input adds no
// strength and only feeds the hash function attacker-chosen volume.
const MaxPasswordLength = 256

// argonSlots bounds concurrent Argon2 computations: each holds 64 MiB, so an
// unbounded burst of logins/registrations could exhaust memory.
var argonSlots = make(chan struct{}, max(2, runtime.NumCPU()))

func argonIDKey(password, salt []byte, t, m uint32, p uint8, keyLen uint32) []byte {
	argonSlots <- struct{}{}
	defer func() { <-argonSlots }()
	return argon2.IDKey(password, salt, t, m, p, keyLen)
}

// ErrInvalidPassword is returned when a password does not match its hash.
var ErrInvalidPassword = errors.New("invalid password")

// HashPassword hashes a plaintext password with Argon2id and returns an
// encoded string of the form: $argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>.
func HashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("generate salt: %w", err)
	}

	hash := argonIDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)

	return fmt.Sprintf(
		"$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version,
		argonMemory,
		argonTime,
		argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(hash),
	), nil
}

// VerifyPassword checks a plaintext password against an encoded Argon2id hash.
func VerifyPassword(password, encoded string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 {
		return false, fmt.Errorf("malformed password hash")
	}

	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return false, fmt.Errorf("parse version: %w", err)
	}
	if version != argon2.Version {
		return false, fmt.Errorf("unsupported argon2 version %d", version)
	}

	var memory uint32
	var time uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &time, &threads); err != nil {
		return false, fmt.Errorf("parse params: %w", err)
	}

	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false, fmt.Errorf("decode salt: %w", err)
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false, fmt.Errorf("decode hash: %w", err)
	}

	actual := argonIDKey([]byte(password), salt, time, memory, threads, uint32(len(expected)))

	if subtle.ConstantTimeCompare(actual, expected) != 1 {
		return false, ErrInvalidPassword
	}
	return true, nil
}
