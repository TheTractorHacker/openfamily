package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// maxTSSkew is the maximum allowed client clock skew into the future.
// maxTSAge is the maximum age of a reported point before it is rejected as
// stale/replayed.
const (
	maxTSSkew = 5 * time.Minute
	maxTSAge  = 15 * time.Minute

	// Ingest throttle per user. Normal reporters emit a point every few
	// seconds; the cap only trips on runaway loops or deliberate flooding.
	ingestPerWindow = 120
	ingestWindow    = time.Minute

	// stationaryDedupMeters is how close a new point must be to the stored
	// last-known position for it to count as "not moved". Such points skip the
	// locations INSERT (a phone parked at home would otherwise write a row per
	// reporting interval — up to ~1440 rows/day) and instead only refresh
	// devices.last_seen / member_positions.updated_at, then announce liveness
	// with a `presence` WebSocket frame. The threshold is above typical GPS
	// noise (~5-15 m) so jitter while standing still still dedups, but well
	// below real movement.
	stationaryDedupMeters = 25.0
)

// IngestLocation stores a single location point for a device owned by the
// authenticated user. The device must already be registered.
func (s *Server) IngestLocation(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.LocationLimit != nil && !s.LocationLimit.Allow("loc:"+claims.UserID, ingestPerWindow, ingestWindow) {
		writeError(w, http.StatusTooManyRequests, "too many location reports")
		return
	}

	var req struct {
		DeviceID       string     `json:"device_id"`
		TS             *time.Time `json:"ts,omitempty"`
		Lat            float64    `json:"lat"`
		Lon            float64    `json:"lon"`
		AccuracyMeters *float64   `json:"accuracy_meters,omitempty"`
		AltitudeMeters *float64   `json:"altitude_meters,omitempty"`
		SpeedMPS       *float64   `json:"speed_mps,omitempty"`
		HeadingDeg     *float64   `json:"heading_deg,omitempty"`
		BatteryPct     *float64   `json:"battery_pct,omitempty"`
		MotionState    string     `json:"motion_state,omitempty"`
		Source         string     `json:"source,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}
	if req.Lat < -90 || req.Lat > 90 || req.Lon < -180 || req.Lon > 180 {
		writeError(w, http.StatusBadRequest, "lat/lon out of range")
		return
	}
	ts := time.Now()
	if req.TS != nil {
		ts = *req.TS
		// Reject stale or far-future timestamps so a replayed/out-of-order
		// point cannot spuriously flip geofence state.
		if ts.After(time.Now().Add(maxTSSkew)) {
			writeError(w, http.StatusBadRequest, "ts is in the future")
			return
		}
		if ts.Before(time.Now().Add(-maxTSAge)) {
			writeError(w, http.StatusBadRequest, "ts is too old")
			return
		}
	}

	// Verify the device belongs to the caller.
	var ownerID string
	err := s.Pool.QueryRow(r.Context(), `
		SELECT user_id FROM devices WHERE id = $1`, req.DeviceID).Scan(&ownerID)
	if err != nil {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	if ownerID != claims.UserID {
		writeError(w, http.StatusForbidden, "device does not belong to you")
		return
	}

	// Store the point atomically with a per-user monotonicity check. Locking
	// the user row serializes concurrent ingests for the same user, so the
	// read-then-insert of the last timestamp cannot race, and the check spans
	// all of the user's devices (geofence state is per-user, not per-device).
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(r.Context())

	var lockedID string
	var dbFamilyID *string
	if err := tx.QueryRow(r.Context(), `SELECT id, family_id FROM users WHERE id = $1 FOR UPDATE`, ownerID).Scan(&lockedID, &dbFamilyID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock user")
		return
	}

	// Load the stored last-known position: used for the per-user monotonicity
	// check and for stationary dedup (below). member_positions is a one-row-
	// per-user table kept in step with every stored point, so this replaces a
	// MAX(ts) scan across every locations chunk (PERF-001/002). Its ts only
	// moves forward when a point is stored, the same value MAX(locations.ts)
	// returned, and it survives retention purges of old chunks.
	var mpLat, mpLon *float64
	var lastTS *time.Time
	err = tx.QueryRow(r.Context(), `
		SELECT lat, lon, ts FROM member_positions WHERE user_id = $1`, ownerID,
	).Scan(&mpLat, &mpLon, &lastTS)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to check last position")
		return
	}
	if lastTS != nil && !ts.After(*lastTS) {
		writeError(w, http.StatusBadRequest, "ts is not newer than the user's last location")
		return
	}

	// Stationary dedup: the point is within GPS noise of the stored position,
	// so storing it again adds no information. Keep the device's liveness fresh
	// (devices.last_seen + member_positions.updated_at + battery), announce a
	// `presence` frame to the family, and acknowledge with 200 so clients can
	// distinguish it from a stored point (201). Geofence evaluation still runs:
	// dwell/pending transitions are time-driven and must advance even while the
	// user stands still. No audit entry — this fires per reporting interval and
	// would flood the audit log with non-events.
	if mpLat != nil && mpLon != nil &&
		haversineMeters(*mpLat, *mpLon, req.Lat, req.Lon) < stationaryDedupMeters {
		if _, err := tx.Exec(r.Context(), `
			UPDATE devices SET last_seen = now() WHERE id = $1`, req.DeviceID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update device")
			return
		}
		if _, err := tx.Exec(r.Context(), `
			UPDATE member_positions
			SET updated_at = now(), battery_pct = COALESCE($2, battery_pct)
			WHERE user_id = $1`, ownerID, req.BatteryPct); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to update member position")
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to commit")
			return
		}

		postCommitRunner.Submit(func() {
			evalCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			s.evaluateGeofences(evalCtx, ownerID, req.Lon, req.Lat, ts)
		})
		// Presence is liveness, so use server receipt time rather than the GPS
		// fix timestamp. A delayed fix must never move "last seen" backwards.
		postCommitRunner.Submit(func() { s.broadcastPresence(ownerID, time.Now().UTC(), req.BatteryPct) })

		writeJSON(w, http.StatusOK, map[string]any{
			"status": "deduplicated",
			"ts":     ts,
		})
		return
	}

	// ON CONFLICT DO NOTHING: (device_id, ts) is unique. A conflict here means a
	// concurrent batch upload stored this exact timestamp first.
	tag, err := tx.Exec(r.Context(), `
		INSERT INTO locations (device_id, ts, geom, accuracy_meters, altitude_meters, speed_mps, heading_deg, battery_pct, motion_state, source)
		VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (device_id, ts) DO NOTHING`,
		req.DeviceID, ts, req.Lon, req.Lat, req.AccuracyMeters, req.AltitudeMeters,
		req.SpeedMPS, req.HeadingDeg, req.BatteryPct, nullIfEmpty(req.MotionState), nullIfEmpty(req.Source),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store location")
		return
	}
	if tag.RowsAffected() == 0 {
		// Already stored: acknowledge idempotently, like the stationary dedup.
		writeJSON(w, http.StatusOK, map[string]any{
			"status": "deduplicated",
			"ts":     ts,
		})
		return
	}

	// Upsert the last-known position into member_positions (separate from the
	// locations hypertable, which is subject to 90-day retention). The WHERE
	// clause skips the update if the stored position is already newer, so an
	// out-of-order point can never regress a member's last-known position.
	if _, err := tx.Exec(r.Context(), `
		INSERT INTO member_positions (user_id, lat, lon, ts, battery_pct, speed_mps, motion_state, accuracy_meters, device_id, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
		ON CONFLICT (user_id) DO UPDATE SET
			lat = EXCLUDED.lat, lon = EXCLUDED.lon, ts = EXCLUDED.ts,
			battery_pct = EXCLUDED.battery_pct, speed_mps = EXCLUDED.speed_mps,
			motion_state = EXCLUDED.motion_state, accuracy_meters = EXCLUDED.accuracy_meters,
			device_id = EXCLUDED.device_id, updated_at = now()
		WHERE member_positions.ts < EXCLUDED.ts`,
		ownerID, req.Lat, req.Lon, ts, req.BatteryPct, req.SpeedMPS,
		nullIfEmpty(req.MotionState), req.AccuracyMeters, req.DeviceID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store member position")
		return
	}

	if _, err := tx.Exec(r.Context(), `
		UPDATE devices SET last_seen = now() WHERE id = $1`, req.DeviceID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update device")
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}

	// Use the DB-resolved family_id (not the JWT claim, which can go stale
	// if the user changes families) for the audit entry.
	var auditFamilyID string
	if dbFamilyID != nil {
		auditFamilyID = *dbFamilyID
	}
	s.logAudit(r.Context(), ownerID, auditFamilyID, "location_ingest",
		fmt.Sprintf("device=%s", req.DeviceID), clientIP(r))

	// Evaluate geofences for the device owner against the new point in a
	// goroutine so the client's ack is not delayed by evaluation. A background
	// context (with a timeout) also means a client disconnect after the commit
	// cannot cancel the evaluation and silently drop the transition.
	postCommitRunner.Submit(func() {
		evalCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		s.evaluateGeofences(evalCtx, ownerID, req.Lon, req.Lat, ts)
	})

	// Fan out the live location update to the owner's family in a goroutine so
	// the ack is not delayed and a client disconnect cannot cancel it.
	postCommitRunner.Submit(func() {
		var motionState *string
		if req.MotionState != "" {
			motionState = &req.MotionState
		}
		s.broadcastLocation(ownerID, wsLocation{
			Type:           "location",
			UserID:         ownerID,
			Lat:            req.Lat,
			Lon:            req.Lon,
			TS:             ts,
			LastSeenAt:     time.Now().UTC(),
			BatteryPct:     req.BatteryPct,
			SpeedMPS:       req.SpeedMPS,
			MotionState:    motionState,
			AccuracyMeters: req.AccuracyMeters,
		})
	})

	writeJSON(w, http.StatusCreated, models.Location{
		DeviceID:       req.DeviceID,
		TS:             ts,
		Lat:            req.Lat,
		Lon:            req.Lon,
		AccuracyMeters: req.AccuracyMeters,
		AltitudeMeters: req.AltitudeMeters,
		SpeedMPS:       req.SpeedMPS,
		HeadingDeg:     req.HeadingDeg,
		BatteryPct:     req.BatteryPct,
		MotionState:    req.MotionState,
		Source:         req.Source,
	})
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
