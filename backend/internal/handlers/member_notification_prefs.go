package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
	_ "time/tzdata" // quiet hours need IANA zones even on minimal images

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Notification categories a user can switch off per member. SOS, help and
// check-in alerts have no category here on purpose: they are never filtered.
const (
	notifArrivals   = "arrivals"
	notifDepartures = "departures"
	notifLowBattery = "low_battery"
	notifDriving    = "driving"
)

type notifPrefsJSON struct {
	SubjectID  string  `json:"subject_id"`
	Muted      bool    `json:"muted"`
	Arrivals   bool    `json:"arrivals"`
	Departures bool    `json:"departures"`
	LowBattery bool    `json:"low_battery"`
	Driving    bool    `json:"driving"`
	QuietStart *string `json:"quiet_start"` // "HH:MM" or null
	QuietEnd   *string `json:"quiet_end"`
	Timezone   string  `json:"timezone"`
	// SOSAlwaysOn is informational: SOS alerts cannot be muted.
	SOSAlwaysOn bool `json:"sos_always_on"`
}

func defaultNotifPrefs(subject string) notifPrefsJSON {
	return notifPrefsJSON{SubjectID: subject, Arrivals: true, Departures: true, LowBattery: true,
		Driving: true, Timezone: "UTC", SOSAlwaysOn: true}
}

// resolveNotifLocation accepts an IANA zone or a fixed offset written
// "UTC+05:30" / "UTC-08:00" (what the phone app sends, since it has no IANA
// name on hand). Fixed offsets do not follow daylight saving; the app re-sends
// the current offset whenever the settings are saved.
func resolveNotifLocation(tz string) (*time.Location, error) {
	if len(tz) == 9 && tz[:3] == "UTC" && (tz[3] == '+' || tz[3] == '-') && tz[6] == ':' {
		t, err := time.Parse("15:04", tz[4:])
		if err == nil {
			off := (t.Hour()*60 + t.Minute()) * 60
			if tz[3] == '-' {
				off = -off
			}
			return time.FixedZone(tz, off), nil
		}
	}
	return time.LoadLocation(tz)
}

func fmtMinutes(m int) string { return fmt.Sprintf("%02d:%02d", m/60, m%60) }

func parseHHMM(s string) (int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, false
	}
	return t.Hour()*60 + t.Minute(), true
}

// notifPrefsTarget authorizes the caller to manage prefs about {id}: the
// subject must be another user who shares a circle with the caller. Anything
// else answers 404 so user ids cannot be probed.
func (s *Server) notifPrefsTarget(w http.ResponseWriter, r *http.Request) (caller, subject string, ok bool) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", "", false
	}
	subject = chi.URLParam(r, "id")
	if !circles.ValidID(subject) {
		writeError(w, http.StatusNotFound, "member not found")
		return "", "", false
	}
	if subject == claims.UserID {
		writeError(w, http.StatusBadRequest, "notification settings are about other members")
		return "", "", false
	}
	shared, err := circles.New(s.Pool).SharedWith(r.Context(), claims.UserID, subject)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check membership")
		return "", "", false
	}
	if len(shared) == 0 {
		writeError(w, http.StatusNotFound, "member not found")
		return "", "", false
	}
	return claims.UserID, subject, true
}

func (s *Server) loadNotifPrefs(ctx context.Context, user, subject string) (notifPrefsJSON, error) {
	p := defaultNotifPrefs(subject)
	var qs, qe *int
	err := s.Pool.QueryRow(ctx, `
		SELECT muted, arrivals, departures, low_battery, driving, quiet_start::int, quiet_end::int, tz
		FROM notification_prefs WHERE user_id = $1 AND subject_id = $2`, user, subject,
	).Scan(&p.Muted, &p.Arrivals, &p.Departures, &p.LowBattery, &p.Driving, &qs, &qe, &p.Timezone)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return defaultNotifPrefs(subject), nil
		}
		return p, err
	}
	if qs != nil && qe != nil {
		a, b := fmtMinutes(*qs), fmtMinutes(*qe)
		p.QuietStart, p.QuietEnd = &a, &b
	}
	return p, nil
}

// GetMemberNotificationPrefs returns the caller's preferences about one member
// (defaults when never saved).
func (s *Server) GetMemberNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	caller, subject, ok := s.notifPrefsTarget(w, r)
	if !ok {
		return
	}
	p, err := s.loadNotifPrefs(r.Context(), caller, subject)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load settings")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// PutMemberNotificationPrefs replaces the caller's preferences about one member.
// The user is always the caller; the body cannot name another user.
func (s *Server) PutMemberNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	caller, subject, ok := s.notifPrefsTarget(w, r)
	if !ok {
		return
	}
	var in notifPrefsJSON
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
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
	var qs, qe *int
	if (in.QuietStart == nil) != (in.QuietEnd == nil) {
		writeError(w, http.StatusBadRequest, "quiet_start and quiet_end must be set together")
		return
	}
	if in.QuietStart != nil {
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
		qs, qe = &a, &b
	}
	if _, err := s.Pool.Exec(r.Context(), `
		INSERT INTO notification_prefs (user_id, subject_id, muted, arrivals, departures, low_battery, driving,
		                                quiet_start, quiet_end, tz, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10, now())
		ON CONFLICT (user_id, subject_id) DO UPDATE SET
		    muted = EXCLUDED.muted, arrivals = EXCLUDED.arrivals, departures = EXCLUDED.departures,
		    low_battery = EXCLUDED.low_battery, driving = EXCLUDED.driving,
		    quiet_start = EXCLUDED.quiet_start, quiet_end = EXCLUDED.quiet_end,
		    tz = EXCLUDED.tz, updated_at = now()`,
		caller, subject, in.Muted, in.Arrivals, in.Departures, in.LowBattery, in.Driving, qs, qe, in.Timezone); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save settings")
		return
	}
	p, err := s.loadNotifPrefs(r.Context(), caller, subject)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load settings")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// DeleteMemberNotificationPrefs resets the caller's preferences about one member.
func (s *Server) DeleteMemberNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	caller, subject, ok := s.notifPrefsTarget(w, r)
	if !ok {
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`DELETE FROM notification_prefs WHERE user_id = $1 AND subject_id = $2`, caller, subject); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to reset settings")
		return
	}
	writeJSON(w, http.StatusOK, defaultNotifPrefs(subject))
}

// inQuietHours reports whether now falls in [start,end) minutes-of-day in tz,
// handling windows that wrap past midnight.
func inQuietHours(now time.Time, tz string, start, end int) bool {
	loc, err := resolveNotifLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	l := now.In(loc)
	m := l.Hour()*60 + l.Minute()
	if start < end {
		return m >= start && m < end
	}
	return m >= start || m < end
}

// notifQuerier is satisfied by both the pool and a transaction.
type notifQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// notifSuppressed returns the users who must NOT be notified about subject for
// the category right now (muted, category off, or inside quiet hours). Only
// the four optional categories are filterable; any other category (SOS, help,
// check-in, resolved, "") returns nobody, so emergencies are never mutable.
// Errors fail open: a broken preference lookup must not drop a notification.
func notifSuppressed(ctx context.Context, q notifQuerier, subjectID, category string, now time.Time) map[string]bool {
	out := map[string]bool{}
	switch category {
	case notifArrivals, notifDepartures, notifLowBattery, notifDriving:
	default:
		return out
	}
	rows, err := q.Query(ctx, `
		SELECT user_id::text, muted, arrivals, departures, low_battery, driving, quiet_start::int, quiet_end::int, tz
		FROM notification_prefs WHERE subject_id = $1`, subjectID)
	if err != nil {
		slog.Error("notif prefs: load", "err", err)
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var uid, tz string
		var muted, arr, dep, low, drv bool
		var qs, qe *int
		if err := rows.Scan(&uid, &muted, &arr, &dep, &low, &drv, &qs, &qe, &tz); err != nil {
			slog.Error("notif prefs: scan", "err", err)
			continue
		}
		on := map[string]bool{notifArrivals: arr, notifDepartures: dep, notifLowBattery: low, notifDriving: drv}[category]
		switch {
		case muted, !on:
			out[uid] = true
		case qs != nil && qe != nil && inQuietHours(now, tz, *qs, *qe):
			out[uid] = true
		}
	}
	return out
}
