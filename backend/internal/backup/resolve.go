package backup

import (
	"errors"
	"strings"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

// ResolveConfig builds the effective configuration: real environment variables
// win (they "pin" a setting and make it read-only in the UI); anything the
// environment leaves unset comes from the settings saved in the admin UI; the
// rest falls back to built-in defaults. All guards of LoadConfig still apply
// (TLS, no unencrypted S3 upload, no private key as recipient, address policy).
func ResolveConfig(getenv func(string) string, st *backupsettings.Stored) (*Config, error) {
	overlay := map[string]string{}
	if st != nil && st.Exists {
		overlay = backupsettings.Overlay(st.Settings, st.Creds)
	}
	envCreds := false
	for _, k := range []string{"BACKUP_S3_ACCESS_KEY_ID", "BACKUP_S3_ACCESS_KEY_ID_FILE", "BACKUP_S3_SECRET_ACCESS_KEY", "BACKUP_S3_SECRET_ACCESS_KEY_FILE"} {
		if getenv(k) != "" {
			envCreds = true
		}
	}
	if envCreds {
		// Credentials from the environment are bound to the environment's
		// destination: the UI can neither redirect them nor change how they
		// are sent. Endpoint, TLS and private-network flags come from env only.
		delete(overlay, "BACKUP_S3_ENDPOINT")
		delete(overlay, "BACKUP_S3_INSECURE")
		delete(overlay, "BACKUP_S3_ALLOW_PRIVATE")
	}
	merged := func(k string) string {
		if v := getenv(k); v != "" {
			return v
		}
		return overlay[k]
	}
	cfg, err := LoadConfig(merged)
	if err != nil {
		return nil, err
	}
	// Saved credentials are only ever used for the destination they were saved for.
	if st != nil && st.Exists && st.Creds != nil && !envCreds && !st.CredsFresh && cfg.S3 != nil {
		if st.Creds.Binding != backupsettings.BindingOf(cfg.S3.Endpoint, cfg.S3.Insecure, cfg.S3.AllowPrivate, cfg.S3.Region) {
			return nil, backupsettings.ErrBinding
		}
	}
	cfg.EnvPublic = map[string]string{}
	for _, k := range backupsettings.PublicEnvVars {
		if v := getenv(k); v != "" {
			cfg.EnvPublic[k] = v
		}
	}
	for _, k := range []string{"BACKUP_S3_ACCESS_KEY_ID", "BACKUP_S3_ACCESS_KEY_ID_FILE", "BACKUP_S3_SECRET_ACCESS_KEY", "BACKUP_S3_SECRET_ACCESS_KEY_FILE",
		"BACKUP_AGE_RECIPIENTS_FILE", "BACKUP_AGE_PASSPHRASE_FILE"} {
		if getenv(k) != "" {
			cfg.EnvSecrets = append(cfg.EnvSecrets, k)
		}
	}
	return cfg, nil
}

// SettingsKey returns the envelope key for the saved credentials, or nil when
// the service was not given a key secret.
func SettingsKey(getenv func(string) string) []byte {
	secret := strings.TrimSpace(getenv("BACKUP_SETTINGS_KEY"))
	if secret == "" {
		return nil
	}
	k, err := backupsettings.DeriveKey(secret)
	if err != nil {
		return nil
	}
	return k
}

var errNoS3 = errors.New("S3 is not enabled")
