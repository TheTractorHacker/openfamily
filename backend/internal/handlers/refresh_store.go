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
	// The returned jti is the successor to hand out: newJTI normally, or the
	// already-issued successor when the same token is presented again within
	// refreshIdempotentWindow (several parts of one app refreshing at once).
	Rotate(ctx context.Context, userID, oldJTI, newJTI string, expires time.Time) (rotateOutcome, string, error)
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

// refreshIdempotentWindow: within this long after a refresh token is spent, presenting it again
// (for any number of times) returns the SAME successor instead of counting as reuse, as long as that
// successor has not been used yet. One phone has several parts that refresh together on start-up (the
// screen, the background location service) and a phone that is frozen or loses its connection while a
// refresh is in flight never receives the answer and retries the same token every ~15 s (its request
// timeout). Production incident (2026-11-09/10, several times): the first retry used the one-off grace,
// the third presentation read as theft and revoked the owner's whole session (token reuse 15 s apart, on
// carrier data and on home Wi-Fi alike). A successor that was already used, or a presentation after the
// window, keeps the strict rules below.
var refreshIdempotentWindow = 3 * time.Minute

// refreshIdempotentMax caps how many times one spent token is answered with the same successor (concurrent
// parts of one phone plus a few lost-answer retries). A replayed token cannot be used indefinitely: past the
// cap the strict rules apply (the one-off grace, then theft).
const refreshIdempotentMax = 8

// Once a token has used up its answers (refreshIdempotentMax) the one-off grace below is closed to it as well:
// the grace issues a SECOND live successor (a fork of the session), which a replayed token must not get.

type pgRefreshStore struct{ pool *pgxpool.Pool }

func (p pgRefreshStore) Create(ctx context.Context, userID, jti string, expires time.Time) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at)
		VALUES ($1, $1, $2, $3)`, jti, userID, expires)
	return err
}

func (p pgRefreshStore) Rotate(ctx context.Context, userID, oldJTI, newJTI string, expires time.Time) (rotateOutcome, string, error) {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return rotateUnknown, "", err
	}
	defer tx.Rollback(ctx)

	var family string
	err = tx.QueryRow(ctx, `
		UPDATE refresh_sessions SET used_at = now()
		WHERE jti = $1 AND user_id = $2 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
		RETURNING family_id`, oldJTI, userID).Scan(&family)
	if err == nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at, parent_jti, client_key, user_agent)
			SELECT $1::text, $2::text, $3::uuid, $4::timestamptz, $5::text, client_key, user_agent FROM refresh_sessions WHERE jti = $5`, newJTI, family, userID, expires, oldJTI); err != nil {
			return rotateUnknown, "", err
		}
		return rotateOK, newJTI, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, "", err
	}

	// Not live: distinguish "never heard of it / expired" from reuse.
	var used, revoked *time.Time
	var expiresAt time.Time
	err = tx.QueryRow(ctx, `
		SELECT family_id, used_at, revoked_at, expires_at FROM refresh_sessions
		WHERE jti = $1 AND user_id = $2`, oldJTI, userID).Scan(&family, &used, &revoked, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, "", nil
	}
	if err != nil {
		return rotateUnknown, "", err
	}
	if used == nil && revoked == nil {
		return rotateUnknown, "", nil // simply expired
	}
	// Several parts of one app refreshing at the same moment: hand every one of them the same
	// successor (it has not been used yet), so nobody is treated as a thief.
	var sameChild string
	err = tx.QueryRow(ctx, `
		WITH p AS (
		  UPDATE refresh_sessions SET retry_count = retry_count + 1
		  WHERE jti = $1 AND user_id = $2
		    AND used_at IS NOT NULL AND revoked_at IS NULL
		    AND used_at > now() - make_interval(secs => $3)
		    AND retry_count < $4
		  RETURNING jti)
		SELECT c.jti FROM p
		JOIN refresh_sessions c ON c.parent_jti = p.jti
		WHERE c.used_at IS NULL AND c.revoked_at IS NULL AND c.expires_at > now()
		ORDER BY c.created_at LIMIT 1`, oldJTI, userID, refreshIdempotentWindow.Seconds(), refreshIdempotentMax).Scan(&sameChild)
	if err == nil {
		return rotateOK, sameChild, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, "", err
	}

	// A refresh response can be lost after the server rotated: the app is
	// killed by an update, the phone drops off the network, or the proxy
	// resets the connection. The client then legitimately retries the token
	// it still holds. That retry is accepted at most once per spent token, only
	// within refreshReuseGrace of the rotation (database clock), and only if
	// the token that rotation produced was never used: a used successor means
	// the client did receive it, so this is a replay. Everything else is reuse.
	var graceFamily string
	err = tx.QueryRow(ctx, `
		UPDATE refresh_sessions SET grace_used_at = now()
		WHERE jti = $1 AND user_id = $2
		  AND used_at IS NOT NULL AND revoked_at IS NULL AND grace_used_at IS NULL
		  AND expires_at > now()
		  AND used_at > now() - make_interval(secs => $3)
		  AND retry_count < $4
		  AND NOT EXISTS (SELECT 1 FROM refresh_sessions c
		                  WHERE c.parent_jti = $1 AND c.used_at IS NOT NULL)
		RETURNING family_id`, oldJTI, userID, refreshReuseGrace.Seconds(), refreshIdempotentMax).Scan(&graceFamily)
	if err == nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO refresh_sessions (jti, family_id, user_id, expires_at, parent_jti, client_key, user_agent)
			SELECT $1::text, $2::text, $3::uuid, $4::timestamptz, $5::text, client_key, user_agent FROM refresh_sessions WHERE jti = $5`, newJTI, graceFamily, userID, expires, oldJTI); err != nil {
			return rotateUnknown, "", err
		}
		return rotateOK, newJTI, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return rotateUnknown, "", err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_sessions SET revoked_at = now()
		WHERE family_id = $1 AND revoked_at IS NULL`, family); err != nil {
		return rotateUnknown, "", err
	}
	return rotateReused, "", tx.Commit(ctx)
}

func (p pgRefreshStore) Purge(ctx context.Context) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE expires_at < now() - interval '1 day'`)
	return err
}
