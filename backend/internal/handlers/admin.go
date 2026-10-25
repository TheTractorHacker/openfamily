package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/models"
)

// adminFamily is the platform-admin view of a family: identity fields plus a
// member count for the admin list.
type adminFamily struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	CreatedAt   time.Time `json:"created_at"`
	MemberCount int       `json:"member_count"`
}

// AdminListFamilies returns every family on the platform with its member count.
// Unlike the family-scoped GetFamily, this is not limited to the caller's
// family. Requires RequireAuth + RequirePlatformAdmin.
func (s *Server) AdminListFamilies(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT f.id, f.name, f.created_at, COUNT(u.id)::int AS member_count
		FROM families f
		LEFT JOIN users u ON u.family_id = f.id
		GROUP BY f.id, f.name, f.created_at
		ORDER BY f.created_at DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list families")
		return
	}
	defer rows.Close()

	families := []adminFamily{}
	for rows.Next() {
		var f adminFamily
		if err := rows.Scan(&f.ID, &f.Name, &f.CreatedAt, &f.MemberCount); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan family")
			return
		}
		families = append(families, f)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read families")
		return
	}
	writeJSON(w, http.StatusOK, families)
}

// AdminListFamilyMembers returns the members of one family (by id) joined to
// their last-known position. It reuses the same MemberWithLocation shape and
// the same users -> member_positions + devices.last_seen JOIN as the
// family-scoped ListMembers, but is not family-scoped to the caller and does
// not redact emails (platform admin sees everything). Requires RequireAuth +
// RequirePlatformAdmin.
func (s *Server) AdminListFamilyMembers(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID := chi.URLParam(r, "id")
	if familyID == "" {
		writeError(w, http.StatusBadRequest, "family id is required")
		return
	}

	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id, u.email, u.name, u.role, u.totp_enabled, u.created_at, u.updated_at,
		       u.avatar_data IS NOT NULL, u.avatar_version, u.avatar_updated_at,
		       mp.lat, mp.lon, mp.ts, mp.battery_pct, mp.speed_mps, mp.motion_state, mp.accuracy_meters,
		       d.last_seen
		FROM users u
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		LEFT JOIN (
			SELECT user_id, MAX(last_seen) AS last_seen
			FROM devices GROUP BY user_id
		) d ON d.user_id = u.id
		WHERE u.family_id = $1
		ORDER BY u.name`, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	defer rows.Close()

	members := []models.MemberWithLocation{}
	for rows.Next() {
		var m models.MemberWithLocation
		if err := rows.Scan(&m.ID, &m.Email, &m.Name, &m.Role, &m.TOTPEnabled, &m.CreatedAt, &m.UpdatedAt,
			&m.HasAvatar, &m.AvatarVersion, &m.AvatarUpdatedAt,
			&m.Lat, &m.Lon, &m.TS, &m.BatteryPct, &m.SpeedMPS, &m.MotionState, &m.AccuracyMeters,
			&m.LastSeenAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan member")
			return
		}
		members = append(members, m)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read members")
		return
	}
	// Distinguish "family has no members" (empty array) from "family not found".
	if len(members) == 0 {
		var exists bool
		err := s.Pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM families WHERE id = $1)`, familyID).Scan(&exists)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to verify family")
			return
		}
		if !exists {
			writeError(w, http.StatusNotFound, "family not found")
			return
		}
	}
	writeJSON(w, http.StatusOK, members)
}

// adminMember is a member tagged with their family id and family name, for the
// platform-wide single-map render. MemberWithLocation already carries the
// member's family_id (via the embedded User.FamilyID); this adds family_name.
type adminMember struct {
	models.MemberWithLocation
	FamilyName *string `json:"family_name"`
}

// AdminListMembers returns every member across every family, each tagged with
// family_id and family_name, for a single platform-wide map render. Members
// with no family (orphaned accounts) have null family_id/family_name and are
// still included. Each member also carries last_seen_at (the most recent
// device heartbeat/ingest time across their devices) so admin viewers see the
// same liveness freshness as the family map. Requires RequireAuth +
// RequirePlatformAdmin.
func (s *Server) AdminListMembers(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT u.id, u.email, u.name, u.role, u.totp_enabled, u.created_at, u.updated_at,
		       u.avatar_data IS NOT NULL, u.avatar_version, u.avatar_updated_at,
		       mp.lat, mp.lon, mp.ts, mp.battery_pct, mp.speed_mps, mp.motion_state, mp.accuracy_meters,
		       d.last_seen,
		       u.family_id, f.name
		FROM users u
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		LEFT JOIN (
			SELECT user_id, MAX(last_seen) AS last_seen
			FROM devices GROUP BY user_id
		) d ON d.user_id = u.id
		LEFT JOIN families f ON f.id = u.family_id
		ORDER BY f.name NULLS LAST, u.name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list members")
		return
	}
	defer rows.Close()

	members := []adminMember{}
	for rows.Next() {
		var m adminMember
		var familyName *string
		if err := rows.Scan(&m.ID, &m.Email, &m.Name, &m.Role, &m.TOTPEnabled, &m.CreatedAt, &m.UpdatedAt,
			&m.HasAvatar, &m.AvatarVersion, &m.AvatarUpdatedAt,
			&m.Lat, &m.Lon, &m.TS, &m.BatteryPct, &m.SpeedMPS, &m.MotionState, &m.AccuracyMeters,
			&m.LastSeenAt,
			&m.FamilyID, &familyName); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan member")
			return
		}
		m.FamilyName = familyName
		members = append(members, m)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read members")
		return
	}
	writeJSON(w, http.StatusOK, members)
}

// GetAdminMemberAvatar returns any user's avatar to an authenticated platform
// administrator. The route itself is protected by RequirePlatformAdmin; this
// handler deliberately returns no public image URL.
func (s *Server) GetAdminMemberAvatar(w http.ResponseWriter, r *http.Request) {
	setPrivateProfileHeaders(w)
	if middleware.ClaimsFromContext(r.Context()) == nil {
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
		SELECT avatar_data, avatar_content_type
		FROM users
		WHERE id = $1 AND avatar_data IS NOT NULL`, memberID,
	).Scan(&avatar, &contentType)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "member avatar not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member avatar")
		return
	}
	writePrivateAvatar(w, avatar, contentType)
}

// BootstrapPlatformAdmin makes the configured email a platform admin. If a user
// with that email already exists, it is promoted to platform_admin = TRUE. If
// not, the account is auto-created (using password) so the admin is the FIRST
// user to log in — no open registration is needed to bootstrap the server.
// The email is lowercased to match the stored (lowercased) email column.
//
// This is idempotent and safe to call every startup. It logs the outcome and
// never returns a fatal error so the server still starts if the configured
// email does not (yet) exist and no password is set.
func (s *Server) BootstrapPlatformAdmin(ctx context.Context, email, password string) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return
	}

	// Promote an existing user (idempotent).
	tag, err := s.Pool.Exec(ctx,
		`UPDATE users SET platform_admin = TRUE, updated_at = now() WHERE lower(email) = $1`,
		email)
	if err != nil {
		slog.Error("platform admin bootstrap failed", "email", email, "err", err)
		return
	}
	if tag.RowsAffected() > 0 {
		slog.Info("platform admin promoted", "email", email)
		s.logAudit(ctx, "", "", "admin.platform_admin_bootstrap",
			"promoted "+email+" to platform admin via PLATFORM_ADMIN_EMAIL", "")
		return
	}

	// No user yet: auto-create the first admin account.
	if password == "" {
		slog.Error("platform admin bootstrap: no user matched PLATFORM_ADMIN_EMAIL and PLATFORM_ADMIN_PASSWORD is empty; set it to auto-create the first admin",
			"email", email)
		return
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		slog.Error("platform admin bootstrap: failed to hash password", "email", email, "err", err)
		return
	}

	name := adminNameFromEmail(email)

	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		slog.Error("platform admin bootstrap: failed to begin transaction", "email", email, "err", err)
		return
	}
	defer tx.Rollback(ctx)

	var familyID string
	if err := tx.QueryRow(ctx,
		`INSERT INTO families (name) VALUES ($1) RETURNING id`, name+"'s Family").Scan(&familyID); err != nil {
		slog.Error("platform admin bootstrap: failed to create family", "email", email, "err", err)
		return
	}

	var userID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO users (email, name, password_hash, family_id, role, platform_admin)
		VALUES ($1, $2, $3, $4, 'admin', TRUE)
		RETURNING id`, email, name, hash, familyID).Scan(&userID); err != nil {
		slog.Error("platform admin bootstrap: failed to create admin user", "email", email, "err", err)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		slog.Error("platform admin bootstrap: failed to commit", "email", email, "err", err)
		return
	}

	slog.Info("platform admin auto-created", "email", email)
	s.logAudit(ctx, userID, familyID, "admin.platform_admin_bootstrap",
		"auto-created first platform admin "+email, "")
}

// adminNameFromEmail derives a display name from an email's local part,
// title-casing the first rune (e.g. "admin@example.com" → "Admin").
func adminNameFromEmail(email string) string {
	local := email
	if i := strings.IndexByte(local, '@'); i >= 0 {
		local = local[:i]
	}
	local = strings.TrimSpace(local)
	if local == "" {
		return "Admin"
	}
	r := []rune(local)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}

// AdminCreateFamily creates a new (empty) family. The platform admin can then
// move members into it or generate invite codes for it.
func (s *Server) AdminCreateFamily(w http.ResponseWriter, r *http.Request) {
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
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	var family models.Family
	err := s.Pool.QueryRow(r.Context(), `
		INSERT INTO families (name) VALUES ($1)
		RETURNING id, name, settings, created_at`, name,
	).Scan(&family.ID, &family.Name, &family.Settings, &family.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create family")
		return
	}
	s.logAudit(r.Context(), claims.UserID, family.ID, "admin.family_created",
		"created family "+family.Name, clientIP(r))
	writeJSON(w, http.StatusCreated, family)
}

// AdminRenameFamily renames a family (platform admin).
func (s *Server) AdminRenameFamily(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID := chi.URLParam(r, "id")
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
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.family_renamed",
		"renamed family to "+name, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// AdminDeleteFamily deletes a family. Its members become unassigned (family_id
// set NULL via ON DELETE SET NULL); places, geofences, and invite codes cascade.
func (s *Server) AdminDeleteFamily(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID := chi.URLParam(r, "id")

	tag, err := s.Pool.Exec(r.Context(), `DELETE FROM families WHERE id = $1`, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete family")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "family not found")
		return
	}
	if s.hub != nil {
		s.hub.disconnectFamily(familyID)
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.family_deleted",
		"deleted family "+familyID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// AdminMoveMember reassigns a member to another family (and optionally a new
// role). This is how a platform admin repairs the "everyone on different
// families" situation from the panel. The platform admin overrides the normal
// last-admin guard, since they act across families.
func (s *Server) AdminMoveMember(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := chi.URLParam(r, "id")
	var req struct {
		FamilyID string      `json:"family_id"`
		Role     models.Role `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.FamilyID == "" {
		writeError(w, http.StatusBadRequest, "family_id is required")
		return
	}
	role := req.Role
	if role == "" {
		role = models.RoleMember
	}
	if !role.Valid() {
		writeError(w, http.StatusBadRequest, "invalid role")
		return
	}

	// Verify the target family exists (clear 404 over a FK 500).
	var exists bool
	if err := s.Pool.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM families WHERE id = $1)`, req.FamilyID).Scan(&exists); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify family")
		return
	}
	if !exists {
		writeError(w, http.StatusNotFound, "family not found")
		return
	}

	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE users SET family_id = $1, role = $2, updated_at = now()
		WHERE id = $3`, req.FamilyID, role, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to move member")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, req.FamilyID, "admin.member_moved",
		"moved user "+userID+" to family "+req.FamilyID+" as "+string(role), clientIP(r))
	// A family WebSocket resolves its family only during its initial handshake.
	// Drop the moved user's family-scoped connections so their normal reconnect
	// starts a stream for the newly assigned family. Platform-admin streams are
	// deliberately not in this index and remain connected.
	s.hub.disconnectFamilyUser(userID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
