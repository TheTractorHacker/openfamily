package handlers

import (
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
	if !s.allowAuth(w, authEmailKey(req.Email), loginPerEmail, loginWindow) {
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
		s.logAudit(r.Context(), user.ID, "", "auth.login_failed", "login failed", clientIP(r))
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	if user.TOTPEnabled {
		if req.TOTPCode == "" || !auth.ValidateTOTPWithSkew(user.TOTPSecret, req.TOTPCode, 1) {
			s.logAudit(r.Context(), user.ID, "", "auth.login_failed", "login failed", clientIP(r))
			writeError(w, http.StatusUnauthorized, "invalid totp code")
			return
		}
	}

	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	s.logAudit(r.Context(), user.ID, familyID, "auth.login", "login for "+user.Email, clientIP(r))
	s.issueTokens(w, user)
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

	s.issueTokens(w, user)
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

func (s *Server) issueTokens(w http.ResponseWriter, user models.User) {
	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	access, err := s.TM.IssueAccess(user.ID, familyID, user.TokenVersion)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to issue access token")
		return
	}
	refresh, err := s.TM.IssueRefresh(user.ID, familyID, user.TokenVersion)
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
