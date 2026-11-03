package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Weekly family driving summary.
//
//   - A background loop checks every few minutes. The job is due once the
//     family's week (Monday 00:00 UTC) has reached Sunday 18:00 UTC; no
//     per-family timezone setting exists, so UTC is used. The summarised window
//     is [Monday 00:00, Sunday 18:00) UTC.
//   - The (family, week) primary key in weekly_summaries makes it idempotent:
//     only the run that inserts the row sends the push. A summary found more
//     than weeklyMaxLate after its due time (server was down) is stored but not
//     pushed.
//   - The push respects the recipient's notification_prefs.weekly_summary
//     switch and member_notification_prefs (muted / driving off / quiet hours
//     per subject): a muted member is left out of that viewer's summary. It only
//     covers members who share their location with the viewer.
//   - GET /trips/weekly-summary serves the app screen (this week vs last week).
//
// Safety score (0-100, the app has none): events = hard brakes + rapid
// accelerations + speeding + phone use; rate = events per 100 km driven (the
// distance is floored at 10 km so one short drive cannot zero the score);
// score = round(100 - 5*rate), clamped to 0..100. No drives = no score.

const (
	weeklyTick      = 10 * time.Minute
	weeklyDueOffset = 6*24*time.Hour + 18*time.Hour // Monday 00:00 + this = Sunday 18:00
	weeklyMaxLate   = 24 * time.Hour
	weeklyRouteKey  = "weekly_summary"
)

// weekStat is one member's driving in one window.
type weekStat struct {
	Drives      int         `json:"drives"`
	DistanceM   float64     `json:"distance_m"`
	DurationS   float64     `json:"duration_s"`
	TopSpeedMps float64     `json:"top_speed_mps"`
	Events      eventCounts `json:"events"`
	Score       *int        `json:"safety_score"`
}

type weekMember struct {
	UserID   string   `json:"user_id"`
	Name     string   `json:"name"`
	Current  weekStat `json:"current"`
	Previous weekStat `json:"previous"`

	phoneUse bool
}

// weeklySafetyScore implements the documented formula. nil when nothing was driven.
func weeklySafetyScore(drives int, distanceM float64, ev eventCounts) *int {
	if drives <= 0 {
		return nil
	}
	n := ev.HardBrake + ev.RapidAccel + ev.Speeding + ev.phone
	km := math.Max(distanceM/1000, 10)
	score := int(math.Round(100 - 5*float64(n)/km*100))
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}
	return &score
}

// weeklyDue returns the Monday 00:00 UTC start of the week whose Sunday-18:00 due
// time most recently passed (or is now), and that due time.
func weeklyDue(now time.Time) (weekStart, due time.Time) {
	now = now.UTC()
	d := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	mon := d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
	if now.Before(mon.Add(weeklyDueOffset)) {
		mon = mon.AddDate(0, 0, -7)
	}
	return mon, mon.Add(weeklyDueOffset)
}

// weekStats computes stats for the given users in [from, to).
func (s *Server) weekStats(ctx context.Context, ids []string, from, to time.Time) (map[string]*weekStat, error) {
	out := map[string]*weekStat{}
	for _, id := range ids {
		out[id] = &weekStat{}
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT user_id::text, count(*), COALESCE(sum(distance_m),0),
		       COALESCE(sum(EXTRACT(EPOCH FROM (ended_at - started_at))),0), COALESCE(max(max_speed_mps),0)
		FROM trips
		WHERE user_id = ANY($1::uuid[]) AND mode = 'driving' AND started_at >= $2 AND started_at < $3
		GROUP BY 1`, ids, from, to)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var uid string
		var st weekStat
		if err := rows.Scan(&uid, &st.Drives, &st.DistanceM, &st.DurationS, &st.TopSpeedMps); err == nil && out[uid] != nil {
			*out[uid] = st
		}
	}
	rows.Close()
	ev, err := s.Pool.Query(ctx, `
		SELECT user_id::text, kind, count(*)
		FROM trip_events_effective
		WHERE user_id = ANY($1::uuid[]) AND started_at >= $2 AND started_at < $3
		GROUP BY 1, 2`, ids, from, to)
	if err != nil {
		return nil, err
	}
	for ev.Next() {
		var uid, kind string
		var n int
		if err := ev.Scan(&uid, &kind, &n); err == nil && out[uid] != nil {
			out[uid].Events.add(kind, n)
		}
	}
	ev.Close()
	return out, nil
}

// finish applies the phone-use opt-in and the score once all events are in.
func (st *weekStat) finish(phoneUse bool) {
	st.Score = weeklySafetyScore(st.Drives, st.DistanceM, st.Events)
	st.Events.finalizePhoneUse(phoneUse)
}

// ---- push text ----

type weeklyTotals struct {
	Drives    int
	DistanceM float64
	// Worst is the member with the most hard brakes (ties: first by name).
	WorstName  string
	WorstKinds int
}

// weeklyPushText builds "Your family's week: 5 drives, 212 mi, Sam had 3 hard
// brakes". ok is false when nobody drove. nameOf maps a member name to what the
// push may reveal (the first name, or "A family member" without VERBOSE_PUSH).
func weeklyPushText(members []weekMember, nameOf func(string) string) (title, body string, ok bool) {
	var drives int
	var dist float64
	worst, worstN := "", 0
	ms := append([]weekMember(nil), members...)
	sort.Slice(ms, func(i, j int) bool { return ms[i].Name < ms[j].Name })
	for _, m := range ms {
		drives += m.Current.Drives
		dist += m.Current.DistanceM
		if n := m.Current.Events.HardBrake; n > worstN {
			worst, worstN = m.Name, n
		}
	}
	if drives == 0 {
		return "", "", false
	}
	plural := func(n int, one, many string) string {
		if n == 1 {
			return fmt.Sprintf("%d %s", n, one)
		}
		return fmt.Sprintf("%d %s", n, many)
	}
	body = fmt.Sprintf("%s, %.0f mi", plural(drives, "drive", "drives"), dist/1609.344)
	if worstN > 0 {
		body += fmt.Sprintf(", %s had %s", nameOf(worst), plural(worstN, "hard brake", "hard brakes"))
	}
	return "Your family's week", "Your family's week: " + body, true
}

// ---- job ----

// RunWeeklySummary blocks until ctx is cancelled.
func (s *Server) RunWeeklySummary(ctx context.Context) {
	t := time.NewTicker(weeklyTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := s.RunWeeklySummaryOnce(ctx, time.Now()); err != nil {
				slog.Warn("weekly summary", "err", err)
			} else if n > 0 {
				slog.Info("weekly summary", "families", n)
			}
		}
	}
}

// RunWeeklySummaryOnce summarises the most recently due week for every family
// that has no summary for it yet. It returns how many summaries it stored.
// Safe to call repeatedly and concurrently.
func (s *Server) RunWeeklySummaryOnce(ctx context.Context, now time.Time) (int, error) {
	week, due := weeklyDue(now)
	if now.Before(due) {
		return 0, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT f.id::text FROM families f
		WHERE NOT EXISTS (SELECT 1 FROM weekly_summaries w WHERE w.family_id = f.id AND w.week_start = $1::date)`, week)
	if err != nil {
		return 0, err
	}
	var fams []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			fams = append(fams, id)
		}
	}
	rows.Close()
	stored := 0
	for _, fam := range fams {
		ok, err := s.summariseFamilyWeek(ctx, fam, week, due, now.Sub(due) <= weeklyMaxLate)
		if err != nil {
			slog.Warn("weekly summary: family", "family", fam, "err", err)
			continue
		}
		if ok {
			stored++
		}
	}
	return stored, nil
}

func (s *Server) familyWeekMembers(ctx context.Context, fam string, from, to time.Time) ([]weekMember, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT id::text, name, (driving_sensor_enabled AND driving_phone_use_enabled)
		FROM users WHERE family_id = $1 ORDER BY name, id`, fam)
	if err != nil {
		return nil, err
	}
	var ms []weekMember
	var ids []string
	for rows.Next() {
		var m weekMember
		if rows.Scan(&m.UserID, &m.Name, &m.phoneUse) == nil {
			ms = append(ms, m)
			ids = append(ids, m.UserID)
		}
	}
	rows.Close()
	stats, err := s.weekStats(ctx, ids, from, to)
	if err != nil {
		return nil, err
	}
	for i := range ms {
		ms[i].Current = *stats[ms[i].UserID]
		ms[i].Current.finish(ms[i].phoneUse)
	}
	return ms, nil
}

// summariseFamilyWeek stores the family's summary and, when claimed by this
// call and notify is set, pushes it. It reports whether this call stored the row.
func (s *Server) summariseFamilyWeek(ctx context.Context, fam string, week, due time.Time, notify bool) (bool, error) {
	ms, err := s.familyWeekMembers(ctx, fam, week, due)
	if err != nil {
		return false, err
	}
	data, err := json.Marshal(map[string]any{"members": ms})
	if err != nil {
		return false, err
	}
	tag, err := s.Pool.Exec(ctx, `
		INSERT INTO weekly_summaries (family_id, week_start, period_start, period_end, data)
		VALUES ($1, $2::date, $3, $4, $5) ON CONFLICT DO NOTHING`, fam, week, week, due, data)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() != 1 {
		return false, nil // another run got there first
	}
	if notify && s.Push != nil {
		s.pushWeeklySummary(ctx, fam, ms)
		_, _ = s.Pool.Exec(ctx, `UPDATE weekly_summaries SET notified_at = now() WHERE family_id = $1 AND week_start = $2::date`, fam, week)
	}
	return true, nil
}

// pushWeeklySummary sends each family member the summary of the members they
// may hear about.
func (s *Server) pushWeeklySummary(ctx context.Context, fam string, ms []weekMember) {
	// viewer -> subjects they may see (subject shares with them, not paused).
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT v.user_id::text, sub.user_id::text
		FROM circle_members sub
		JOIN circle_members v ON v.circle_id = sub.circle_id
		JOIN users vu ON vu.id = v.user_id AND vu.family_id = $1
		JOIN users su ON su.id = sub.user_id AND su.family_id = $1
		WHERE sub.sharing_enabled AND NOT `+pausedExprSQL("sub.user_id"), fam)
	if err != nil {
		slog.Warn("weekly summary: visibility", "err", err)
		return
	}
	visible := map[string]map[string]bool{}
	for rows.Next() {
		var v, sub string
		if rows.Scan(&v, &sub) == nil {
			if visible[v] == nil {
				visible[v] = map[string]bool{}
			}
			visible[v][sub] = true
		}
	}
	rows.Close()
	byID := map[string]weekMember{}
	for _, m := range ms {
		byID[m.UserID] = m
	}
	now := time.Now()
	// Per-member prefs: viewers who muted a subject (or are in quiet hours for it).
	hidden := map[string]map[string]bool{} // viewer -> subject
	for _, m := range ms {
		for v := range notifSuppressed(ctx, s.Pool, m.UserID, notifDriving, now) {
			if hidden[v] == nil {
				hidden[v] = map[string]bool{}
			}
			hidden[v][m.UserID] = true
		}
	}
	viewers := make([]string, 0, len(visible))
	for v := range visible {
		viewers = append(viewers, v)
	}
	sort.Strings(viewers)
	pctx := withPushRoute(ctx, weeklyRouteKey)
	for _, v := range viewers {
		var sel []weekMember
		for sub := range visible[v] {
			if m, ok := byID[sub]; ok && !hidden[v][sub] {
				sel = append(sel, m)
			}
		}
		_, body, ok := weeklyPushText(sel, s.pushName)
		if !ok {
			continue
		}
		s.pushFamilyAlertOnly(pctx, fam, weatherZeroUser, "", "Your family's week", body, "weekly_summary", map[string]bool{v: true})
	}
}

// ---- endpoint ----

// WeeklySummary is GET /trips/weekly-summary?utc_offset_minutes=&circle_id=:
// this week (so far) against last week, per visible member.
func (s *Server) WeeklySummary(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	q := r.URL.Query()
	offset := 0
	if v := q.Get("utc_offset_minutes"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < -14*60 || n > 14*60 {
			writeError(w, http.StatusBadRequest, "utc_offset_minutes must be between -840 and 840")
			return
		}
		offset = n
	}
	now := time.Now()
	per, _ := computeReportPeriod("week", "", now, offset)

	az := circles.New(s.Pool)
	circleID := q.Get("circle_id")
	if circleID == "" {
		fam, err := s.familyIDForUser(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load circle")
			return
		}
		if fam == "" {
			writeError(w, http.StatusNotFound, "circle not found")
			return
		}
		circleID = fam
	}
	if _, err := az.RequireMember(r.Context(), claims.UserID, circleID); err != nil {
		circleAuthError(w, err)
		return
	}
	vis, err := az.LocationVisibility(r.Context(), claims.UserID, []string{circleID})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	ids := []string{}
	for id, ok := range vis {
		if ok {
			ids = append(ids, id)
		}
	}
	nameRows, err := s.Pool.Query(r.Context(), `
		SELECT id::text, name, (driving_sensor_enabled AND driving_phone_use_enabled)
		FROM users WHERE id = ANY($1::uuid[]) ORDER BY name, id`, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	var ms []weekMember
	for nameRows.Next() {
		var m weekMember
		if nameRows.Scan(&m.UserID, &m.Name, &m.phoneUse) == nil {
			ms = append(ms, m)
		}
	}
	nameRows.Close()
	cur, err := s.weekStats(r.Context(), ids, per.start, per.end)
	if err == nil {
		var prev map[string]*weekStat
		prev, err = s.weekStats(r.Context(), ids, per.prevStart, per.prevEnd)
		for i := range ms {
			if err != nil {
				break
			}
			ms[i].Current, ms[i].Previous = *cur[ms[i].UserID], *prev[ms[i].UserID]
			ms[i].Current.finish(ms[i].phoneUse)
			ms[i].Previous.finish(ms[i].phoneUse)
		}
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load trips")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"week_start": per.startDay, "prev_week_start": per.prevStartDay,
		"members": ms, "estimated": true,
	})
}
