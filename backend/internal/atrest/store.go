package atrest

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Status is what the admin page shows.
type Status struct {
	// Configured: OPENFAMILY_DATA_KEY is set and valid.
	Configured bool `json:"configured"`
	// Active: the key opened the stored data key and new values are sealed.
	Active bool `json:"active"`
	// Problem is a plain sentence when protection was requested but not working.
	Problem string `json:"problem,omitempty"`
}

// Load reads the operator key and the stored wrapped DEK and installs the
// process keyring.
//
//   - no key and no stored DEK: protection stays off (nothing changes).
//   - key, no stored DEK: a new DEK is created and stored wrapped.
//   - key and stored DEK: the DEK is unwrapped; a WRONG key is an error.
//   - no key but a stored DEK: error. Starting anyway would write new secrets
//     in plaintext next to sealed ones, silently weakening a protected box.
func Load(ctx context.Context, pool *pgxpool.Pool) (Status, error) {
	secret, err := EnvSecret()
	if err != nil {
		return Status{Problem: err.Error()}, err
	}
	var wrapped []byte
	qerr := pool.QueryRow(ctx, `SELECT wrapped_dek FROM at_rest_keys WHERE id = 1`).Scan(&wrapped)
	have := qerr == nil
	if qerr != nil && !errors.Is(qerr, pgx.ErrNoRows) {
		return Status{}, qerr
	}
	if secret == "" {
		if have {
			e := errors.New("data protection was turned on for this server but OPENFAMILY_DATA_KEY is not set; refusing to start so secrets are not written unprotected. Restore the key (see docs/self-hosting.md) or ask for help before removing it")
			return Status{Problem: e.Error()}, e
		}
		SetDefault(nil)
		return Status{}, nil
	}
	kek, err := DeriveKEK(secret)
	if err != nil {
		return Status{Problem: err.Error()}, err
	}
	var dek []byte
	if have {
		if dek, err = Unwrap(kek, wrapped); err != nil {
			return Status{Configured: true, Problem: err.Error()}, err
		}
	} else {
		dek = NewDEK()
		if _, err := pool.Exec(ctx, `INSERT INTO at_rest_keys (id, wrapped_dek) VALUES (1, $1) ON CONFLICT (id) DO NOTHING`, Wrap(kek, dek)); err != nil {
			return Status{}, err
		}
		// Another instance may have won the race: re-read so every process agrees.
		if err := pool.QueryRow(ctx, `SELECT wrapped_dek FROM at_rest_keys WHERE id = 1`).Scan(&wrapped); err != nil {
			return Status{}, err
		}
		if dek, err = Unwrap(kek, wrapped); err != nil {
			return Status{}, err
		}
	}
	SetDefault(NewKeyring(dek))
	return Status{Configured: true, Active: true}, nil
}

// Rewrap replaces the operator key: it unwraps the DEK with oldSecret and
// stores it wrapped by newSecret. No value is re-encrypted (the DEK does not
// change), so it is instant and safe to repeat. Back up the new key first.
func Rewrap(ctx context.Context, pool *pgxpool.Pool, oldSecret, newSecret string) error {
	oldK, err := DeriveKEK(oldSecret)
	if err != nil {
		return fmt.Errorf("current key: %w", err)
	}
	newK, err := DeriveKEK(newSecret)
	if err != nil {
		return fmt.Errorf("new key: %w", err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var wrapped []byte
	if err := tx.QueryRow(ctx, `SELECT wrapped_dek FROM at_rest_keys WHERE id = 1 FOR UPDATE`).Scan(&wrapped); err != nil {
		return errors.New("no data key is stored yet; start the server once with OPENFAMILY_DATA_KEY set")
	}
	dek, err := Unwrap(oldK, wrapped)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE at_rest_keys SET wrapped_dek = $1, rewrapped_at = now() WHERE id = 1`, Wrap(newK, dek)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// column is one protected column.
type column struct{ Table, Col, Key string }

// Columns lists every protected column (label = table.column). The Key is the
// primary-key expression used to update a row.
var Columns = []column{
	{"dawarich_settings", "api_key", "id"},
	{"dawarich_user_map", "api_key", "user_id"},
	{"sms_settings", "auth_token", "id"},
	{"ha_integrations", "webhook_secret", "id"},
}

// Label is the AAD of a column.
func Label(table, col string) string { return table + "." + col }

// SealExisting seals legacy plaintext values of every protected column. It is
// idempotent and runs at start-up after Load when protection is active.
func SealExisting(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	k := Default()
	if k == nil {
		return 0, nil
	}
	total := 0
	for _, c := range Columns {
		rows, err := pool.Query(ctx, fmt.Sprintf(`SELECT %s::text, %s FROM %s WHERE %s <> '' AND %s NOT LIKE '%s%%'`,
			c.Key, c.Col, c.Table, c.Col, c.Col, Prefix))
		if err != nil {
			// A table that does not exist yet (older schema) is not an error.
			continue
		}
		type kv struct{ key, val string }
		var todo []kv
		for rows.Next() {
			var e kv
			if err := rows.Scan(&e.key, &e.val); err == nil {
				todo = append(todo, e)
			}
		}
		rows.Close()
		for _, e := range todo {
			sealed, _ := k.Seal(Label(c.Table, c.Col), e.val)
			if _, err := pool.Exec(ctx, fmt.Sprintf(`UPDATE %s SET %s = $1 WHERE %s::text = $2 AND %s = $3`, c.Table, c.Col, c.Key, c.Col),
				sealed, e.key, e.val); err != nil {
				return total, err
			}
			total++
		}
	}
	return total, nil
}
