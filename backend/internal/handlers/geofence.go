package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// geofenceOut is the API representation of a geofence, including the linked
// place's name for convenience.
type geofenceOut struct {
	ID          string    `json:"id"`
	FamilyID    string    `json:"family_id"`
	PlaceID     *string   `json:"place_id,omitempty"`
	PlaceName   string    `json:"place_name,omitempty"`
	UserID      *string   `json:"user_id,omitempty"`
	EnterNotify bool      `json:"enter_notify"`
	ExitNotify  bool      `json:"exit_notify"`
	Enabled     bool      `json:"enabled"`
	CreatedAt   time.Time `json:"created_at"`
}

// nullableString distinguishes an absent JSON field from an explicit null.
// It is used for user_id, where null means "family-wide geofence".
type nullableString struct {
	set   bool
	value *string
}

func (n *nullableString) UnmarshalJSON(b []byte) error {
	n.set = true
	if string(b) == "null" {
		n.value = nil
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	n.value = &s
	return nil
}

// stringPtrsEqual reports whether two nullable string values are equal
// (both nil, or both non-nil with equal values).
func stringPtrsEqual(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// userCanManage reports whether the user's role permits managing family
// resources (places/geofences). Only admins and members may; children cannot.
func (s *Server) userCanManage(ctx context.Context, userID string) (bool, error) {
	var role models.Role
	err := s.Pool.QueryRow(ctx, `SELECT role FROM users WHERE id = $1`, userID).Scan(&role)
	if err != nil {
		return false, err
	}
	return role == models.RoleAdmin || role == models.RoleMember, nil
}

// requireManager enforces that the caller's role permits managing family
// resources. It writes the error response and returns false when not allowed.
func (s *Server) requireManager(w http.ResponseWriter, r *http.Request) bool {
	claims := middleware.ClaimsFromContext(r.Context())
	canManage, err := s.userCanManage(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return false
	}
	if !canManage {
		writeError(w, http.StatusForbidden, "insufficient role")
		return false
	}
	return true
}

// userIsAdmin reports whether the user is a family admin.
func (s *Server) userIsAdmin(ctx context.Context, userID string) (bool, error) {
	var role models.Role
	err := s.Pool.QueryRow(ctx, `SELECT role FROM users WHERE id = $1`, userID).Scan(&role)
	if err != nil {
		return false, err
	}
	return role == models.RoleAdmin, nil
}

// requireCreator enforces that the caller is the resource's creator ("only the
// creator can edit"). When the creator is gone (deleted) or no longer
// a manager (demoted to child), family admins may edit/delete it so orphaned
// resources are not stuck. It writes the error response and returns false
// otherwise.
func (s *Server) requireCreator(w http.ResponseWriter, r *http.Request, createdBy *string) bool {
	claims := middleware.ClaimsFromContext(r.Context())
	if createdBy != nil && *createdBy == claims.UserID {
		return true
	}
	// Determine whether the creator can still manage the resource. If not
	// (deleted, or demoted to child), fall back to family admins.
	creatorGone := createdBy == nil
	if createdBy != nil {
		canManage, err := s.userCanManage(r.Context(), *createdBy)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load creator role")
			return false
		}
		creatorGone = !canManage
	}
	if creatorGone {
		isAdmin, err := s.userIsAdmin(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load role")
			return false
		}
		if isAdmin {
			return true
		}
	}
	writeError(w, http.StatusForbidden, "only the creator can modify this")
	return false
}

// ListGeofences returns all geofences in the caller's family.
func (s *Server) ListGeofences(w http.ResponseWriter, r *http.Request) {
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

	rows, err := s.Pool.Query(r.Context(), `
		SELECT g.id, g.family_id, g.place_id, g.user_id, g.enter_notify, g.exit_notify, g.enabled, g.created_at,
		       p.name
		FROM geofences g
		JOIN places p ON p.id = g.place_id
		WHERE g.family_id = $1
		ORDER BY g.created_at`, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list geofences")
		return
	}
	defer rows.Close()

	geofences := []geofenceOut{}
	for rows.Next() {
		var g geofenceOut
		if err := rows.Scan(&g.ID, &g.FamilyID, &g.PlaceID, &g.UserID, &g.EnterNotify, &g.ExitNotify, &g.Enabled, &g.CreatedAt, &g.PlaceName); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan geofence")
			return
		}
		geofences = append(geofences, g)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read geofences")
		return
	}
	writeJSON(w, http.StatusOK, geofences)
}

// CreateGeofence links a place to a user (or the whole family) with enter/exit
// notification flags.
func (s *Server) CreateGeofence(w http.ResponseWriter, r *http.Request) {
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
	if !s.requireManager(w, r) {
		return
	}

	var req struct {
		PlaceID     string  `json:"place_id"`
		UserID      *string `json:"user_id,omitempty"`
		EnterNotify *bool   `json:"enter_notify,omitempty"`
		ExitNotify  *bool   `json:"exit_notify,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.PlaceID == "" {
		writeError(w, http.StatusBadRequest, "place_id is required")
		return
	}

	// Validate the place belongs to the family and is alertable (has a
	// location and a radius), so the geofence can actually fire.
	var geomExists, radiusExists bool
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT geom IS NOT NULL, radius_meters IS NOT NULL
		FROM places WHERE id = $1 AND family_id = $2`,
		req.PlaceID, familyID).Scan(&geomExists, &radiusExists); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to validate place")
		return
	}
	if !geomExists || !radiusExists {
		writeError(w, http.StatusBadRequest, "place is not alertable (missing location or radius)")
		return
	}

	// Validate the user belongs to the family (when a specific user is set).
	if req.UserID != nil {
		var userExists bool
		if err := s.Pool.QueryRow(r.Context(), `
			SELECT EXISTS(SELECT 1 FROM users WHERE id = $1 AND family_id = $2)`,
			*req.UserID, familyID).Scan(&userExists); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to validate user")
			return
		}
		if !userExists {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
	}

	enterNotify := true
	if req.EnterNotify != nil {
		enterNotify = *req.EnterNotify
	}
	exitNotify := true
	if req.ExitNotify != nil {
		exitNotify = *req.ExitNotify
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Lock the place row to serialize the family-wide vs per-user overlap check
	// with concurrent geofence creates/updates, so two concurrent creates cannot
	// both pass the check.
	var lockedPlace string
	if err := tx.QueryRow(r.Context(), `SELECT id FROM places WHERE id = $1 FOR UPDATE`, req.PlaceID).Scan(&lockedPlace); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock place")
		return
	}

	// Prevent a place from having both a family-wide and a per-user geofence,
	// which would otherwise fire duplicate alerts for the same transition.
	var overlap bool
	if req.UserID == nil {
		err = tx.QueryRow(r.Context(), `
			SELECT EXISTS(SELECT 1 FROM geofences WHERE place_id = $1 AND user_id IS NOT NULL)`,
			req.PlaceID).Scan(&overlap)
	} else {
		err = tx.QueryRow(r.Context(), `
			SELECT EXISTS(SELECT 1 FROM geofences WHERE place_id = $1 AND user_id IS NULL)`,
			req.PlaceID).Scan(&overlap)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check geofence overlap")
		return
	}
	if overlap {
		writeError(w, http.StatusConflict, "place already has a conflicting geofence")
		return
	}

	var g geofenceOut
	err = tx.QueryRow(r.Context(), `
		WITH ins AS (
			INSERT INTO geofences (family_id, place_id, user_id, enter_notify, exit_notify, created_by)
			VALUES ($1, $2, $3, $4, $5, $6)
			RETURNING id, family_id, place_id, user_id, enter_notify, exit_notify, enabled, created_at
		)
		SELECT ins.id, ins.family_id, ins.place_id, ins.user_id, ins.enter_notify, ins.exit_notify, ins.enabled, ins.created_at,
		       COALESCE(p.name, '')
		FROM ins
		LEFT JOIN places p ON p.id = ins.place_id`,
		familyID, req.PlaceID, req.UserID, enterNotify, exitNotify, claims.UserID,
	).Scan(&g.ID, &g.FamilyID, &g.PlaceID, &g.UserID, &g.EnterNotify, &g.ExitNotify, &g.Enabled, &g.CreatedAt, &g.PlaceName)
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "geofence already exists for this place and user")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to create geofence")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "geofence.create", "created geofence "+g.ID, clientIP(r))
	writeJSON(w, http.StatusCreated, g)
}

// UpdateGeofence patches a geofence's place, user, flags, or enabled state.
func (s *Server) UpdateGeofence(w http.ResponseWriter, r *http.Request) {
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
	if !s.requireManager(w, r) {
		return
	}
	id := chi.URLParam(r, "id")

	// Only the creator may edit (or an admin when the creator was deleted or
	// demoted).
	var createdBy *string
	var curPlaceID *string
	var curUserID *string
	var curEnterNotify, curExitNotify bool
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT created_by, place_id, user_id, enter_notify, exit_notify
		FROM geofences WHERE id = $1 AND family_id = $2`, id, familyID).Scan(&createdBy, &curPlaceID, &curUserID, &curEnterNotify, &curExitNotify); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "geofence not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load geofence")
		return
	}
	if !s.requireCreator(w, r, createdBy) {
		return
	}

	var req struct {
		PlaceID     *string        `json:"place_id,omitempty"`
		UserID      nullableString `json:"user_id,omitempty"`
		EnterNotify *bool          `json:"enter_notify,omitempty"`
		ExitNotify  *bool          `json:"exit_notify,omitempty"`
		Enabled     *bool          `json:"enabled,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	// Validate any referenced place/user belongs to the family.
	if req.PlaceID != nil {
		if *req.PlaceID == "" {
			writeError(w, http.StatusBadRequest, "place_id cannot be empty")
			return
		}
		var geomExists, radiusExists bool
		if err := s.Pool.QueryRow(r.Context(), `
			SELECT geom IS NOT NULL, radius_meters IS NOT NULL
			FROM places WHERE id = $1 AND family_id = $2`,
			*req.PlaceID, familyID).Scan(&geomExists, &radiusExists); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, http.StatusNotFound, "place not found")
				return
			}
			writeError(w, http.StatusInternalServerError, "failed to validate place")
			return
		}
		if !geomExists || !radiusExists {
			writeError(w, http.StatusBadRequest, "place is not alertable (missing location or radius)")
			return
		}
	}
	if req.UserID.set && req.UserID.value != nil {
		var userExists bool
		if err := s.Pool.QueryRow(r.Context(), `
			SELECT EXISTS(SELECT 1 FROM users WHERE id = $1 AND family_id = $2)`,
			*req.UserID.value, familyID).Scan(&userExists); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to validate user")
			return
		}
		if !userExists {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
	}

	// Effective place_id/user_id after the update, for the overlap re-check.
	effPlaceID := curPlaceID
	if req.PlaceID != nil {
		effPlaceID = req.PlaceID
	}
	effUserID := curUserID
	if req.UserID.set {
		effUserID = req.UserID.value
	}

	// Build the SET clause dynamically from the provided fields.
	sets := []string{}
	args := []any{}
	arg := 1
	if req.PlaceID != nil {
		sets = append(sets, fmt.Sprintf("place_id = $%d", arg))
		args = append(args, *req.PlaceID)
		arg++
	}
	if req.UserID.set {
		sets = append(sets, fmt.Sprintf("user_id = $%d", arg))
		args = append(args, req.UserID.value) // nil -> NULL (family-wide)
		arg++
	}
	if req.EnterNotify != nil {
		sets = append(sets, fmt.Sprintf("enter_notify = $%d", arg))
		args = append(args, *req.EnterNotify)
		arg++
	}
	if req.ExitNotify != nil {
		sets = append(sets, fmt.Sprintf("exit_notify = $%d", arg))
		args = append(args, *req.ExitNotify)
		arg++
	}
	if req.Enabled != nil {
		sets = append(sets, fmt.Sprintf("enabled = $%d", arg))
		args = append(args, *req.Enabled)
		arg++
	}
	if len(sets) == 0 {
		writeError(w, http.StatusBadRequest, "no fields to update")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Re-check the family-wide vs per-user overlap rule when place_id or
	// user_id changes (CreateGeofence enforces it, but an update could bypass
	// it). Lock the place row to serialize concurrent geofence changes.
	if (req.PlaceID != nil || req.UserID.set) && effPlaceID != nil {
		var lockedPlace string
		if err := tx.QueryRow(r.Context(), `SELECT id FROM places WHERE id = $1 FOR UPDATE`, *effPlaceID).Scan(&lockedPlace); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to lock place")
			return
		}
		var overlap bool
		if effUserID == nil {
			err = tx.QueryRow(r.Context(), `
				SELECT EXISTS(SELECT 1 FROM geofences WHERE place_id = $1 AND user_id IS NOT NULL AND id <> $2)`,
				*effPlaceID, id).Scan(&overlap)
		} else {
			err = tx.QueryRow(r.Context(), `
				SELECT EXISTS(SELECT 1 FROM geofences WHERE place_id = $1 AND user_id IS NULL AND id <> $2)`,
				*effPlaceID, id).Scan(&overlap)
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to check geofence overlap")
			return
		}
		if overlap {
			writeError(w, http.StatusConflict, "place already has a conflicting geofence")
			return
		}
	}

	query := fmt.Sprintf(`
		WITH upd AS (
			UPDATE geofences SET %s
			WHERE id = $%d AND family_id = $%d
			RETURNING id, family_id, place_id, user_id, enter_notify, exit_notify, enabled, created_at
		)
		SELECT upd.id, upd.family_id, upd.place_id, upd.user_id, upd.enter_notify, upd.exit_notify, upd.enabled, upd.created_at,
		       COALESCE(p.name, '')
		FROM upd
		LEFT JOIN places p ON p.id = upd.place_id`,
		strings.Join(sets, ", "), arg, arg+1)
	args = append(args, id, familyID)

	var g geofenceOut
	err = tx.QueryRow(r.Context(), query, args...).Scan(
		&g.ID, &g.FamilyID, &g.PlaceID, &g.UserID, &g.EnterNotify, &g.ExitNotify, &g.Enabled, &g.CreatedAt, &g.PlaceName)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "geofence not found")
			return
		}
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "geofence already exists for this place and user")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to update geofence")
		return
	}

	// Reset state when the geofence's semantics ACTUALLY change (disabled,
	// place/user reassigned, or notify flags toggled), so the next point does
	// not fire a spurious transition from stale state (and the previous user's
	// state row is not orphaned). A no-op update (same value) does not reset.
	placeChanged := req.PlaceID != nil && (curPlaceID == nil || *req.PlaceID != *curPlaceID)
	userChanged := req.UserID.set && !stringPtrsEqual(req.UserID.value, curUserID)
	enterChanged := req.EnterNotify != nil && *req.EnterNotify != curEnterNotify
	exitChanged := req.ExitNotify != nil && *req.ExitNotify != curExitNotify
	disabled := req.Enabled != nil && !*req.Enabled

	if disabled || placeChanged || userChanged || enterChanged || exitChanged {
		if _, err := tx.Exec(r.Context(), `DELETE FROM geofence_states WHERE geofence_id = $1`, id); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to clear geofence state")
			return
		}
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	writeJSON(w, http.StatusOK, g)
}

// DeleteGeofence removes a geofence from the caller's family.
func (s *Server) DeleteGeofence(w http.ResponseWriter, r *http.Request) {
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
	if !s.requireManager(w, r) {
		return
	}
	id := chi.URLParam(r, "id")

	// Only the creator may delete (or an admin when the creator was deleted).
	var createdBy *string
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT created_by FROM geofences WHERE id = $1 AND family_id = $2`, id, familyID).Scan(&createdBy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "geofence not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load geofence")
		return
	}
	if !s.requireCreator(w, r, createdBy) {
		return
	}

	tag, err := s.Pool.Exec(r.Context(), `
		DELETE FROM geofences WHERE id = $1 AND family_id = $2`, id, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete geofence")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "geofence not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "geofence.delete", "deleted geofence "+id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
