package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

// Per-person, per-place alert rules and the user-wide quiet window. Both only
// ever narrow place arrival/departure pushes; the geofence event and alert
// history are recorded regardless, and emergencies never consult them.
//
// Quiet hours suppress the push (rather than sending it silently): push
// payloads carry no per-notification priority switch today, and the event
// remains visible in history.

const (
	ruleBoth       = "both"
	ruleArrivals   = "arrivals"
	ruleDepartures = "departures"
	ruleOff        = "off"
)

// ruleAllows reports whether a rule mode lets eventType ("enter"/"exit") through.
// Unknown modes behave like "both" (fail open).
func ruleAllows(mode, eventType string) bool {
	switch mode {
	case ruleOff:
		return false
	case ruleArrivals:
		return eventType != "exit"
	case ruleDepartures:
		return eventType == "exit"
	}
	return true
}

// placeAlertSuppressed returns the users who must not get a push about
// subject's place event: per-member prefs (mute, category, member quiet hours),
// the user-wide quiet window, and the per-place rule. It runs its queries one
// after another and fully reads each, so it is safe on a transaction.
func placeAlertSuppressed(ctx context.Context, q notifQuerier, subjectID, placeID, eventType string, now time.Time) map[string]bool {
	category := notifArrivals
	if eventType == "exit" {
		category = notifDepartures
	}
	out := notifSuppressed(ctx, q, subjectID, category, now)

	// User-wide quiet window for everyone who could be told about subject.
	rows, err := q.Query(ctx, `
		SELECT q.user_id::text, q.quiet_start::int, q.quiet_end::int, q.tz
		FROM user_quiet_hours q
		JOIN users v ON v.id = q.user_id
		JOIN users s ON s.id = $1 AND s.family_id = v.family_id`, subjectID)
	if err != nil {
		slog.Error("quiet hours: load", "err", err)
	} else {
		for rows.Next() {
			var uid, tz string
			var qs, qe int
			if err := rows.Scan(&uid, &qs, &qe, &tz); err != nil {
				slog.Error("quiet hours: scan", "err", err)
				continue
			}
			if inQuietHours(now, tz, qs, qe) {
				out[uid] = true
			}
		}
		rows.Close()
	}

	if placeID != "" {
		rows, err := q.Query(ctx, `
			SELECT user_id::text, mode FROM place_alert_rules WHERE subject_id = $1 AND place_id = $2`,
			subjectID, placeID)
		if err != nil {
			slog.Error("place rules: load", "err", err)
		} else {
			for rows.Next() {
				var uid, mode string
				if err := rows.Scan(&uid, &mode); err != nil {
					slog.Error("place rules: scan", "err", err)
					continue
				}
				if !ruleAllows(mode, eventType) {
					out[uid] = true
				}
			}
			rows.Close()
		}
	}
	return out
}

// ---- API: per-place rules -------------------------------------------------

type placeRuleJSON struct {
	PlaceID string `json:"place_id"`
	Mode    string `json:"mode"`
}

// ListPlaceAlertRules returns the caller's non-default rules about one member.
func (s *Server) ListPlaceAlertRules(w http.ResponseWriter, r *http.Request) {
	caller, subject, ok := s.notifPrefsTarget(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(),
		`SELECT place_id::text, mode FROM place_alert_rules WHERE user_id = $1 AND subject_id = $2 ORDER BY place_id`,
		caller, subject)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load rules")
		return
	}
	defer rows.Close()
	out := []placeRuleJSON{}
	for rows.Next() {
		var p placeRuleJSON
		if err := rows.Scan(&p.PlaceID, &p.Mode); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load rules")
			return
		}
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"rules": out})
}

// PutPlaceAlertRule sets (or, for "both", clears) the caller's rule about one
// member at one place.
func (s *Server) PutPlaceAlertRule(w http.ResponseWriter, r *http.Request) {
	caller, subject, ok := s.notifPrefsTarget(w, r)
	if !ok {
		return
	}
	placeID := chi.URLParam(r, "placeId")
	if !circles.ValidID(placeID) {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	var in placeRuleJSON
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	switch in.Mode {
	case ruleBoth, ruleArrivals, ruleDepartures, ruleOff:
	default:
		writeError(w, http.StatusBadRequest, "mode must be both, arrivals, departures or off")
		return
	}
	var ok2 bool
	if err := s.Pool.QueryRow(r.Context(), `
		SELECT EXISTS (SELECT 1 FROM places p JOIN users u ON u.id = $1
		               WHERE p.id = $2 AND p.family_id = u.family_id AND `+placeVisibleSQL("p", "u.id")+`)`,
		caller, placeID).Scan(&ok2); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check place")
		return
	}
	if !ok2 {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	var err error
	if in.Mode == ruleBoth {
		_, err = s.Pool.Exec(r.Context(),
			`DELETE FROM place_alert_rules WHERE user_id = $1 AND subject_id = $2 AND place_id = $3`,
			caller, subject, placeID)
	} else {
		_, err = s.Pool.Exec(r.Context(), `
			INSERT INTO place_alert_rules (user_id, subject_id, place_id, mode) VALUES ($1,$2,$3,$4)
			ON CONFLICT (user_id, subject_id, place_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at = now()`,
			caller, subject, placeID, in.Mode)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save rule")
		return
	}
	writeJSON(w, http.StatusOK, placeRuleJSON{PlaceID: placeID, Mode: in.Mode})
}

// ---- API: user-wide quiet hours -------------------------------------------

type quietHoursJSON struct {
	QuietStart *string `json:"quiet_start"`
	QuietEnd   *string `json:"quiet_end"`
	Timezone   string  `json:"timezone"`
}

func (s *Server) loadQuietHours(ctx context.Context, user string) (quietHoursJSON, error) {
	q := quietHoursJSON{Timezone: "UTC"}
	var qs, qe int
	err := s.Pool.QueryRow(ctx,
		`SELECT quiet_start::int, quiet_end::int, tz FROM user_quiet_hours WHERE user_id = $1`, user).Scan(&qs, &qe, &q.Timezone)
	if errors.Is(err, pgx.ErrNoRows) {
		return q, nil
	}
	if err != nil {
		return q, err
	}
	a, b := fmtMinutes(qs), fmtMinutes(qe)
	q.QuietStart, q.QuietEnd = &a, &b
	return q, nil
}

func (s *Server) GetQuietHours(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	q, err := s.loadQuietHours(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load quiet hours")
		return
	}
	writeJSON(w, http.StatusOK, q)
}

// PutQuietHours replaces the caller's quiet window; null start/end clears it.
func (s *Server) PutQuietHours(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var in quietHoursJSON
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if in.Timezone == "" {
		in.Timezone = "UTC"
	}
	if _, err := resolveNotifLocation(in.Timezone); err != nil || len(in.Timezone) > 64 {
		writeError(w, http.StatusBadRequest, "unknown timezone")
		return
	}
	if (in.QuietStart == nil) != (in.QuietEnd == nil) {
		writeError(w, http.StatusBadRequest, "quiet_start and quiet_end must be set together")
		return
	}
	if in.QuietStart == nil {
		if _, err := s.Pool.Exec(r.Context(), `DELETE FROM user_quiet_hours WHERE user_id = $1`, claims.UserID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save quiet hours")
			return
		}
	} else {
		a, ok1 := parseHHMM(*in.QuietStart)
		b, ok2 := parseHHMM(*in.QuietEnd)
		if !ok1 || !ok2 {
			writeError(w, http.StatusBadRequest, "quiet hours must be HH:MM")
			return
		}
		if a == b {
			writeError(w, http.StatusBadRequest, "quiet hours must not be empty")
			return
		}
		if _, err := s.Pool.Exec(r.Context(), `
			INSERT INTO user_quiet_hours (user_id, quiet_start, quiet_end, tz) VALUES ($1,$2,$3,$4)
			ON CONFLICT (user_id) DO UPDATE SET quiet_start = EXCLUDED.quiet_start,
			    quiet_end = EXCLUDED.quiet_end, tz = EXCLUDED.tz, updated_at = now()`,
			claims.UserID, a, b, in.Timezone); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save quiet hours")
			return
		}
	}
	q, err := s.loadQuietHours(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load quiet hours")
		return
	}
	writeJSON(w, http.StatusOK, q)
}
