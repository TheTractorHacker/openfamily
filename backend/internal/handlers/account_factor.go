package handlers

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

const (
	keyPurposeTOTP     = "totp-secret/v1"
	keyPurposeRecovery = "totp-recovery/v1"
	keyPurposeReset    = "password-reset/v1"

	recoveryCodeCount = 10
	recoveryCodeLen   = 10

	// stepUpFailsPerUser caps wrong passwords / second-factor codes presented
	// to any step-up endpoint (change password, disable TOTP, delete account).
	stepUpFailsPerUser = passwordFailsPerUser
	stepUpFailsWindow  = passwordFailsWindow
)

// dummyHash is verified when a login names an unknown email, so unknown and
// known emails cost one Argon2 computation either way (BSEC-012). It is
// created with the production parameters, so it tracks any future tuning.
var (
	dummyHashOnce sync.Once
	dummyHashVal  string
)

func dummyPasswordHash() string {
	dummyHashOnce.Do(func() {
		h, err := auth.HashPassword("openfamily-dummy-password-for-timing")
		if err != nil {
			slog.Error("dummy hash generation failed", "err", err)
		}
		dummyHashVal = h
	})
	return dummyHashVal
}

// burnPasswordCheck spends the cost of one password verification.
func burnPasswordCheck(password string) {
	if h := dummyPasswordHash(); h != "" {
		_, _ = auth.VerifyPassword(password, h)
	}
}

func (s *Server) totpKey() []byte     { return s.TM.DeriveKey(keyPurposeTOTP) }
func (s *Server) recoveryKey() []byte { return s.TM.DeriveKey(keyPurposeRecovery) }
func (s *Server) resetKey() []byte    { return s.TM.DeriveKey(keyPurposeReset) }

// looksLikeTOTP reports whether a submitted code has the shape of a 6-digit
// authenticator code (anything else is tried as a recovery code).
func looksLikeTOTP(code string) bool {
	code = strings.TrimSpace(code)
	if len(code) != 6 {
		return false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// acceptTOTPStep atomically advances users.totp_last_step to step. It returns
// false when step is not strictly newer than the last accepted step, so a code
// (and every older one) can be used only once per user.
func (s *Server) acceptTOTPStep(ctx context.Context, userID string, step int64) (bool, error) {
	tag, err := s.Pool.Exec(ctx,
		`UPDATE users SET totp_last_step = $2 WHERE id = $1 AND totp_last_step < $2`, userID, step)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// consumeRecoveryCode spends one unused recovery code.
func (s *Server) consumeRecoveryCode(ctx context.Context, userID, code string) (bool, error) {
	norm := auth.NormalizeCode(code)
	if norm == "" || len(norm) > 32 {
		return false, nil
	}
	tag, err := s.Pool.Exec(ctx, `
		UPDATE totp_recovery_codes SET used_at = now()
		WHERE user_id = $1 AND code_hash = $2 AND used_at IS NULL`,
		userID, auth.MACCode(s.recoveryKey(), norm))
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// verifySecondFactor checks a TOTP code (replay-guarded) or a recovery code
// against the user's stored (sealed) secret.
func (s *Server) verifySecondFactor(ctx context.Context, userID, storedSecret, code string) bool {
	code = strings.TrimSpace(code)
	if code == "" {
		return false
	}
	if looksLikeTOTP(code) {
		secret, err := auth.OpenSecret(s.totpKey(), storedSecret)
		if err != nil {
			slog.Error("totp secret undecryptable (JWT_SECRET changed?)", "user", userID)
			return false
		}
		step, ok := auth.MatchTOTPStep(secret, code, time.Now())
		if !ok {
			return false
		}
		fresh, err := s.acceptTOTPStep(ctx, userID, step)
		return err == nil && fresh
	}
	ok, err := s.consumeRecoveryCode(ctx, userID, code)
	return err == nil && ok
}

// stepUp re-authenticates the caller for a sensitive action (BSEC-020): the
// current password, plus a TOTP or recovery code when TOTP is enabled. Wrong
// answers are throttled per user. It writes the error response itself and
// returns false on any failure. The status is 400, not 401, so clients that
// refresh on 401 do not treat a typo as a dead session.
func (s *Server) stepUp(w http.ResponseWriter, r *http.Request, userID, password, totpCode string) bool {
	if password == "" {
		writeError(w, http.StatusBadRequest, "password is required")
		return false
	}
	if len(password) > auth.MaxPasswordLength {
		writeError(w, http.StatusBadRequest, "password is incorrect")
		return false
	}
	failKey := "pwchange:fail:" + userID
	if s.AuthLimit != nil && s.AuthLimit.Exceeded(failKey, stepUpFailsPerUser, stepUpFailsWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return false
	}
	fail := func(msg string) bool {
		if s.AuthLimit != nil {
			s.AuthLimit.Record(failKey, stepUpFailsWindow)
		}
		writeError(w, http.StatusBadRequest, msg)
		return false
	}

	var hash, secret string
	var totpOn bool
	err := s.Pool.QueryRow(r.Context(),
		`SELECT password_hash, COALESCE(totp_secret, ''), totp_enabled FROM users WHERE id = $1`, userID,
	).Scan(&hash, &secret, &totpOn)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load account")
		return false
	}
	ok, err := auth.VerifyPassword(password, hash)
	if err != nil && !errors.Is(err, auth.ErrInvalidPassword) {
		writeError(w, http.StatusInternalServerError, "failed to verify password")
		return false
	}
	if err != nil || !ok {
		return fail("password is incorrect")
	}
	if totpOn {
		if strings.TrimSpace(totpCode) == "" {
			writeError(w, http.StatusBadRequest, "totp_code is required")
			return false
		}
		if !s.verifySecondFactor(r.Context(), userID, secret, totpCode) {
			return fail("invalid verification code")
		}
	}
	return true
}

// revokeAllSessions revokes every refresh-token family of the user.
func (s *Server) revokeAllSessions(ctx context.Context, userID string) error {
	_, err := s.Pool.Exec(ctx,
		`UPDATE refresh_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, userID)
	return err
}
