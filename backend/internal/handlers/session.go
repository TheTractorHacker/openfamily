package handlers

import (
	"context"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func (s *Server) bumpTokenVersion(ctx context.Context, userID string) error {
	_, err := s.Pool.Exec(ctx,
		`UPDATE users SET token_version = token_version + 1, updated_at = now() WHERE id = $1`,
		userID)
	return err
}

func (s *Server) tokenVersionMatches(ctx context.Context, userID string, version int) bool {
	if s.Pool == nil {
		return true
	}
	var current int
	err := s.Pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id = $1`, userID).Scan(&current)
	return err == nil && current == version
}

// revokeIngestKeys invalidates every device ingest key the user holds. Called
// on logout, password change/reset: a key must not outlive the credential
// event that is supposed to cut a device off (BSEC-004 / MOB-003). The device
// rows are kept; the app obtains a new key via POST /devices/{id}/ingest-key
// after it signs in again.
func (s *Server) revokeIngestKeys(ctx context.Context, userID string) error {
	_, err := s.Pool.Exec(ctx, `
		UPDATE devices SET ingest_key_hash = NULL, ingest_key_expires_at = NULL
		WHERE user_id = $1 AND ingest_key_hash IS NOT NULL`, userID)
	s.Direct.CloseUser(userID)
	return err
}

// newIngestKeyExpiry is the expiry to store alongside a freshly issued key.
func newIngestKeyExpiry() *time.Time { return middleware.NewIngestKeyExpiry(time.Now()) }

// revokeCredentialArtifacts is the full cut-off for a credential event done on
// someone's behalf (admin password reset, admin email change): every refresh
// family, every device ingest key and every public share link of the user. The
// caller bumps token_version itself (access tokens). Public share links are
// bearer credentials for the live location, so they must not survive it.
func (s *Server) revokeCredentialArtifacts(ctx context.Context, userID string) error {
	if err := s.revokeAllSessions(ctx, userID); err != nil {
		return err
	}
	if err := s.revokeIngestKeys(ctx, userID); err != nil {
		return err
	}
	return s.revokeShareLinks(ctx, userID)
}
