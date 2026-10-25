package handlers

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// inviteError is a user-facing invite-code validation failure (invalid,
// expired, or exhausted). It is distinct from internal errors so the handler
// can map it to a 400 rather than a 500.
type inviteError struct{ msg string }

func (e *inviteError) Error() string { return e.msg }

// inviteCodeAlphabet is a Crockford-style base32 alphabet: digits and letters
// with the ambiguous characters (0/O, 1/I/L) removed, so codes are easy to read
// and type. 8 characters give ~40 bits of entropy.
const (
	inviteCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	inviteCodeLength   = 8
)

// generateInviteCode returns a cryptographically random 8-character code drawn
// from inviteCodeAlphabet.
func generateInviteCode() (string, error) {
	b := make([]byte, inviteCodeLength)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(inviteCodeAlphabet))))
		if err != nil {
			return "", err
		}
		b[i] = inviteCodeAlphabet[n.Int64()]
	}
	return string(b), nil
}

// normalizeCode uppercases a code and strips everything but letters and digits,
// so "ab12-cd34" and "AB12CD34" match the same stored code.
func normalizeCode(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(strings.TrimSpace(code)) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// consumeInviteCode validates and consumes an invite code within tx, returning
// the family id and role the joining user should be assigned. It locks the code
// row (FOR UPDATE) so concurrent registrations cannot both consume the same
// single-use code. A user-facing failure returns an *inviteError; a real
// database failure returns the underlying error.
func (s *Server) consumeInviteCode(ctx context.Context, tx pgx.Tx, code string) (string, models.Role, error) {
	code = normalizeCode(code)
	if code == "" {
		return "", "", &inviteError{msg: "invalid invite code"}
	}
	var (
		id        string
		familyID  *string
		role      models.Role
		maxUses   int
		uses      int
		expiresAt *time.Time
	)
	err := tx.QueryRow(ctx, `
		SELECT id, family_id, role, max_uses, uses, expires_at
		FROM invite_codes WHERE code = $1 FOR UPDATE`, code,
	).Scan(&id, &familyID, &role, &maxUses, &uses, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", &inviteError{msg: "invalid invite code"}
	}
	if err != nil {
		return "", "", err
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		return "", "", &inviteError{msg: "invite code has expired"}
	}
	if uses >= maxUses {
		return "", "", &inviteError{msg: "invite code has already been used"}
	}
	if familyID == nil {
		// A code for a circle that is not a legacy family: only
		// POST /circles/join can redeem it. Rejected before it is consumed.
		return "", "", &inviteError{msg: "invalid invite code"}
	}
	if _, err := tx.Exec(ctx, `UPDATE invite_codes SET uses = uses + 1 WHERE id = $1`, id); err != nil {
		return "", "", err
	}
	return *familyID, role, nil
}

// insertInviteCode generates a unique code and inserts it within tx, returning
// the created row. It retries on the (astronomically unlikely) code collision.
func (s *Server) insertInviteCode(ctx context.Context, tx pgx.Tx, familyID string, createdBy *string, role models.Role, maxUses int, expiresAt *time.Time) (models.InviteCode, error) {
	var ic models.InviteCode
	for attempt := 0; attempt < 5; attempt++ {
		code, err := generateInviteCode()
		if err != nil {
			return ic, err
		}
		err = tx.QueryRow(ctx, `
			INSERT INTO invite_codes (code, family_id, created_by, role, max_uses, expires_at)
			VALUES ($1, $2, $3, $4, $5, $6)
			RETURNING id, code, family_id, created_by, role, max_uses, uses, expires_at, created_at`,
			code, familyID, createdBy, role, maxUses, expiresAt,
		).Scan(&ic.ID, &ic.Code, &ic.FamilyID, &ic.CreatedBy, &ic.Role, &ic.MaxUses, &ic.Uses, &ic.ExpiresAt, &ic.CreatedAt)
		if err == nil {
			return ic, nil
		}
		if isUniqueViolation(err) {
			continue
		}
		return ic, err
	}
	return ic, errors.New("failed to generate a unique invite code")
}

const (
	maxInviteUses       = 50
	maxInviteExpiryHrs  = 30 * 24
	defaultInviteExpiry = 7 * 24
)

// normalizeInviteParams applies defaults to an invite request: role defaults to
// member, max_uses to 1, and expiry to 7 days when not specified. Values above
// maxInviteUses / 30 days are rejected (BSEC-019), which also rules out
// time.Duration overflow from absurd expires_in_hours.
func normalizeInviteParams(role models.Role, maxUses, expiresInHours int) (models.Role, int, *time.Time, error) {
	if role == "" {
		role = models.RoleMember
	}
	if !role.Valid() {
		return "", 0, nil, errors.New("invalid role")
	}
	if maxUses <= 0 {
		maxUses = 1
	}
	if maxUses > maxInviteUses {
		return "", 0, nil, fmt.Errorf("max_uses must be at most %d", maxInviteUses)
	}
	hours := expiresInHours
	if hours <= 0 {
		hours = defaultInviteExpiry
	}
	if hours > maxInviteExpiryHrs {
		return "", 0, nil, fmt.Errorf("expires_in_hours must be at most %d", maxInviteExpiryHrs)
	}
	t := time.Now().Add(time.Duration(hours) * time.Hour)
	return role, maxUses, &t, nil
}

// CreateFamilyInvite generates an invite code for the caller's family (family
// admin only). The code assigns the joining user to this family with the given
// role.
func (s *Server) CreateFamilyInvite(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}
	if familyID == "" {
		writeError(w, http.StatusNotFound, "no family")
		return
	}
	isAdmin, err := s.userIsAdmin(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}
	if !isAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}

	var req struct {
		Role           models.Role `json:"role"`
		MaxUses        int         `json:"max_uses"`
		ExpiresInHours int         `json:"expires_in_hours"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	role, maxUses, expiresAt, err := normalizeInviteParams(req.Role, req.MaxUses, req.ExpiresInHours)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	ic, err := s.insertInviteCode(r.Context(), tx, familyID, &claims.UserID, role, maxUses, expiresAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create invite code")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	s.logAudit(r.Context(), claims.UserID, familyID, "family.invite_created",
		"created invite code "+ic.Code, clientIP(r))
	writeJSON(w, http.StatusCreated, ic)
}

// JoinFamily assigns an already-registered user to a family by consuming an
// invite code. This covers users who registered before invites were required
// (or in open mode) and now want to join a family. A user who already belongs
// to a family is rejected so joining cannot silently abandon it.
func (s *Server) JoinFamily(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("join", clientIP(r)), joinPerIP, joinWindow) {
		return
	}
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
	code := strings.TrimSpace(req.Code)
	if code == "" {
		writeError(w, http.StatusBadRequest, "code is required")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var existingFamily *string
	if err := tx.QueryRow(r.Context(), `SELECT family_id FROM users WHERE id = $1 FOR UPDATE`, claims.UserID).Scan(&existingFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if existingFamily != nil {
		writeError(w, http.StatusConflict, "user already belongs to a family")
		return
	}

	familyID, role, err := s.consumeInviteCode(r.Context(), tx, code)
	if err != nil {
		var ie *inviteError
		if errors.As(err, &ie) {
			writeError(w, http.StatusBadRequest, ie.msg)
		} else {
			writeError(w, http.StatusInternalServerError, "failed to validate invite code")
		}
		return
	}

	if _, err := tx.Exec(r.Context(), `
		UPDATE users SET family_id = $1, role = $2, updated_at = now()
		WHERE id = $3`, familyID, role, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to join family")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	s.logAudit(r.Context(), claims.UserID, familyID, "family.join",
		"joined family via invite code", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// adminInvite is an invite code tagged with its family name, for the admin
// panel list.
type adminInvite struct {
	models.InviteCode
	FamilyName string `json:"family_name"`
}

// AdminCreateInvite generates an invite code for any family (platform admin).
func (s *Server) AdminCreateInvite(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		FamilyID       string      `json:"family_id"`
		Role           models.Role `json:"role"`
		MaxUses        int         `json:"max_uses"`
		ExpiresInHours int         `json:"expires_in_hours"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.FamilyID == "" {
		writeError(w, http.StatusBadRequest, "family_id is required")
		return
	}
	role, maxUses, expiresAt, err := normalizeInviteParams(req.Role, req.MaxUses, req.ExpiresInHours)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Verify the family exists before inserting (FK would also catch this, but
	// a clear 404 is friendlier than a 500).
	var exists bool
	if err := s.Pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM families WHERE id = $1)`, req.FamilyID).Scan(&exists); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify family")
		return
	}
	if !exists {
		writeError(w, http.StatusNotFound, "family not found")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	ic, err := s.insertInviteCode(r.Context(), tx, req.FamilyID, &claims.UserID, role, maxUses, expiresAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create invite code")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	s.logAudit(r.Context(), claims.UserID, req.FamilyID, "admin.invite_created",
		"created invite code "+ic.Code+" for family "+req.FamilyID, clientIP(r))
	writeJSON(w, http.StatusCreated, ic)
}

// AdminListInvites returns every invite code across all families, tagged with
// the family name (platform admin).
func (s *Server) AdminListInvites(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT ic.id, ic.code, ic.family_id, ic.created_by, ic.role, ic.max_uses,
		       ic.uses, ic.expires_at, ic.created_at, COALESCE(f.name, '')
		FROM invite_codes ic
		LEFT JOIN families f ON f.id = ic.family_id
		WHERE ic.family_id IS NOT NULL
		ORDER BY ic.created_at DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list invite codes")
		return
	}
	defer rows.Close()

	invites := []adminInvite{}
	for rows.Next() {
		var inv adminInvite
		if err := rows.Scan(&inv.ID, &inv.Code, &inv.FamilyID, &inv.CreatedBy, &inv.Role,
			&inv.MaxUses, &inv.Uses, &inv.ExpiresAt, &inv.CreatedAt, &inv.FamilyName); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan invite code")
			return
		}
		invites = append(invites, inv)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read invite codes")
		return
	}
	writeJSON(w, http.StatusOK, invites)
}
