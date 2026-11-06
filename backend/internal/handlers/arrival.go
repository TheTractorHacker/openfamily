package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Missed-arrival alerts ("usually home by 4, not yet").
//
// MINIMAL, CONSERVATIVE VERSION. What it does and does not do:
//   - Strictly opt-in: a person switches it on for themselves, per saved place
//     (PUT /me/arrival-watch). Nobody can enable it for someone else.
//   - Only for circles whose positions the server can read (plain circles, or
//     Private circles in trusted-server mode). Private circles without a
//     server member are never evaluated: the server has no positions there, and
//     the API refuses to create a watch for them.
//   - Learns from geofence enter events at that place over the last
//     arrivalHistoryDays days. It needs at least arrivalMinArrivals arrivals on
//     the same kind of day (weekday vs weekend, in the person's own time zone),
//     arrivals on at least arrivalMinShare of those days, and a tight spread
//     (median absolute deviation under arrivalMaxMAD). The alert time is the
//     median arrival plus arrivalGrace.
//   - Hard limits: one alert per person/place/day (arrival_alert_log primary
//     key), at most arrivalMaxPerUserDay per person per day, arrivalMaxPerRun
//     per pass, and never more than arrivalWindow after the deadline.
//   - Not sent when the phone itself has been silent for arrivalFreshness (we
//     cannot tell "late" from "offline"; the silent-phone alert covers that),
//     when the person is inside the place, has already arrived today, or has
//     paused sharing.
//   - Recipients are people who can see the person, minus anyone who muted
//     them, turned arrivals or place alerts off, or is in quiet hours; names
//     follow show_names.
//
// Not done: holidays/one-off schedule changes (the median adapts after a few
// days), per-place custom thresholds, and snooze (turn the watch off).

const (
	arrivalTick           = 10 * time.Minute
	arrivalHistoryDays    = 42
	arrivalMinArrivals    = 5
	arrivalMinShare       = 0.6
	arrivalMaxMAD         = 30 // minutes
	arrivalGrace          = 60 // minutes after the median
	arrivalWindow         = 3 * time.Hour
	arrivalFreshness      = 2 * time.Hour
	arrivalMaxPerUserDay  = 2
	arrivalMaxPerRun      = 20
	arrivalMaxWatchPerUsr = 10
)

func isWeekend(t time.Time) bool { return t.Weekday() == time.Saturday || t.Weekday() == time.Sunday }

// arrivalDeadline learns the local time-of-day (minutes after midnight) by which
// this person usually arrives, from enter-event timestamps. ok is false when the
// history is not strong enough to alert on.
func arrivalDeadline(enters []time.Time, loc *time.Location, now time.Time) (minutes int, ok bool) {
	today := now.In(loc)
	wantWeekend := isWeekend(today)
	todayDate := time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, loc)

	first := map[string]int{} // local date -> earliest arrival minute
	for _, e := range enters {
		l := e.In(loc)
		if l.Before(todayDate.AddDate(0, 0, -arrivalHistoryDays)) || !l.Before(todayDate) {
			continue // outside the window, or today (not history)
		}
		if isWeekend(l) != wantWeekend {
			continue
		}
		key := l.Format("2006-01-02")
		m := l.Hour()*60 + l.Minute()
		if cur, seen := first[key]; !seen || m < cur {
			first[key] = m
		}
	}
	classDays := 0
	for i := 1; i <= arrivalHistoryDays; i++ {
		d := todayDate.AddDate(0, 0, -i)
		if isWeekend(d) == wantWeekend {
			classDays++
		}
	}
	if len(first) < arrivalMinArrivals || classDays == 0 || float64(len(first))/float64(classDays) < arrivalMinShare {
		return 0, false
	}
	mins := make([]int, 0, len(first))
	for _, m := range first {
		mins = append(mins, m)
	}
	sort.Ints(mins)
	med := median(mins)
	dev := make([]int, len(mins))
	for i, m := range mins {
		d := m - med
		if d < 0 {
			d = -d
		}
		dev[i] = d
	}
	sort.Ints(dev)
	if median(dev) > arrivalMaxMAD {
		return 0, false
	}
	return med + arrivalGrace, true
}

func median(sorted []int) int {
	n := len(sorted)
	if n%2 == 1 {
		return sorted[n/2]
	}
	return (sorted[n/2-1] + sorted[n/2]) / 2
}

// arrivalOverdue is the full decision for one person/place at now.
func arrivalOverdue(enters []time.Time, loc *time.Location, now time.Time, arrivedToday bool) bool {
	if arrivedToday {
		return false
	}
	deadline, ok := arrivalDeadline(enters, loc, now)
	if !ok {
		return false
	}
	l := now.In(loc)
	nowMin := l.Hour()*60 + l.Minute()
	if nowMin < deadline {
		return false
	}
	return time.Duration(nowMin-deadline)*time.Minute <= arrivalWindow && deadline < 24*60
}

// arrivalPlaceReadable reports whether the place's circle exposes positions to
// the server. Places of a Private circle without a server member do not.
const arrivalReadableSQL = `(c.e2ee_mode = 'off' OR e2ee_server_member(c.id))`

type arrivalWatchOut struct {
	PlaceID   string `json:"place_id"`
	PlaceName string `json:"place_name"`
	TZ        string `json:"tz"`
}

// GetArrivalWatch is GET /me/arrival-watch: the caller's own watches and the
// places they could watch.
func (s *Server) GetArrivalWatch(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	watches := []arrivalWatchOut{}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT w.place_id::text, p.name, w.tz FROM arrival_watch w JOIN places p ON p.id = w.place_id
		WHERE w.user_id = $1 ORDER BY p.name`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load")
		return
	}
	for rows.Next() {
		var o arrivalWatchOut
		if rows.Scan(&o.PlaceID, &o.PlaceName, &o.TZ) == nil {
			watches = append(watches, o)
		}
	}
	rows.Close()
	places := []map[string]string{}
	prow, err := s.Pool.Query(r.Context(), `
		SELECT DISTINCT p.id::text, p.name
		FROM places p
		JOIN circles c ON c.id = COALESCE(p.circle_id, p.family_id)
		JOIN live_circle_members m ON m.circle_id = c.id AND m.user_id = $1
		WHERE `+arrivalReadableSQL+` ORDER BY p.name LIMIT 100`, claims.UserID)
	if err == nil {
		for prow.Next() {
			var id, name string
			if prow.Scan(&id, &name) == nil {
				places = append(places, map[string]string{"place_id": id, "place_name": name})
			}
		}
		prow.Close()
	}
	writeJSON(w, http.StatusOK, map[string]any{"watches": watches, "places": places})
}

// PutArrivalWatch is PUT /me/arrival-watch {"place_id","enabled","tz"}.
func (s *Server) PutArrivalWatch(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var in struct {
		PlaceID string `json:"place_id"`
		Enabled bool   `json:"enabled"`
		TZ      string `json:"tz"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.PlaceID == "" {
		writeError(w, http.StatusBadRequest, "place_id is required")
		return
	}
	if in.TZ == "" {
		in.TZ = "UTC"
	}
	if _, err := resolveNotifLocation(in.TZ); err != nil || len(in.TZ) > 64 {
		writeError(w, http.StatusBadRequest, "invalid timezone")
		return
	}
	if !in.Enabled {
		if _, err := s.Pool.Exec(r.Context(), `DELETE FROM arrival_watch WHERE user_id = $1 AND place_id::text = $2`, claims.UserID, in.PlaceID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"enabled": false})
		return
	}
	var ok bool
	err := s.Pool.QueryRow(r.Context(), `
		SELECT EXISTS (
			SELECT 1 FROM places p
			JOIN circles c ON c.id = COALESCE(p.circle_id, p.family_id)
			JOIN live_circle_members m ON m.circle_id = c.id AND m.user_id = $1
			WHERE p.id::text = $2 AND `+arrivalReadableSQL+`)`, claims.UserID, in.PlaceID).Scan(&ok)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "place not found")
		return
	}
	var n int
	_ = s.Pool.QueryRow(r.Context(), `SELECT count(*) FROM arrival_watch WHERE user_id = $1 AND place_id::text <> $2`, claims.UserID, in.PlaceID).Scan(&n)
	if n >= arrivalMaxWatchPerUsr {
		writeError(w, http.StatusBadRequest, "too many watched places")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		INSERT INTO arrival_watch (user_id, place_id, tz) VALUES ($1, $2::uuid, $3)
		ON CONFLICT (user_id, place_id) DO UPDATE SET tz = EXCLUDED.tz`, claims.UserID, in.PlaceID, in.TZ); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": true})
}

// ---- job ------------------------------------------------------------------

// RunArrivalWatch blocks until ctx is cancelled.
func (s *Server) RunArrivalWatch(ctx context.Context) {
	t := time.NewTicker(arrivalTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := s.RunArrivalOnce(ctx, time.Now()); err != nil {
				slog.Warn("arrival watch", "err", err)
			} else if n > 0 {
				slog.Info("arrival watch", "sent", n)
			}
		}
	}
}

// sendArrival delivers a missed-arrival notification; tests replace it.
func (s *Server) sendArrival(ctx context.Context, userIDs []string, render pushRender) {
	if s.Push == nil {
		return
	}
	s.pushUsersRender(ctx, userIDs, render)
}

// RunArrivalOnce evaluates every watch at now and returns how many alerts it sent.
func (s *Server) RunArrivalOnce(ctx context.Context, now time.Time) (int, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT w.user_id::text, u.name, w.place_id::text, p.name, w.tz, COALESCE(p.circle_id, p.family_id)::text,
		       GREATEST(COALESCE(rs.last_report_at, 'epoch'), COALESCE((SELECT max(d.last_seen) FROM devices d WHERE d.user_id = u.id), 'epoch'))
		FROM arrival_watch w
		JOIN users u ON u.id = w.user_id
		JOIN places p ON p.id = w.place_id
		JOIN circles c ON c.id = COALESCE(p.circle_id, p.family_id)
		JOIN live_circle_members m ON m.circle_id = c.id AND m.user_id = u.id AND m.sharing_enabled
		LEFT JOIN member_report_state rs ON rs.user_id = u.id
		WHERE `+arrivalReadableSQL+` AND c.ended_at IS NULL AND NOT `+pausedExprSQL("u.id")+`
		ORDER BY w.user_id, w.place_id`)
	if err != nil {
		return 0, err
	}
	type watch struct {
		user, name, place, placeName, tz, circle string
		last                                     time.Time
	}
	var ws []watch
	for rows.Next() {
		var w watch
		if rows.Scan(&w.user, &w.name, &w.place, &w.placeName, &w.tz, &w.circle, &w.last) == nil {
			ws = append(ws, w)
		}
	}
	rows.Close()
	sent := 0
	for _, w := range ws {
		if sent >= arrivalMaxPerRun {
			break
		}
		if now.Sub(w.last) > arrivalFreshness {
			continue
		}
		loc, err := resolveNotifLocation(w.tz)
		if err != nil {
			loc = time.UTC
		}
		local := now.In(loc)
		dayStart := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
		er, err := s.Pool.Query(ctx, `
			SELECT ts FROM geofence_events
			WHERE user_id = $1 AND place_id = $2::uuid AND event_type = 'enter' AND ts >= $3 AND ts <= $4 ORDER BY ts`,
			w.user, w.place, dayStart.AddDate(0, 0, -arrivalHistoryDays), now)
		if err != nil {
			continue
		}
		var enters []time.Time
		for er.Next() {
			var t time.Time
			if er.Scan(&t) == nil {
				enters = append(enters, t)
			}
		}
		er.Close()
		arrivedToday := false
		for _, e := range enters {
			if !e.Before(dayStart) {
				arrivedToday = true
			}
		}
		// Inside right now (latest event for the place is an enter) also counts.
		var inside bool
		_ = s.Pool.QueryRow(ctx, `
			SELECT COALESCE((SELECT event_type = 'enter' FROM geofence_events
			                 WHERE user_id = $1 AND place_id = $2::uuid ORDER BY ts DESC LIMIT 1), FALSE)`, w.user, w.place).Scan(&inside)
		if inside || !arrivalOverdue(enters, loc, now, arrivedToday) {
			continue
		}
		if s.alertArrival(ctx, w.user, w.name, w.place, w.placeName, w.circle, dayStart, now) {
			sent++
		}
	}
	return sent, nil
}

func (s *Server) alertArrival(ctx context.Context, user, name, place, placeName, circle string, day, now time.Time) bool {
	var today int
	_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM arrival_alert_log WHERE user_id = $1 AND alerted_at >= $2`, user, now.Add(-24*time.Hour)).Scan(&today)
	if today >= arrivalMaxPerUserDay {
		return false
	}
	// Recipients: members of the place's circle who may hear about this person.
	only, err := s.sharingRecipients(ctx, user)
	if err != nil {
		return false
	}
	inCircle := map[string]bool{}
	if r, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1`, circle); err == nil {
		for r.Next() {
			var id string
			if r.Scan(&id) == nil {
				inCircle[id] = true
			}
		}
		r.Close()
	}
	for id := range only {
		if !inCircle[id] {
			delete(only, id)
		}
	}
	for id := range placeAlertSuppressed(ctx, s.Pool, user, place, "enter", now) {
		delete(only, id)
	}
	for id := range s.usersMuted(ctx, "place_alerts") {
		delete(only, id)
	}
	if len(only) == 0 {
		return false
	}
	tag, err := s.Pool.Exec(ctx, `
		INSERT INTO arrival_alert_log (user_id, place_id, day, alerted_at) VALUES ($1, $2::uuid, $3::date, $4) ON CONFLICT DO NOTHING`,
		user, place, day.Format("2006-01-02"), now)
	if err != nil || tag.RowsAffected() != 1 {
		return false
	}
	ids := make([]string, 0, len(only))
	for id := range only {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	s.sendArrival(ctx, ids, func(rc pushRecipient) (string, string) {
		who := nameIf(rc.Show, name)
		return who + " hasn't arrived yet", fmt.Sprintf("%s usually arrives at %s about now.", who, placeName)
	})
	return true
}
