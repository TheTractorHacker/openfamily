package handlers

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

func TestShareTileConfig(t *testing.T) {
	tpl, src, ok := shareTileConfig("")
	if !ok || src != "https://tile.openstreetmap.org" || !strings.Contains(tpl, "{z}") {
		t.Fatalf("default: %q %q %v", tpl, src, ok)
	}
	if _, src, _ := shareTileConfig("https://{s}.tiles.example.com/{z}/{x}/{y}{r}.png"); src != "https://*.tiles.example.com" {
		t.Fatalf("subdomain: %q", src)
	}
	if _, _, ok := shareTileConfig("http://t.example.com/{z}/{x}/{y}.png"); ok {
		t.Fatal("http template must be refused")
	}
}

func TestShareTokenHashing(t *testing.T) {
	a, _ := newShareLinkToken()
	b, _ := newShareLinkToken()
	if a == b || len(a) != shareLinkTokenLen || !shareLinkTokenRe.MatchString(a) {
		t.Fatalf("token shape: %q %q", a, b)
	}
	if h := hashShareToken(a); len(h) != 32 || string(h) != string(func() []byte { s := sha256.Sum256([]byte(a)); return s[:] }()) {
		t.Fatal("hash is not sha256")
	}
}

func newShareLinkRouter(fx *alertFixture) http.Handler {
	srv := fx.srv
	r := chi.NewRouter()
	r.Post("/share-links", srv.CreateShareLink)
	r.Get("/share-links", srv.ListShareLinks)
	r.Delete("/share-links/{id}", srv.DeleteShareLink)
	r.Get("/s/{token}", srv.ShareViewPage)
	r.Get("/s/{token}/data", srv.ShareViewData)
	r.Get("/s/{token}/photo", srv.ShareViewPhoto)
	return r
}

func rawGet(h http.Handler, path string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	return w
}

func TestShareLinkLifecycle(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	h := newShareLinkRouter(fx)
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO member_positions (user_id, lat, lon, ts, battery_pct, speed_mps, accuracy_meters, heading_deg)
		VALUES ($1, 51.5, -0.12, now(), 77, 3.5, 12, 90)`, fx.a); err != nil {
		t.Fatal(err)
	}

	// Validation.
	if code, _ := callJSON(t, h, "POST", "/share-links", fx.a, map[string]any{"minutes": 0}); code != 400 {
		t.Fatalf("0 minutes: %d", code)
	}
	if code, _ := callJSON(t, h, "POST", "/share-links", fx.a, map[string]any{"minutes": 4321}); code != 400 {
		t.Fatalf("over 72h: %d", code)
	}
	code, c := callJSON(t, h, "POST", "/share-links", fx.a, map[string]any{"minutes": 60, "label": "Dinner"})
	if code != 201 {
		t.Fatalf("create: %d %v", code, c)
	}
	token, _ := c["token"].(string)
	id, _ := c["id"].(string)
	if len(token) != shareLinkTokenLen || c["url"] != "https://of.example.com/s/"+token {
		t.Fatalf("token/url: %v", c)
	}

	// Only the hash is stored.
	var stored []byte
	if err := fx.pool.QueryRow(ctx, `SELECT token_hash FROM share_links WHERE id = $1`, id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if string(stored) == token || string(stored) != string(hashShareToken(token)) {
		t.Fatal("token hash not stored correctly")
	}

	// List shows it without any token.
	code, l := callJSON(t, h, "GET", "/share-links", fx.a, nil)
	links, _ := l["links"].([]any)
	if code != 200 || len(links) != 1 {
		t.Fatalf("list: %d %v", code, l)
	}
	if _, has := links[0].(map[string]any)["token"]; has {
		t.Fatal("list leaked token")
	}
	if code, l = callJSON(t, h, "GET", "/share-links", fx.b, nil); len(l["links"].([]any)) != 0 {
		t.Fatalf("other user sees links: %v", l)
	}

	// Public viewer.
	w := rawGet(h, "/s/"+token+"/data")
	if w.Code != 200 {
		t.Fatalf("data: %d %s", w.Code, w.Body)
	}
	for k, v := range map[string]string{"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex"} {
		if !strings.Contains(w.Header().Get(k), v) {
			t.Fatalf("header %s=%q", k, w.Header().Get(k))
		}
	}
	var d map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &d)
	if d["state"] != "active" || d["lat"] != 51.5 || d["battery_pct"] != 77.0 || d["name"] != "a Tester" || d["initial"] != "A" {
		t.Fatalf("data body: %v", d)
	}
	// No leaked fields.
	body := w.Body.String()
	for _, banned := range []string{fx.a, fx.f1, "@example.com", "email", "user_id", "circle", "family", "history", "token"} {
		if strings.Contains(body, banned) {
			t.Fatalf("data leaks %q: %s", banned, body)
		}
	}
	allowed := map[string]bool{"state": true, "name": true, "initial": true, "lat": true, "lon": true, "accuracy_m": true,
		"heading_deg": true, "speed_mps": true, "battery_pct": true, "updated_at": true, "expires_at": true}
	for k := range d {
		if !allowed[k] {
			t.Fatalf("unexpected field %q", k)
		}
	}

	pg := rawGet(h, "/s/"+token)
	csp := pg.Header().Get("Content-Security-Policy")
	if pg.Code != 200 || !strings.Contains(csp, "default-src 'none'") || !strings.Contains(csp, "nonce-") ||
		!strings.Contains(csp, "tile.openstreetmap.org") || strings.Contains(csp, "unsafe-eval") {
		t.Fatalf("page: %d csp=%q", pg.Code, csp)
	}
	if strings.Contains(pg.Body.String(), token) || strings.Contains(pg.Body.String(), "a Tester") {
		t.Fatal("page embeds token or user data")
	}
	if strings.Contains(pg.Body.String(), "https://cdn") || strings.Contains(pg.Body.String(), "src=\"http") {
		t.Fatal("page references a third-party host")
	}

	// Pause: no location, no battery.
	if _, err := fx.pool.Exec(ctx, `INSERT INTO sharing_pauses (user_id, paused_until) VALUES ($1, now() + interval '1 hour')`, fx.a); err != nil {
		t.Fatal(err)
	}
	w = rawGet(h, "/s/"+token+"/data")
	d = map[string]any{}
	_ = json.Unmarshal(w.Body.Bytes(), &d)
	if w.Code != 200 || d["state"] != "paused" || d["lat"] != nil || d["lon"] != nil || d["battery_pct"] != nil {
		t.Fatalf("paused: %d %v", w.Code, d)
	}
	_, _ = fx.pool.Exec(ctx, `DELETE FROM sharing_pauses WHERE user_id = $1`, fx.a)

	// Unknown token vs. valid-but-revoked vs. expired: identical 404 bodies.
	unknown, _ := newShareLinkToken()
	missData := rawGet(h, "/s/"+unknown+"/data")
	missPage := rawGet(h, "/s/"+unknown)
	if missData.Code != 404 || missPage.Code != 404 {
		t.Fatalf("unknown: %d %d", missData.Code, missPage.Code)
	}
	malformed := rawGet(h, "/s/short/data")
	if malformed.Code != 404 || malformed.Body.String() != missData.Body.String() {
		t.Fatal("malformed token distinguishable")
	}

	// Expiry stops serving immediately.
	if _, err := fx.pool.Exec(ctx, `UPDATE share_links SET expires_at = now() - interval '1 second' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/data", "", "/photo"} {
		w := rawGet(h, "/s/"+token+p)
		if w.Code != 404 {
			t.Fatalf("expired %q: %d", p, w.Code)
		}
	}
	if w := rawGet(h, "/s/"+token+"/data"); w.Body.String() != missData.Body.String() || w.Header().Get("Content-Type") != missData.Header().Get("Content-Type") {
		t.Fatalf("expired differs from unknown: %q vs %q", w.Body, missData.Body)
	}
	if w := rawGet(h, "/s/"+token); w.Body.String() != missPage.Body.String() {
		t.Fatal("expired page differs from unknown page")
	}
	if _, l = callJSON(t, h, "GET", "/share-links", fx.a, nil); len(l["links"].([]any)) != 0 {
		t.Fatalf("expired link listed: %v", l)
	}

	// Revoke: owner only, immediate, uniform 404 afterwards.
	_, c2 := callJSON(t, h, "POST", "/share-links", fx.a, map[string]any{"minutes": 120})
	tok2, id2 := c2["token"].(string), c2["id"].(string)
	if rawGet(h, "/s/"+tok2+"/data").Code != 200 {
		t.Fatal("second link not served")
	}
	if code, _ := callJSON(t, h, "DELETE", "/share-links/"+id2, fx.b, nil); code != 404 {
		t.Fatalf("non-owner revoke: %d", code)
	}
	if rawGet(h, "/s/"+tok2+"/data").Code != 200 {
		t.Fatal("non-owner revoke stopped sharing")
	}
	if code, _ := callJSON(t, h, "DELETE", "/share-links/"+id2, fx.a, nil); code != 200 {
		t.Fatalf("revoke: %d", code)
	}
	if w := rawGet(h, "/s/"+tok2+"/data"); w.Code != 404 || w.Body.String() != missData.Body.String() {
		t.Fatalf("revoked: %d %s", w.Code, w.Body)
	}
	if code, _ := callJSON(t, h, "DELETE", "/share-links/"+id2, fx.a, nil); code != 404 {
		t.Fatalf("second revoke: %d", code)
	}
	if code, _ := callJSON(t, h, "DELETE", "/share-links/not-a-uuid", fx.a, nil); code != 404 {
		t.Fatalf("bad id: %d", code)
	}
}

func TestShareLinkCapAndPhoto(t *testing.T) {
	fx := newAlertFixture(t)
	h := newShareLinkRouter(fx)
	var tok string
	for i := 0; i < maxActiveLinks; i++ {
		code, c := callJSON(t, h, "POST", "/share-links", fx.c, map[string]any{"minutes": 30})
		if code != 201 {
			t.Fatalf("create %d: %d", i, code)
		}
		tok = c["token"].(string)
	}
	if code, _ := callJSON(t, h, "POST", "/share-links", fx.c, map[string]any{"minutes": 30}); code != 409 {
		t.Fatalf("cap: %d", code)
	}
	// No avatar: data has no photo_url and /photo is a 404.
	w := rawGet(h, "/s/"+tok+"/data")
	if strings.Contains(w.Body.String(), "photo_url") || rawGet(h, "/s/"+tok+"/photo").Code != 404 {
		t.Fatal("photo served without an avatar")
	}
	// With an avatar the photo is served only while the link lives.
	png := []byte("\x89PNG\r\n\x1a\nxx")
	if _, err := fx.pool.Exec(context.Background(), `UPDATE users SET avatar_data=$2, avatar_content_type='image/png', avatar_updated_at=now() WHERE id=$1`, fx.c, png); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rawGet(h, "/s/"+tok+"/data").Body.String(), "/s/"+tok+"/photo") {
		t.Fatal("photo_url missing")
	}
	if p := rawGet(h, "/s/"+tok+"/photo"); p.Code != 200 || p.Header().Get("Content-Type") != "image/png" || p.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("photo: %d %v", p.Code, p.Header())
	}
	_, _ = fx.pool.Exec(context.Background(), `UPDATE share_links SET revoked_at = now() WHERE user_id = $1`, fx.c)
	if rawGet(h, "/s/"+tok+"/photo").Code != 404 {
		t.Fatal("photo served after revoke")
	}
}

func TestShareViewRateLimit(t *testing.T) {
	fx := newAlertFixture(t)
	fx.srv.AuthLimit = sms.NewLimiter()
	h := newShareLinkRouter(fx)
	unknown, _ := newShareLinkToken()
	var last int
	for i := 0; i < shareLinkMissPerIP+1; i++ {
		last = rawGet(h, "/s/"+unknown+"/data").Code
		if i < shareLinkMissPerIP && last != 404 {
			t.Fatalf("request %d: %d", i, last)
		}
	}
	if last != 429 {
		t.Fatalf("misses not rate limited: %d", last)
	}
}

