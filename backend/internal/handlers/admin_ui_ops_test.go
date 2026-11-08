package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func callAs(t *testing.T, h http.Handler, method, path, uid, fam string, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(method, path, bytes.NewReader(b))
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid, SessionID: fam}))
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
	// A token without a session id cannot protect the caller: refused.
	if code, _ := callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, "", map[string]any{"mode": "inactive", "days": 3}); code != 409 {
		t.Fatalf("no sid: %d", code)
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

func TestLoginReplacesSameInstallAndSweepsIdle(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE family_id LIKE 'hy-%'`) })
	mk := func(jti, uid, ageSQL string) {
		if _, err := fx.pool.Exec(ctx, `INSERT INTO refresh_sessions (jti, family_id, user_id, created_at, expires_at)
			VALUES ($1,$1,$2, now() - `+ageSQL+`::interval, now() + interval '10 days')`, jti, uid); err != nil {
			t.Fatal(err)
		}
	}
	revoked := func(jti string) (b bool) {
		_ = fx.pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM refresh_sessions WHERE jti = $1`, jti).Scan(&b)
		return
	}
	login := func(jti, install string) {
		mk(jti, fx.c, "'0 seconds'")
		req := httptest.NewRequest("POST", "/auth/login", nil)
		if install != "" {
			req.Header.Set("X-Install-Id", install)
		}
		fx.srv.tagSessionClient(req, fx.c, jti)
	}
	login("hy-1", "install-phone-1")
	login("hy-2", "install-phone-2")
	login("hy-3", "install-phone-1") // same phone signs in again
	if !revoked("hy-1") || revoked("hy-2") || revoked("hy-3") {
		t.Fatalf("replace: 1=%v 2=%v 3=%v", revoked("hy-1"), revoked("hy-2"), revoked("hy-3"))
	}
	login("hy-4", "") // no install id: nothing is guessed
	if revoked("hy-2") || revoked("hy-3") {
		t.Fatal("anonymous login revoked others")
	}
	// Idle sweep: default 14 days.
	mk("hy-old", fx.c, "'20 days'")
	if _, err := fx.srv.SweepIdleSessions(ctx); err != nil {
		t.Fatal(err)
	}
	if !revoked("hy-old") || revoked("hy-3") {
		t.Fatalf("sweep: old=%v fresh=%v", revoked("hy-old"), revoked("hy-3"))
	}
	// Cap per user.
	_, _ = fx.pool.Exec(ctx, `UPDATE security_settings SET max_sessions_per_user = 2 WHERE id = 1`)
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `UPDATE security_settings SET max_sessions_per_user = 20 WHERE id = 1`) })
	login("hy-5", "")
	if !revoked("hy-2") || revoked("hy-5") || revoked("hy-4") {
		t.Fatalf("cap: 2=%v 4=%v 5=%v", revoked("hy-2"), revoked("hy-4"), revoked("hy-5"))
	}
}

func TestPublicDownloadIPAWithoutConfigIs404AndServesCache(t *testing.T) {
	rec := httptest.NewRecorder()
	(&Server{}).PublicDownloadIPA(rec, httptest.NewRequest(http.MethodGet, "/app.ipa", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d", rec.Code)
	}
	// GitHub unreachable but an IPA is cached: serve it.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "openfamily-release.ipa"), []byte("IPA"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &Server{APKDir: dir, APKGitHubRepo: "bad repo"}
	rec = httptest.NewRecorder()
	s.PublicDownloadIPA(rec, httptest.NewRequest(http.MethodGet, "/app.ipa", nil))
	if rec.Code != 200 || rec.Body.String() != "IPA" || !strings.Contains(rec.Header().Get("Content-Disposition"), ".ipa") {
		t.Fatalf("cached ipa: %d %q", rec.Code, rec.Body.String())
	}
}

func TestRevocationCoversRotatedFamilies(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	t.Cleanup(func() { _, _ = fx.pool.Exec(ctx, `DELETE FROM refresh_sessions WHERE family_id LIKE 'rf-%'`) })
	store := pgRefreshStore{pool: fx.pool}
	exp := time.Now().Add(24 * time.Hour)
	activeRows := func(fam string) (n int) {
		_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE family_id = $1 AND revoked_at IS NULL AND used_at IS NULL`, fam).Scan(&n)
		return
	}
	// Family A: signed in on install "rotated-install", then rotated twice.
	if err := store.Create(ctx, fx.c, "rf-A", exp); err != nil {
		t.Fatal(err)
	}
	_, _ = fx.pool.Exec(ctx, `UPDATE refresh_sessions SET client_key = 'rotated-install' WHERE jti = 'rf-A'`)
	for _, pair := range [][2]string{{"rf-A", "rf-A2"}, {"rf-A2", "rf-A3"}} {
		if out, _, err := store.Rotate(ctx, fx.c, pair[0], pair[1], exp); err != nil || out != rotateOK {
			t.Fatalf("rotate: %v %v", out, err)
		}
	}
	// Another family (B) for the same user, and the caller's own (C).
	_ = store.Create(ctx, fx.c, "rf-B", exp)
	_ = store.Create(ctx, fx.c, "rf-C", exp)
	if activeRows("rf-A") != 1 {
		t.Fatalf("expected one live token in family A")
	}
	// Same install signs in again: ALL live rows of family A must be revoked,
	// including the rotated one that carries no explicit login tag.
	_ = store.Create(ctx, fx.c, "rf-D", exp)
	req := httptest.NewRequest("POST", "/auth/login", nil)
	req.Header.Set("X-Install-Id", "rotated-install")
	fx.srv.tagSessionClient(req, fx.c, "rf-D")
	if n := activeRows("rf-A"); n != 0 {
		t.Fatalf("family A still has %d live rows after replacement", n)
	}
	if activeRows("rf-D") != 1 || activeRows("rf-B") != 1 {
		t.Fatal("unrelated families must stay active")
	}
	// Bulk revoke from C's point of view: rotate B twice, then revoke all but C.
	for _, pair := range [][2]string{{"rf-B", "rf-B2"}, {"rf-B2", "rf-B3"}} {
		if out, _, err := store.Rotate(ctx, fx.c, pair[0], pair[1], exp); err != nil || out != rotateOK {
			t.Fatalf("rotate: %v %v", out, err)
		}
	}
	r := chi.NewRouter()
	r.Post("/sessions/bulk-revoke", fx.srv.AdminBulkRevokeSessions)
	code, out := callAs(t, r, "POST", "/sessions/bulk-revoke", fx.a, "rf-C", map[string]any{"mode": "all_except_current", "user_id": fx.c})
	if code != 200 || out["revoked"].(float64) < 2 {
		t.Fatalf("bulk: %d %v", code, out)
	}
	if activeRows("rf-B") != 0 || activeRows("rf-D") != 0 {
		t.Fatalf("rotated family left live rows: B=%d D=%d", activeRows("rf-B"), activeRows("rf-D"))
	}
	if activeRows("rf-C") != 1 {
		t.Fatal("current family was revoked")
	}
}
