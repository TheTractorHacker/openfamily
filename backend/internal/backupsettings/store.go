package backupsettings

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Stored is the saved UI configuration.
type Stored struct {
	Exists   bool
	Settings Settings
	Creds    *Credentials // nil when none stored or unreadable
	HasCreds bool         // a credentials blob exists (even if unreadable)
	// CredsFresh marks credentials typed in the current request (not loaded
	// from the database); they are bound to the destination they are used for.
	CredsFresh bool
	CredsErr   error
	UpdatedAt  time.Time
}

// Load reads the saved settings. key may be nil (credentials are then not
// decrypted), which is what the API uses for plain reads.
func Load(ctx context.Context, pool *pgxpool.Pool, key []byte) (*Stored, error) {
	st := &Stored{Settings: Defaults()}
	var raw []byte
	var blob []byte
	err := pool.QueryRow(ctx, `SELECT settings, credentials_enc, updated_at FROM backup_settings WHERE id = 1`).Scan(&raw, &blob, &st.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	st.Exists = true
	if err := json.Unmarshal(raw, &st.Settings); err != nil {
		return nil, errors.New("saved backup settings are corrupt")
	}
	if st.Settings.AgeRecipients == nil {
		st.Settings.AgeRecipients = []string{}
	}
	st.HasCreds = len(blob) > 0
	if st.HasCreds && key != nil {
		st.Creds, st.CredsErr = Open(key, blob)
	}
	return st, nil
}

// Save stores settings. creds == nil keeps the stored credentials unless clear.
// binding is the fingerprint of the EFFECTIVE destination (after environment
// pins); use s.Binding() when nothing is pinned.
func Save(ctx context.Context, pool *pgxpool.Pool, key []byte, s Settings, creds *Credentials, clear bool, userID, binding string) error {
	var blob []byte
	switch {
	case clear:
		s.AccessKeyHint = ""
	case creds != nil:
		c := *creds
		c.Binding = binding
		b, err := Seal(key, c)
		if err != nil {
			return err
		}
		blob = b
		s.AccessKeyHint = Hint(creds.AccessKeyID)
	}
	if blob == nil && !clear && s.S3Enabled {
		// Keeping the stored credentials: they must belong to this destination.
		var old []byte
		if err := pool.QueryRow(ctx, `SELECT credentials_enc FROM backup_settings WHERE id = 1`).Scan(&old); err == nil && len(old) > 0 {
			if c, err := Open(key, old); err != nil || c.Binding != binding {
				return ErrBinding
			}
		}
	}
	raw, _ := json.Marshal(s)
	var uid any
	if userID != "" {
		uid = userID
	}
	// credentials_enc: replaced when blob != nil, cleared when clear, else kept.
	_, err := pool.Exec(ctx, `
		INSERT INTO backup_settings (id, settings, credentials_enc, updated_at, updated_by)
		VALUES (1, $1, $2, now(), $3)
		ON CONFLICT (id) DO UPDATE SET settings = $1,
		  credentials_enc = CASE WHEN $4 THEN NULL WHEN $2::bytea IS NOT NULL THEN $2 ELSE backup_settings.credentials_enc END,
		  updated_at = now(), updated_by = $3`, raw, blob, uid, clear)
	return err
}
