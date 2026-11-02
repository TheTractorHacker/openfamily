package handlers

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	crashAlertMaxAge    = 30 * time.Minute
	crashAlertMaxFuture = 2 * time.Minute
	standardGravityMps2 = 9.80665
)

type crashAlertRequest struct {
	OccurredAt     *time.Time `json:"occurred_at"`
	Lat            *float64   `json:"lat"`
	Lon            *float64   `json:"lon"`
	PeakG          float64    `json:"peak_g"`
	SpeedBeforeMps float64    `json:"speed_before_mps"`
	SpeedAfterMps  float64    `json:"speed_after_mps"`
	HelpRequested  bool       `json:"help_requested"`
}

func finiteIn(v, min, max float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= min && v <= max
}

// PostCrashAlert records a crash the phone itself detected and the person did
// not cancel in the "Are you OK?" countdown (or for which they asked for
// help), and notifies the circle. It reuses the crash report storage and push
// pipeline, so the event shows in Crash reports and in the admin activity
// feed. The phone also posts /alerts/help when help was requested, which puts
// it in the alerts history. Emergency services are never contacted.
// POST /crash-alerts   (Bearer token or device ingest key)
func (s *Server) PostCrashAlert(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req crashAlertRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !validAlertCoord(req.Lat, -90, 90) || !validAlertCoord(req.Lon, -180, 180) ||
		!finiteIn(req.PeakG, 0, 200) ||
		!finiteIn(req.SpeedBeforeMps, 0, 150) || !finiteIn(req.SpeedAfterMps, 0, 150) {
		writeError(w, http.StatusBadRequest, "values out of range")
		return
	}
	now := time.Now()
	at := now
	if req.OccurredAt != nil && req.OccurredAt.After(now.Add(-crashAlertMaxAge)) &&
		req.OccurredAt.Before(now.Add(crashAlertMaxFuture)) {
		at = req.OccurredAt.UTC()
	}
	ctx := r.Context()

	lat, lon := req.Lat, req.Lon
	if lat == nil || lon == nil {
		var la, lo float64
		err := s.Pool.QueryRow(ctx, `SELECT lat, lon FROM member_positions WHERE user_id = $1`,
			claims.UserID).Scan(&la, &lo)
		if err == nil {
			lat, lon = &la, &lo
		} else if err != pgx.ErrNoRows {
			writeError(w, http.StatusInternalServerError, "failed to load location")
			return
		}
	}

	kind := "device"
	if req.HelpRequested {
		kind = "device_help"
	}
	brake := req.PeakG * standardGravityMps2

	// The same crash may already be stored (a retry, the foreground and
	// background senders racing, or the server heuristic got there first).
	var id string
	var existingHelp bool
	err := s.Pool.QueryRow(ctx, `
		SELECT id::text, help_requested FROM crash_events
		WHERE user_id = $1 AND occurred_at BETWEEN $2 AND $3
		ORDER BY occurred_at LIMIT 1`,
		claims.UserID, at.Add(-crashDeviceDedupe), at.Add(crashDeviceDedupe)).Scan(&id, &existingHelp)
	switch {
	case err == nil:
		if req.HelpRequested && !existingHelp {
			_, _ = s.Pool.Exec(ctx, `UPDATE crash_events SET help_requested = TRUE WHERE id = $1`, id)
			go s.announceCrashAsync(claims.UserID, id, kind)
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": crashStatusPossibl})
		return
	case err != pgx.ErrNoRows:
		writeError(w, http.StatusInternalServerError, "failed to save crash report")
		return
	}

	err = s.Pool.QueryRow(ctx, `
		INSERT INTO crash_events (user_id, occurred_at, lat, lon, brake_mps2, speed_before_mps,
		                          speed_after_mps, source, help_requested, peak_g)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'device', $8, $9)
		ON CONFLICT (user_id, occurred_at) DO UPDATE SET help_requested = crash_events.help_requested OR EXCLUDED.help_requested
		RETURNING id::text`,
		claims.UserID, at, lat, lon, brake, req.SpeedBeforeMps, req.SpeedAfterMps,
		req.HelpRequested, req.PeakG).Scan(&id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save crash report")
		return
	}
	go s.announceCrashAsync(claims.UserID, id, kind)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":      id,
		"status":  crashStatusPossibl,
		"message": alertNotifiedMessage,
	})
}

func (s *Server) announceCrashAsync(userID, crashID, kind string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s.announceCrash(ctx, userID, crashID, kind)
}
