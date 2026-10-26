package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

// Driving events detected by the phone's motion sensor (docs/driving.md).
// Authenticated like location ingest (device ingest key or access token).
const (
	sensorMaxEvents   = 100
	sensorMaxBody     = 64 << 10
	sensorMaxAge      = 7 * 24 * time.Hour
	sensorSkew        = 5 * time.Minute
	sensorMaxDuration = 5 * time.Minute // phone_use only
	// A braking or acceleration episode lasts seconds. A long one is rejected so a
	// single self-reported event can never stand in for many real ones.
	sensorMaxBrakeAccelDuration = 10 * time.Second
	sensorMaxAccel    = 30.0  // m/s^2
	sensorMaxPhoneS   = 300.0 // seconds of interaction
	sensorRateLimit   = 30
	sensorRateWindow  = time.Minute
)

type sensorEventIn struct {
	Kind      string   `json:"kind"`
	StartedAt string   `json:"started_at"`
	EndedAt   string   `json:"ended_at"`
	Magnitude *float64 `json:"magnitude"`
	Lat       *float64 `json:"lat"`
	Lon       *float64 `json:"lon"`
}

type sensorEvent struct {
	Kind       string
	Start, End time.Time
	Magnitude  float64
	Lat, Lon   *float64
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }

// validateSensorEvent checks one event against the contract. Pure.
func validateSensorEvent(in sensorEventIn, now time.Time) (sensorEvent, bool) {
	var ev sensorEvent
	max := sensorMaxAccel
	switch in.Kind {
	case trips.EventHardBrake, trips.EventRapidAccel:
	case trips.EventPhoneUse:
		max = sensorMaxPhoneS
	default:
		return ev, false
	}
	start, err := time.Parse(time.RFC3339, in.StartedAt)
	if err != nil {
		return ev, false
	}
	end, err := time.Parse(time.RFC3339, in.EndedAt)
	if err != nil {
		return ev, false
	}
	if start.After(now.Add(sensorSkew)) || start.Before(now.Add(-sensorMaxAge)) {
		return ev, false
	}
	maxDur := sensorMaxDuration
	if in.Kind != trips.EventPhoneUse {
		maxDur = sensorMaxBrakeAccelDuration
	}
	if end.Before(start) || end.Sub(start) > maxDur {
		return ev, false
	}
	if in.Magnitude == nil || !finite(*in.Magnitude) || *in.Magnitude < 0 || *in.Magnitude > max {
		return ev, false
	}
	if (in.Lat == nil) != (in.Lon == nil) {
		return ev, false
	}
	if in.Lat != nil {
		if !finite(*in.Lat) || !finite(*in.Lon) || *in.Lat < -90 || *in.Lat > 90 || *in.Lon < -180 || *in.Lon > 180 {
			return ev, false
		}
	}
	return sensorEvent{Kind: in.Kind, Start: start.UTC(), End: end.UTC(), Magnitude: *in.Magnitude, Lat: in.Lat, Lon: in.Lon}, true
}

// IngestSensorEvents stores motion-sensor driving events for the caller.
// POST /trips/sensor-events
func (s *Server) IngestSensorEvents(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	deviceID := middleware.DeviceIDFromContext(r.Context())
	if s.LocationLimit != nil {
		key := "sensor:user:" + claims.UserID
		if deviceID != "" {
			key = "sensor:dev:" + deviceID
		}
		if !s.LocationLimit.Allow(key, sensorRateLimit, sensorRateWindow) {
			writeError(w, http.StatusTooManyRequests, "too many sensor event requests")
			return
		}
	}

	r.Body = http.MaxBytesReader(w, r.Body, sensorMaxBody)
	var req struct {
		Events        []sensorEventIn `json:"events"`
		SensorEnabled *bool           `json:"sensor_enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "request body too large (max 64 KB)")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.Events) > sensorMaxEvents {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("too many events (max %d)", sensorMaxEvents))
		return
	}
	if len(req.Events) == 0 && req.SensorEnabled == nil {
		writeError(w, http.StatusBadRequest, "events or sensor_enabled is required")
		return
	}

	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store events")
		return
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var enabled bool
	if req.SensorEnabled != nil {
		err = tx.QueryRow(ctx, `UPDATE users SET driving_sensor_enabled = $2 WHERE id = $1 RETURNING driving_sensor_enabled`,
			claims.UserID, *req.SensorEnabled).Scan(&enabled)
	} else {
		err = tx.QueryRow(ctx, `SELECT driving_sensor_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&enabled)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load settings")
		return
	}

	accepted, duplicate, rejected := 0, 0, 0
	if !enabled {
		rejected = len(req.Events) // opted out: nothing is stored
	} else {
		now := time.Now()
		var dev any
		if deviceID != "" {
			dev = deviceID
		}
		for _, in := range req.Events {
			ev, ok := validateSensorEvent(in, now)
			if !ok {
				rejected++
				continue
			}
			tag, err := tx.Exec(ctx, `
				INSERT INTO trip_events (user_id, device_id, source, kind, started_at, ended_at, magnitude, lat, lon)
				VALUES ($1, $2::uuid, 'sensor', $3, $4, $5, $6, $7, $8)
				ON CONFLICT (user_id, kind, started_at) WHERE source = 'sensor' DO NOTHING`,
				claims.UserID, dev, ev.Kind, ev.Start, ev.End, ev.Magnitude, ev.Lat, ev.Lon)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "failed to store events")
				return
			}
			if tag.RowsAffected() == 1 {
				accepted++
			} else {
				duplicate++
			}
		}
		if accepted > 0 {
			if err := trips.LinkSensorEvents(ctx, tx, claims.UserID); err != nil {
				writeError(w, http.StatusInternalServerError, "failed to link events")
				return
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store events")
		return
	}

	// Counts only: no times, places or magnitudes in the audit log.
	if req.SensorEnabled != nil {
		s.logAudit(ctx, claims.UserID, "", "driving.sensor_toggle", fmt.Sprintf("driving sensor enabled=%t", enabled), clientIP(r))
	}
	if len(req.Events) > 0 && accepted > 0 {
		s.logAudit(ctx, claims.UserID, "", "driving.sensor_events",
			fmt.Sprintf("accepted=%d duplicate=%d rejected=%d", accepted, duplicate, rejected), clientIP(r))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accepted": accepted, "duplicate": duplicate, "rejected": rejected, "sensor_enabled": enabled,
	})
}

