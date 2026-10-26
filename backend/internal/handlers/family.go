package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// CreateFamily creates a family and assigns the caller as its admin.
func (s *Server) CreateFamily(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Reject if the user already belongs to a family, so creating a new family
	// cannot silently abandon (and orphan) an existing one. The FOR UPDATE lock
	// serializes concurrent CreateFamily calls for the same user.
	var existingFamily *string
	if err := tx.QueryRow(r.Context(), `
		SELECT family_id FROM users WHERE id = $1 FOR UPDATE`, claims.UserID).Scan(&existingFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if existingFamily != nil {
		writeError(w, http.StatusConflict, "user already belongs to a family")
		return
	}

	var family models.Family
	err = tx.QueryRow(r.Context(), `
		INSERT INTO families (name) VALUES ($1)
		RETURNING id, name, settings, created_at`, req.Name,
	).Scan(&family.ID, &family.Name, &family.Settings, &family.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create family")
		return
	}

	_, err = tx.Exec(r.Context(), `
		UPDATE users SET family_id = $1, role = 'admin' WHERE id = $2`,
		family.ID, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to assign family")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	writeJSON(w, http.StatusCreated, family)
}

// familyOut is the API representation of a family, including the caller's
// role and user id so the Flutter app can gate UI (e.g. hide place management
// for children) without a separate member-list fetch.
type familyOut struct {
	models.Family
	Role   models.Role `json:"role"`
	UserID string      `json:"user_id"`
}

// GetFamily returns the caller's family.
func (s *Server) GetFamily(w http.ResponseWriter, r *http.Request) {
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

	var family models.Family
	err = s.Pool.QueryRow(r.Context(), `
		SELECT id, name, settings, created_at FROM families WHERE id = $1`,
		familyID,
	).Scan(&family.ID, &family.Name, &family.Settings, &family.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "family not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}

	var role models.Role
	if err := s.Pool.QueryRow(r.Context(), `SELECT role FROM users WHERE id = $1`, claims.UserID).Scan(&role); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}
	writeJSON(w, http.StatusOK, familyOut{Family: family, Role: role, UserID: claims.UserID})
}

// RenameFamily changes the caller's family name (family admin only).
func (s *Server) RenameFamily(w http.ResponseWriter, r *http.Request) {
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
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	tag, err := s.Pool.Exec(r.Context(), `UPDATE families SET name = $1 WHERE id = $2`, name, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rename family")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "family not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "family.renamed",
		"renamed family to "+name, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "name": name})
}

// leaveFamilyBlocked reports whether the caller is the last admin and therefore
// cannot leave (they must promote someone else first).
func leaveFamilyBlocked(role models.Role, adminCount int) bool {
	return role == models.RoleAdmin && adminCount <= 1
}

// LeaveFamily removes the caller from their family. The last admin cannot
// leave until they promote another member.
func (s *Server) LeaveFamily(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var familyID *string
	var role models.Role
	if err := tx.QueryRow(r.Context(), `
		SELECT family_id, role FROM users WHERE id = $1 FOR UPDATE`, claims.UserID,
	).Scan(&familyID, &role); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	if familyID == nil {
		writeError(w, http.StatusNotFound, "no family")
		return
	}

	var lockedFamily string
	if err := tx.QueryRow(r.Context(), `
		SELECT id FROM families WHERE id = $1 FOR UPDATE`, *familyID).Scan(&lockedFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}

	var adminCount int
	if err := tx.QueryRow(r.Context(), `
		SELECT COUNT(*) FROM users WHERE family_id = $1 AND role = 'admin'`,
		*familyID).Scan(&adminCount); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count admins")
		return
	}
	if leaveFamilyBlocked(role, adminCount) {
		writeError(w, http.StatusConflict, "cannot leave as the last admin")
		return
	}

	if _, err := tx.Exec(r.Context(), `
		UPDATE users SET family_id = NULL, role = 'member', updated_at = now()
		WHERE id = $1`, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to leave family")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.disconnectFamilyUser(claims.UserID)
	}
	s.logAudit(r.Context(), claims.UserID, *familyID, "family.left",
		"left family", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ListMembers returns all users in the caller's family with their last-known
// position (if any).
func (s *Server) ListMembers(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	// Scope: ?circle_id=<uuid> lists one circle (404 for a malformed id or a
	// non-member, so ids cannot be probed), ?circle_id=all every circle of the
	// caller, and no parameter the legacy primary circle.
	az := circles.New(s.Pool)
	scope := []string{}
	switch q := r.URL.Query().Get("circle_id"); q {
	case "":
		familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load family")
			return
		}
		if familyID == "" {
			writeError(w, http.StatusNotFound, "no family")
			return
		}
		scope = []string{familyID}
	case "all":
		ids, err := az.CircleIDs(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load circles")
			return
		}
		if len(ids) == 0 {
			writeError(w, http.StatusNotFound, "no family")
			return
		}
		scope = ids
	default:
		scope = []string{strings.ToLower(q)}
	}

	// Children may see member names/locations but not email addresses.
	canManage, err := s.userCanManage(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}

	// Location fields are only filled for members who share with the caller in
	// the scope (the caller always sees themselves); a member who turned
	// sharing off stays listed. Phone numbers go to admins of a scoped circle.
	adminOf := map[string]bool{}
	for _, id := range scope {
		m, err := az.RequireMember(r.Context(), claims.UserID, id)
		if err != nil {
			if errors.Is(err, circles.ErrNotFound) {
				writeError(w, http.StatusNotFound, "no family")
				return
			}
			writeError(w, http.StatusInternalServerError, "failed to load family")
			return
		}
		if m.Role == circles.RoleAdmin {
			adminOf[id] = true
		}
	}
	visible, err := az.LocationVisibility(r.Context(), claims.UserID, scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	byMember, err := az.MemberCircles(r.Context(), claims.UserID, scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	memberIDs := make([]string, 0, len(visible))
	for id := range visible {
		memberIDs = append(memberIDs, id)
	}

	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id, u.email, u.name, u.role, u.totp_enabled, u.created_at, u.updated_at,
		       u.avatar_data IS NOT NULL, u.avatar_version, u.avatar_updated_at,
		       mp.lat, mp.lon, mp.ts, mp.battery_pct, mp.speed_mps, mp.motion_state, mp.accuracy_meters,
		       d.last_seen, u.phone, u.platform_admin
		FROM users u
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		LEFT JOIN (
			SELECT user_id, MAX(last_seen) AS last_seen
			FROM devices GROUP BY user_id
		) d ON d.user_id = u.id
		WHERE u.id = ANY($1::uuid[])
		ORDER BY u.name`, memberIDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	defer rows.Close()

	members := []models.MemberWithLocation{}
	for rows.Next() {
		var m models.MemberWithLocation
		var memberIsPlatformAdmin bool
		if err := rows.Scan(&m.ID, &m.Email, &m.Name, &m.Role, &m.TOTPEnabled, &m.CreatedAt, &m.UpdatedAt,
			&m.HasAvatar, &m.AvatarVersion, &m.AvatarUpdatedAt,
			&m.Lat, &m.Lon, &m.TS, &m.BatteryPct, &m.SpeedMPS, &m.MotionState, &m.AccuracyMeters,
			&m.LastSeenAt, &m.Phone, &memberIsPlatformAdmin); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan member")
			return
		}
		if !visible[m.ID] {
			m.Lat, m.Lon, m.TS, m.BatteryPct, m.SpeedMPS, m.MotionState, m.AccuracyMeters, m.LastSeenAt =
				nil, nil, nil, nil, nil, nil, nil, nil
		}
		for _, mc := range byMember[m.ID] {
			m.CircleIDs = append(m.CircleIDs, mc.CircleID)
			if mc.Sharing {
				m.SharingCircleIDs = append(m.SharingCircleIDs, mc.CircleID)
			}
		}
		if !canManage {
			m.Email = "" // redact email for non-manager (child) viewers
		}
		// Phone numbers go only to admins of a circle they share with this
		// member (who can edit them), never to plain members, and never for
		// platform-admin accounts other than the caller's own.
		adminHere := false
		for _, mc := range byMember[m.ID] {
			if adminOf[mc.CircleID] {
				adminHere = true
			}
		}
		if !adminHere || (memberIsPlatformAdmin && m.ID != claims.UserID) {
			m.Phone = nil
		}
		members = append(members, m)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read members")
		return
	}
	writeJSON(w, http.StatusOK, members)
}

// GetFamilyMemberAvatar returns a member's avatar only when the caller and
// member currently belong to the same family. The image itself stays behind an
// authenticated request; list and WebSocket responses carry metadata only.
func (s *Server) GetFamilyMemberAvatar(w http.ResponseWriter, r *http.Request) {
	setPrivateProfileHeaders(w)
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	memberID := chi.URLParam(r, "id")
	if memberID == "" {
		writeError(w, http.StatusBadRequest, "member id is required")
		return
	}

	var avatar []byte
	var contentType string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT member.avatar_data, member.avatar_content_type
		FROM users AS caller
		JOIN users AS member
		  ON member.id = $2
		 AND member.family_id = caller.family_id
		WHERE caller.id = $1
		  AND caller.family_id IS NOT NULL
		  AND member.avatar_data IS NOT NULL`, claims.UserID, memberID,
	).Scan(&avatar, &contentType)
	if errors.Is(err, pgx.ErrNoRows) {
		// Deliberately use the same response for a missing photo and a member in
		// another family, so this endpoint does not disclose membership.
		writeError(w, http.StatusNotFound, "member avatar not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member avatar")
		return
	}
	writePrivateAvatar(w, avatar, contentType)
}

// UpdateMemberRole changes a member's role (admin only).
func (s *Server) UpdateMemberRole(w http.ResponseWriter, r *http.Request) {
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

	userID := chi.URLParam(r, "id")
	var req struct {
		Role models.Role `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !req.Role.Valid() {
		writeError(w, http.StatusBadRequest, "invalid role")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Lock the family row to serialize all role changes within the family, so
	// two concurrent demotions of different admins cannot both pass the
	// last-admin check (which would otherwise read a stale admin count).
	var lockedFamily string
	if err := tx.QueryRow(r.Context(), `
		SELECT id FROM families WHERE id = $1 FOR UPDATE`, familyID).Scan(&lockedFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}

	// Only admins may change roles (prevents a child from self-promoting to
	// admin and bypassing the geofence/place role checks). Re-checked inside
	// the transaction, after the family-row lock, so a concurrent demotion of
	// the caller cannot race this check (TOCTOU).
	var callerRole models.Role
	if err := tx.QueryRow(r.Context(), `SELECT role FROM users WHERE id = $1`, claims.UserID).Scan(&callerRole); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}
	if callerRole != models.RoleAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}

	// Lock the target user and guard against demoting the last admin.
	var targetRole models.Role
	err = tx.QueryRow(r.Context(), `
		SELECT role FROM users WHERE id = $1 AND family_id = $2 FOR UPDATE`,
		userID, familyID).Scan(&targetRole)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	if targetRole == models.RoleAdmin && req.Role != models.RoleAdmin {
		var adminCount int
		if err := tx.QueryRow(r.Context(), `
			SELECT COUNT(*) FROM users WHERE family_id = $1 AND role = 'admin'`,
			familyID).Scan(&adminCount); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to count admins")
			return
		}
		if adminCount <= 1 {
			writeError(w, http.StatusBadRequest, "cannot demote the last admin")
			return
		}
	}

	tag, err := tx.Exec(r.Context(), `
		UPDATE users SET role = $1, updated_at = now()
		WHERE id = $2 AND family_id = $3`,
		req.Role, userID, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update role")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "family.role_change",
		"changed role of user "+userID+" to "+string(req.Role), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
