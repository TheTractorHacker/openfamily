package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/jackc/pgx/v5"
)

// Notification categories a person can switch off. SOS and "needs help"
// alerts are deliberately not here: they always reach the family.
//
// place_alerts and check_in are enforced today. The rest are stored so the
// app can show and keep the choice; the server honours them as soon as it
// starts sending those pushes.
var notificationCategories = []string{
	"place_alerts", "check_in", "low_battery",
	"completed_drives", "safety_incidents", "severe_weather",
}

// NotificationPrefs is the wire shape of GET/PUT /me/notifications.
type NotificationPrefs struct {
	PlaceAlerts     bool `json:"place_alerts"`
	CheckIn         bool `json:"check_in"`
	LowBattery      bool `json:"low_battery"`
	CompletedDrives bool `json:"completed_drives"`
	SafetyIncidents bool `json:"safety_incidents"`
	SevereWeather   bool `json:"severe_weather"`
}

func defaultNotificationPrefs() NotificationPrefs {
	return NotificationPrefs{true, true, true, true, true, true}
}

// EnsureNotificationSchema creates the preferences table. Idempotent; it is
// not a numbered migration so it cannot collide with concurrent work.
func (s *Server) EnsureNotificationSchema(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS notification_prefs (
			user_id           UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
			place_alerts      BOOLEAN NOT NULL DEFAULT TRUE,
			check_in          BOOLEAN NOT NULL DEFAULT TRUE,
			low_battery       BOOLEAN NOT NULL DEFAULT TRUE,
			completed_drives  BOOLEAN NOT NULL DEFAULT TRUE,
			safety_incidents  BOOLEAN NOT NULL DEFAULT TRUE,
			severe_weather    BOOLEAN NOT NULL DEFAULT TRUE,
			updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	return err
}

func (s *Server) loadNotificationPrefs(ctx context.Context, userID string) (NotificationPrefs, error) {
	p := defaultNotificationPrefs()
	err := s.Pool.QueryRow(ctx, `
		SELECT place_alerts, check_in, low_battery, completed_drives, safety_incidents, severe_weather
		FROM notification_prefs WHERE user_id = $1`, userID).
		Scan(&p.PlaceAlerts, &p.CheckIn, &p.LowBattery, &p.CompletedDrives, &p.SafetyIncidents, &p.SevereWeather)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return defaultNotificationPrefs(), nil
		}
		return p, err
	}
	return p, nil
}

// GetNotificationPrefs returns the caller's notification choices.
func (s *Server) GetNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	p, err := s.loadNotificationPrefs(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load notification settings")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// PutNotificationPrefs updates the caller's choices. Omitted fields keep
// their current value, so the app can send only what changed.
func (s *Server) PutNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var in struct {
		PlaceAlerts     *bool `json:"place_alerts"`
		CheckIn         *bool `json:"check_in"`
		LowBattery      *bool `json:"low_battery"`
		CompletedDrives *bool `json:"completed_drives"`
		SafetyIncidents *bool `json:"safety_incidents"`
		SevereWeather   *bool `json:"severe_weather"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	p, err := s.loadNotificationPrefs(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load notification settings")
		return
	}
	apply := func(dst *bool, v *bool) {
		if v != nil {
			*dst = *v
		}
	}
	apply(&p.PlaceAlerts, in.PlaceAlerts)
	apply(&p.CheckIn, in.CheckIn)
	apply(&p.LowBattery, in.LowBattery)
	apply(&p.CompletedDrives, in.CompletedDrives)
	apply(&p.SafetyIncidents, in.SafetyIncidents)
	apply(&p.SevereWeather, in.SevereWeather)
	_, err = s.Pool.Exec(r.Context(), `
		INSERT INTO notification_prefs
			(user_id, place_alerts, check_in, low_battery, completed_drives, safety_incidents, severe_weather, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7, now())
		ON CONFLICT (user_id) DO UPDATE SET
			place_alerts = EXCLUDED.place_alerts, check_in = EXCLUDED.check_in,
			low_battery = EXCLUDED.low_battery, completed_drives = EXCLUDED.completed_drives,
			safety_incidents = EXCLUDED.safety_incidents, severe_weather = EXCLUDED.severe_weather,
			updated_at = now()`,
		claims.UserID, p.PlaceAlerts, p.CheckIn, p.LowBattery, p.CompletedDrives, p.SafetyIncidents, p.SevereWeather)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save notification settings")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// usersMuted returns the users who switched [category] off. It fails open: on
// any error (or an unknown category) nobody is muted, so a database problem
// can never silence a safety notification.
func (s *Server) usersMuted(ctx context.Context, category string) map[string]bool {
	muted := map[string]bool{}
	known := false
	for _, c := range notificationCategories {
		if c == category {
			known = true
		}
	}
	if !known { // category is interpolated below: only allow the fixed list
		return muted
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM notification_prefs WHERE `+category+` = FALSE`)
	if err != nil {
		slog.Warn("notification prefs: load muted users", "category", category, "err", err)
		return muted
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			muted[id] = true
		}
	}
	return muted
}
