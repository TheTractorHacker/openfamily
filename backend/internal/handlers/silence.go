package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
)

// "Phone went silent" alerts.
//
// A circle admin switches the feature on per circle and picks the threshold
// (2 to 72 hours; off by default so an upgrade never starts pushing by itself).
// Every tick the server looks for members whose phone has not talked to it for
// at least that long AND who normally report at this hour of the day, and tells
// the circle admins plus the member themselves.
//
// Inputs are timestamps only (member_report_state, devices.last_seen and the
// per-hour activity buckets), never a coordinate, so Private circles work the
// same way as plain ones.
//
// Spam controls, all conservative on purpose:
//   - one alert per silence episode (silence_alert_state; a new episode starts
//     only after the member reports again),
//   - the member must have at least silenceMinDays days of history and have
//     reported in this same UTC hour on at least silenceMinHourDays of the last
//     silenceHistoryDays days ("hours it normally reports"),
//   - nothing after silenceGiveUp of silence (an abandoned phone is not an
//     emergency to re-announce),
//   - if at least half of a circle (and 3+ people) look silent at once it is
//     treated as a server/network outage and nothing is sent,
//   - at most silenceMaxPerCircleRun alerts per circle per run,
//   - recipients in their quiet hours, with the category off, or who muted the
//     member are skipped (and the episode stays unclaimed so it can fire later),
//   - per-member disable and snooze.
// Copy follows show_names: without it the push says "A family member".

const (
	silenceTick           = 10 * time.Minute
	silenceHistoryDays    = 14
	silenceMinDays        = 3
	silenceMinHourDays    = 3
	silenceGiveUp         = 7 * 24 * time.Hour
	silenceMaxPerCircle   = 5
	silenceOutageMinCount = 3
	silenceMaxSnooze      = 14 * 24 * time.Hour
	notifSilent           = "silent"
)

// silenceInput is everything the decision needs; Now is injected so tests use a
// fake clock.
type silenceInput struct {
	Now        time.Time
	LastReport time.Time
	Threshold  time.Duration
	// HourDays[h] is how many distinct days in the history window had a report
	// in UTC hour h; Days is how many distinct days had any report.
	HourDays [24]int
	Days     int
}

// silenceDue reports whether this member's phone counts as silent right now.
func silenceDue(in silenceInput) bool {
	if in.LastReport.IsZero() || in.Threshold <= 0 {
		return false
	}
	quiet := in.Now.Sub(in.LastReport)
	if quiet < in.Threshold || quiet > silenceGiveUp {
		return false
	}
	if in.Days < silenceMinDays {
		return false
	}
	return in.HourDays[in.Now.UTC().Hour()] >= silenceMinHourDays
}

// silenceHoursText renders "about 9 hours" without false precision.
func silenceHoursText(d time.Duration) string {
	h := int(d.Hours() + 0.5)
	if h < 1 {
		h = 1
	}
	if h == 1 {
		return "about 1 hour"
	}
	return fmt.Sprintf("about %d hours", h)
}

type silenceCandidate struct {
	circleID, circleName string
	userID, name         string
	last                 time.Time
	threshold            time.Duration
	hourDays             [24]int
	days                 int
}

// RunSilenceAlerts blocks until ctx is cancelled.
func (s *Server) RunSilenceAlerts(ctx context.Context) {
	t := time.NewTicker(silenceTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := s.RunSilenceOnce(ctx, time.Now())
			if err != nil {
				slog.Warn("silence alerts", "err", err)
			} else if n > 0 {
				slog.Info("silence alerts", "sent", n)
			}
			if _, err := s.Pool.Exec(ctx, `DELETE FROM member_report_hours WHERE hour < now() - interval '28 days'`); err != nil {
				slog.Debug("silence alerts: prune", "err", err)
			}
		}
	}
}

// sendSilence delivers one silence notification; tests replace it.
func (s *Server) sendSilence(ctx context.Context, userIDs []string, route string, render pushRender) {
	if s.Push == nil {
		return
	}
	s.pushUsersRender(withPushRoute(ctx, route), userIDs, render)
}

// RunSilenceOnce evaluates every opted-in circle at now and returns how many
// alerts it claimed. Safe to call repeatedly and concurrently.
func (s *Server) RunSilenceOnce(ctx context.Context, now time.Time) (int, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id::text, c.name, c.silence_alert_hours, u.id::text, u.name,
		       GREATEST(COALESCE(rs.last_report_at, 'epoch'), COALESCE(rs.last_ws_at, 'epoch'),
		       COALESCE((SELECT max(d.last_seen) FROM devices d WHERE d.user_id = u.id), 'epoch'),
		       COALESCE((SELECT max(i.received_at) FROM e2ee_items i JOIN device_keys k ON k.device_id = i.device_id
		                 WHERE k.user_id = u.id AND i.circle_id = c.id), 'epoch'))
		FROM circles c
		JOIN live_circle_members m ON m.circle_id = c.id AND m.sharing_enabled
		JOIN users u ON u.id = m.user_id
		LEFT JOIN member_report_state rs ON rs.user_id = u.id
		LEFT JOIN silence_member_prefs p ON p.circle_id = c.id AND p.user_id = u.id
		WHERE c.silence_alert_hours > 0 AND c.ended_at IS NULL
		  AND NOT `+pausedExprSQL("u.id")+`
		  AND COALESCE(p.disabled, FALSE) = FALSE
		  AND (p.snoozed_until IS NULL OR p.snoozed_until <= $1)
		  AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = u.id)
		ORDER BY c.id, u.id`, now)
	if err != nil {
		return 0, err
	}
	var cands []*silenceCandidate
	userSet := map[string]bool{}
	for rows.Next() {
		var c silenceCandidate
		var hours int
		if err := rows.Scan(&c.circleID, &c.circleName, &hours, &c.userID, &c.name, &c.last); err != nil {
			continue
		}
		c.threshold = time.Duration(hours) * time.Hour
		if c.last.Unix() <= 0 {
			c.last = time.Time{}
		}
		cands = append(cands, &c)
		userSet[c.userID] = true
	}
	rows.Close()
	if len(cands) == 0 {
		return 0, nil
	}
	users := make([]string, 0, len(userSet))
	for u := range userSet {
		users = append(users, u)
	}
	sort.Strings(users)
	hist, err := s.reportHistory(ctx, users, now)
	if err != nil {
		return 0, err
	}
	for _, c := range cands {
		if h := hist[c.userID]; h != nil {
			c.hourDays, c.days = h.hourDays, h.days
		}
	}

	byCircle := map[string][]*silenceCandidate{}
	var order []string
	for _, c := range cands {
		if _, ok := byCircle[c.circleID]; !ok {
			order = append(order, c.circleID)
		}
		byCircle[c.circleID] = append(byCircle[c.circleID], c)
	}
	claimed := 0
	for _, cid := range order {
		group := byCircle[cid]
		var due []*silenceCandidate
		withHistory := 0
		for _, c := range group {
			if c.days >= silenceMinDays {
				withHistory++
			}
			if silenceDue(silenceInput{Now: now, LastReport: c.last, Threshold: c.threshold, HourDays: c.hourDays, Days: c.days}) {
				due = append(due, c)
			}
		}
		if len(due) == 0 {
			continue
		}
		if len(due) >= silenceOutageMinCount && len(due)*2 >= withHistory {
			slog.Warn("silence alerts: many members silent at once, treating as an outage", "circle", cid, "silent", len(due))
			continue
		}
		sent := 0
		for _, c := range due {
			if sent >= silenceMaxPerCircle {
				break
			}
			if s.alertSilence(ctx, c, now) {
				sent++
				claimed++
			}
		}
	}
	return claimed, nil
}

type reportHist struct {
	hourDays [24]int
	days     int
}

// reportHistory loads the per-hour activity histogram for users.
func (s *Server) reportHistory(ctx context.Context, users []string, now time.Time) (map[string]*reportHist, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT user_id::text, EXTRACT(HOUR FROM hour AT TIME ZONE 'UTC')::int, count(DISTINCT (hour AT TIME ZONE 'UTC')::date)
		FROM member_report_hours
		WHERE user_id = ANY($1::uuid[]) AND hour >= $2 AND hour < $3
		GROUP BY 1, 2`, users, now.AddDate(0, 0, -silenceHistoryDays), now)
	if err != nil {
		return nil, err
	}
	out := map[string]*reportHist{}
	for rows.Next() {
		var u string
		var h, n int
		if rows.Scan(&u, &h, &n) == nil && h >= 0 && h < 24 {
			if out[u] == nil {
				out[u] = &reportHist{}
			}
			out[u].hourDays[h] = n
		}
	}
	rows.Close()
	days, err := s.Pool.Query(ctx, `
		SELECT user_id::text, count(DISTINCT (hour AT TIME ZONE 'UTC')::date)
		FROM member_report_hours
		WHERE user_id = ANY($1::uuid[]) AND hour >= $2 AND hour < $3 GROUP BY 1`, users, now.AddDate(0, 0, -silenceHistoryDays), now)
	if err != nil {
		return nil, err
	}
	for days.Next() {
		var u string
		var n int
		if days.Scan(&u, &n) == nil && out[u] != nil {
			out[u].days = n
		}
	}
	days.Close()
	return out, nil
}

// silenceRecipients returns who would be told about c right now: the circle's
// admins (minus the member) and the member, after quiet hours, the recipient's
// category switch and per-member mutes.
func (s *Server) silenceRecipients(ctx context.Context, c *silenceCandidate, now time.Time) (admins []string, self bool) {
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1 AND role = 'admin' AND user_id <> $2`, c.circleID, c.userID)
	if err != nil {
		return nil, false
	}
	cand := map[string]bool{c.userID: true}
	var adminIDs []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			cand[id] = true
			adminIDs = append(adminIDs, id)
		}
	}
	rows.Close()
	skip := map[string]bool{}
	ids := make([]string, 0, len(cand))
	for id := range cand {
		ids = append(ids, id)
	}
	if r, err := s.Pool.Query(ctx, `SELECT user_id::text FROM notification_prefs WHERE user_id = ANY($1::uuid[]) AND NOT phone_silent`, ids); err == nil {
		for r.Next() {
			var id string
			if r.Scan(&id) == nil {
				skip[id] = true
			}
		}
		r.Close()
	}
	if r, err := s.Pool.Query(ctx, `SELECT user_id::text, quiet_start::int, quiet_end::int, tz FROM user_quiet_hours WHERE user_id = ANY($1::uuid[])`, ids); err == nil {
		for r.Next() {
			var id, tz string
			var qs, qe int
			if r.Scan(&id, &qs, &qe, &tz) == nil && inQuietHours(now, tz, qs, qe) {
				skip[id] = true
			}
		}
		r.Close()
	}
	for id := range notifSuppressed(ctx, s.Pool, c.userID, notifSilent, now) {
		skip[id] = true
	}
	sort.Strings(adminIDs)
	for _, id := range adminIDs {
		if !skip[id] {
			admins = append(admins, id)
		}
	}
	return admins, !skip[c.userID]
}

// alertSilence claims the episode and sends. It reports whether it claimed.
func (s *Server) alertSilence(ctx context.Context, c *silenceCandidate, now time.Time) bool {
	admins, self := s.silenceRecipients(ctx, c, now)
	if len(admins) == 0 && !self {
		return false // everyone is in quiet hours or opted out: try again later
	}
	tag, err := s.Pool.Exec(ctx, `
		INSERT INTO silence_alert_state (circle_id, user_id, last_report_at, alerted_at) VALUES ($1, $2, $3, $4)
		ON CONFLICT (circle_id, user_id) DO UPDATE SET last_report_at = EXCLUDED.last_report_at, alerted_at = EXCLUDED.alerted_at
		WHERE silence_alert_state.last_report_at < EXCLUDED.last_report_at`,
		c.circleID, c.userID, c.last, now)
	if err != nil || tag.RowsAffected() != 1 {
		return false // already alerted for this episode (or a concurrent run won)
	}
	text := silenceHoursText(now.Sub(c.last))
	name := c.name
	if len(admins) > 0 {
		s.sendSilence(ctx, admins, "", func(rc pushRecipient) (string, string) {
			who := nameIf(rc.Show, name)
			return "Phone hasn't checked in", fmt.Sprintf("%s's phone hasn't reported for %s.", who, text)
		})
	}
	if self {
		s.sendSilence(ctx, []string{c.userID}, "diagnostics", fixedRender(
			"Orbitly can't reach your phone", "It hasn't reported for "+text+". Tap to find out why."))
	}
	return true
}

// ---- API ------------------------------------------------------------------

type silenceSettings struct {
	Hours        int        `json:"hours"`
	Disabled     bool       `json:"disabled"`
	SnoozedUntil *time.Time `json:"snoozed_until"`
	IsAdmin      bool       `json:"is_admin"`
}

// GetSilenceAlerts is GET /circles/{id}/silence-alerts (any member).
func (s *Server) GetSilenceAlerts(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	out := silenceSettings{IsAdmin: m.Role == circles.RoleAdmin}
	if err := s.Pool.QueryRow(r.Context(), `SELECT silence_alert_hours FROM circles WHERE id = $1`, m.CircleID).Scan(&out.Hours); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load settings")
		return
	}
	_ = s.Pool.QueryRow(r.Context(), `SELECT disabled, snoozed_until FROM silence_member_prefs WHERE circle_id = $1 AND user_id = $2`,
		m.CircleID, uid).Scan(&out.Disabled, &out.SnoozedUntil)
	writeJSON(w, http.StatusOK, out)
}

// PutSilenceAlerts is PUT /circles/{id}/silence-alerts {"hours": 0|2..72}
// (circle admin): turns the alerts on, off, or changes the threshold.
func (s *Server) PutSilenceAlerts(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if _, err := circles.New(s.Pool).RequireAdmin(r.Context(), claims.UserID, chi.URLParam(r, "id")); err != nil {
		circleAuthError(w, err)
		return
	}
	var in struct {
		Hours int `json:"hours"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if in.Hours != 0 && (in.Hours < 2 || in.Hours > 72) {
		writeError(w, http.StatusBadRequest, "hours must be 0 (off) or between 2 and 72")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `UPDATE circles SET silence_alert_hours = $2 WHERE id = $1`, chi.URLParam(r, "id"), in.Hours); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"hours": in.Hours})
}

// PutMySilencePrefs is PUT /circles/{id}/silence-alerts/me
// {"disabled": bool, "snooze_hours": 0..336}: the member opts out of (or
// snoozes) alerts about their own phone. Any member, for themselves only.
func (s *Server) PutMySilencePrefs(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	var in struct {
		Disabled    bool `json:"disabled"`
		SnoozeHours int  `json:"snooze_hours"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if in.SnoozeHours < 0 || time.Duration(in.SnoozeHours)*time.Hour > silenceMaxSnooze {
		writeError(w, http.StatusBadRequest, "snooze_hours must be between 0 and 336")
		return
	}
	var until *time.Time
	if in.SnoozeHours > 0 {
		t := time.Now().Add(time.Duration(in.SnoozeHours) * time.Hour)
		until = &t
	}
	if _, err := s.Pool.Exec(r.Context(), `
		INSERT INTO silence_member_prefs (circle_id, user_id, disabled, snoozed_until) VALUES ($1, $2, $3, $4)
		ON CONFLICT (circle_id, user_id) DO UPDATE SET disabled = EXCLUDED.disabled, snoozed_until = EXCLUDED.snoozed_until`,
		m.CircleID, uid, in.Disabled, until); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	writeJSON(w, http.StatusOK, silenceSettings{Disabled: in.Disabled, SnoozedUntil: until})
}
