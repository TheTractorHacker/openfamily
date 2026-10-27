package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Possible-crash reports. Detection is a server-side heuristic over data the
// phone already sends: a very hard brake event from the motion sensor, taken
// at driving speed, followed by the GPS fixes showing the car did not keep
// going. It is not a certified crash detector and never contacts emergency
// services.
const (
	crashMinBrakeMps2  = 8.0              // ~0.8 g, well above ordinary hard braking (3.5)
	crashMinSpeedMps   = 13.0             // ~30 mph just before the event
	crashMaxAfterMps   = 4.0              // still moving faster than this afterwards = not a crash
	crashSettle        = 60 * time.Second // wait for the post-event fixes to upload
	crashPreWindow     = 20 * time.Second
	crashPostWindow    = 60 * time.Second
	crashStatusPossibl = "possible"
	crashListLimit     = 50
)

// EnsureCrashSchema creates the crash objects idempotently (not a numbered
// migration: those are shared with other in-flight work).
func (s *Server) EnsureCrashSchema(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `
		ALTER TABLE users ADD COLUMN IF NOT EXISTS crash_detection_enabled BOOLEAN NOT NULL DEFAULT TRUE;
		CREATE TABLE IF NOT EXISTS crash_events (
			id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			occurred_at      TIMESTAMPTZ NOT NULL,
			lat              DOUBLE PRECISION,
			lon              DOUBLE PRECISION,
			brake_mps2       DOUBLE PRECISION NOT NULL,
			speed_before_mps DOUBLE PRECISION NOT NULL,
			speed_after_mps  DOUBLE PRECISION,
			status           TEXT NOT NULL DEFAULT 'possible',
			created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
			resolved_at      TIMESTAMPTZ,
			UNIQUE (user_id, occurred_at)
		);
		CREATE INDEX IF NOT EXISTS crash_events_user_time ON crash_events (user_id, occurred_at DESC);`)
	return err
}

type crashCandidate struct {
	At        time.Time
	End       time.Time
	Magnitude float64
	Lat, Lon  *float64
}

// detectCrashes waits for GPS fixes to catch up, then records and announces
// any candidate that looks like a real stop from driving speed.
func (s *Server) detectCrashes(userID string, cands []crashCandidate) {
	time.Sleep(crashSettle)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var enabled bool
	if err := s.Pool.QueryRow(ctx, `
		SELECT crash_detection_enabled AND driving_sensor_enabled FROM users WHERE id = $1`,
		userID).Scan(&enabled); err != nil || !enabled {
		return
	}
	for _, c := range cands {
		var pre *float64
		var postN int
		var post *float64
		var flat, flon *float64
		err := s.Pool.QueryRow(ctx, `
			SELECT
			  (SELECT max(l.speed_mps) FROM locations l JOIN devices d ON d.id = l.device_id
			    WHERE d.user_id = $1 AND l.ts BETWEEN $2 AND $3),
			  (SELECT count(l.speed_mps) FROM locations l JOIN devices d ON d.id = l.device_id
			    WHERE d.user_id = $1 AND l.ts BETWEEN $4 AND $5),
			  (SELECT max(l.speed_mps) FROM locations l JOIN devices d ON d.id = l.device_id
			    WHERE d.user_id = $1 AND l.ts BETWEEN $4 AND $5),
			  (SELECT ST_Y(l.geom) FROM locations l JOIN devices d ON d.id = l.device_id
			    WHERE d.user_id = $1 AND l.ts BETWEEN $2 AND $5 ORDER BY l.ts DESC LIMIT 1),
			  (SELECT ST_X(l.geom) FROM locations l JOIN devices d ON d.id = l.device_id
			    WHERE d.user_id = $1 AND l.ts BETWEEN $2 AND $5 ORDER BY l.ts DESC LIMIT 1)`,
			userID, c.At.Add(-crashPreWindow), c.At.Add(2*time.Second),
			c.End.Add(5*time.Second), c.End.Add(crashPostWindow),
		).Scan(&pre, &postN, &post, &flat, &flon)
		if err != nil {
			slog.Warn("crash: lookup", "err", err)
			continue
		}
		if pre == nil || *pre < crashMinSpeedMps {
			continue // was not at driving speed
		}
		if postN > 0 && post != nil && *post > crashMaxAfterMps {
			continue // kept driving: just a hard stop
		}
		lat, lon := c.Lat, c.Lon
		if lat == nil || lon == nil {
			lat, lon = flat, flon
		}
		var id string
		err = s.Pool.QueryRow(ctx, `
			INSERT INTO crash_events (user_id, occurred_at, lat, lon, brake_mps2, speed_before_mps, speed_after_mps)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
			ON CONFLICT (user_id, occurred_at) DO NOTHING
			RETURNING id`,
			userID, c.At, lat, lon, c.Magnitude, *pre, post).Scan(&id)
		if err != nil {
			continue // duplicate (or error): never announce twice
		}
		s.announceCrash(ctx, userID, id)
	}
}

func (s *Server) announceCrash(ctx context.Context, userID, crashID string) {
	familyID, err := s.familyIDForUser(ctx, userID)
	if err != nil || familyID == "" || s.Push == nil {
		return
	}
	// One announcement per person per 10 minutes, however many candidates fire.
	var recent int
	_ = s.Pool.QueryRow(ctx, `
		SELECT count(*) FROM crash_events
		WHERE user_id = $1 AND id <> $2 AND occurred_at > now() - interval '10 minutes'`,
		userID, crashID).Scan(&recent)
	if recent > 0 {
		return
	}
	// Only people who share a circle with this person AND in which they share
	// their location may be told where and when they stopped.
	only := map[string]bool{}
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT v.user_id::text
		FROM live_circle_members s
		JOIN live_circle_members v ON v.circle_id = s.circle_id AND v.user_id <> s.user_id
		WHERE s.user_id = $1 AND s.sharing_enabled
		  AND NOT `+pausedExprSQL("s.user_id"), userID)
	if err != nil {
		return
	}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			only[id] = true
		}
	}
	rows.Close()
	if len(only) == 0 {
		return
	}
	var name string
	_ = s.Pool.QueryRow(ctx, `SELECT name FROM users WHERE id = $1`, userID).Scan(&name)
	who := s.pushName(name)
	title := "Possible crash: " + who
	body := who + "'s phone detected a sudden stop at driving speed. Check that they are okay."
	sent, failed := s.pushFamilyAlertOnly(ctx, familyID, userID, "", title, body, "safety_incidents", only)
	s.logAudit(ctx, userID, familyID, "crash.detected",
		fmt.Sprintf("crash_id=%s push_sent=%d push_failed=%d", crashID, sent, failed), "")
}

type crashJSON struct {
	ID             string     `json:"id"`
	UserID         string     `json:"user_id"`
	Name           string     `json:"name"`
	Mine           bool       `json:"mine"`
	OccurredAt     time.Time  `json:"occurred_at"`
	Lat            *float64   `json:"lat,omitempty"`
	Lon            *float64   `json:"lon,omitempty"`
	BrakeMps2      float64    `json:"brake_mps2"`
	SpeedBeforeMps float64    `json:"speed_before_mps"`
	SpeedAfterMps  *float64   `json:"speed_after_mps,omitempty"`
	Status         string     `json:"status"`
	ResolvedAt     *time.Time `json:"resolved_at,omitempty"`
}

// ListCrashes returns the caller's and their circle's crash reports (90 days).
// GET /crashes
func (s *Server) ListCrashes(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT c.id, c.user_id, u.name, c.occurred_at, c.lat, c.lon, c.brake_mps2,
		       c.speed_before_mps, c.speed_after_mps, c.status, c.resolved_at
		FROM crash_events c
		JOIN users u ON u.id = c.user_id
		WHERE c.occurred_at > now() - interval '90 days'
		  AND (c.user_id = $1
		       OR EXISTS (
		           SELECT 1 FROM live_circle_members v
		           JOIN live_circle_members s ON s.circle_id = v.circle_id
		           WHERE v.user_id = $1 AND s.user_id = c.user_id AND s.sharing_enabled
		             AND NOT `+pausedExprSQL("s.user_id")+`))
		ORDER BY c.occurred_at DESC LIMIT $2`, claims.UserID, crashListLimit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load crash reports")
		return
	}
	defer rows.Close()
	out := []crashJSON{}
	for rows.Next() {
		var c crashJSON
		if err := rows.Scan(&c.ID, &c.UserID, &c.Name, &c.OccurredAt, &c.Lat, &c.Lon, &c.BrakeMps2,
			&c.SpeedBeforeMps, &c.SpeedAfterMps, &c.Status, &c.ResolvedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load crash reports")
			return
		}
		c.Mine = c.UserID == claims.UserID
		out = append(out, c)
	}
	var enabled bool
	_ = s.Pool.QueryRow(r.Context(), `SELECT crash_detection_enabled FROM users WHERE id = $1`, claims.UserID).Scan(&enabled)
	writeJSON(w, http.StatusOK, map[string]any{"crashes": out, "detection_enabled": enabled})
}

// SetCrashStatus lets the person involved mark a report "ok" or "false_alarm".
// POST /crashes/{id}/status
func (s *Server) SetCrashStatus(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Status string `json:"status"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil ||
		(req.Status != "ok" && req.Status != "false_alarm") {
		writeError(w, http.StatusBadRequest, "status must be ok or false_alarm")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE crash_events SET status = $3, resolved_at = now()
		WHERE id = $1 AND user_id = $2`, chi.URLParam(r, "id"), claims.UserID, req.Status)
	if err != nil {
		writeError(w, http.StatusNotFound, "crash report not found")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "crash report not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": req.Status})
}

// SetCrashDetection turns crash detection on or off for the caller.
// PUT /crashes/settings
func (s *Server) SetCrashDetection(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || req.Enabled == nil {
		writeError(w, http.StatusBadRequest, "enabled is required")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `UPDATE users SET crash_detection_enabled = $2 WHERE id = $1`,
		claims.UserID, *req.Enabled); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"detection_enabled": *req.Enabled})
}
