package backup

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"filippo.io/age"
)

const (
	EncX25519 = "age-x25519"
	EncScrypt = "age-scrypt"
	EncNone   = "none"
)

// encryptFn wraps dst so everything written to the returned writer is age
// encrypted; Close must be called to finish the stream.
type encryptFn func(dst io.Writer) (io.WriteCloser, error)

// newEncryptor builds the encryption step from the config. Only public key
// material (recipients) or an operator-supplied passphrase file is ever read;
// an age private key is never needed, read, or logged by the backup service.
func newEncryptor(c *Config) (encryptFn, string, error) {
	switch {
	case len(c.Recipients) > 0:
		var rs []age.Recipient
		for _, s := range c.Recipients {
			if strings.HasPrefix(s, "AGE-SECRET-KEY-") {
				// Never echo the value.
				return nil, "", errors.New("BACKUP_AGE_RECIPIENT contains a PRIVATE key (AGE-SECRET-KEY-...); supply only the public key (age1...) and keep the private key off the server")
			}
			r, err := age.ParseX25519Recipient(s)
			if err != nil {
				return nil, "", errors.New("BACKUP_AGE_RECIPIENT is not a valid age public key (expected age1...)")
			}
			rs = append(rs, r)
		}
		return func(dst io.Writer) (io.WriteCloser, error) { return age.Encrypt(dst, rs...) }, EncX25519, nil
	case c.PassphraseFile != "":
		pass, err := readFileTrim(c.PassphraseFile)
		if err != nil {
			return nil, "", errors.New("BACKUP_AGE_PASSPHRASE_FILE: cannot read file")
		}
		if len(pass) < 12 {
			return nil, "", errors.New("BACKUP_AGE_PASSPHRASE_FILE: passphrase must be at least 12 characters (use a long random one)")
		}
		r, err := age.NewScryptRecipient(pass)
		if err != nil {
			return nil, "", err
		}
		return func(dst io.Writer) (io.WriteCloser, error) { return age.Encrypt(dst, r) }, EncScrypt, nil
	}
	return func(dst io.Writer) (io.WriteCloser, error) { return nopWriteCloser{dst}, nil }, EncNone, nil
}

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }

// GenerateKeyPair returns a fresh age identity (private) and its recipient
// (public). The caller decides where the private key goes; it must stay with
// the owner, not on the server.
func GenerateKeyPair() (private, public string, err error) {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		return "", "", err
	}
	return id.String(), id.Recipient().String(), nil
}

// Decrypt reads an age stream from src using either an identity file
// (AGE-SECRET-KEY-... lines) or a passphrase file, and writes plaintext to dst.
func Decrypt(dst io.Writer, src io.Reader, identityFile, passphraseFile string) error {
	var ids []age.Identity
	switch {
	case identityFile != "":
		f, err := os.Open(identityFile)
		if err != nil {
			return errors.New("cannot read the identity file")
		}
		defer f.Close()
		parsed, err := age.ParseIdentities(f)
		if err != nil {
			return errors.New("the identity file is not a valid age identity file")
		}
		ids = parsed
	case passphraseFile != "":
		pass, err := readFileTrim(passphraseFile)
		if err != nil {
			return errors.New("cannot read the passphrase file")
		}
		id, err := age.NewScryptIdentity(pass)
		if err != nil {
			return err
		}
		ids = []age.Identity{id}
	default:
		return errors.New("an identity file (BACKUP_AGE_IDENTITY_FILE) or passphrase file (BACKUP_AGE_PASSPHRASE_FILE) is required to decrypt")
	}
	r, err := age.Decrypt(bufio.NewReaderSize(src, 1<<20), ids...)
	if err != nil {
		var nm *age.NoIdentityMatchError
		if errors.As(err, &nm) {
			return errors.New("decryption failed: the key/passphrase does not match this backup")
		}
		return fmt.Errorf("decryption failed: %w", err)
	}
	if _, err := io.Copy(dst, r); err != nil {
		return fmt.Errorf("decryption failed (corrupt or truncated backup): %w", err)
	}
	return nil
}
