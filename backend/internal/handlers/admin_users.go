package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

const (
	maxAdminNameLength  = 120
	maxAdminEmailLength = 320
	minPasswordLength   = 8
)

type validatedAdminUserInput struct {
	Email string
	Name  string
	Role  models.Role
}

func validateAdminUserInput(email, password, name string, role models.Role) (validatedAdminUserInput, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	name = strings.TrimSpace(name)
	if email == "" || len(email) > maxAdminEmailLength {
		return validatedAdminUserInput{}, errors.New("a valid email is required")
	}
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email {
		return validatedAdminUserInput{}, errors.New("a valid email is required")
	}
	if len([]rune(name)) == 0 || len([]rune(name)) > maxAdminNameLength {
		return validatedAdminUserInput{}, fmt.Errorf("name is required and must be %d characters or fewer", maxAdminNameLength)
	}
	if len(password) > auth.MaxPasswordLength {
		return validatedAdminUserInput{}, fmt.Errorf("password must be at most %d characters", auth.MaxPasswordLength)
	}
	if len(password) < minPasswordLength {
		return validatedAdminUserInput{}, fmt.Errorf("password must be at least %d characters", minPasswordLength)
	}
	if !role.Valid() {
		return validatedAdminUserInput{}, errors.New("invalid role")
	}
	return validatedAdminUserInput{Email: email, Name: name, Role: role}, nil
}

// adminUser is the platform-admin view of an account, including users with no
// family. Family name is joined so the Users page can render without a second
// round-trip.
type adminUser struct {
	ID            string      `json:"id"`
	FamilyID      *string     `json:"family_id"`
	FamilyName    *string     `json:"family_name"`
	Email         string      `json:"email"`
	Name          string      `json:"name"`
	Phone         *string     `json:"phone"`
	Role          models.Role `json:"role"`
	PlatformAdmin bool        `json:"platform_admin"`
	CreatedAt     time.Time   `json:"created_at"`
	UpdatedAt     time.Time   `json:"updated_at"`
}

type adminCreateUserRequest struct {
	Email    string      `json:"email"`
	Password string      `json:"password"`
	Name     string      `json:"name"`
	Role     models.Role `json:"role"`
	FamilyID string      `json:"family_id"`
}

type adminFamilyAssignmentRequest struct {
	FamilyID *string `json:"family_id"`
}

type adminRoleRequest struct {
	Role models.Role `json:"role"`
}

type adminPasswordRequest struct {
	Password string `json:"password"`
}

type adminOperationError struct {
	status  int
	message string
}

// AdminListUsers returns every account, including users without a family.
func (s *Server) AdminListUsers(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id, u.family_id, f.name, u.email, u.name, u.phone, u.role, u.platform_admin,
		       u.created_at, u.updated_at
		FROM users u
		LEFT JOIN families f ON f.id = u.family_id
		ORDER BY u.name, u.email`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list users")
		return
	}
	defer rows.Close()

	users := []adminUser{}
	for rows.Next() {
		var user adminUser
		if err := rows.Scan(&user.ID, &user.FamilyID, &user.FamilyName, &user.Email, &user.Name, &user.Phone,
			&user.Role, &user.PlatformAdmin, &user.CreatedAt, &user.UpdatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan user")
			return
		}
		users = append(users, user)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read users")
		return
	}
	writeJSON(w, http.StatusOK, users)
}

// AdminCreateUser creates an account and optionally assigns it to a family.
// Platform-admin creation bypasses invite-gated registration so an operator can
// provision accounts without minting a code.
func (s *Server) AdminCreateUser(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req adminCreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Role == "" {
		req.Role = models.RoleMember
	}
	input, err := validateAdminUserInput(req.Email, req.Password, req.Name, req.Role)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	familyID := strings.TrimSpace(req.FamilyID)
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}

	if familyID != "" {
		var exists bool
		if err := s.Pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM families WHERE id = $1)`, familyID).Scan(&exists); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to verify family")
			return
		}
		if !exists {
			writeError(w, http.StatusNotFound, "family not found")
			return
		}
	}

	var userID string
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO users (family_id, email, name, role, password_hash)
		VALUES (NULLIF($1, '')::uuid, $2, $3, $4, $5)
		RETURNING id`, familyID, input.Email, input.Name, input.Role, hash).Scan(&userID)
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "email already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to create user")
		return
	}
	user, err := s.adminUserByID(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load created user")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.user_created",
		"created user "+userID+" ("+input.Email+")", clientIP(r))
	writeJSON(w, http.StatusCreated, user)
}

// AdminAssignUser moves a user into a family or removes them from their family
// when family_id is null. Unlike AdminMoveMember (Families page), this endpoint
// refuses to leave a family with no admin — unassigning is easy to do by
// accident from the Users table.
func (s *Server) AdminAssignUser(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req adminFamilyAssignmentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	user, changed, err := s.adminMoveUser(r.Context(), userID, req.FamilyID)
	if err != nil {
		writeError(w, err.status, err.message)
		return
	}
	if changed {
		s.hub.disconnectFamilyUser(userID)
	}
	dest := ""
	if user.FamilyID != nil {
		dest = *user.FamilyID
	}
	s.logAudit(r.Context(), claims.UserID, dest, "admin.user_assigned",
		"assigned user "+userID+" to family "+dest, clientIP(r))
	writeJSON(w, http.StatusOK, user)
}

// AdminUpdateUserRole changes a user's family role while preserving the
// invariant that every non-empty family has an admin.
func (s *Server) AdminUpdateUserRole(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req adminRoleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !req.Role.Valid() {
		writeError(w, http.StatusBadRequest, "invalid role")
		return
	}
	if err := s.adminSetUserRole(r.Context(), userID, req.Role); err != nil {
		writeError(w, err.status, err.message)
		return
	}
	user, loadErr := s.adminUserByID(r.Context(), userID)
	if loadErr != nil {
		writeError(w, http.StatusInternalServerError, "failed to load updated user")
		return
	}
	familyID := ""
	if user.FamilyID != nil {
		familyID = *user.FamilyID
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.user_role_updated",
		"set user "+userID+" role to "+string(req.Role), clientIP(r))
	writeJSON(w, http.StatusOK, user)
}

// AdminResetUserPassword resets an account password without exposing the hash.
func (s *Server) AdminResetUserPassword(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req adminPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.Password) < minPasswordLength || len(req.Password) > auth.MaxPasswordLength {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("password must be %d-%d characters", minPasswordLength, auth.MaxPasswordLength))
		return
	}
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to hash password")
		return
	}
	command, err := s.Pool.Exec(r.Context(),
		`UPDATE users SET password_hash = $1, token_version = token_version + 1, updated_at = now() WHERE id = $2`,
		hash, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset password")
		return
	}
	if command.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if err := s.revokeIngestKeys(r.Context(), userID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke device keys")
		return
	}
	s.dropUserSockets(userID)
	s.logAudit(r.Context(), claims.UserID, "", "admin.user_password_reset",
		"reset password for user "+userID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) adminMoveUser(ctx context.Context, userID string, destination *string) (adminUser, bool, *adminOperationError) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to begin transaction"}
	}
	defer tx.Rollback(ctx)

	var currentFamily *string
	var currentRole models.Role
	if err := tx.QueryRow(ctx, `SELECT family_id, role FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&currentFamily, &currentRole); errors.Is(err, pgx.ErrNoRows) {
		return adminUser{}, false, &adminOperationError{http.StatusNotFound, "user not found"}
	} else if err != nil {
		return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to load user"}
	}

	var destinationID *string
	if destination != nil {
		trimmed := strings.TrimSpace(*destination)
		if trimmed != "" {
			var exists bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM families WHERE id = $1)`, trimmed).Scan(&exists); err != nil {
				return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to verify family"}
			}
			if !exists {
				return adminUser{}, false, &adminOperationError{http.StatusNotFound, "family not found"}
			}
			destinationID = &trimmed
		}
	}
	if stringPtrEqual(currentFamily, destinationID) {
		if err := tx.Commit(ctx); err != nil {
			return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to commit"}
		}
		user, loadErr := s.adminUserByID(ctx, userID)
		if loadErr != nil {
			return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to load user"}
		}
		return user, false, nil
	}

	// Lock affected family rows in a stable order so concurrent moves cannot
	// race the last-admin check or deadlock when swapping two families.
	familyLocks := make([]string, 0, 2)
	if currentFamily != nil {
		familyLocks = append(familyLocks, *currentFamily)
	}
	if destinationID != nil {
		familyLocks = append(familyLocks, *destinationID)
	}
	sort.Strings(familyLocks)
	for i, familyID := range familyLocks {
		if i > 0 && familyID == familyLocks[i-1] {
			continue
		}
		if err := tx.QueryRow(ctx, `SELECT id FROM families WHERE id = $1 FOR UPDATE`, familyID).Scan(new(string)); err != nil {
			return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to lock family"}
		}
	}

	if currentFamily != nil && currentRole == models.RoleAdmin {
		var adminCount int
		if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM users WHERE family_id = $1 AND role = 'admin'`, *currentFamily).Scan(&adminCount); err != nil {
			return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to count family admins"}
		}
		if adminCount <= 1 {
			return adminUser{}, false, &adminOperationError{http.StatusBadRequest, "cannot remove the last family admin"}
		}
	}

	if _, err := tx.Exec(ctx, `UPDATE users SET family_id = $1, updated_at = now() WHERE id = $2`, destinationID, userID); err != nil {
		return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to assign family"}
	}
	if err := tx.Commit(ctx); err != nil {
		return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to commit"}
	}
	user, err := s.adminUserByID(ctx, userID)
	if err != nil {
		return adminUser{}, false, &adminOperationError{http.StatusInternalServerError, "failed to load updated user"}
	}
	return user, true, nil
}

func (s *Server) adminSetUserRole(ctx context.Context, userID string, role models.Role) *adminOperationError {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return &adminOperationError{http.StatusInternalServerError, "failed to begin transaction"}
	}
	defer tx.Rollback(ctx)

	var familyID *string
	var oldRole models.Role
	if err := tx.QueryRow(ctx, `SELECT family_id, role FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&familyID, &oldRole); errors.Is(err, pgx.ErrNoRows) {
		return &adminOperationError{http.StatusNotFound, "user not found"}
	} else if err != nil {
		return &adminOperationError{http.StatusInternalServerError, "failed to load user"}
	}
	if familyID != nil {
		if err := tx.QueryRow(ctx, `SELECT id FROM families WHERE id = $1 FOR UPDATE`, *familyID).Scan(new(string)); err != nil {
			return &adminOperationError{http.StatusInternalServerError, "failed to lock family"}
		}
	}
	if familyID != nil && oldRole == models.RoleAdmin && role != models.RoleAdmin {
		var adminCount int
		if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM users WHERE family_id = $1 AND role = 'admin'`, *familyID).Scan(&adminCount); err != nil {
			return &adminOperationError{http.StatusInternalServerError, "failed to count family admins"}
		}
		if adminCount <= 1 {
			return &adminOperationError{http.StatusBadRequest, "cannot demote the last family admin"}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET role = $1, updated_at = now() WHERE id = $2`, role, userID); err != nil {
		return &adminOperationError{http.StatusInternalServerError, "failed to update role"}
	}
	if err := tx.Commit(ctx); err != nil {
		return &adminOperationError{http.StatusInternalServerError, "failed to commit"}
	}
	return nil
}

func (s *Server) adminUserByID(ctx context.Context, userID string) (adminUser, error) {
	var user adminUser
	err := s.Pool.QueryRow(ctx, `
		SELECT u.id, u.family_id, f.name, u.email, u.name, u.phone, u.role, u.platform_admin,
		       u.created_at, u.updated_at
		FROM users u
		LEFT JOIN families f ON f.id = u.family_id
		WHERE u.id = $1`, userID).Scan(&user.ID, &user.FamilyID, &user.FamilyName, &user.Email, &user.Name, &user.Phone,
		&user.Role, &user.PlatformAdmin, &user.CreatedAt, &user.UpdatedAt)
	return user, err
}

func stringPtrEqual(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

type adminUpdateUserRequest struct {
	Name  *string `json:"name"`
	Email *string `json:"email"`
	Phone *string `json:"phone"`
}

// validateAdminEmail applies the same rules as account creation.
func validateAdminEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" || len(email) > maxAdminEmailLength {
		return "", errors.New("a valid email is required")
	}
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email {
		return "", errors.New("a valid email is required")
	}
	return email, nil
}

// AdminUpdateUser edits another account's name, email and phone. All fields
// are optional; only those present are changed.
//
// Changing an email changes the login identity, so it bumps token_version
// (revoking refresh tokens and access tokens) and revokes device ingest keys,
// exactly like a password reset. Policy: the email of a platform admin other
// than the caller cannot be changed here, because rewriting another operator's
// login identity is an account-takeover vector. Admins may still edit their
// own email (which signs them out) and any platform admin's name or phone.
func (s *Server) AdminUpdateUser(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req adminUpdateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == nil && req.Email == nil && req.Phone == nil {
		writeError(w, http.StatusBadRequest, "provide name, email or phone")
		return
	}
	var name *string
	if req.Name != nil {
		n := strings.TrimSpace(*req.Name)
		if len([]rune(n)) == 0 || len([]rune(n)) > maxAdminNameLength {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("name is required and must be %d characters or fewer", maxAdminNameLength))
			return
		}
		name = &n
	}
	var email *string
	if req.Email != nil {
		e, err := validateAdminEmail(*req.Email)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		email = &e
	}
	updatePhone := req.Phone != nil
	phone := ""
	if updatePhone {
		normalized, err := sms.NormalizeE164(*req.Phone)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		phone = normalized
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var curEmail string
	var targetIsAdmin bool
	var familyID *string
	err = tx.QueryRow(r.Context(),
		`SELECT email, platform_admin, family_id FROM users WHERE id = $1 FOR UPDATE`, userID,
	).Scan(&curEmail, &targetIsAdmin, &familyID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "user not found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	emailChanged := email != nil && *email != curEmail
	if emailChanged && targetIsAdmin && userID != claims.UserID {
		writeError(w, http.StatusForbidden, "cannot change another platform admin's email")
		return
	}
	if _, err := tx.Exec(r.Context(), `
		UPDATE users SET
			name = COALESCE($1, name),
			email = COALESCE($2, email),
			phone = CASE WHEN $3 THEN NULLIF($4, '') ELSE phone END,
			token_version = CASE WHEN $5 THEN token_version + 1 ELSE token_version END,
			updated_at = now()
		WHERE id = $6`, name, email, updatePhone, phone, emailChanged, userID); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			if strings.Contains(pgErr.ConstraintName, "phone") {
				writeError(w, http.StatusConflict, "phone number already in use by another account")
			} else {
				writeError(w, http.StatusConflict, "email already registered to another account")
			}
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to update user")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if emailChanged {
		if err := s.revokeIngestKeys(r.Context(), userID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to revoke device keys")
			return
		}
		s.dropUserSockets(userID)
	}
	user, err := s.adminUserByID(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load updated user")
		return
	}
	fields := []string{}
	if name != nil {
		fields = append(fields, "name")
	}
	if email != nil {
		fields = append(fields, "email")
	}
	if updatePhone {
		fields = append(fields, "phone")
	}
	fam := ""
	if familyID != nil {
		fam = *familyID
	}
	detail := "edited user " + userID + " fields: " + strings.Join(fields, ",")
	if emailChanged {
		detail += " (email changed, sessions revoked)"
	}
	s.logAudit(r.Context(), claims.UserID, fam, "admin.user_updated", detail, clientIP(r))
	writeJSON(w, http.StatusOK, user)
}
