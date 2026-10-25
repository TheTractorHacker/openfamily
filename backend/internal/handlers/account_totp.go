package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
)

const totpIssuer = "OpenFamily"

// TOTPSetup starts enrollment: it generates a secret, stores it sealed but
// not yet enabled, and returns it once with the otpauth URI. Requires the
// current password. Calling it again before enabling replaces the pending
// secret; it is refused once TOTP is enabled (disable first).
func (s *Server) TOTPSetup(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Password == "" {
		writeError(w, http.StatusBadRequest, "password is required")
		return
	}
	// TOTP is off here (checked below), so stepUp verifies the password only.
	var email string
	var enabled bool
	err := s.Pool.QueryRow(r.Context(), `SELECT email, totp_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&email, &enabled)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if enabled {
		writeError(w, http.StatusConflict, "two-factor authentication is already enabled; disable it first")
		return
	}
	if !s.stepUp(w, r, claims.UserID, req.Password, "") {
		return
	}
	secret, uri, err := auth.GenerateTOTPSecret(totpIssuer, email)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate secret")
		return
	}
	sealed, err := auth.SealSecret(s.totpKey(), secret)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to protect secret")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE users SET totp_secret = $2, totp_last_step = 0, updated_at = now()
		WHERE id = $1 AND totp_enabled = FALSE`, claims.UserID, sealed)
	if err != nil || tag.RowsAffected() != 1 {
		writeError(w, http.StatusConflict, "could not start enrollment")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "auth.totp_setup", "started TOTP enrollment", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"secret": secret, "otpauth_uri": uri})
}

// TOTPEnable confirms enrollment with a code from the authenticator app,
// turns TOTP on and returns the one-time recovery codes (shown only now).
func (s *Server) TOTPEnable(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	failKey := "totp:enable:fail:" + claims.UserID
	if s.AuthLimit != nil && s.AuthLimit.Exceeded(failKey, stepUpFailsPerUser, stepUpFailsWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	var stored string
	var enabled bool
	err := s.Pool.QueryRow(r.Context(),
		`SELECT COALESCE(totp_secret, ''), totp_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&stored, &enabled)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load account")
		return
	}
	if enabled {
		writeError(w, http.StatusConflict, "two-factor authentication is already enabled")
		return
	}
	if stored == "" {
		writeError(w, http.StatusConflict, "call /auth/totp/setup first")
		return
	}
	secret, err := auth.OpenSecret(s.totpKey(), stored)
	if err != nil {
		writeError(w, http.StatusConflict, "pending secret is unreadable; call /auth/totp/setup again")
		return
	}
	step, ok := auth.MatchTOTPStep(secret, req.Code, time.Now())
	if !ok {
		if s.AuthLimit != nil {
			s.AuthLimit.Record(failKey, stepUpFailsWindow)
		}
		writeError(w, http.StatusBadRequest, "invalid verification code")
		return
	}

	codes, hashes, err := s.newRecoveryCodes()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to generate recovery codes")
		return
	}
	if err := s.enableTOTP(r.Context(), claims.UserID, step, hashes); err != nil {
		if errors.Is(err, errTOTPRace) {
			writeError(w, http.StatusConflict, "two-factor authentication is already enabled")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to enable two-factor authentication")
		return
	}
	if s.AuthLimit != nil {
		s.AuthLimit.Reset(failKey)
	}
	s.logAudit(r.Context(), claims.UserID, "", "auth.totp_enabled", "enabled TOTP", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"enabled": true, "recovery_codes": codes})
}

var errTOTPRace = errors.New("totp state changed")

// newRecoveryCodes returns display strings and their stored MACs.
func (s *Server) newRecoveryCodes() (display, hashes []string, err error) {
	key := s.recoveryKey()
	for i := 0; i < recoveryCodeCount; i++ {
		c, err := auth.RandomCode(recoveryCodeLen)
		if err != nil {
			return nil, nil, err
		}
		display = append(display, auth.FormatCode(c))
		hashes = append(hashes, auth.MACCode(key, c))
	}
	return display, hashes, nil
}

func (s *Server) enableTOTP(ctx context.Context, userID string, step int64, hashes []string) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `
		UPDATE users SET totp_enabled = TRUE, totp_last_step = $2, updated_at = now()
		WHERE id = $1 AND totp_enabled = FALSE AND totp_secret IS NOT NULL`, userID, step)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return errTOTPRace
	}
	if _, err := tx.Exec(ctx, `DELETE FROM totp_recovery_codes WHERE user_id = $1`, userID); err != nil {
		return err
	}
	for _, h := range hashes {
		if _, err := tx.Exec(ctx,
			`INSERT INTO totp_recovery_codes (user_id, code_hash) VALUES ($1, $2)`, userID, h); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// TOTPDisable turns TOTP off. Requires the password and a valid TOTP or
// recovery code (stepUp enforces both because TOTP is enabled).
func (s *Server) TOTPDisable(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	var enabled bool
	if err := s.Pool.QueryRow(r.Context(), `SELECT totp_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&enabled); err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !enabled {
		writeError(w, http.StatusConflict, "two-factor authentication is not enabled")
		return
	}
	if !s.stepUp(w, r, claims.UserID, req.Password, req.Code) {
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	defer tx.Rollback(r.Context())
	if _, err := tx.Exec(r.Context(), `
		UPDATE users SET totp_enabled = FALSE, totp_secret = NULL, totp_last_step = 0, updated_at = now()
		WHERE id = $1`, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	if _, err := tx.Exec(r.Context(), `DELETE FROM totp_recovery_codes WHERE user_id = $1`, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "auth.totp_disabled", "disabled TOTP", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": false})
}

// trimmedLower is shared by handlers that take an email.
func trimmedLower(s string) string { return strings.ToLower(strings.TrimSpace(s)) }
