package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// UpdateFamilyMember lets the admin of a circle/family edit a member's name
// and phone: PATCH /family/members/{id} {name?, phone?}. Email, role,
// password and 2FA are deliberately out of scope. A caller who shares no
// circle with the target gets 404 (existence is not leaked); a plain member of
// a shared circle gets 403. Platform-admin accounts can only be edited by
// themselves here.
func (s *Server) UpdateFamilyMember(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	targetID := chi.URLParam(r, "id")
	if !circles.ValidID(targetID) {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	var req struct {
		Name  *string `json:"name"`
		Phone *string `json:"phone"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == nil && req.Phone == nil {
		writeError(w, http.StatusBadRequest, "provide name or phone")
		return
	}

	// Authorize before validating values so outsiders learn nothing.
	var shared, adminOf bool
	var circleID *string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT COUNT(*) > 0,
		       COALESCE(bool_or(cm.role = 'admin'), false),
		       (array_agg(cm.circle_id ORDER BY (cm.role = 'admin') DESC, cm.joined_at))[1]
		FROM circle_members cm
		JOIN circle_members tm ON tm.circle_id = cm.circle_id AND tm.user_id = $2
		WHERE cm.user_id = $1`, claims.UserID, targetID).Scan(&shared, &adminOf, &circleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	if !shared {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if !adminOf {
		writeError(w, http.StatusForbidden, "admin only")
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

	var targetPlatformAdmin bool
	err = tx.QueryRow(r.Context(),
		`SELECT platform_admin FROM users WHERE id = $1 FOR UPDATE`, targetID).Scan(&targetPlatformAdmin)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "member not found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	if targetPlatformAdmin && targetID != claims.UserID {
		writeError(w, http.StatusForbidden, "cannot edit a platform admin's details")
		return
	}
	if _, err := tx.Exec(r.Context(), `
		UPDATE users SET
			name = COALESCE($1, name),
			phone = CASE WHEN $2 THEN NULLIF($3, '') ELSE phone END,
			updated_at = now()
		WHERE id = $4`, name, updatePhone, phone, targetID); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			writeError(w, http.StatusConflict, "phone number already in use by another account")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to update member")
		return
	}
	var out models.User
	if err := tx.QueryRow(r.Context(), `
		SELECT id, family_id, email, name, phone, role, totp_enabled, created_at, updated_at
		FROM users WHERE id = $1`, targetID).Scan(&out.ID, &out.FamilyID, &out.Email, &out.Name,
		&out.Phone, &out.Role, &out.TOTPEnabled, &out.CreatedAt, &out.UpdatedAt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load updated member")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	fields := []string{}
	if name != nil {
		fields = append(fields, "name")
	}
	if updatePhone {
		fields = append(fields, "phone")
	}
	fam := ""
	if circleID != nil {
		fam = *circleID
	}
	s.logAudit(r.Context(), claims.UserID, fam, "family.member_updated",
		"edited member "+targetID+" fields: "+strings.Join(fields, ","), clientIP(r))
	writeJSON(w, http.StatusOK, out)
}
