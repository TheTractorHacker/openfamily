package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/models"
)

type registerRequest struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	Name       string `json:"name"`
	InviteCode string `json:"invite_code,omitempty"`
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	TOTPCode string `json:"totp_code,omitempty"`
}

type tokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
}

// Register creates a new user account. When the server requires an invite
// (RequireInvite), the request must carry a valid invite code, which assigns
// the new user to the code's family and role. When invites are not required,
// a code is still honored if present (so joining a family works in open mode),
// and a missing code creates an unassigned account as before.
func (s *Server) Register(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("register", clientIP(r)), registerPerIP, registerWindow) {
		return
	}
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	req.InviteCode = strings.TrimSpace(req.InviteCode)
	if req.Email == "" || req.Password == "" || req.Name == "" {
		writeError(w, http.StatusBadRequest, "email, password, and name are required")
		return
	}
	if len(req.Password) < 8 {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}
	if len(req.Password) > auth.MaxPasswordLength {
		writeError(w, http.StatusBadRequest, "password must be at most 256 bytes")
		return
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Resolve the family and role for the new user.
	var familyID *string
	role := models.RoleMember
	if req.InviteCode != "" {
		fid, rl, err := s.consumeInviteCode(r.Context(), tx, req.InviteCode)
		if err != nil {
			var ie *inviteError
			if errors.As(err, &ie) {
				writeError(w, http.StatusBadRequest, ie.msg)
			} else {
				writeError(w, http.StatusInternalServerError, "failed to validate invite code")
			}
			return
		}
		familyID = &fid
		role = rl
	} else if s.RequireInvite {
		writeError(w, http.StatusForbidden, "an invite code is required to register")
		return
	}

	var user models.User
	err = tx.QueryRow(r.Context(), `
		INSERT INTO users (email, name, password_hash, family_id, role)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, family_id, email, name, role, totp_enabled, created_at, updated_at`,
		req.Email, req.Name, hash, familyID, role,
	).Scan(&user.ID, &user.FamilyID, &user.Email, &user.Name, &user.Role, &user.TOTPEnabled, &user.CreatedAt, &user.UpdatedAt)
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "email already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to create user")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	s.logAudit(r.Context(), user.ID, "", "auth.register", "registered "+user.Email, clientIP(r))
	writeJSON(w, http.StatusCreated, user)
}

// Login verifies credentials (and TOTP when enabled) and returns a token pair.
func (s *Server) Login(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("login", clientIP(r)), loginPerIP, loginWindow) {
		return
	}
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	emailKey := authEmailKey(req.Email, clientIP(r))
	if s.loginBlocked(w, emailKey) {
		return
	}

	if len(req.Password) > auth.MaxPasswordLength {
		// Never feed oversized input to Argon2.
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	var user models.User
	err := s.Pool.QueryRow(r.Context(), `
		SELECT id, family_id, email, name, role, password_hash, COALESCE(totp_secret, ''), totp_enabled, token_version, created_at, updated_at
		FROM users WHERE email = $1`, req.Email,
	).Scan(&user.ID, &user.FamilyID, &user.Email, &user.Name, &user.Role,
		&user.PasswordHash, &user.TOTPSecret, &user.TOTPEnabled, &user.TokenVersion, &user.CreatedAt, &user.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		// Avoid leaking which emails exist — same HTTP body and audit text.
		s.loginFailed(emailKey)
		s.logAudit(r.Context(), "", "", "auth.login_failed", "login failed", clientIP(r))
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}

	ok, err := auth.VerifyPassword(req.Password, user.PasswordHash)
	if err != nil || !ok {
		s.loginFailed(emailKey)
		s.logAudit(r.Context(), user.ID, "", "auth.login_failed", "login failed", clientIP(r))
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	if user.TOTPEnabled {
		if req.TOTPCode == "" || !auth.ValidateTOTPWithSkew(user.TOTPSecret, req.TOTPCode, 1) {
			s.loginFailed(emailKey)
			s.logAudit(r.Context(), user.ID, "", "auth.login_failed", "login failed", clientIP(r))
			writeError(w, http.StatusUnauthorized, "invalid totp code")
			return
		}
	}

	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	s.loginSucceeded(emailKey)
	s.logAudit(r.Context(), user.ID, familyID, "auth.login", "login for "+user.Email, clientIP(r))
	jti, err := newTokenID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	if err := s.refreshSessions().Create(r.Context(), user.ID, jti, time.Now().Add(s.TM.RefreshTTL())); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	// Opportunistic cleanup of long-expired rows; never blocks login.
	go func() { _ = s.refreshSessions().Purge(context.Background()) }()
	s.issueTokens(w, user, jti)
}

// Refresh rotates a refresh token into a new token pair.
func (s *Server) Refresh(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("refresh", clientIP(r)), refreshPerIP, refreshWindow) {
		return
	}
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	claims, err := s.TM.Parse(req.RefreshToken, auth.RefreshToken)
	if err != nil {
		s.logAudit(r.Context(), "", "", "auth.refresh_failed", "invalid refresh token", clientIP(r))
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}

	var user models.User
	err = s.Pool.QueryRow(r.Context(), `
		SELECT id, family_id, email, name, role, totp_enabled, token_version, created_at, updated_at
		FROM users WHERE id = $1`, claims.UserID,
	).Scan(&user.ID, &user.FamilyID, &user.Email, &user.Name, &user.Role,
		&user.TOTPEnabled, &user.TokenVersion, &user.CreatedAt, &user.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusUnauthorized, "user no longer exists")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if claims.TokenVersion != user.TokenVersion {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}

	newJTI, status := s.rotateRefreshToken(r.Context(), user.ID, claims.ID)
	switch status {
	case refreshRotated:
	case refreshReuse:
		s.logAudit(r.Context(), user.ID, "", "auth.refresh_reuse",
			"refresh token reuse detected; session family revoked", clientIP(r))
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	case refreshRejected:
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	default:
		writeError(w, http.StatusInternalServerError, "failed to rotate refresh token")
		return
	}
	s.issueTokens(w, user, newJTI)
}

// Logout bumps token_version so every outstanding access and refresh token
// for this user is rejected. The client still clears local storage.
func (s *Server) Logout(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if err := s.bumpTokenVersion(r.Context(), claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to log out")
		return
	}
	if err := s.revokeIngestKeys(r.Context(), claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke device keys")
		return
	}
	s.dropUserSockets(claims.UserID)
	s.logAudit(r.Context(), claims.UserID, "", "auth.logout", "logged out", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// issueTokens writes a fresh token pair. refreshJTI is the id of the (already
// stored) refresh token to embed.
type refreshStatus int

const (
	refreshRotated refreshStatus = iota
	refreshRejected
	refreshReuse
	refreshError
)

// rotateRefreshToken spends oldJTI and returns the id of its successor. Every
// refresh token is single-use; presenting a spent one revokes its whole
// family. An empty oldJTI is a token issued before rotation existed: it is
// accepted once and replaced by a tracked token (replay of such legacy tokens
// cannot be detected).
func (s *Server) rotateRefreshToken(ctx context.Context, userID, oldJTI string) (string, refreshStatus) {
	newJTI, err := newTokenID()
	if err != nil {
		return "", refreshError
	}
	expires := time.Now().Add(s.TM.RefreshTTL())
	if oldJTI == "" {
		if err := s.refreshSessions().Create(ctx, userID, newJTI, expires); err != nil {
			return "", refreshError
		}
		return newJTI, refreshRotated
	}
	out, err := s.refreshSessions().Rotate(ctx, userID, oldJTI, newJTI, expires)
	if err != nil {
		return "", refreshError
	}
	switch out {
	case rotateOK:
		return newJTI, refreshRotated
	case rotateReused:
		return "", refreshReuse
	}
	return "", refreshRejected
}

func (s *Server) issueTokens(w http.ResponseWriter, user models.User, refreshJTI string) {
	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	access, err := s.TM.IssueAccess(user.ID, familyID, user.TokenVersion)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue access token")
		return
	}
	refresh, err := s.TM.IssueRefreshWithID(user.ID, familyID, user.TokenVersion, refreshJTI)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue refresh token")
		return
	}
	writeJSON(w, http.StatusOK, tokenPair{
		AccessToken:  access,
		RefreshToken: refresh,
		TokenType:    "Bearer",
		ExpiresIn:    int64(s.TM.AccessTTL() / time.Second),
	})
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
