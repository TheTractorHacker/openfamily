package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// rotateOutcome is the result of presenting a refresh token for rotation.
type rotateOutcome int

const (
	// rotateOK: the token was live; it is now spent and its successor stored.
	rotateOK rotateOutcome = iota
	// rotateUnknown: no such token (never issued, purged, or expired).
	rotateUnknown
	// rotateReused: the token was already used or revoked. If it was merely
	// used (not yet revoked), the whole family has now been revoked.
	rotateReused
)

// refreshStore persists refresh-token families for rotation and reuse
// detection (BSEC-003).
type refreshStore interface {
	// Create starts a new family whose first token is jti.
	Create(ctx context.Context, userID, jti string, expires time.Time) error
	// Rotate atomically spends oldJTI and records newJTI in the same family.
	// Presenting a spent or revoked token revokes the whole family.
	Rotate(ctx context.Context, userID, oldJTI, newJTI string, expires time.Time) (rotateOutcome, error)
	// Purge deletes long-expired rows.
	Purge(ctx context.Context) error
}

func newTokenID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// refreshReuseGrace is how long after a refresh token is spent that presenting
// it again is treated as a lost-response retry instead of token theft.
const refreshReuseGrace = 60 * time.Second

type pgRefreshStore struct{ pool *pgxpool.Pool }

func (p pgRefreshStore) Create(ctx context.Context, userID, jti string, expires time.Time) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at)
		VALUES ($1, $1, $2, $3)`, jti, userID, expires)
	return err
}

func (p pgRefreshStore) Rotate(ctx context.Context, userID, oldJTI, newJTI string, expires time.Time) (rotateOutcome, error) {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return rotateUnknown, err
	}
	defer tx.Rollback(ctx)

	var family string
	err = tx.QueryRow(ctx, `
		UPDATE refresh_sessions SET used_at = now()
		WHERE jti = $1 AND user_id = $2 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
		RETURNING family_id`, oldJTI, userID).Scan(&family)
	if err == nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at)
			VALUES ($1, $2, $3, $4)`, newJTI, family, userID, expires); err != nil {
			return rotateUnknown, err
		}
		return rotateOK, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, err
	}

	// Not live: distinguish "never heard of it / expired" from reuse.
	var used, revoked *time.Time
	var expiresAt time.Time
	err = tx.QueryRow(ctx, `
		SELECT family_id, used_at, revoked_at, expires_at FROM refresh_sessions
		WHERE jti = $1 AND user_id = $2`, oldJTI, userID).Scan(&family, &used, &revoked, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, nil
	}
	if err != nil {
		return rotateUnknown, err
	}
	if used == nil && revoked == nil {
		return rotateUnknown, nil // simply expired
	}
	// A refresh response can be lost after the server rotated: the app is
	// killed by an update, the phone drops off the network, or the proxy
	// resets the connection. The client then legitimately retries the token
	// it still holds. Within a short window that retry is not theft, so
	// mint a sibling in the same family rather than revoking the session.
	// A token spent longer ago, or a revoked family, is still reuse.
	if revoked == nil && used != nil && expiresAt.After(time.Now()) &&
		time.Since(*used) <= refreshReuseGrace {
		if _, err := tx.Exec(ctx, `
			INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at)
			VALUES ($1, $2, $3, $4)`, newJTI, family, userID, expires); err != nil {
			return rotateUnknown, err
		}
		return rotateOK, tx.Commit(ctx)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_sessions SET revoked_at = now()
		WHERE family_id = $1 AND revoked_at IS NULL`, family); err != nil {
		return rotateUnknown, err
	}
	return rotateReused, tx.Commit(ctx)
}

func (p pgRefreshStore) Purge(ctx context.Context) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE expires_at < now() - interval '1 day'`)
	return err
}
