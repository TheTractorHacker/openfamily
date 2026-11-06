package handlers

import (
	"net/http"
	"net/http/httptest"
	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"context"
	"strings"
	"testing"
	"time"
)

// ---- pure: silence decision with a fake clock ------------------------------

func fullHistory() (h [24]int) {
	for i := range h {
		h[i] = 5
	}
	return
}

func TestSilenceDue(t *testing.T) {
	now := time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)
	base := silenceInput{Now: now, LastReport: now.Add(-9 * time.Hour), Threshold: 8 * time.Hour, HourDays: fullHistory(), Days: 6}
	if !silenceDue(base) {
		t.Fatal("9h quiet over an 8h threshold with history must be due")
	}
	cases := map[string]func(*silenceInput){
		"under threshold":     func(i *silenceInput) { i.LastReport = now.Add(-7 * time.Hour) },
		"never reported":      func(i *silenceInput) { i.LastReport = time.Time{} },
		"threshold off":       func(i *silenceInput) { i.Threshold = 0 },
		"abandoned for weeks": func(i *silenceInput) { i.LastReport = now.Add(-8 * 24 * time.Hour) },
		"too little history":  func(i *silenceInput) { i.Days = 2 },
		"not a usual hour":    func(i *silenceInput) { i.HourDays[15] = 2 },
	}
	for name, mut := range cases {
		in := base
		mut(&in)
		if silenceDue(in) {
			t.Errorf("%s: must not be due", name)
		}
	}
}

func TestSilenceHoursText(t *testing.T) {
	if got := silenceHoursText(9*time.Hour + 20*time.Minute); got != "about 9 hours" {
		t.Errorf("got %q", got)
	}
	if got := silenceHoursText(10 * time.Minute); got != "about 1 hour" {
		t.Errorf("got %q", got)
	}
}

func TestReportTrackerThrottles(t *testing.T) {
	var tr reportTracker
	t0 := time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)
	if row, hour := tr.due("u", t0); !row || !hour {
		t.Fatal("first report writes both")
	}
	if row, hour := tr.due("u", t0.Add(20*time.Second)); row || hour {
		t.Fatal("within a minute and the same hour: no writes")
	}
	if row, hour := tr.due("u", t0.Add(2*time.Minute)); !row || hour {
		t.Fatal("a minute later: row only")
	}
	if row, hour := tr.due("u", t0.Add(61*time.Minute)); !row || !hour {
		t.Fatal("next hour: both")
	}
}

// ---- pure: missed-arrival learning with a fake clock -----------------------

// weekdayArrivals returns n weekday arrivals at hh:mm UTC ending the day before day.
func weekdayArrivals(day time.Time, n, hh, mm int) []time.Time {
	var out []time.Time
	for d := 1; len(out) < n; d++ {
		x := day.AddDate(0, 0, -d)
		if !isWeekend(x) {
			out = append(out, time.Date(x.Year(), x.Month(), x.Day(), hh, mm, 0, 0, time.UTC))
		}
	}
	return out
}

func TestArrivalDeadlineAndOverdue(t *testing.T) {
	tue := time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC) // a Tuesday
	enters := weekdayArrivals(tue, 20, 16, 0)
	d, ok := arrivalDeadline(enters, time.UTC, tue.Add(17*time.Hour))
	if !ok || d != 17*60 {
		t.Fatalf("deadline = %d %v, want 17:00", d, ok)
	}
	at := func(h, m int) time.Time { return tue.Add(time.Duration(h)*time.Hour + time.Duration(m)*time.Minute) }
	if arrivalOverdue(enters, time.UTC, at(16, 45), false) {
		t.Error("before the grace period ends")
	}
	if !arrivalOverdue(enters, time.UTC, at(17, 5), false) {
		t.Error("17:05 should be overdue")
	}
	if arrivalOverdue(enters, time.UTC, at(17, 5), true) {
		t.Error("already arrived today")
	}
	if arrivalOverdue(enters, time.UTC, at(20, 30), false) {
		t.Error("more than the window after the deadline")
	}
	// A weekend has no weekday history.
	sat := time.Date(2026, 3, 14, 18, 0, 0, 0, time.UTC)
	if arrivalOverdue(enters, time.UTC, sat, false) {
		t.Error("weekend must not use weekday history")
	}
	// Not enough history.
	if _, ok := arrivalDeadline(enters[:4], time.UTC, at(17, 0)); ok {
		t.Error("4 arrivals is too few")
	}
	// Erratic arrivals (spread too wide) never alert.
	var erratic []time.Time
	for i, e := range enters {
		erratic = append(erratic, e.Add(time.Duration((i%2)*5-2)*time.Hour))
	}
	if _, ok := arrivalDeadline(erratic, time.UTC, at(17, 0)); ok {
		t.Error("erratic arrivals must not produce a deadline")
	}
	// Arrivals on few of the days (sparse) do not count.
	if _, ok := arrivalDeadline(enters[:5], time.UTC, at(17, 0)); ok {
		t.Error("5 arrivals in 30 weekdays is under the share threshold")
	}
	// Local time zone: 16:00 at UTC-8 is 00:00 UTC next day.
	la := time.FixedZone("UTC-08:00", -8*3600)
	var laEnters []time.Time
	for _, e := range weekdayArrivals(tue, 20, 16, 0) {
		laEnters = append(laEnters, time.Date(e.Year(), e.Month(), e.Day(), 16, 0, 0, 0, la))
	}
	nowLA := time.Date(2026, 3, 10, 17, 10, 0, 0, la)
	if !arrivalOverdue(laEnters, la, nowLA, false) {
		t.Error("time zone aware decision failed")
	}
}

// ---- DB: silence alerts end to end -----------------------------------------

type captured struct {
	endpoint, title, body, route string
}

func capturedPushes(fx *alertFixture) []captured {
	fx.push.mu.Lock()
	defer fx.push.mu.Unlock()
	var out []captured
	for _, n := range fx.push.sent {
		out = append(out, captured{n.UnifiedPushEndpoint, n.Title, n.Body, n.Route})
	}
	return out
}

func TestSilenceAlertsEndToEnd(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if err := fx.srv.EnsureNotificationSchema(ctx); err != nil {
		t.Fatal(err)
	}
	pool := fx.pool
	exec := func(q string, a ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, a...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	exec(`INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/a')`, fx.a)
	exec(`INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/d')`, fx.d)
	// fx.b already has a device (https://ntfy.example/b); c has none.

	now := time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)
	history := func(user string, days int) {
		exec(`INSERT INTO member_report_hours (user_id, hour)
			SELECT $1::uuid, ($2::timestamptz - make_interval(days => d)) - make_interval(hours => h)
			FROM generate_series(1, $3) d, generate_series(0, 23) h ON CONFLICT DO NOTHING`, user, now, days)
	}
	history(fx.b, 6)
	exec(`INSERT INTO member_report_state (user_id, last_report_at) VALUES ($1, $2)`, fx.b, now.Add(-10*time.Hour))

	run := func(at time.Time) int {
		t.Helper()
		n, err := fx.srv.RunSilenceOnce(ctx, at)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := run(now); n != 0 {
		t.Fatalf("feature is off by default, got %d alerts", n)
	}
	exec(`UPDATE circles SET silence_alert_hours = 8 WHERE id = $1`, fx.f1)

	// Quiet hours for every recipient: nothing sent and the episode stays open.
	for _, u := range []string{fx.a, fx.d, fx.b} {
		exec(`INSERT INTO user_quiet_hours (user_id, quiet_start, quiet_end, tz) VALUES ($1, 0, 1439, 'UTC')
			ON CONFLICT (user_id) DO UPDATE SET quiet_start = 0, quiet_end = 1439`, u)
	}
	if n := run(now); n != 0 {
		t.Fatalf("quiet hours must hold the alert back, got %d", n)
	}
	exec(`DELETE FROM user_quiet_hours WHERE user_id = ANY($1::uuid[])`, []string{fx.a, fx.d, fx.b})

	// Per-member snooze and disable.
	exec(`INSERT INTO silence_member_prefs (circle_id, user_id, snoozed_until) VALUES ($1,$2,$3)`, fx.f1, fx.b, now.Add(time.Hour))
	if n := run(now); n != 0 {
		t.Fatalf("snoozed member alerted: %d", n)
	}
	exec(`UPDATE silence_member_prefs SET snoozed_until = NULL, disabled = TRUE WHERE circle_id = $1 AND user_id = $2`, fx.f1, fx.b)
	if n := run(now); n != 0 {
		t.Fatalf("disabled member alerted: %d", n)
	}
	exec(`DELETE FROM silence_member_prefs WHERE circle_id = $1`, fx.f1)

	// d switches the category off; a keeps it, with names hidden (default).
	exec(`INSERT INTO notification_prefs (user_id, phone_silent) VALUES ($1, FALSE)`, fx.d)
	if n := run(now); n != 1 {
		t.Fatalf("expected one alert, got %d", n)
	}
	got := capturedPushes(fx)
	var toA, toB, toD *captured
	for i := range got {
		switch got[i].endpoint {
		case "https://ntfy.example/a":
			toA = &got[i]
		case "https://ntfy.example/b":
			toB = &got[i]
		case "https://ntfy.example/d":
			toD = &got[i]
		}
	}
	if toD != nil {
		t.Errorf("recipient with phone_silent off was notified: %+v", *toD)
	}
	if toA == nil || !strings.Contains(toA.body, "A family member's phone hasn't reported for about 10 hours") {
		t.Fatalf("admin copy wrong: %+v", toA)
	}
	if toB == nil || toB.route != "diagnostics" || !strings.Contains(toB.body, "about 10 hours") {
		t.Fatalf("member copy wrong: %+v", toB)
	}
	for _, g := range got {
		if strings.ContainsAny(g.body, "0123456789") && !strings.Contains(g.body, "10 hours") {
			t.Errorf("unexpected digits (coordinates?) in %q", g.body)
		}
		if strings.Contains(strings.ToLower(g.body), "lat") || strings.Contains(g.body, "°") {
			t.Errorf("location-like text in %q", g.body)
		}
	}

	// Idempotent: the same episode is never announced twice.
	if n := run(now.Add(30 * time.Minute)); n != 0 {
		t.Fatalf("repeat alert for one episode: %d", n)
	}
	// After the member reports again, a new silence is a new episode.
	exec(`UPDATE member_report_state SET last_report_at = $2 WHERE user_id = $1`, fx.b, now.Add(time.Hour))
	if n := run(now.Add(2 * time.Hour)); n != 0 {
		t.Fatalf("only 1h quiet: %d", n)
	}
	if n := run(now.Add(10 * time.Hour)); n != 1 {
		t.Fatalf("second episode should alert once, got %d", n)
	}

	// Show-names recipient sees the first name.
	exec(`UPDATE circles SET silence_alert_hours = 8 WHERE id = $1`, fx.f1)
	exec(`INSERT INTO notification_prefs (user_id, show_names) VALUES ($1, TRUE) ON CONFLICT (user_id) DO UPDATE SET show_names = TRUE`, fx.a)
	exec(`UPDATE member_report_state SET last_report_at = $2 WHERE user_id = $1`, fx.b, now.Add(11*time.Hour))
	before := len(capturedPushes(fx))
	if n := run(now.Add(21 * time.Hour)); n != 1 {
		t.Fatalf("third episode: %d", n)
	}
	named := false
	for _, g := range capturedPushes(fx)[before:] {
		if g.endpoint == "https://ntfy.example/a" && strings.HasPrefix(g.body, "b's phone") {
			named = true
		}
	}
	if !named {
		t.Errorf("show_names recipient did not get the first name: %+v", capturedPushes(fx)[before:])
	}

	// Many people silent at once looks like an outage: nothing is sent.
	exec(`INSERT INTO devices (user_id, platform) VALUES ($1,'android'), ($2,'android')`, fx.c, fx.a)
	history(fx.c, 6)
	history(fx.a, 6)
	exec(`INSERT INTO member_report_state (user_id, last_report_at) VALUES ($1,$3), ($2,$3)
		ON CONFLICT (user_id) DO UPDATE SET last_report_at = EXCLUDED.last_report_at`, fx.c, fx.a, now.Add(30*time.Hour))
	exec(`UPDATE member_report_state SET last_report_at = $2 WHERE user_id = $1`, fx.b, now.Add(30*time.Hour))
	if n := run(now.Add(45 * time.Hour)); n != 0 {
		t.Fatalf("outage guard should hold back a mass silence, got %d", n)
	}
}

// ---- DB: diagnostics endpoints ----------------------------------------------

func TestDiagnosticsEndpoints(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	var devB, devX string
	if err := fx.pool.QueryRow(ctx, `SELECT id::text FROM devices WHERE user_id = $1`, fx.b).Scan(&devB); err != nil {
		t.Fatal(err)
	}
	if err := fx.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, fx.x).Scan(&devX); err != nil {
		t.Fatal(err)
	}
	h := newDiagRouter(fx)

	code, _ := callJSON(t, h, "PUT", "/devices/"+devB+"/diagnostics", fx.b, map[string]any{
		"os_version": "Android 14 (SDK 34)", "battery_opt": "restricted", "outbox_pending": 7,
		"loc_permission": "while_in_use", "notif_permission": "granted", "bg_service": false, "app_version": "0.19.0"})
	if code != 204 {
		t.Fatalf("own device: %d", code)
	}
	if code, _ = callJSON(t, h, "PUT", "/devices/"+devX+"/diagnostics", fx.b, map[string]any{"battery_opt": "restricted"}); code != 404 {
		t.Fatalf("someone else's device must be 404, got %d", code)
	}
	if code, _ = callJSON(t, h, "PUT", "/devices/"+devB+"/diagnostics", fx.b, map[string]any{"battery_opt": "bogus"}); code != 400 {
		t.Fatalf("bad enum: %d", code)
	}
	if code, _ = callJSON(t, h, "PUT", "/devices/"+devB+"/diagnostics", fx.b, map[string]any{"outbox_pending": -1}); code != 400 {
		t.Fatalf("negative outbox: %d", code)
	}

	fx.srv.noteReport(ctx, fx.b, time.Now())
	code, me := callJSON(t, h, "GET", "/me/diagnostics", fx.b, nil)
	if code != 200 || me["server_time"] == nil || me["last_report_at"] == nil {
		t.Fatalf("diagnostics: %d %v", code, me)
	}
	devs, _ := me["devices"].([]any)
	if len(devs) != 1 {
		t.Fatalf("devices: %v", me["devices"])
	}
	d := devs[0].(map[string]any)
	if d["battery_opt"] != "restricted" || d["push_registered"] != true || d["os_version"] != "Android 14 (SDK 34)" {
		t.Fatalf("device facts: %v", d)
	}
	// Another user never sees b's device.
	_, other := callJSON(t, h, "GET", "/me/diagnostics", fx.x, nil)
	if od, _ := other["devices"].([]any); len(od) != 1 || od[0].(map[string]any)["id"] != devX {
		t.Fatalf("x sees %v", other["devices"])
	}

	// Admin fleet view: facts but no coordinates or credentials.
	rec := callRaw(t, h, "GET", "/fleet", fx.a)
	body := rec
	for _, bad := range []string{"\"lat\"", "\"lon\"", "push_token", "unifiedpush_endpoint", "ingest_key"} {
		if strings.Contains(body, bad) {
			t.Errorf("fleet response contains %s: %s", bad, body)
		}
	}
	if !strings.Contains(body, "restricted") || !strings.Contains(body, "0.19.0") {
		t.Errorf("fleet response missing facts: %s", body)
	}
}

// ---- DB: arrival watch --------------------------------------------------------

func TestArrivalWatchEndToEnd(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if err := fx.srv.EnsureNotificationSchema(ctx); err != nil {
		t.Fatal(err)
	}
	pool := fx.pool
	exec := func(q string, a ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, a...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	exec(`INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/a')`, fx.a)
	var place, gf string
	if err := pool.QueryRow(ctx, `INSERT INTO places (family_id, name, geom, radius_meters, circle_id)
		VALUES ($1,'Home',ST_SetSRID(ST_MakePoint(-0.12,51.5),4326),150,$1) RETURNING id::text`, fx.f1).Scan(&place); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO geofences (family_id, place_id) VALUES ($1,$2) RETURNING id::text`, fx.f1, place).Scan(&gf); err != nil {
		t.Fatal(err)
	}
	h := newDiagRouter(fx)

	// A place of another family cannot be watched.
	var otherPlace string
	_ = pool.QueryRow(ctx, `INSERT INTO places (family_id, name, geom, radius_meters, circle_id)
		VALUES ($1,'Elsewhere',ST_SetSRID(ST_MakePoint(1,1),4326),150,$1) RETURNING id::text`, fx.f2).Scan(&otherPlace)
	if code, _ := callJSON(t, h, "PUT", "/me/arrival-watch", fx.b, map[string]any{"place_id": otherPlace, "enabled": true}); code != 404 {
		t.Fatalf("foreign place: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", "/me/arrival-watch", fx.b, map[string]any{"place_id": place, "enabled": true, "tz": "Nowhere/Land"}); code != 400 {
		t.Fatalf("bad tz: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", "/me/arrival-watch", fx.b, map[string]any{"place_id": place, "enabled": true, "tz": "UTC"}); code != 200 {
		t.Fatalf("watch: %d", code)
	}

	tue := time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC)
	for _, e := range weekdayArrivals(tue, 20, 16, 0) {
		exec(`INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts) VALUES ($1,$2,$3,'enter',$4)`, gf, fx.b, place, e)
		exec(`INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts) VALUES ($1,$2,$3,'exit',$4)`, gf, fx.b, place, e.Add(10*time.Hour))
	}
	now := tue.Add(17*time.Hour + 10*time.Minute)
	run := func(at time.Time) int {
		t.Helper()
		n, err := fx.srv.RunArrivalOnce(ctx, at)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	// Phone silent for hours: we cannot tell late from offline.
	exec(`INSERT INTO member_report_state (user_id, last_report_at) VALUES ($1,$2)`, fx.b, now.Add(-5*time.Hour))
	if n := run(now); n != 0 {
		t.Fatalf("stale phone alerted: %d", n)
	}
	exec(`UPDATE member_report_state SET last_report_at = $2 WHERE user_id = $1`, fx.b, now.Add(-5*time.Minute))
	if n := run(now.Add(-30 * time.Minute)); n != 0 {
		t.Fatalf("alerted before the deadline: %d", n)
	}
	if n := run(now); n != 1 {
		t.Fatalf("expected one alert, got %d", n)
	}
	pushes := capturedPushes(fx)
	if len(pushes) != 1 || pushes[0].endpoint != "https://ntfy.example/a" || !strings.Contains(pushes[0].body, "A family member usually arrives at Home") {
		t.Fatalf("pushes: %+v", pushes)
	}
	if n := run(now.Add(20 * time.Minute)); n != 0 {
		t.Fatalf("hard rate limit / idempotency broken: %d", n)
	}
	// Arriving cancels (a fresh day is a new day, so check the same-day case).
	exec(`DELETE FROM arrival_alert_log`)
	exec(`INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts) VALUES ($1,$2,$3,'enter',$4)`, gf, fx.b, place, now.Add(-time.Minute))
	if n := run(now); n != 0 {
		t.Fatalf("already arrived today: %d", n)
	}
}

func newDiagRouter(fx *alertFixture) http.Handler {
	srv := fx.srv
	r := chi.NewRouter()
	r.Get("/me/diagnostics", srv.GetMyDiagnostics)
	r.Put("/devices/{id}/diagnostics", srv.ReportDeviceDiagnostics)
	r.Get("/fleet", srv.AdminFleetHealth)
	r.Get("/me/arrival-watch", srv.GetArrivalWatch)
	r.Put("/me/arrival-watch", srv.PutArrivalWatch)
	r.Post("/me/diagnostics/test-push", srv.SendTestPush)
	r.Get("/circles/{id}/silence-alerts", srv.GetSilenceAlerts)
	r.Put("/circles/{id}/silence-alerts", srv.PutSilenceAlerts)
	r.Put("/circles/{id}/silence-alerts/me", srv.PutMySilencePrefs)
	return r
}

func callRaw(t *testing.T, h http.Handler, method, path, uid string) string {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w.Body.String()
}

// ---- DB: silence-alert settings authorization ---------------------------------

func TestSilenceAlertSettingsAuthorization(t *testing.T) {
	fx := newAlertFixture(t)
	h := newDiagRouter(fx)
	path := "/circles/" + fx.f1 + "/silence-alerts"

	if code, _ := callJSON(t, h, "GET", path, fx.x, nil); code != 404 {
		t.Fatalf("outsider read: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", path, fx.x, map[string]any{"hours": 8}); code != 404 {
		t.Fatalf("outsider write: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", path, fx.c, map[string]any{"hours": 8}); code != 403 {
		t.Fatalf("plain member must not change the circle setting: %d", code)
	}
	for _, bad := range []int{1, 73, -4} {
		if code, _ := callJSON(t, h, "PUT", path, fx.a, map[string]any{"hours": bad}); code != 400 {
			t.Fatalf("hours=%d: %d", bad, code)
		}
	}
	if code, _ := callJSON(t, h, "PUT", path, fx.a, map[string]any{"hours": 8}); code != 200 {
		t.Fatalf("admin set: %d", code)
	}
	code, got := callJSON(t, h, "GET", path, fx.c, nil)
	if code != 200 || got["hours"] != float64(8) || got["is_admin"] != false {
		t.Fatalf("member read: %d %v", code, got)
	}
	// A member controls only their own opt-out, and only within limits.
	if code, _ := callJSON(t, h, "PUT", path+"/me", fx.c, map[string]any{"disabled": true}); code != 200 {
		t.Fatalf("own opt-out: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", path+"/me", fx.c, map[string]any{"snooze_hours": 100000}); code != 400 {
		t.Fatalf("snooze cap: %d", code)
	}
	if code, _ := callJSON(t, h, "PUT", path+"/me", fx.x, map[string]any{"disabled": true}); code != 404 {
		t.Fatalf("outsider opt-out: %d", code)
	}
	var disabled bool
	_ = fx.pool.QueryRow(context.Background(), `SELECT disabled FROM silence_member_prefs WHERE circle_id = $1 AND user_id = $2`, fx.f1, fx.c).Scan(&disabled)
	if !disabled {
		t.Fatal("opt-out was not stored for the caller")
	}
	if code, _ := callJSON(t, h, "POST", "/me/diagnostics/test-push", fx.b, nil); code != 200 {
		t.Fatalf("test push: %d", code)
	}
}
