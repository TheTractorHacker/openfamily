package handlers

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Platform-admin view of a circle's members. Shows who belongs, their circle
// role and whether they currently share their location into the circle, but
// never any coordinates: reading a live location stays a separate, audited
// action (admin.location_view).

type adminCircleMemberOut struct {
	UserID         string       `json:"user_id"`
	Name           string       `json:"name"`
	Email          string       `json:"email"`
	Role           circles.Role `json:"role"`
	SharingEnabled bool         `json:"sharing_enabled"`
	JoinedAt       time.Time    `json:"joined_at"`
}

// AdminListCircleMembers lists every member of one circle (including a
// temporary circle that has lapsed but is not purged yet).
// GET /api/admin/circles/{id}/members
func (s *Server) AdminListCircleMembers(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	var exists bool
	if err := s.Pool.QueryRow(r.Context(), `SELECT EXISTS (SELECT 1 FROM circles WHERE id = $1)`, id).Scan(&exists); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	if !exists {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id::text, u.name, u.email, cm.role, cm.sharing_enabled, cm.joined_at
		FROM circle_members cm JOIN users u ON u.id = cm.user_id
		WHERE cm.circle_id = $1
		ORDER BY (cm.role = 'admin') DESC, u.name, u.id`, id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	defer rows.Close()
	out := []adminCircleMemberOut{}
	for rows.Next() {
		var m adminCircleMemberOut
		if err := rows.Scan(&m.UserID, &m.Name, &m.Email, &m.Role, &m.SharingEnabled, &m.JoinedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read members")
			return
		}
		out = append(out, m)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read members")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminRemoveCircleMember removes a member from a circle, repairing the legacy
// primary-circle pointer exactly like the member-facing endpoint. The last
// admin of a circle cannot be removed (end or delete the circle instead).
// DELETE /api/admin/circles/{id}/members/{user_id}
func (s *Server) AdminRemoveCircleMember(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	circleID, target := chi.URLParam(r, "id"), chi.URLParam(r, "user_id")
	if !circles.ValidID(circleID) || !circles.ValidID(target) {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())
	admins, err := lockCircleAdmins(r.Context(), tx, circleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock circle")
		return
	}
	var role string
	if err := tx.QueryRow(r.Context(),
		`SELECT role FROM circle_members WHERE circle_id = $1 AND user_id = $2`, circleID, target).Scan(&role); err != nil {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if role == string(circles.RoleAdmin) && admins <= 1 {
		writeError(w, http.StatusConflict, "cannot remove the last admin of a circle")
		return
	}
	if err := removeMemberTx(r.Context(), tx, circleID, target); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to remove member")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.unsubscribeUser(target, circleID)
	}
	s.auditCircle(r.Context(), claims.UserID, circleID, "admin.circle.member_removed", "removed user "+target, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
