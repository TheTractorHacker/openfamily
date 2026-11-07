package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func callAs(t *testing.T, h http.Handler, method, path, uid, fam string, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(method, path, bytes.NewReader(b))
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid, FamilyID: fam}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func TestRegisterDeviceReusesRow(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	r := chi.NewRouter()
	r.Post("/devices", fx.srv.RegisterDevice)
	count := func() (n int) {
		_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id = $1`, fx.c).Scan(&n)
		return
	}
	body := map[string]any{"platform": "android", "name": "Android device", "install_id": "install-abcdef-1", "app_version": "0.24.0"}
	code, first := callAs(t, r, "POST", "/devices", fx.c, "", body)
	if code != 201 || count() != 1 {
		t.Fatalf("first: %d %v", code, first)
	}
	// Same install again (e.g. after logout/login): same row, fresh key.
	body["app_version"] = "0.24.1"
	code, second := callAs(t, r, "POST", "/devices", fx.c, "", body)
	if code != 200 || second["id"] != first["id"] || count() != 1 || second["ingest_key"] == first["ingest_key"] {
		t.Fatalf("reuse by install id: %d %v", code, second)
	}
	if second["app_version"] != "0.24.1" {
		t.Fatalf("version not refreshed: %v", second)
	}
	// A different install is a different device.
	body["install_id"] = "install-abcdef-2"
	code, third := callAs(t, r, "POST", "/devices", fx.c, "", body)
	if code != 201 || third["id"] == first["id"] || count() != 2 {
		t.Fatalf("new install: %d %v", code, third)
	}
	// No install id (old app) but same UnifiedPush endpoint: reused.
	p := map[string]any{"platform": "android", "name": "x", "unifiedpush_endpoint": "https://ntfy.sh/upabc123"}
	code, a := callAs(t, r, "POST", "/devices", fx.c, "", p)
	code2, b := callAs(t, r, "POST", "/devices", fx.c, "", p)
	if code != 201 || code2 != 200 || a["id"] != b["id"] || count() != 3 {
		t.Fatalf("reuse by endpoint: %d %d %v %v", code, code2, a, b)
	}
	// Another user never reuses it.
	code, o := callAs(t, r, "POST", "/devices", fx.b, "", p)
	if code != 201 || o["id"] == a["id"] {
		t.Fatalf("cross-user reuse: %d %v", code, o)
	}
	if code, _ := callAs(t, r, "POST", "/devices", fx.c, "", map[string]any{"platform": "android", "install_id": "bad id!"}); code != 400 {
		t.Fatalf("bad install id: %d", code)
	}
}

func TestAdminBulkRevokeSessions(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	r := chi.NewRouter()
	r.Post("/sessions/bulk-revoke", fx.srv.AdminBulkRevokeSessions)
	mk := func(fam, uid, ageSQL string) {
		if _, err := fx.pool.Exec(ctx, `INSERT INTO refresh_sessions (jti, family_id, user_id, created_at, expires_at)
			VALUES ($1,$1,$2, now() - `+ageSQL+`::interval, now() + interval '10 days')`, fam, uid); err != nil {
			t.Fatal(err)
		}
	}
	mk("ui-cur-"+fx.a, fx.a, "'1 minute'")
	mk("ui-old1-"+fx.a, fx.a, "'20 days'")
	mk("ui-old2-"+fx.b, fx.b, "'11 days'")
	mk("ui-new-"+fx.b, fx.b, "'1 hour'")
	cur := "ui-cur-" + fx.a
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE family_id LIKE 'ui-%'`) })
	live := func() (n int) {
		_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE family_id LIKE 'ui-%' AND revoked_at IS NULL`).Scan(&n)
		return
	}
	// Narrow by user so unrelated rows in a shared test DB cannot interfere.
	for _, tc := range []struct {
		body  map[string]any
		count int
	}{
		{map[string]any{"mode": "inactive", "days": 7, "user_id": fx.b, "dry_run": true}, 1},
		{map[string]any{"mode": "inactive", "days": 7, "user_id": fx.a, "dry_run": true}, 1},
		{map[string]any{"mode": "all_except_current", "user_id": fx.a, "dry_run": true}, 1},
	} {
		code, out := callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, cur, tc.body)
		if code != 200 || int(out["count"].(float64)) != tc.count || live() != 4 {
			t.Fatalf("preview %v: %d %v live=%d", tc.body, code, out, live())
		}
	}
	// Real run: the caller's own family survives.
	code, out := callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, cur, map[string]any{"mode": "all_except_current", "user_id": fx.a})
	if code != 200 || int(out["revoked"].(float64)) != 1 || live() != 3 {
		t.Fatalf("revoke: %d %v live=%d", code, out, live())
	}
	var curRevoked bool
	_ = fx.pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM refresh_sessions WHERE jti = $1`, cur).Scan(&curRevoked)
	if curRevoked {
		t.Fatal("current session revoked")
	}
	// Inactive for 7 days also spares the current one; only fx.b's old one goes.
	code, out = callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, cur, map[string]any{"mode": "inactive", "days": 7, "user_id": fx.b})
	if code != 200 || int(out["revoked"].(float64)) != 1 || live() != 2 {
		t.Fatalf("inactive: %d %v live=%d", code, out, live())
	}
	for _, bad := range []map[string]any{{"mode": "nope"}, {"mode": "inactive"}, {"mode": "inactive", "days": 0},
		{"mode": "all_except_current", "include_current": true}, {"mode": "inactive", "days": 3, "user_id": "zzz"}} {
		if code, _ := callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, cur, bad); code != 400 {
			t.Fatalf("bad %v: %d", bad, code)
		}
	}
	// Explicit include_current may cut off the caller.
	code, out = callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, cur, map[string]any{"mode": "inactive", "days": 1, "user_id": fx.a, "include_current": true, "dry_run": true})
	if code != 200 || int(out["count"].(float64)) != 0 {
		t.Fatalf("include_current preview: %d %v", code, out)
	}
}

func TestAdminHideStaleDevices(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	r := chi.NewRouter()
	r.Post("/fleet/hide-stale", fx.srv.AdminHideStaleDevices)
	r.Get("/fleet", fx.srv.AdminFleetHealth)
	for _, ago := range []string{"1 hour", "9 days", "30 days"} {
		if _, err := fx.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, name, last_seen) VALUES ($1,'android','Android device', now() - $2::interval)`, fx.c, ago); err != nil {
			t.Fatal(err)
		}
	}
	code, out := callAs(t, r, "POST", "/fleet/hide-stale", fx.a, "", map[string]any{"days": 7, "dry_run": true})
	if code != 200 || out["dry_run"] != true {
		t.Fatalf("preview: %d %v", code, out)
	}
	n := int(out["count"].(float64))
	if n < 2 {
		t.Fatalf("expected at least 2 stale, got %d", n)
	}
	code, out = callAs(t, r, "POST", "/fleet/hide-stale", fx.a, "", map[string]any{"days": 7})
	if code != 200 || int(out["hidden"].(float64)) != n {
		t.Fatalf("hide: %d %v", code, out)
	}
	var visible int
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id = $1 AND (hidden_at IS NULL OR last_seen > hidden_at)`, fx.c).Scan(&visible)
	if visible != 1 {
		t.Fatalf("user keeps only the fresh device, got %d", visible)
	}
	// A hidden device that reports again comes back.
	_, _ = fx.pool.Exec(ctx, `UPDATE devices SET last_seen = now() WHERE user_id = $1 AND last_seen < now() - interval '20 days'`, fx.c)
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM devices WHERE user_id = $1 AND (hidden_at IS NULL OR last_seen > hidden_at)`, fx.c).Scan(&visible)
	if visible != 2 {
		t.Fatalf("returning device not visible: %d", visible)
	}
	if code, _ := callAs(t, r, "POST", "/fleet/hide-stale", fx.a, "", map[string]any{"days": -1}); code != 400 {
		t.Fatalf("bad days: %d", code)
	}
}
