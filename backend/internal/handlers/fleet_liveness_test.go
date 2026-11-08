package handlers

import (
	"fmt"
	"net/http"
	"strings"
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// The exact body the Flutter app builds (DiagnosticsReporter.body) must be
// accepted; the earlier failures were silent, so pin the payload here.
func TestDiagnosticsAcceptsAppPayload(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	var dev string
	if err := fx.pool.QueryRow(ctx, `SELECT id::text FROM devices WHERE user_id = $1`, fx.b).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	h := newDiagRouter(fx)
	for _, loc := range []string{"always", "while_in_use", "denied", "unknown"} {
		code, body := callJSON(t, h, "PUT", "/devices/"+dev+"/diagnostics", fx.b, map[string]any{
			"os_version": "Android 14 (SDK 34)", "battery_opt": "unrestricted", "outbox_pending": 0,
			"loc_permission": loc, "notif_permission": "granted", "bg_service": true, "app_version": "0.23.0+45"})
		if code != 204 {
			t.Fatalf("loc %s: %d %v", loc, code, body)
		}
	}
	var v string
	var at *time.Time
	if err := fx.pool.QueryRow(ctx, `SELECT app_version, diag_reported_at FROM devices WHERE id = $1`, dev).Scan(&v, &at); err != nil || v != "0.23.0+45" || at == nil {
		t.Fatalf("stored %q %v %v", v, at, err)
	}
}

func TestDeviceVersionAndPrivateLiveness(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	var mine, other string
	if err := fx.pool.QueryRow(ctx, `SELECT id::text FROM devices WHERE user_id = $1`, fx.b).Scan(&mine); err != nil {
		t.Fatal(err)
	}
	if err := fx.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, app_version) VALUES ($1,'android','0.1.0') RETURNING id::text`, fx.x).Scan(&other); err != nil {
		t.Fatal(err)
	}
	if _, err := fx.pool.Exec(ctx, `UPDATE devices SET app_version='0.1.0', platform='android', last_seen = now() - interval '5 hours' WHERE id = $1`, mine); err != nil {
		t.Fatal(err)
	}
	ver := func(id string) (v string) {
		_ = fx.pool.QueryRow(ctx, `SELECT app_version FROM devices WHERE id = $1`, id).Scan(&v)
		return
	}
	// By X-Device-Id.
	if err := middleware.TouchDeviceVersion(ctx, fx.pool, fx.b, mine, "android", "0.23.0"); err != nil || ver(mine) != "0.23.0" {
		t.Fatalf("by id: %v %q", err, ver(mine))
	}
	// Someone else's device id never changes it.
	if err := middleware.TouchDeviceVersion(ctx, fx.pool, fx.b, other, "android", "9.9.9"); err != nil || ver(other) != "0.1.0" {
		t.Fatalf("foreign id: %v %q", err, ver(other))
	}
	// No id: nothing is written (no "newest device" guess).
	if err := middleware.TouchDeviceVersion(ctx, fx.pool, fx.b, "", "android", "0.24.0"); err != nil || ver(mine) != "0.23.0" {
		t.Fatalf("no-id must not write: %v %q", err, ver(mine))
	}

	// Private-circle liveness: needs a valid own X-Device-Id and a platform.
	liveTouch.mu.Lock()
	liveTouch.m = map[string]time.Time{}
	liveTouch.mu.Unlock()
	mk := func(devHdr string) *http.Request {
		req := httptest.NewRequest("POST", "/x", nil)
		if devHdr != "" {
			req.Header.Set("X-Device-Id", devHdr)
		}
		return req.WithContext(middleware.ContextWithAppInfo(req.Context(), middleware.AppInfo{Platform: "android"}))
	}
	lastSeen := func(id string) (t time.Time) {
		_ = fx.pool.QueryRow(ctx, `SELECT last_seen FROM devices WHERE id = $1`, id).Scan(&t)
		return
	}
	stale := func() {
		_, _ = fx.pool.Exec(ctx, `UPDATE devices SET last_seen = now() - interval '5 hours' WHERE id = ANY($1::uuid[])`, []string{mine, other})
	}
	stale()
	fx.srv.touchPrivateLiveness(mk(""), fx.b) // no device id: no bump
	if time.Since(lastSeen(mine)) < time.Hour {
		t.Fatal("bumped without X-Device-Id")
	}
	fx.srv.touchPrivateLiveness(mk(other), fx.b) // spoofed foreign id: ignored, stores nothing
	if time.Since(lastSeen(other)) < time.Hour || len(liveTouch.m) != 0 {
		t.Fatalf("foreign device touched or remembered: %d", len(liveTouch.m))
	}
	noPlat := httptest.NewRequest("POST", "/x", nil)
	noPlat.Header.Set("X-Device-Id", mine)
	fx.srv.touchPrivateLiveness(noPlat, fx.b) // no platform: no bump
	if time.Since(lastSeen(mine)) < time.Hour {
		t.Fatal("bumped without a platform")
	}
	fx.srv.touchPrivateLiveness(mk(mine), fx.b)
	if time.Since(lastSeen(mine)) > time.Minute {
		t.Fatal("own device not bumped")
	}
	stale()
	fx.srv.touchPrivateLiveness(mk(mine), fx.b) // throttled
	if time.Since(lastSeen(mine)) < time.Hour {
		t.Fatal("throttle did not hold")
	}
	// The map stays bounded.
	for i := 0; i < liveTouchLimit+10; i++ {
		liveTouch.set(fmt.Sprint(i), time.Now())
	}
	if len(liveTouch.m) > liveTouchLimit {
		t.Fatalf("unbounded: %d", len(liveTouch.m))
	}

	// Fleet exposes the best-known activity and the client version.
	_, _ = fx.pool.Exec(ctx, `INSERT INTO app_client_versions (user_id, app_version, platform) VALUES ($1,'0.23.0','android') ON CONFLICT DO NOTHING`, fx.b)
	body := callRaw(t, newDiagRouter(fx), "GET", "/fleet", fx.a)
	for _, want := range []string{`"last_activity_at"`, `"client_version":"0.23.0"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("fleet missing %s in %s", want, body)
		}
	}
}



// A phone that only polls (or a client that never uploads) must not hide a
// dead phone: polls never bump liveness, so the silence alert still fires.
func TestSilenceStillFiresForPollOnlyPhone(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if err := fx.srv.EnsureNotificationSchema(ctx); err != nil {
		t.Fatal(err)
	}
	exec := func(q string, a ...any) {
		t.Helper()
		if _, err := fx.pool.Exec(ctx, q, a...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	exec(`INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/a')`, fx.a)
	now := time.Date(2026, 3, 10, 15, 0, 0, 0, time.UTC)
	exec(`INSERT INTO member_report_hours (user_id, hour)
		SELECT $1::uuid, ($2::timestamptz - make_interval(days => d)) - make_interval(hours => h)
		FROM generate_series(1, 6) d, generate_series(0, 23) h ON CONFLICT DO NOTHING`, fx.b, now)
	exec(`INSERT INTO member_report_state (user_id, last_report_at) VALUES ($1, $2)`, fx.b, now.Add(-10*time.Hour))
	exec(`UPDATE circles SET silence_alert_hours = 8 WHERE id = $1`, fx.f1)
	exec(`UPDATE devices SET last_seen = $2 WHERE user_id = $1`, fx.b, now.Add(-10*time.Hour))
	// What a poll does to liveness: nothing (the list handler no longer calls the helper).
	if n, err := fx.srv.RunSilenceOnce(ctx, now); err != nil || n != 1 {
		t.Fatalf("silence alert suppressed: %d %v", n, err)
	}
}
