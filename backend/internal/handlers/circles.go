package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/circles"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/models"
)

// Circle API (stage 1). Every handler authorizes through internal/circles;
// none of them reads users.family_id to decide access. See docs/design/CIRCLES.md.

const (
	maxCirclesPerUser = 25
	maxCircleNameLen  = 100
	maxCircleIconLen  = 32
)

// circleOut is the API representation of a circle for its caller.
type circleOut struct {
	ID             string       `json:"id"`
	Name           string       `json:"name"`
	Icon           *string      `json:"icon"`
	CreatedBy      *string      `json:"created_by"`
	CreatedAt      time.Time    `json:"created_at"`
	Role           circles.Role `json:"role"`
	SharingEnabled bool         `json:"sharing_enabled"`
	JoinedAt       time.Time    `json:"joined_at"`
	MemberCount    int          `json:"member_count"`
	IsPrimary      bool         `json:"is_primary"`
}

type circleMemberOut struct {
	UserID         string       `json:"user_id"`
	Name           string       `json:"name"`
	Role           circles.Role `json:"role"`
	SharingEnabled bool         `json:"sharing_enabled"`
	JoinedAt       time.Time    `json:"joined_at"`
}

// circleCaller returns the authenticated user id or writes 401.
func circleCaller(w http.ResponseWriter, r *http.Request) (string, bool) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", false
	}
	return claims.UserID, true
}

// circleAuthError maps a helper error to a response. Not-a-member and
// no-such-circle both answer 404 so circle ids cannot be probed.
func circleAuthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, circles.ErrNotFound):
		writeError(w, http.StatusNotFound, "circle not found")
	case errors.Is(err, circles.ErrForbidden):
		writeError(w, http.StatusForbidden, "admin only")
	default:
		writeError(w, http.StatusInternalServerError, "failed to authorize")
	}
}

// requireCircleMember authorizes the caller as a member of the {id} circle.
func (s *Server) requireCircleMember(w http.ResponseWriter, r *http.Request) (string, circles.Membership, bool) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return "", circles.Membership{}, false
	}
	m, err := circles.New(s.Pool).RequireMember(r.Context(), uid, chi.URLParam(r, "id"))
	if err != nil {
		circleAuthError(w, err)
		return "", m, false
	}
	return uid, m, true
}

// requireCircleAdmin authorizes the caller as an admin of the {id} circle.
func (s *Server) requireCircleAdmin(w http.ResponseWriter, r *http.Request) (string, circles.Membership, bool) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return "", circles.Membership{}, false
	}
	m, err := circles.New(s.Pool).RequireAdmin(r.Context(), uid, chi.URLParam(r, "id"))
	if err != nil {
		circleAuthError(w, err)
		return "", m, false
	}
	return uid, m, true
}

// auditCircle writes an audit row. audit_log.family_id references families, so
// the circle id is only stored there when the circle is family-backed; the id
// is always in the detail text.
func (s *Server) auditCircle(ctx context.Context, userID, circleID, action, detail, ip string) {
	detail += " (circle " + circleID + ")"
	if s.auditHook != nil {
		s.auditHook(userID, circleID, action, detail)
		return
	}
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO audit_log (user_id, family_id, action, detail, ip_address)
		VALUES ($1, (SELECT id FROM families WHERE id = $2), $3, $4, $5)`,
		userID, circleID, action, detail, ip); err != nil {
		_ = err // audit is best effort, matching logAudit
	}
}

func cleanCircleName(name string) (string, bool) {
	name = strings.TrimSpace(name)
	n := utf8.RuneCountInString(name)
	return name, n > 0 && n <= maxCircleNameLen
}

func cleanCircleIcon(icon string) (string, bool) {
	icon = strings.TrimSpace(icon)
	return icon, utf8.RuneCountInString(icon) <= maxCircleIconLen
}

// circleRoleToUserRole maps a circle role onto the legacy users.role value for
// a circle that is the user's primary one. 'child' is not a circle role, so a
// legacy child stays a child when the circle role is member.
func legacyRoleFor(circleRole circles.Role, current models.Role) models.Role {
	if circleRole == circles.RoleAdmin {
		return models.RoleAdmin
	}
	if current == models.RoleChild {
		return models.RoleChild
	}
	return models.RoleMember
}

// reassignPrimarySQL moves users whose primary circle is $1 (optionally only
// user $2) to their oldest other family-backed circle, or to no family. The
// legacy endpoints keep working on whatever it picks, and never on a circle the
// user has left.
const reassignPrimarySQL = `
	UPDATE users u SET
	  family_id = (SELECT cm.circle_id FROM circle_members cm
	               JOIN families f ON f.id = cm.circle_id
	               WHERE cm.user_id = u.id AND cm.circle_id <> $1
	               ORDER BY cm.joined_at, cm.circle_id LIMIT 1),
	  role = COALESCE((SELECT CASE cm.role WHEN 'admin' THEN 'admin' ELSE 'member' END
	               FROM circle_members cm JOIN families f ON f.id = cm.circle_id
	               WHERE cm.user_id = u.id AND cm.circle_id <> $1
	               ORDER BY cm.joined_at, cm.circle_id LIMIT 1), 'member'),
	  updated_at = now()
	WHERE u.family_id = $1 AND ($2::uuid IS NULL OR u.id = $2)`

// removeMemberTx removes userID from circleID inside tx, repairing the legacy
// primary-circle pointer so the legacy endpoints lose access too.
func removeMemberTx(ctx context.Context, tx pgx.Tx, circleID, userID string) error {
	if _, err := tx.Exec(ctx, reassignPrimarySQL, circleID, userID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, circleID, userID)
	return err
}

// CreateCircle creates a circle; the caller becomes its admin.
func (s *Server) CreateCircle(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		Name string `json:"name"`
		Icon string `json:"icon"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	name, ok := cleanCircleName(req.Name)
	if !ok {
		writeError(w, http.StatusBadRequest, "name is required (max 100 characters)")
		return
	}
	icon, ok := cleanCircleIcon(req.Icon)
	if !ok {
		writeError(w, http.StatusBadRequest, "icon is too long")
		return
	}
	var iconArg any
	if icon != "" {
		iconArg = icon
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Serialize per user so the membership cap cannot be raced past.
	if _, err := tx.Exec(r.Context(), `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, uid); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	var n int
	if err := tx.QueryRow(r.Context(), `SELECT count(*) FROM circle_members WHERE user_id = $1`, uid).Scan(&n); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count circles")
		return
	}
	if n >= maxCirclesPerUser {
		writeError(w, http.StatusConflict, "circle limit reached")
		return
	}

	out := circleOut{Role: circles.RoleAdmin, SharingEnabled: true}
	err = tx.QueryRow(r.Context(), `
		INSERT INTO circles (name, icon, created_by) VALUES ($1, $2, $3)
		RETURNING id, name, icon, created_by, created_at`, name, iconArg, uid,
	).Scan(&out.ID, &out.Name, &out.Icon, &out.CreatedBy, &out.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create circle")
		return
	}
	if err := tx.QueryRow(r.Context(), `
		INSERT INTO circle_members (circle_id, user_id, role) VALUES ($1, $2, 'admin')
		RETURNING joined_at`, out.ID, uid).Scan(&out.JoinedAt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to add creator")
		return
	}
	out.MemberCount = 1
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.subscribeUser(uid, out.ID)
	}
	s.auditCircle(r.Context(), uid, out.ID, "circle.created", "created circle "+name, clientIP(r))
	writeJSON(w, http.StatusCreated, out)
}

// ListCircles returns the caller's circles with role and sharing state.
func (s *Server) ListCircles(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT c.id, c.name, c.icon, c.created_by, c.created_at,
		       cm.role, cm.sharing_enabled, cm.joined_at,
		       (SELECT count(*) FROM circle_members x WHERE x.circle_id = c.id),
		       COALESCE(u.family_id = c.id, false)
		FROM circle_members cm
		JOIN circles c ON c.id = cm.circle_id
		JOIN users u ON u.id = cm.user_id
		WHERE cm.user_id = $1
		ORDER BY cm.joined_at, c.id`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list circles")
		return
	}
	defer rows.Close()
	out := []circleOut{}
	for rows.Next() {
		var c circleOut
		if err := rows.Scan(&c.ID, &c.Name, &c.Icon, &c.CreatedBy, &c.CreatedAt,
			&c.Role, &c.SharingEnabled, &c.JoinedAt, &c.MemberCount, &c.IsPrimary); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read circles")
			return
		}
		out = append(out, c)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read circles")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// UpdateCircle renames a circle or changes its icon (circle admin only).
func (s *Server) UpdateCircle(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	var req struct {
		Name *string `json:"name"`
		Icon *string `json:"icon"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == nil && req.Icon == nil {
		writeError(w, http.StatusBadRequest, "nothing to update")
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())
	if req.Name != nil {
		name, ok := cleanCircleName(*req.Name)
		if !ok {
			writeError(w, http.StatusBadRequest, "name must be 1-100 characters")
			return
		}
		if _, err := tx.Exec(r.Context(), `UPDATE circles SET name = $1 WHERE id = $2`, name, m.CircleID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update circle")
			return
		}
		// Keep the legacy family name (GET /family) in step.
		if _, err := tx.Exec(r.Context(), `UPDATE families SET name = $1 WHERE id = $2`, name, m.CircleID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update circle")
			return
		}
	}
	if req.Icon != nil {
		icon, ok := cleanCircleIcon(*req.Icon)
		if !ok {
			writeError(w, http.StatusBadRequest, "icon is too long")
			return
		}
		var arg any
		if icon != "" {
			arg = icon
		}
		if _, err := tx.Exec(r.Context(), `UPDATE circles SET icon = $1 WHERE id = $2`, arg, m.CircleID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update circle")
			return
		}
	}
	var c circleOut
	if err := tx.QueryRow(r.Context(), `
		SELECT id, name, icon, created_by, created_at FROM circles WHERE id = $1`, m.CircleID,
	).Scan(&c.ID, &c.Name, &c.Icon, &c.CreatedBy, &c.CreatedAt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read circle")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	c.Role, c.SharingEnabled, c.JoinedAt = m.Role, m.SharingEnabled, m.JoinedAt
	s.auditCircle(r.Context(), uid, m.CircleID, "circle.updated", "updated circle", clientIP(r))
	writeJSON(w, http.StatusOK, c)
}

// DeleteCircle deletes a circle (circle admin only).
//
// Policy: it is refused with 409 when it is the ONLY circle of at least one
// member, because deleting it would leave that person with no circle. The admin
// can resubmit with ?force=true to delete anyway. A family-backed circle's
// legacy family row (places, geofences, history of alerts) is NOT deleted; only
// the circle and its memberships and invites are. Members whose primary circle
// it was are moved to their next family-backed circle, or to no family.
func (s *Server) DeleteCircle(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	force := r.URL.Query().Get("force") == "true"

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	if _, err := tx.Exec(r.Context(), `SELECT 1 FROM circles WHERE id = $1 FOR UPDATE`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock circle")
		return
	}
	var stranded int
	if err := tx.QueryRow(r.Context(), `
		SELECT count(*) FROM circle_members cm
		WHERE cm.circle_id = $1
		  AND (SELECT count(*) FROM circle_members x WHERE x.user_id = cm.user_id) = 1`,
		m.CircleID).Scan(&stranded); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check members")
		return
	}
	if stranded > 0 && !force {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":                 "circle is the only circle of some members; pass force=true to delete anyway",
			"members_without_other": stranded,
		})
		return
	}
	if _, err := tx.Exec(r.Context(), reassignPrimarySQL, m.CircleID, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update members")
		return
	}
	if _, err := tx.Exec(r.Context(), `DELETE FROM circles WHERE id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete circle")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.unsubscribeCircle(m.CircleID)
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "circle.deleted", "deleted circle", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ListCircleMembers lists the members of a circle with role and sharing state.
// It never returns locations; those travel only through the live read path.
func (s *Server) ListCircleMembers(w http.ResponseWriter, r *http.Request) {
	_, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id, u.name, cm.role, cm.sharing_enabled, cm.joined_at
		FROM circle_members cm JOIN users u ON u.id = cm.user_id
		WHERE cm.circle_id = $1
		ORDER BY u.name, u.id`, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	defer rows.Close()
	out := []circleMemberOut{}
	for rows.Next() {
		var mo circleMemberOut
		if err := rows.Scan(&mo.UserID, &mo.Name, &mo.Role, &mo.SharingEnabled, &mo.JoinedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read members")
			return
		}
		out = append(out, mo)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read members")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// lockCircleAdmins serializes membership changes in one circle and returns the
// current admin count.
func lockCircleAdmins(ctx context.Context, tx pgx.Tx, circleID string) (int, error) {
	if _, err := tx.Exec(ctx, `SELECT 1 FROM circles WHERE id = $1 FOR UPDATE`, circleID); err != nil {
		return 0, err
	}
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM circle_members WHERE circle_id = $1 AND role = 'admin'`, circleID).Scan(&n)
	return n, err
}

// RemoveCircleMember removes a member (circle admin) or lets a member leave
// (target == caller, or "me"). The last admin cannot leave or be removed.
func (s *Server) RemoveCircleMember(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	circleID := chi.URLParam(r, "id")
	target := chi.URLParam(r, "user_id")
	if target == "me" {
		target = uid
	}
	az := circles.New(s.Pool)
	caller, err := az.RequireMember(r.Context(), uid, circleID)
	if err != nil {
		circleAuthError(w, err)
		return
	}
	if target != uid && caller.Role != circles.RoleAdmin {
		writeError(w, http.StatusForbidden, "admin only")
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
	// Re-check inside the lock so a concurrent demotion cannot race us.
	cur, err := circles.New(tx).RequireMember(r.Context(), uid, circleID)
	if err != nil {
		circleAuthError(w, err)
		return
	}
	if target != uid && cur.Role != circles.RoleAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}
	tm, err := circles.New(tx).RequireMember(r.Context(), target, circleID)
	if err != nil {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if tm.Role == circles.RoleAdmin && admins <= 1 {
		writeError(w, http.StatusConflict, "cannot remove or leave as the last admin")
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
	action := "circle.member_removed"
	if target == uid {
		action = "circle.left"
	}
	s.auditCircle(r.Context(), uid, circleID, action, "user "+target, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// UpdateCircleMemberRole changes a member's role (circle admin only).
func (s *Server) UpdateCircleMemberRole(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	target := chi.URLParam(r, "user_id")
	var req struct {
		Role circles.Role `json:"role"`
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
	admins, err := lockCircleAdmins(r.Context(), tx, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock circle")
		return
	}
	// The caller must still be an admin once the lock is held.
	if _, err := circles.New(tx).RequireAdmin(r.Context(), uid, m.CircleID); err != nil {
		circleAuthError(w, err)
		return
	}
	tm, err := circles.New(tx).RequireMember(r.Context(), target, m.CircleID)
	if err != nil {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	if tm.Role == circles.RoleAdmin && req.Role != circles.RoleAdmin && admins <= 1 {
		writeError(w, http.StatusConflict, "cannot demote the last admin")
		return
	}
	if _, err := tx.Exec(r.Context(), `
		UPDATE circle_members SET role = $1 WHERE circle_id = $2 AND user_id = $3`,
		req.Role, m.CircleID, target); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update role")
		return
	}
	// If this is the target's primary circle, the legacy endpoints read
	// users.role, so it must follow (a legacy child stays a child).
	var cur models.Role
	err = tx.QueryRow(r.Context(), `SELECT role FROM users WHERE id = $1 AND family_id = $2 FOR UPDATE`,
		target, m.CircleID).Scan(&cur)
	if err == nil {
		if _, err := tx.Exec(r.Context(), `UPDATE users SET role = $1, updated_at = now() WHERE id = $2`,
			legacyRoleFor(req.Role, cur), target); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update role")
			return
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to update role")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "circle.role_change",
		"changed role of user "+target+" to "+string(req.Role), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// SetCircleSharing turns the caller's own location sharing on or off for one
// circle. It is read from the database on every live update, so the change is
// effective immediately.
func (s *Server) SetCircleSharing(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Enabled == nil {
		writeError(w, http.StatusBadRequest, "enabled is required")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE circle_members SET sharing_enabled = $1 WHERE circle_id = $2 AND user_id = $3`,
		*req.Enabled, m.CircleID, uid); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update sharing")
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "circle.sharing", "sharing set to "+boolWord(*req.Enabled), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"circle_id": m.CircleID, "sharing_enabled": *req.Enabled})
}

func boolWord(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

// circleInviteOut is a per-circle invitation.
type circleInviteOut struct {
	ID        string       `json:"id"`
	Code      string       `json:"code"`
	CircleID  string       `json:"circle_id"`
	Role      circles.Role `json:"role"`
	MaxUses   int          `json:"max_uses"`
	Uses      int          `json:"uses"`
	ExpiresAt *time.Time   `json:"expires_at"`
	CreatedAt time.Time    `json:"created_at"`
}

// CreateCircleInvite creates an invite code for a circle (circle admin only).
// Roles are admin or member. For a family-backed circle family_id is set too,
// so the code also works in the legacy join and register flows.
func (s *Server) CreateCircleInvite(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
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
	if !circles.Role(role).Valid() {
		writeError(w, http.StatusBadRequest, "role must be admin or member")
		return
	}
	var inv circleInviteOut
	for attempt := 0; attempt < 5; attempt++ {
		code, err := generateInviteCode()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to create invite code")
			return
		}
		err = s.Pool.QueryRow(r.Context(), `
			INSERT INTO invite_codes (code, family_id, circle_id, created_by, role, max_uses, expires_at)
			VALUES ($1, (SELECT id FROM families WHERE id = $2), $2, $3, $4, $5, $6)
			RETURNING id, code, circle_id, role, max_uses, uses, expires_at, created_at`,
			code, m.CircleID, uid, role, maxUses, expiresAt,
		).Scan(&inv.ID, &inv.Code, &inv.CircleID, &inv.Role, &inv.MaxUses, &inv.Uses, &inv.ExpiresAt, &inv.CreatedAt)
		if err == nil {
			s.auditCircle(r.Context(), uid, m.CircleID, "circle.invite_created", "created invite code "+inv.Code, clientIP(r))
			writeJSON(w, http.StatusCreated, inv)
			return
		}
		if !isUniqueViolation(err) {
			writeError(w, http.StatusInternalServerError, "failed to create invite code")
			return
		}
	}
	writeError(w, http.StatusInternalServerError, "failed to generate a unique invite code")
}

// ListCircleInvites lists a circle's invite codes (circle admin only).
func (s *Server) ListCircleInvites(w http.ResponseWriter, r *http.Request) {
	_, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, code, COALESCE(circle_id, family_id), role, max_uses, uses, expires_at, created_at
		FROM invite_codes WHERE COALESCE(circle_id, family_id) = $1
		ORDER BY created_at DESC`, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list invites")
		return
	}
	defer rows.Close()
	out := []circleInviteOut{}
	for rows.Next() {
		var inv circleInviteOut
		if err := rows.Scan(&inv.ID, &inv.Code, &inv.CircleID, &inv.Role, &inv.MaxUses, &inv.Uses, &inv.ExpiresAt, &inv.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read invites")
			return
		}
		out = append(out, inv)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read invites")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// RevokeCircleInvite deletes an invite code of the {id} circle (admin only).
// The invite must belong to that circle, so an admin of one circle cannot
// revoke another circle's code by guessing its id.
func (s *Server) RevokeCircleInvite(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	inviteID := chi.URLParam(r, "invite_id")
	if !circles.ValidID(inviteID) {
		writeError(w, http.StatusNotFound, "invite not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		DELETE FROM invite_codes WHERE id = $1 AND COALESCE(circle_id, family_id) = $2`, inviteID, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke invite")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "invite not found")
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "circle.invite_revoked", "revoked invite "+inviteID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// JoinCircle adds the caller to a circle by invite code. Unlike the legacy
// POST /family/join, a user may already belong to other circles. Being in the
// circle already is a 409 and does not consume the code.
func (s *Server) JoinCircle(w http.ResponseWriter, r *http.Request) {
	if !s.allowAuth(w, authIPKey("join", clientIP(r)), joinPerIP, joinWindow) {
		return
	}
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	code := normalizeCode(req.Code)
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

	var primary *string
	if err := tx.QueryRow(r.Context(), `SELECT family_id FROM users WHERE id = $1 FOR UPDATE`, uid).Scan(&primary); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}
	var (
		inviteID  string
		circleID  string
		familyID  *string
		role      models.Role
		maxUses   int
		uses      int
		expiresAt *time.Time
	)
	err = tx.QueryRow(r.Context(), `
		SELECT ic.id, COALESCE(ic.circle_id, ic.family_id), ic.family_id, ic.role, ic.max_uses, ic.uses, ic.expires_at
		FROM invite_codes ic
		JOIN circles c ON c.id = COALESCE(ic.circle_id, ic.family_id)
		WHERE ic.code = $1 FOR UPDATE OF ic`, code,
	).Scan(&inviteID, &circleID, &familyID, &role, &maxUses, &uses, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusBadRequest, "invalid invite code")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to validate invite code")
		return
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		writeError(w, http.StatusBadRequest, "invite code has expired")
		return
	}
	if uses >= maxUses {
		writeError(w, http.StatusBadRequest, "invite code has already been used")
		return
	}
	if _, err := circles.New(tx).RequireMember(r.Context(), uid, circleID); err == nil {
		writeError(w, http.StatusConflict, "already a member of this circle")
		return
	} else if !errors.Is(err, circles.ErrNotFound) {
		writeError(w, http.StatusInternalServerError, "failed to check membership")
		return
	}
	var n int
	if err := tx.QueryRow(r.Context(), `SELECT count(*) FROM circle_members WHERE user_id = $1`, uid).Scan(&n); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to count circles")
		return
	}
	if n >= maxCirclesPerUser {
		writeError(w, http.StatusConflict, "circle limit reached")
		return
	}

	if familyID != nil && primary == nil {
		// Legacy semantics for a user with no family: the circle becomes their
		// primary one and users.role takes the invite role. The trigger adds
		// the membership.
		if _, err := tx.Exec(r.Context(), `
			UPDATE users SET family_id = $1, role = $2, updated_at = now() WHERE id = $3`,
			*familyID, role, uid); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to join circle")
			return
		}
	} else {
		cr := circles.RoleMember
		if role == models.RoleAdmin {
			cr = circles.RoleAdmin
		}
		if _, err := tx.Exec(r.Context(), `
			INSERT INTO circle_members (circle_id, user_id, role) VALUES ($1, $2, $3)
			ON CONFLICT (circle_id, user_id) DO NOTHING`, circleID, uid, cr); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to join circle")
			return
		}
	}
	if _, err := tx.Exec(r.Context(), `UPDATE invite_codes SET uses = uses + 1 WHERE id = $1`, inviteID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to consume invite code")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if s.hub != nil {
		s.hub.subscribeUser(uid, circleID)
	}
	s.auditCircle(r.Context(), uid, circleID, "circle.join", "joined circle via invite code", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "circle_id": circleID})
}
