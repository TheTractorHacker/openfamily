package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

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
	s.auditRekeyIfNeeded(r.Context(), claims.UserID, circleID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type adminAddCircleMemberRequest struct {
	UserID string `json:"user_id"`
	Role   string `json:"role"`
}

// AdminAddCircleMember puts an existing account into a circle. Joining by invite
// code always joins the signed-in user, so an admin who created someone's account
// had no way to place that person in an app-made circle; this is that way.
// It applies the same rules as joining by code: a live circle, not already a
// member, the per-user circle limit and the old-app guard. No code is consumed.
// POST /api/admin/circles/{id}/members  {"user_id": "...", "role": "member"|"admin"}
func (s *Server) AdminAddCircleMember(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	circleID := chi.URLParam(r, "id")
	var req adminAddCircleMemberRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Role == "" {
		req.Role = string(circles.RoleMember)
	}
	if req.Role != string(circles.RoleMember) && req.Role != string(circles.RoleAdmin) {
		writeError(w, http.StatusBadRequest, "role must be member or admin")
		return
	}
	if !circles.ValidID(circleID) {
		writeError(w, http.StatusNotFound, "circle not found")
		return
	}
	if !circles.ValidID(req.UserID) {
		writeError(w, http.StatusBadRequest, "user_id is required")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var familyBacked bool
	var e2eeMode string
	err = tx.QueryRow(r.Context(), `
		SELECT EXISTS (SELECT 1 FROM families f WHERE f.id = c.id), c.e2ee_mode
		FROM circles c WHERE c.id = $1 AND `+circleLiveSQL+` FOR UPDATE OF c`, circleID).Scan(&familyBacked, &e2eeMode)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "circle not found or already ended")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	if e2eeMode == "private" {
		// The server cannot grant membership of an end-to-end-encrypted circle: the members' phones
		// would hand the circle key to the new account on first use. Members join by invite.
		writeError(w, http.StatusConflict, "cannot add members to a private (end-to-end encrypted) circle; use an invite")
		return
	}
	var primary *string
	var targetIsAdmin bool
	err = tx.QueryRow(r.Context(), `SELECT family_id::text, platform_admin FROM users WHERE id = $1 FOR UPDATE`, req.UserID).Scan(&primary, &targetIsAdmin)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if (req.UserID == claims.UserID || targetIsAdmin) && !s.AdminLocationAccess {
		// Membership gives the ordinary member API the circle's live and historic locations, so an
		// administrator account is placed like a location read, which this deployment has turned off.
		_ = tx.Rollback(r.Context()) // release the row locks before the audit write needs them
		s.adminLocationDenied(r.Context(), claims.UserID, "", "denied adding platform admin "+req.UserID+" to circle "+circleID, clientIP(r))
		writeError(w, http.StatusForbidden, "platform admin location access is disabled; an admin account cannot be added to a circle")
		return
	}
	var already bool
	if err := tx.QueryRow(r.Context(),
		`SELECT EXISTS (SELECT 1 FROM circle_members WHERE circle_id = $1 AND user_id = $2)`,
		circleID, req.UserID).Scan(&already); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check membership")
		return
	}
	if already {
		writeError(w, http.StatusConflict, "already a member of this circle")
		return
	}
	var n int
	if err := tx.QueryRow(r.Context(), `SELECT count(*) FROM live_circle_members WHERE user_id = $1`, req.UserID).Scan(&n); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count circles")
		return
	}
	if n >= maxCirclesPerUser {
		writeError(w, http.StatusConflict, "circle limit reached")
		return
	}
	if oldAppBlocksJoin(r.Context(), tx, circleID, req.UserID) {
		writeUpdateRequired(w, nil)
		return
	}

	if familyBacked && primary == nil {
		// Same as joining by code with no group yet: the circle becomes the primary one and
		// users.role takes the role. The trigger adds the membership row.
		_, err = tx.Exec(r.Context(),
			`UPDATE users SET family_id = $1, role = $2, updated_at = now() WHERE id = $3`,
			circleID, req.Role, req.UserID)
	} else {
		_, err = tx.Exec(r.Context(),
			`INSERT INTO circle_members (circle_id, user_id, role) VALUES ($1, $2, $3)
			 ON CONFLICT (circle_id, user_id) DO NOTHING`, circleID, req.UserID, req.Role)
	}
	if err != nil {
		if isUpdateRequiredErr(err) {
			writeUpdateRequired(w, nil)
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to add member")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.subscribeUser(req.UserID, circleID)
	}
	s.auditCircle(r.Context(), claims.UserID, circleID, "admin.circle.member_added",
		"added user "+req.UserID+" as "+req.Role, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "circle_id": circleID})
}
