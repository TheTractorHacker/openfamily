package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// placeOut is the API representation of a place.
type placeOut struct {
	ID           string    `json:"id"`
	FamilyID     string    `json:"family_id"`
	Name         string    `json:"name"`
	Type         string    `json:"type"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	RadiusMeters *float64  `json:"radius_meters,omitempty"`
	Address      string    `json:"address"`
	CreatedAt    time.Time `json:"created_at"`
}

// nullableFloat64 distinguishes an absent JSON field from an explicit null.
// It is used for radius_meters on update, where null clears the radius.
type nullableFloat64 struct {
	set   bool
	value *float64
}

func (n *nullableFloat64) UnmarshalJSON(b []byte) error {
	n.set = true
	if string(b) == "null" {
		n.value = nil
		return nil
	}
	var f float64
	if err := json.Unmarshal(b, &f); err != nil {
		return err
	}
	n.value = &f
	return nil
}

// floatPtrsEqual reports whether two nullable float64 values are equal
// (both nil, or both non-nil with equal values).
func floatPtrsEqual(a, b *float64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// validPlaceType reports whether t is a known place type.
func validPlaceType(t string) bool {
	switch t {
	case "home", "school", "work", "gym", "custom":
		return true
	}
	return false
}

// Radius bounds per the product bar: 250 ft to 2 mi (≈76–3219 m).
const (
	minPlaceRadiusMeters = 76.0
	maxPlaceRadiusMeters = 3219.0
)

// Text limits shared by create and update.
const (
	maxPlaceNameRunes    = 100
	maxPlaceAddressRunes = 500
)

// placeTextError returns a validation message for an invalid name or address
// (empty string when fine). Create and update both use it so they cannot drift.
func placeTextError(name *string, address *string) string {
	if name != nil {
		if strings.TrimSpace(*name) == "" {
			return "name cannot be empty"
		}
		if utf8.RuneCountInString(*name) > maxPlaceNameRunes {
			return "name must be at most 100 characters"
		}
	}
	if address != nil && utf8.RuneCountInString(*address) > maxPlaceAddressRunes {
		return "address must be at most 500 characters"
	}
	return ""
}

// validRadius reports whether r is within the allowed radius range.
func validRadius(r float64) bool {
	return r >= minPlaceRadiusMeters && r <= maxPlaceRadiusMeters
}

// queryRower is the subset of pgx query interfaces needed by the overlap
// checks, satisfied by both *pgxpool.Pool and pgx.Tx.
type queryRower interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// nullableUUID returns nil when id is empty so PostgreSQL receives NULL
// instead of ''. places.id is UUID, and '' is invalid input for that type —
// which is what made CreatePlace fail with "failed to check place overlap"
// even when the family had no other places.
func nullableUUID(id string) any {
	if id == "" {
		return nil
	}
	return id
}

// placeOverlaps reports whether a circle at (lon, lat) with the given radius
// overlaps any other place's circle in the family (excluding excludeID). Two
// circles overlap when the distance between their centers is less than the sum
// of their radii, computed with ST_DWithin on geography (meters).
//
// excludeID is the place being updated (empty on create). Empty is sent as
// NULL so the UUID comparison does not try to cast ''.
func (s *Server) placeOverlaps(ctx context.Context, q queryRower, familyID, excludeID string, lon, lat, radius float64) (bool, error) {
	var overlaps bool
	err := q.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM places p
			WHERE p.family_id = $1
			  AND p.id IS DISTINCT FROM $2::uuid
			  AND p.geom IS NOT NULL
			  AND p.radius_meters IS NOT NULL
			  AND ST_DWithin(p.geom::geography, ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography, p.radius_meters + $5)
		)`, familyID, nullableUUID(excludeID), lon, lat, radius).Scan(&overlaps)
	return overlaps, err
}

// ListPlaces returns all places in the caller's family.
func (s *Server) ListPlaces(w http.ResponseWriter, r *http.Request) {
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
	// Places are shared read-only with all Circle members (including children),
	// matching the bar's "shared with all Circle members". Create/edit/delete
	// remain restricted to the creator.

	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, family_id, name, type, ST_Y(geom), ST_X(geom), radius_meters, address, created_at
		FROM places WHERE family_id = $1 ORDER BY created_at`, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list places")
		return
	}
	defer rows.Close()

	places := []placeOut{}
	for rows.Next() {
		var p placeOut
		if err := rows.Scan(&p.ID, &p.FamilyID, &p.Name, &p.Type, &p.Lat, &p.Lon, &p.RadiusMeters, &p.Address, &p.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan place")
			return
		}
		places = append(places, p)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read places")
		return
	}
	writeJSON(w, http.StatusOK, places)
}

// adminPlaceOut reuses the placeOut shape and adds the owning family's name for
// the platform-admin map, which renders places across ALL families.
type adminPlaceOut struct {
	placeOut
	FamilyName string `json:"family_name"`
}

// AdminListPlaces returns every place across every family, each tagged with
// family_id + family_name, for the platform-admin map's Home/School/Work pins.
// It reuses the placeOut shape and the same places query as the family-scoped
// ListPlaces, but drops the family scoping and joins families for the name.
// Requires RequireAuth + RequirePlatformAdmin (enforced by the route group).
func (s *Server) AdminListPlaces(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT p.id, p.family_id, f.name, p.name, p.type,
		       ST_Y(p.geom), ST_X(p.geom), p.radius_meters, p.address, p.created_at
		FROM places p
		JOIN families f ON f.id = p.family_id
		ORDER BY f.name, p.created_at`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list places")
		return
	}
	defer rows.Close()

	places := []adminPlaceOut{}
	for rows.Next() {
		var p adminPlaceOut
		if err := rows.Scan(&p.ID, &p.FamilyID, &p.FamilyName, &p.Name, &p.Type, &p.Lat, &p.Lon, &p.RadiusMeters, &p.Address, &p.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan place")
			return
		}
		places = append(places, p)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read places")
		return
	}
	writeJSON(w, http.StatusOK, places)
}

// CreatePlace creates a named point of interest for the caller's family.
func (s *Server) CreatePlace(w http.ResponseWriter, r *http.Request) {
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
		Name         string   `json:"name"`
		Type         string   `json:"type"`
		Lat          float64  `json:"lat"`
		Lon          float64  `json:"lon"`
		RadiusMeters *float64 `json:"radius_meters,omitempty"`
		Address      string   `json:"address,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	if msg := placeTextError(&req.Name, &req.Address); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if req.Lat < -90 || req.Lat > 90 || req.Lon < -180 || req.Lon > 180 {
		writeError(w, http.StatusBadRequest, "lat/lon out of range")
		return
	}
	if req.RadiusMeters == nil {
		writeError(w, http.StatusBadRequest, "radius_meters is required")
		return
	}
	if !validRadius(*req.RadiusMeters) {
		writeError(w, http.StatusBadRequest, "radius_meters must be between 76 and 3219 meters (250 ft to 2 mi)")
		return
	}
	placeType := req.Type
	if placeType == "" {
		placeType = "custom"
	}
	if !validPlaceType(placeType) {
		writeError(w, http.StatusBadRequest, "invalid type")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Lock the family row to serialize the overlap check with concurrent place
	// creates/updates, so two concurrent creates cannot both pass the
	// non-overlap check.
	var lockedFamily string
	if err := tx.QueryRow(r.Context(), `SELECT id FROM families WHERE id = $1 FOR UPDATE`, familyID).Scan(&lockedFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}

	// Reject if the new place's circle overlaps an existing place's circle.
	overlaps, err := s.placeOverlaps(r.Context(), tx, familyID, "", req.Lon, req.Lat, *req.RadiusMeters)
	if err != nil {
		slog.Error("place overlap check failed", "err", err)
		writeError(w, http.StatusInternalServerError, "failed to check place overlap")
		return
	}
	if overlaps {
		writeError(w, http.StatusBadRequest, "place overlaps an existing place")
		return
	}

	var p placeOut
	err = tx.QueryRow(r.Context(), `
		INSERT INTO places (family_id, name, type, geom, radius_meters, created_by, address)
		VALUES ($1, $2, $3, ST_SetSRID(ST_MakePoint($4, $5), 4326), $6, $7, $8)
		RETURNING id, family_id, name, type, ST_Y(geom), ST_X(geom), radius_meters, address, created_at`,
		familyID, req.Name, placeType, req.Lon, req.Lat, req.RadiusMeters, claims.UserID, req.Address,
	).Scan(&p.ID, &p.FamilyID, &p.Name, &p.Type, &p.Lat, &p.Lon, &p.RadiusMeters, &p.Address, &p.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create place")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "place.create", "created place "+p.ID+" ("+p.Name+")", clientIP(r))
	writeJSON(w, http.StatusCreated, p)
}

// UpdatePlace patches a place's name, type, location, or radius.
func (s *Server) UpdatePlace(w http.ResponseWriter, r *http.Request) {
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

	// Only the creator may edit (or an admin when the creator was deleted).
	var createdBy *string
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT created_by FROM places WHERE id = $1 AND family_id = $2`, id, familyID).Scan(&createdBy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	if !s.requireCreator(w, r, createdBy) {
		return
	}

	var req struct {
		Name         *string         `json:"name,omitempty"`
		Type         *string         `json:"type,omitempty"`
		Lat          *float64        `json:"lat,omitempty"`
		Lon          *float64        `json:"lon,omitempty"`
		RadiusMeters nullableFloat64 `json:"radius_meters,omitempty"`
		Address      *string         `json:"address,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if msg := placeTextError(req.Name, req.Address); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if req.RadiusMeters.set && req.RadiusMeters.value == nil {
		// Create requires a radius, so an update must not remove it either: a
		// place without a radius can never fire a geofence.
		writeError(w, http.StatusBadRequest, "radius_meters cannot be null")
		return
	}
	if req.Type != nil && !validPlaceType(*req.Type) {
		writeError(w, http.StatusBadRequest, "invalid type")
		return
	}
	if req.Lat != nil && (*req.Lat < -90 || *req.Lat > 90) {
		writeError(w, http.StatusBadRequest, "lat out of range")
		return
	}
	if req.Lon != nil && (*req.Lon < -180 || *req.Lon > 180) {
		writeError(w, http.StatusBadRequest, "lon out of range")
		return
	}
	if req.RadiusMeters.set && req.RadiusMeters.value != nil && !validRadius(*req.RadiusMeters.value) {
		writeError(w, http.StatusBadRequest, "radius_meters must be between 76 and 3219 meters (250 ft to 2 mi)")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Lock the family row to serialize the overlap check with concurrent place
	// creates/updates, so two concurrent changes cannot both pass the
	// non-overlap check.
	var lockedFamily string
	if err := tx.QueryRow(r.Context(), `SELECT id FROM families WHERE id = $1 FOR UPDATE`, familyID).Scan(&lockedFamily); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}

	// Fetch the current place inside the transaction (after the family-row
	// lock) so a partial location update merges against a consistent snapshot
	// and cannot be raced by a concurrent update (lost-update).
	var cur placeOut
	err = tx.QueryRow(r.Context(), `
		SELECT id, family_id, name, type, ST_Y(geom), ST_X(geom), radius_meters, address, created_at
		FROM places WHERE id = $1 AND family_id = $2`, id, familyID,
	).Scan(&cur.ID, &cur.FamilyID, &cur.Name, &cur.Type, &cur.Lat, &cur.Lon, &cur.RadiusMeters, &cur.Address, &cur.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}

	name := cur.Name
	if req.Name != nil {
		name = *req.Name
	}
	placeType := cur.Type
	if req.Type != nil {
		placeType = *req.Type
	}
	lat := cur.Lat
	if req.Lat != nil {
		lat = *req.Lat
	}
	lon := cur.Lon
	if req.Lon != nil {
		lon = *req.Lon
	}
	radius := cur.RadiusMeters
	if req.RadiusMeters.set {
		radius = req.RadiusMeters.value // nil clears the radius
	}
	address := cur.Address
	if req.Address != nil {
		address = *req.Address
	}

	// Geometry/radius changes invalidate the geofence state of any geofence
	// referencing this place, so the next point does not fire a spurious
	// transition from stale state. Only reset when the geometry ACTUALLY
	// changed (not merely because the field was present with the same value).
	radiusChanged := req.RadiusMeters.set && !floatPtrsEqual(req.RadiusMeters.value, cur.RadiusMeters)
	geometryChanged := (req.Lat != nil && *req.Lat != cur.Lat) ||
		(req.Lon != nil && *req.Lon != cur.Lon) ||
		radiusChanged

	// Reject if the updated circle overlaps another place's circle.
	if radius != nil {
		overlaps, err := s.placeOverlaps(r.Context(), tx, familyID, id, lon, lat, *radius)
		if err != nil {
			slog.Error("place overlap check failed", "err", err, "place_id", id)
			writeError(w, http.StatusInternalServerError, "failed to check place overlap")
			return
		}
		if overlaps {
			writeError(w, http.StatusBadRequest, "place overlaps an existing place")
			return
		}
	}

	// Lock the geofence rows referencing this place so a concurrent ingest's
	// processGeofence (which locks the geofence row) serializes with the
	// geometry change + state reset, preventing a stale inside value from being
	// written against the old geometry.
	if geometryChanged {
		rows, err := tx.Query(r.Context(), `SELECT id FROM geofences WHERE place_id = $1 FOR UPDATE`, id)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to lock geofences")
			return
		}
		for rows.Next() {
		}
		rows.Close()
		if rows.Err() != nil {
			writeError(w, http.StatusInternalServerError, "failed to lock geofences")
			return
		}
	}

	var p placeOut
	err = tx.QueryRow(r.Context(), `
		UPDATE places SET name = $3, type = $4, geom = ST_SetSRID(ST_MakePoint($5, $6), 4326), radius_meters = $7, address = $8
		WHERE id = $1 AND family_id = $2
		RETURNING id, family_id, name, type, ST_Y(geom), ST_X(geom), radius_meters, address, created_at`,
		id, familyID, name, placeType, lon, lat, radius, address,
	).Scan(&p.ID, &p.FamilyID, &p.Name, &p.Type, &p.Lat, &p.Lon, &p.RadiusMeters, &p.Address, &p.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update place")
		return
	}

	if geometryChanged {
		if _, err := tx.Exec(r.Context(), `
			DELETE FROM geofence_states WHERE geofence_id IN (
				SELECT id FROM geofences WHERE place_id = $1
			)`, id); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to reset geofence state")
			return
		}
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// DeletePlace removes a place and its geofences from the caller's family.
func (s *Server) DeletePlace(w http.ResponseWriter, r *http.Request) {
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
		SELECT created_by FROM places WHERE id = $1 AND family_id = $2`, id, familyID).Scan(&createdBy); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	if !s.requireCreator(w, r, createdBy) {
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// Delete the place's geofences first so no zombie rows remain (the schema
	// would otherwise SET NULL on place_id).
	if _, err := tx.Exec(r.Context(), `DELETE FROM geofences WHERE place_id = $1 AND family_id = $2`, id, familyID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete geofences")
		return
	}

	tag, err := tx.Exec(r.Context(), `DELETE FROM places WHERE id = $1 AND family_id = $2`, id, familyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete place")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "place.delete", "deleted place "+id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
