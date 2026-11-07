package handlers

import (
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
	// Fallback: no id, newest device of that platform.
	if err := middleware.TouchDeviceVersion(ctx, fx.pool, fx.b, "", "android", "0.24.0"); err != nil || ver(mine) != "0.24.0" {
		t.Fatalf("fallback: %v %q", err, ver(mine))
	}

	// Private-circle liveness: last_seen is bumped, throttled, and scoped to the caller.
	liveTouch.Range(func(k, _ any) bool { liveTouch.Delete(k); return true })
	req := httptest.NewRequest("POST", "/x", nil)
	req.Header.Set("X-Device-Id", mine)
	fx.srv.touchPrivateLiveness(req, fx.b)
	var seen time.Time
	_ = fx.pool.QueryRow(ctx, `SELECT last_seen FROM devices WHERE id = $1`, mine).Scan(&seen)
	if time.Since(seen) > time.Minute {
		t.Fatalf("last_seen not bumped: %v", seen)
	}
	_, _ = fx.pool.Exec(ctx, `UPDATE devices SET last_seen = now() - interval '5 hours' WHERE id = $1`, mine)
	fx.srv.touchPrivateLiveness(req, fx.b)
	_ = fx.pool.QueryRow(ctx, `SELECT last_seen FROM devices WHERE id = $1`, mine).Scan(&seen)
	if time.Since(seen) < time.Hour {
		t.Fatalf("throttle did not hold: %v", seen)
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


