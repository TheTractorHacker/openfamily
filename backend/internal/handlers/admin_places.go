package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// adminPlaceInput is the body of the admin place create/update endpoints.
// Every field is optional on update; create requires all but address.
type adminPlaceInput struct {
	FamilyID     string   `json:"family_id,omitempty"`
	Name         *string  `json:"name,omitempty"`
	Type         *string  `json:"type,omitempty"`
	Lat          *float64 `json:"lat,omitempty"`
	Lon          *float64 `json:"lon,omitempty"`
	RadiusMeters *float64 `json:"radius_meters,omitempty"`
	Address      *string  `json:"address,omitempty"`
	// CircleID restricts the place to one circle; null/"" = whole family.
	CircleID nullableString `json:"circle_id,omitempty"`
}

// validate returns a user-facing message for the first invalid field, or "".
// create additionally requires family, name, location and radius.
func (in *adminPlaceInput) validate(create bool) string {
	if create {
		if !circles.ValidID(in.FamilyID) {
			return "family_id is required"
		}
		if in.Name == nil || strings.TrimSpace(*in.Name) == "" {
			return "name is required"
		}
		if in.Lat == nil || in.Lon == nil {
			return "lat and lon are required"
		}
		if in.RadiusMeters == nil {
			return "radius_meters is required"
		}
	}
	if in.Name != nil {
		trimmed := strings.TrimSpace(*in.Name)
		in.Name = &trimmed
	}
	if msg := placeTextError(in.Name, in.Address); msg != "" {
		return msg
	}
	if in.CircleID.set && in.CircleID.value != nil {
		if *in.CircleID.value == "" {
			in.CircleID.value = nil
		} else if !circles.ValidID(*in.CircleID.value) {
			return "circle not found"
		}
	}
	if in.Type != nil && !validPlaceType(*in.Type) {
		return "invalid type"
	}
	if in.Lat != nil && (*in.Lat < -90 || *in.Lat > 90) {
		return "lat out of range"
	}
	if in.Lon != nil && (*in.Lon < -180 || *in.Lon > 180) {
		return "lon out of range"
	}
	if in.RadiusMeters != nil && !validRadius(*in.RadiusMeters) {
		return "radius_meters must be between 76 and 3219 meters (250 ft to 2 mi)"
	}
	return ""
}

const adminPlaceSelect = `
	SELECT p.id, p.family_id, f.name, p.name, p.type,
	       ST_Y(p.geom), ST_X(p.geom), p.radius_meters, p.address, p.created_at,
	       p.circle_id, c.name
	FROM places p JOIN families f ON f.id = p.family_id
	LEFT JOIN circles c ON c.id = p.circle_id`

// adminLiveCircleExists reports whether circleID is a live (not ended or
// expired) circle. Admins may scope a place to any live circle.
func adminLiveCircleExists(ctx context.Context, q queryRower, circleID string) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM circles WHERE id = $1 AND ended_at IS NULL
		              AND (expires_at IS NULL OR expires_at > now()))`, circleID).Scan(&ok)
	return ok, err
}

// AdminCreatePlace creates a place in any family.
// POST /api/admin/places
func (s *Server) AdminCreatePlace(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var in adminPlaceInput
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if msg := in.validate(true); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	placeType := "custom"
	if in.Type != nil && *in.Type != "" {
		placeType = *in.Type
	}
	address := ""
	if in.Address != nil {
		address = *in.Address
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	// The family row lock serializes the overlap check, as in CreatePlace.
	var locked string
	if err := tx.QueryRow(r.Context(), `SELECT id FROM families WHERE id = $1 FOR UPDATE`, in.FamilyID).Scan(&locked); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "family not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}
	overlaps, err := s.placeOverlaps(r.Context(), tx, in.FamilyID, "", *in.Lon, *in.Lat, *in.RadiusMeters)
	if err != nil {
		slog.Error("admin place overlap check failed", "err", err)
		writeError(w, http.StatusInternalServerError, "failed to check place overlap")
		return
	}
	if overlaps {
		writeError(w, http.StatusBadRequest, "place overlaps an existing place")
		return
	}
	if in.CircleID.value != nil {
		if ok, err := adminLiveCircleExists(r.Context(), tx, *in.CircleID.value); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to check circle")
			return
		} else if !ok {
			writeError(w, http.StatusBadRequest, "circle not found")
			return
		}
	}
	var id string
	if err := tx.QueryRow(r.Context(), `
		INSERT INTO places (family_id, name, type, geom, radius_meters, created_by, address, circle_id)
		VALUES ($1, $2, $3, ST_SetSRID(ST_MakePoint($4, $5), 4326), $6, $7, $8, $9)
		RETURNING id`,
		in.FamilyID, *in.Name, placeType, *in.Lon, *in.Lat, *in.RadiusMeters, claims.UserID, address, in.CircleID.value,
	).Scan(&id); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create place")
		return
	}
	var out adminPlaceOut
	if err := tx.QueryRow(r.Context(), adminPlaceSelect+` WHERE p.id = $1`, id).Scan(
		&out.ID, &out.FamilyID, &out.FamilyName, &out.Name, &out.Type,
		&out.Lat, &out.Lon, &out.RadiusMeters, &out.Address, &out.CreatedAt, &out.CircleID, &out.CircleName); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, in.FamilyID, "admin.place.create",
		"created place "+id+" ("+out.Name+")", clientIP(r))
	writeJSON(w, http.StatusCreated, out)
}

// AdminUpdatePlace patches a place's name, type, location, radius or address.
// PUT /api/admin/places/{id}
func (s *Server) AdminUpdatePlace(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	var in adminPlaceInput
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if msg := in.validate(false); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var familyID string
	if err := tx.QueryRow(r.Context(), `SELECT family_id FROM places WHERE id = $1`, id).Scan(&familyID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	var locked string
	if err := tx.QueryRow(r.Context(), `SELECT id FROM families WHERE id = $1 FOR UPDATE`, familyID).Scan(&locked); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock family")
		return
	}
	var cur placeOut
	if err := tx.QueryRow(r.Context(), `
		SELECT id, family_id, name, type, ST_Y(geom), ST_X(geom), radius_meters, address, created_at, circle_id
		FROM places WHERE id = $1`, id).Scan(
		&cur.ID, &cur.FamilyID, &cur.Name, &cur.Type, &cur.Lat, &cur.Lon, &cur.RadiusMeters, &cur.Address, &cur.CreatedAt, &cur.CircleID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}

	name, placeType, lat, lon, radius, address := cur.Name, cur.Type, cur.Lat, cur.Lon, cur.RadiusMeters, cur.Address
	if in.Name != nil {
		name = *in.Name
	}
	if in.Type != nil {
		placeType = *in.Type
	}
	if in.Lat != nil {
		lat = *in.Lat
	}
	if in.Lon != nil {
		lon = *in.Lon
	}
	if in.RadiusMeters != nil {
		radius = in.RadiusMeters
	}
	if in.Address != nil {
		address = *in.Address
	}
	circleID := cur.CircleID
	if in.CircleID.set {
		circleID = in.CircleID.value
	}
	if in.CircleID.set && in.CircleID.value != nil {
		if ok, err := adminLiveCircleExists(r.Context(), tx, *in.CircleID.value); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to check circle")
			return
		} else if !ok {
			writeError(w, http.StatusBadRequest, "circle not found")
			return
		}
	}
	geometryChanged := lat != cur.Lat || lon != cur.Lon || !floatPtrsEqual(radius, cur.RadiusMeters)

	if radius != nil {
		overlaps, err := s.placeOverlaps(r.Context(), tx, familyID, id, lon, lat, *radius)
		if err != nil {
			slog.Error("admin place overlap check failed", "err", err, "place_id", id)
			writeError(w, http.StatusInternalServerError, "failed to check place overlap")
			return
		}
		if overlaps {
			writeError(w, http.StatusBadRequest, "place overlaps an existing place")
			return
		}
	}
	if geometryChanged {
		// Same serialization as UpdatePlace: hold the geofence rows so a
		// concurrent ingest cannot write state against the old geometry.
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
	if _, err := tx.Exec(r.Context(), `
		UPDATE places SET name = $2, type = $3, geom = ST_SetSRID(ST_MakePoint($4, $5), 4326),
		       radius_meters = $6, address = $7, circle_id = $8
		WHERE id = $1`, id, name, placeType, lon, lat, radius, address, circleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update place")
		return
	}
	if geometryChanged {
		if _, err := tx.Exec(r.Context(), `
			DELETE FROM geofence_states WHERE geofence_id IN (
				SELECT id FROM geofences WHERE place_id = $1)`, id); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to reset geofence state")
			return
		}
	}
	var out adminPlaceOut
	if err := tx.QueryRow(r.Context(), adminPlaceSelect+` WHERE p.id = $1`, id).Scan(
		&out.ID, &out.FamilyID, &out.FamilyName, &out.Name, &out.Type,
		&out.Lat, &out.Lon, &out.RadiusMeters, &out.Address, &out.CreatedAt, &out.CircleID, &out.CircleName); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.place.update",
		"updated place "+id+" ("+out.Name+")", clientIP(r))
	writeJSON(w, http.StatusOK, out)
}

// AdminDeletePlace removes a place and its geofences.
// DELETE /api/admin/places/{id}
func (s *Server) AdminDeletePlace(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var familyID, name string
	if err := tx.QueryRow(r.Context(), `SELECT family_id, name FROM places WHERE id = $1`, id).Scan(&familyID, &name); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "place not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to load place")
		return
	}
	// Geofences first so no orphan rows remain (the schema would SET NULL).
	if _, err := tx.Exec(r.Context(), `DELETE FROM geofences WHERE place_id = $1`, id); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete geofences")
		return
	}
	if _, err := tx.Exec(r.Context(), `DELETE FROM places WHERE id = $1`, id); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete place")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.logAudit(r.Context(), claims.UserID, familyID, "admin.place.delete",
		"deleted place "+id+" ("+name+")", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
