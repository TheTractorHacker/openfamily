package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

const (
	resetCodeTTL      = 30 * time.Minute
	resetCodeLen      = 12
	resetIssuePerUser = 10
	resetIssueWindow  = time.Hour
	resetRedeemPerIP  = 10
	resetRedeemWindow = 15 * time.Minute
	resetFailsPerKey  = 5
)

var errBadResetCode = errors.New("invalid or expired reset code")

// ChangePassword is the step-up password change: current password (and TOTP
// when enabled) required, the hash update and token_version bump are one
// statement, every other session and device key is revoked, and the caller
// gets a fresh token pair so this device stays signed in.
func (s *Server) ChangePassword(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		CurrentPassword string `json:"current_password"`
		NewPassword     string `json:"new_password"`
		TOTPCode        string `json:"totp_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if err := validatePasswordChange(req.CurrentPassword, req.NewPassword); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !s.stepUp(w, r, claims.UserID, req.CurrentPassword, req.TOTPCode) {
		return
	}
	newHash, err := auth.HashPassword(req.NewPassword)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}
	var user models.User
	err = s.Pool.QueryRow(r.Context(), `
		UPDATE users SET password_hash = $1, token_version = token_version + 1, updated_at = now()
		WHERE id = $2
		RETURNING id, family_id, email, name, role, totp_enabled, token_version, created_at, updated_at`,
		newHash, claims.UserID,
	).Scan(&user.ID, &user.FamilyID, &user.Email, &user.Name, &user.Role,
		&user.TOTPEnabled, &user.TokenVersion, &user.CreatedAt, &user.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "profile not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update password")
		return
	}
	if err := s.revokeAllSessions(r.Context(), user.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to invalidate sessions")
		return
	}
	if err := s.revokeIngestKeys(r.Context(), user.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke device keys")
		return
	}
	s.dropUserSockets(user.ID)
	s.logAudit(r.Context(), user.ID, "", "profile.password_changed", "changed password; other sessions revoked", clientIP(r))

	jti, err := newTokenID()
	if err == nil {
		err = s.refreshSessions().Create(r.Context(), user.ID, jti, time.Now().Add(s.TM.RefreshTTL()))
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	s.tagSession(r, jti)
	s.issueTokens(w, user, jti)
}

type resetCodeResponse struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
	SMSSent   bool      `json:"sms_sent"`
	SMSNote   string    `json:"sms_note,omitempty"`
}

// issueResetCode replaces any unused reset code of the target with a new one
// valid for resetCodeTTL and returns its display form.
func (s *Server) issueResetCode(ctx context.Context, targetID, issuerID string) (string, time.Time, error) {
	raw, err := auth.RandomCode(resetCodeLen)
	if err != nil {
		return "", time.Time{}, err
	}
	expires := time.Now().Add(resetCodeTTL)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return "", time.Time{}, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx,
		`DELETE FROM password_reset_codes WHERE user_id = $1 AND used_at IS NULL`, targetID); err != nil {
		return "", time.Time{}, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO password_reset_codes (user_id, issued_by, code_hash, expires_at)
		VALUES ($1, $2, $3, $4)`, targetID, issuerID, auth.MACCode(s.resetKey(), raw), expires); err != nil {
		return "", time.Time{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", time.Time{}, err
	}
	return auth.FormatCode(raw), expires, nil
}

// respondResetCode issues a code for target and writes the response, with the
// opt-in SMS delivery. Authorization is the caller's job.
func (s *Server) respondResetCode(w http.ResponseWriter, r *http.Request, issuerID, targetID, auditFamily string) {
	var req struct {
		SendSMS bool `json:"send_sms"`
	}
	if r.Body != nil && r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
	}
	if !s.allowKey(w, "resetcode:issue:"+issuerID, resetIssuePerUser, resetIssueWindow) {
		return
	}
	var phone *string
	if err := s.Pool.QueryRow(r.Context(), `SELECT phone FROM users WHERE id = $1`, targetID).Scan(&phone); err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	code, expires, err := s.issueResetCode(r.Context(), targetID, issuerID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue reset code")
		return
	}
	resp := resetCodeResponse{Code: code, ExpiresAt: expires}
	if req.SendSMS {
		switch {
		case !s.SMSEnabled():
			resp.SMSNote = "SMS is not configured on this server"
		case phone == nil || *phone == "":
			resp.SMSNote = "the user has no phone number"
		default:
			msg := fmt.Sprintf("OpenFamily password reset code: %s (valid 30 minutes). Ignore if you did not ask for this.", code)
			if err := s.sendSMS(r.Context(), *phone, msg); err != nil {
				resp.SMSNote = "SMS delivery failed"
			} else {
				resp.SMSSent = true
			}
		}
	}
	s.logAudit(r.Context(), issuerID, auditFamily, "account.reset_code_issued",
		fmt.Sprintf("issued password reset code for user %s (sms=%t)", targetID, resp.SMSSent), clientIP(r))
	writeJSON(w, http.StatusCreated, resp)
}

// AdminIssueResetCode lets a platform admin issue a reset code for any other
// account. The code is returned once and stored only as an HMAC.
func (s *Server) AdminIssueResetCode(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	target := chi.URLParam(r, "id")
	if target == claims.UserID {
		writeError(w, http.StatusBadRequest, "use change password for your own account")
		return
	}
	var fid *string
	if err := s.Pool.QueryRow(r.Context(), `SELECT family_id FROM users WHERE id = $1`, target).Scan(&fid); err != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	af := ""
	if fid != nil {
		af = *fid
	}
	s.respondResetCode(w, r, claims.UserID, target, af)
}

// FamilyIssueResetCode lets a family admin issue a reset code for another
// member of the same family. Platform-admin accounts cannot be reset this way.
func (s *Server) FamilyIssueResetCode(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	target := chi.URLParam(r, "id")
	var callerFamily *string
	var callerRole models.Role
	if err := s.Pool.QueryRow(r.Context(), `SELECT family_id, role FROM users WHERE id = $1`, claims.UserID).
		Scan(&callerFamily, &callerRole); err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if callerFamily == nil || callerRole != models.RoleAdmin {
		writeError(w, http.StatusForbidden, "family admin role required")
		return
	}
	if target == claims.UserID {
		writeError(w, http.StatusBadRequest, "use change password for your own account")
		return
	}
	var targetFamily *string
	var targetPlatformAdmin bool
	err := s.Pool.QueryRow(r.Context(), `SELECT family_id, platform_admin FROM users WHERE id = $1`, target).
		Scan(&targetFamily, &targetPlatformAdmin)
	if err != nil || targetFamily == nil || *targetFamily != *callerFamily || targetPlatformAdmin {
		// Same answer for "no such user" and "not yours": no probing of ids.
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	s.respondResetCode(w, r, claims.UserID, target, *callerFamily)
}

// ResetPassword redeems an admin-issued reset code: POST /auth/password/reset
// {email, code, new_password}. Every failure is the same 400, whether the
// email is unknown, the code wrong, expired or used. On success the password
// changes, all sessions and device ingest keys are revoked, and other unused
// codes die. TOTP, if enabled, still applies at the next login.
func (s *Server) ResetPassword(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("pwreset", clientIP(r)), resetRedeemPerIP, resetRedeemWindow) {
		return
	}
	var req struct {
		Email       string `json:"email"`
		Code        string `json:"code"`
		NewPassword string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Email = trimmedLower(req.Email)
	code := auth.NormalizeCode(req.Code)
	if req.Email == "" || code == "" || req.NewPassword == "" {
		writeError(w, http.StatusBadRequest, "email, code and new_password are required")
		return
	}
	if len(req.NewPassword) < minPasswordLength || len(req.NewPassword) > auth.MaxPasswordLength {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("password must be %d-%d characters", minPasswordLength, auth.MaxPasswordLength))
		return
	}
	failKey := "pwreset:fail:" + req.Email + "|" + limiterIP(clientIP(r))
	if s.AuthLimit != nil && s.AuthLimit.Exceeded(failKey, resetFailsPerKey, resetRedeemWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	userID, err := s.redeemResetCode(r.Context(), req.Email, code, req.NewPassword)
	if errors.Is(err, errBadResetCode) {
		if s.AuthLimit != nil {
			s.AuthLimit.Record(failKey, resetRedeemWindow)
		}
		s.logAudit(r.Context(), "", "", "auth.password_reset_failed", "password reset failed", clientIP(r))
		writeError(w, http.StatusBadRequest, "invalid or expired reset code")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}
	if s.AuthLimit != nil {
		s.AuthLimit.Reset(failKey)
	}
	if err := s.revokeIngestKeys(r.Context(), userID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke device keys")
		return
	}
	s.dropUserSockets(userID)
	s.logAudit(r.Context(), userID, "", "auth.password_reset", "password reset with admin-issued code", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// redeemResetCode consumes the code and sets the new password in one
// transaction (a failure after consumption rolls the consumption back).
func (s *Server) redeemResetCode(ctx context.Context, email, code, newPassword string) (string, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	var userID string
	err = tx.QueryRow(ctx, `
		UPDATE password_reset_codes c SET used_at = now()
		FROM users u
		WHERE u.id = c.user_id AND u.email = $1 AND c.code_hash = $2
		  AND c.used_at IS NULL AND c.expires_at > now()
		RETURNING c.user_id`, email, auth.MACCode(s.resetKey(), code)).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errBadResetCode
	}
	if err != nil {
		return "", err
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE users SET password_hash = $2, token_version = token_version + 1, updated_at = now()
		WHERE id = $1`, userID, hash); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE refresh_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, userID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM password_reset_codes WHERE user_id = $1 AND used_at IS NULL`, userID); err != nil {
		return "", err
	}
	return userID, tx.Commit(ctx)
}
