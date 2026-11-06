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
	"completed_drives", "safety_incidents", "severe_weather", "weekly_summary", "phone_silent",
}

// NotificationPrefs is the wire shape of GET/PUT /me/notifications.
type NotificationPrefs struct {
	PlaceAlerts     bool `json:"place_alerts"`
	CheckIn         bool `json:"check_in"`
	LowBattery      bool `json:"low_battery"`
	CompletedDrives bool `json:"completed_drives"`
	SafetyIncidents bool `json:"safety_incidents"`
	SevereWeather   bool `json:"severe_weather"`
	WeeklySummary   bool `json:"weekly_summary"`
	// PhoneSilent is the switch for "a phone went silent" alerts (silence.go).
	PhoneSilent bool `json:"phone_silent"`
	// ShowNames puts first names (and check-in notes) in pushes sent to this
	// person. Off by default: the push provider then never learns who.
	ShowNames bool `json:"show_names"`
	// Units is "imperial" or "metric" for server-written text; "" means the
	// person has not chosen and the instance default applies.
	Units string `json:"units"`
}

func defaultNotificationPrefs() NotificationPrefs {
	return NotificationPrefs{PlaceAlerts: true, CheckIn: true, LowBattery: true, CompletedDrives: true,
		SafetyIncidents: true, SevereWeather: true, WeeklySummary: true, PhoneSilent: true}
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
	if err != nil {
		return err
	}
	// Added later than the table itself (weekly driving summary opt-out).
	if _, err = s.Pool.Exec(ctx, `ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS weekly_summary BOOLEAN NOT NULL DEFAULT TRUE`); err != nil {
		return err
	}
	// Per-recipient opt-in for names in pushes, and the distance/speed unit.
	if _, err = s.Pool.Exec(ctx, `ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS show_names BOOLEAN NOT NULL DEFAULT FALSE`); err != nil {
		return err
	}
	if _, err = s.Pool.Exec(ctx, `ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS units TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	// "Your phone went silent" / "a family member's phone went silent" alerts.
	_, err = s.Pool.Exec(ctx, `ALTER TABLE notification_prefs ADD COLUMN IF NOT EXISTS phone_silent BOOLEAN NOT NULL DEFAULT TRUE`)
	return err
}

// validUnits reports whether v is an accepted unit system ("" = unset).
func validUnits(v string) bool { return v == "" || v == "imperial" || v == "metric" }

// pushRecipient is what the copy for one recipient may reveal and how it
// should be written for them.
type pushRecipient struct {
	// Show is true when names and notes may appear (the recipient opted in, or
	// VERBOSE_PUSH is on server-wide).
	Show bool
	// Units is "imperial" or "metric".
	Units string
}

// pushRender builds the title and body for one recipient.
type pushRender func(rc pushRecipient) (title, body string)

func fixedRender(title, body string) pushRender {
	return func(pushRecipient) (string, string) { return title, body }
}

// recipientDirectory resolves per-recipient push settings from one query.
type recipientDirectory struct {
	verbose  bool
	def      string
	showName map[string]bool
	units    map[string]string
}

// recipients loads every person's show_names/units choice. It fails closed for
// names (nobody opted in) and open for units (instance default).
func (s *Server) recipients(ctx context.Context) *recipientDirectory {
	d := &recipientDirectory{verbose: s.VerbosePush, def: s.defaultUnits(ctx),
		showName: map[string]bool{}, units: map[string]string{}}
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text, show_names, units FROM notification_prefs WHERE show_names OR units <> ''`)
	if err != nil {
		slog.Warn("notification prefs: load recipients", "err", err)
		return d
	}
	defer rows.Close()
	for rows.Next() {
		var id, u string
		var show bool
		if rows.Scan(&id, &show, &u) == nil {
			d.showName[id] = show
			if u == "imperial" || u == "metric" {
				d.units[id] = u
			}
		}
	}
	return d
}

// For returns the settings for one recipient.
func (d *recipientDirectory) For(uid string) pushRecipient {
	u := d.def
	if v, ok := d.units[uid]; ok {
		u = v
	}
	return pushRecipient{Show: d.verbose || d.showName[uid], Units: u}
}

// nameIf is the name allowed in a push to a recipient: the first name when
// show is true, "A family member" otherwise.
func nameIf(show bool, fullName string) string {
	if show {
		return firstName(fullName)
	}
	return "A family member"
}

func (s *Server) loadNotificationPrefs(ctx context.Context, userID string) (NotificationPrefs, error) {
	p := defaultNotificationPrefs()
	err := s.Pool.QueryRow(ctx, `
		SELECT place_alerts, check_in, low_battery, completed_drives, safety_incidents, severe_weather, weekly_summary, phone_silent, show_names, units
		FROM notification_prefs WHERE user_id = $1`, userID).
		Scan(&p.PlaceAlerts, &p.CheckIn, &p.LowBattery, &p.CompletedDrives, &p.SafetyIncidents, &p.SevereWeather, &p.WeeklySummary, &p.PhoneSilent, &p.ShowNames, &p.Units)
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
		WeeklySummary   *bool `json:"weekly_summary"`
		PhoneSilent     *bool `json:"phone_silent"`
		ShowNames       *bool `json:"show_names"`
		Units           *string `json:"units"`
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
	apply(&p.WeeklySummary, in.WeeklySummary)
	apply(&p.PhoneSilent, in.PhoneSilent)
	apply(&p.ShowNames, in.ShowNames)
	if in.Units != nil {
		if !validUnits(*in.Units) {
			writeError(w, http.StatusBadRequest, "units must be imperial or metric")
			return
		}
		p.Units = *in.Units
	}
	_, err = s.Pool.Exec(r.Context(), `
		INSERT INTO notification_prefs
			(user_id, place_alerts, check_in, low_battery, completed_drives, safety_incidents, severe_weather, weekly_summary, phone_silent, show_names, units, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, now())
		ON CONFLICT (user_id) DO UPDATE SET
			place_alerts = EXCLUDED.place_alerts, check_in = EXCLUDED.check_in,
			low_battery = EXCLUDED.low_battery, completed_drives = EXCLUDED.completed_drives,
			safety_incidents = EXCLUDED.safety_incidents, severe_weather = EXCLUDED.severe_weather, weekly_summary = EXCLUDED.weekly_summary, phone_silent = EXCLUDED.phone_silent,
			show_names = EXCLUDED.show_names, units = EXCLUDED.units,
			updated_at = now()`,
		claims.UserID, p.PlaceAlerts, p.CheckIn, p.LowBattery, p.CompletedDrives, p.SafetyIncidents, p.SevereWeather, p.WeeklySummary, p.PhoneSilent, p.ShowNames, p.Units)
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
