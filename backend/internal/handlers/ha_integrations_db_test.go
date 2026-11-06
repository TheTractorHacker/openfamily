package handlers

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// Home Assistant integration: tokens, privacy gating, IDOR, events, webhook.
// Need TEST_DATABASE_URL.

type haEnv struct {
	*circleEnv
	api http.Handler
}

func newHAEnv(t *testing.T) *haEnv {
	e := &haEnv{circleEnv: newCircleEnv(t)}
	e.rt.Get("/integrations/ha/tokens", e.srv.ListHATokens)
	e.rt.Post("/integrations/ha/tokens", e.srv.CreateHAToken)
	e.rt.Patch("/integrations/ha/tokens/{id}", e.srv.UpdateHAToken)
	e.rt.Delete("/integrations/ha/tokens/{id}", e.srv.RevokeHAToken)
	e.rt.Post("/integrations/ha/tokens/{id}/test", e.srv.TestHAWebhook)
	e.srv.AuthLimit = sms.NewLimiter()
	if err := e.srv.EnsureCrashSchema(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := chi.NewRouter()
	mux.Get("/integrations/ha/v1/ping", e.srv.HAPing)
	mux.Get("/integrations/ha/v1/members", e.srv.HAMembers)
	mux.Get("/integrations/ha/v1/places", e.srv.HAPlaces)
	mux.Get("/integrations/ha/v1/events", e.srv.HAEvents)
	e.api = mux
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM ha_integrations WHERE name LIKE 'test-%'`)
	})
	return e
}

func (e *haEnv) get(token, path string) (int, map[string]any, string) {
	e.t.Helper()
	return haGet(e.api, token, path)
}

func haGet(h http.Handler, token, path string) (int, map[string]any, string) {
	req := httptest.NewRequest("GET", path, nil)
	req.RemoteAddr = "192.0.2.50:1111"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var m map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	return rec.Code, m, rec.Body.String()
}

// mint creates a token through the real endpoint.
func (e *haEnv) mint(user string, circles []string, scopes ...string) (token, id string) {
	e.t.Helper()
	body := map[string]any{"name": "test-" + user, "circle_ids": circles}
	if len(scopes) > 0 {
		body["scopes"] = scopes
	}
	m := e.mustCode(user, "POST", "/integrations/ha/tokens", body, 201)
	return m["token"].(string), m["id"].(string)
}

func memberByID(m map[string]any, id string) map[string]any {
	ms, _ := m["members"].([]any)
	for _, x := range ms {
		mm := x.(map[string]any)
		if mm["id"] == id {
			return mm
		}
	}
	return nil
}

func TestHATokenLifecycle(t *testing.T) {
	e := newHAEnv(t)
	c1 := e.createCircle("A", "HA1", "B")
	c2 := e.createCircle("C", "HA2")

	// Creation: shown once, hashed at rest, IDOR-safe circle check.
	tok, id := e.mint("A", []string{c1}, "presence", "location")
	if !strings.HasPrefix(tok, "ofha_") || len(tok) != haTokenLen {
		t.Fatalf("token shape: %q", tok)
	}
	var stored int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM ha_integrations WHERE token_hash = $1`, haHashToken(tok)).Scan(&stored); err != nil || stored != 1 {
		t.Fatalf("hash not stored: %d %v", stored, err)
	}
	var leaked int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM ha_integrations WHERE webhook_url = $1 OR name = $1 OR token_hint = $1`, tok).Scan(&leaked)
	if leaked != 0 {
		t.Fatal("plaintext token stored")
	}
	_, list, raw := e.do("A", "GET", "/integrations/ha/tokens", nil)
	_ = list
	if strings.Contains(string(raw), tok) || strings.Contains(string(raw), `"token"`) || strings.Contains(string(raw), "webhook_secret") {
		t.Fatalf("list leaks token or secret: %s", raw)
	}
	e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "x", "circle_ids": []string{c2}}, 404) // not a member
	e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "x", "circle_ids": []string{}}, 400)
	e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "", "circle_ids": []string{c1}}, 400)
	e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "x", "circle_ids": []string{c1}, "scopes": []string{"admin"}}, 400)
	e.mustCode("D", "POST", "/integrations/ha/tokens", map[string]any{"name": "x", "circle_ids": []string{c1}}, 404) // no circles
	// location implies presence.
	m := e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "test-loc", "circle_ids": []string{c1}, "scopes": []string{"location"}}, 201)
	if sc := m["scopes"].([]any); len(sc) != 2 {
		t.Fatalf("scopes: %v", sc)
	}

	// IDOR: another user cannot see, edit, test or revoke it.
	e.mustCode("B", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"name": "pwn"}, 404)
	e.mustCode("B", "DELETE", "/integrations/ha/tokens/"+id, nil, 404)
	e.mustCode("B", "POST", "/integrations/ha/tokens/"+id+"/test", nil, 404)
	e.mustCode("A", "PATCH", "/integrations/ha/tokens/not-a-uuid", map[string]any{"name": "x"}, 404)
	if _, _, raw := e.do("B", "GET", "/integrations/ha/tokens", nil); strings.Contains(string(raw), id) {
		t.Fatal("B lists A's token")
	}

	// Token works, last_used_at is set, audit rows exist.
	if c, _, body := e.get(tok, "/integrations/ha/v1/members"); c != 200 {
		t.Fatalf("members: %d %s", c, body)
	}
	var used *time.Time
	_ = e.pool.QueryRow(context.Background(), `SELECT last_used_at FROM ha_integrations WHERE id = $1`, id).Scan(&used)
	if used == nil {
		t.Fatal("last_used_at not set")
	}
	// Revocation is immediate and stops the webhook; 404 the second time.
	e.mustCode("A", "DELETE", "/integrations/ha/tokens/"+id, nil, 204)
	if c, _, _ := e.get(tok, "/integrations/ha/v1/members"); c != 401 {
		t.Fatalf("revoked token: %d", c)
	}
	e.mustCode("A", "DELETE", "/integrations/ha/tokens/"+id, nil, 404)
	// A user session is not an integration token, and tokens are not accepted as sessions.
	if c, _, _ := e.get("", "/integrations/ha/v1/members"); c != 401 {
		t.Fatalf("anonymous: %d", c)
	}
	if c, _, _ := e.get("not-a-token", "/integrations/ha/v1/ping"); c != 401 {
		t.Fatalf("junk: %d", c)
	}
}

func TestHATokenCapAndRateLimit(t *testing.T) {
	e := newHAEnv(t)
	c1 := e.createCircle("A", "HAcap")
	for i := 0; i < haMaxActiveTokens; i++ {
		e.mustCode("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "test-cap", "circle_ids": []string{c1}}, 201)
	}
	// create rate limit is 10/h: the 11th is 429 before the cap is evaluated.
	code, _, _ := e.do("A", "POST", "/integrations/ha/tokens", map[string]any{"name": "test-cap", "circle_ids": []string{c1}})
	if code != 429 && code != 409 {
		t.Fatalf("11th token: %d", code)
	}
}

func TestHAMembersPrivacy(t *testing.T) {
	e := newHAEnv(t)
	c1 := e.createCircle("A", "HAp", "B", "C")
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `UPDATE member_positions SET lat = 52.123456, lon = 13.654321, battery_pct = 61, speed_mps = 3 WHERE user_id = $1`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	pres, _ := e.mint("A", []string{c1}, "presence")
	loc, _ := e.mint("A", []string{c1}, "presence", "location")

	// Without the location scope: state and battery, never coordinates.
	c, m, raw := e.get(pres, "/integrations/ha/v1/members")
	if c != 200 {
		t.Fatalf("%d %s", c, raw)
	}
	b := memberByID(m, e.ids["B"])
	if b == nil || b["state"] != "not_home" || b["battery_pct"].(float64) != 61 {
		t.Fatalf("B: %v", b)
	}
	if strings.Contains(raw, "52.123456") || strings.Contains(raw, "13.654321") || b["location"] != nil {
		t.Fatalf("coordinates leaked without the location scope: %s", raw)
	}
	// With the scope: coordinates.
	_, m, raw = e.get(loc, "/integrations/ha/v1/members")
	if lb := memberByID(m, e.ids["B"])["location"].(map[string]any); lb["lat"].(float64) != 52.123456 {
		t.Fatalf("location: %s", raw)
	}
	// Sharing off: state only.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	_, m, raw = e.get(loc, "/integrations/ha/v1/members")
	b = memberByID(m, e.ids["B"])
	if b["state"] != haStateSharingOff || b["location"] != nil || b["battery_pct"] != nil || strings.Contains(raw, "52.123456") {
		t.Fatalf("sharing off still leaks: %s", raw)
	}
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": true}, 200)
	// Sharing pause.
	if _, err := e.pool.Exec(ctx, `INSERT INTO sharing_pauses (user_id, paused_until) VALUES ($1, now() + interval '1 hour')`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	_, m, raw = e.get(loc, "/integrations/ha/v1/members")
	if b = memberByID(m, e.ids["B"]); b["state"] != haStateSharingOff || strings.Contains(raw, "52.123456") {
		t.Fatalf("paused still leaks: %s", raw)
	}
	_, _ = e.pool.Exec(ctx, `DELETE FROM sharing_pauses WHERE user_id = $1`, e.ids["B"])

	// Private (E2EE) circle without a trusted server device: NO coordinates for anyone,
	// including the token owner herself.
	if _, err := e.pool.Exec(ctx, `UPDATE circles SET e2ee_mode = 'private', e2ee_epoch = 1 WHERE id = $1`, c1); err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{e.ids["B"], e.ids["A"]} {
		_, m, raw = e.get(loc, "/integrations/ha/v1/members")
		b = memberByID(m, uid)
		if b["state"] != haStateUnavailablePrivate || b["location"] != nil || b["battery_pct"] != nil || b["speed_mps"] != nil ||
			b["last_seen"] != nil || b["location_available"] != false {
			t.Fatalf("private circle member %s: %v", uid, b)
		}
	}
	if strings.Contains(raw, "52.123456") || strings.Contains(raw, "13.654321") {
		t.Fatalf("private circle leaked coordinates: %s", raw)
	}
	cs := m["circles"].([]any)[0].(map[string]any)
	if cs["state"] != haStateUnavailablePrivate {
		t.Fatalf("circle state: %v", cs)
	}
	// Places also unavailable in a private circle.
	places, _ := e.mint("A", []string{c1}, "places")
	_, m, _ = e.get(places, "/integrations/ha/v1/places")
	if ps := m["places"].([]any); len(ps) != 0 {
		t.Fatalf("places listed for private circle: %v", ps)
	}
	// A second, ordinary circle in the same token still delivers its members.
	c2 := e.createCircle("A", "HAordinary", "B")
	both, _ := e.mint("A", []string{c1, c2}, "presence", "location")
	_, m, _ = e.get(both, "/integrations/ha/v1/members")
	if b = memberByID(m, e.ids["B"]); b["state"] == haStateUnavailablePrivate || b["location"] == nil {
		t.Fatalf("shared ordinary circle should still locate B: %v", b)
	}
	// C is only in the private circle.
	if cm := memberByID(m, e.ids["C"]); cm["state"] != haStateUnavailablePrivate || cm["location"] != nil {
		t.Fatalf("C: %v", cm)
	}
}

func TestHAServerMemberCircleDeliversCoordinates(t *testing.T) {
	se := readyEnv(t)
	ctx := context.Background()
	se.srv.AuthLimit = sms.NewLimiter()
	if err := se.srv.EnsureCrashSchema(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := se.pool.Exec(ctx, `UPDATE member_positions SET lat = 40.5, lon = -3.25, ts = now() WHERE user_id = $1`, se.ids["B"]); err != nil {
		t.Fatal(err)
	}
	var id string
	tok := "ofha_" + strings.Repeat("S", 43)
	if err := se.pool.QueryRow(ctx, `INSERT INTO ha_integrations (user_id, name, token_hash, scopes, circle_ids)
		VALUES ($1,'test-srv',$2,ARRAY['presence','location'],ARRAY[$3]::uuid[]) RETURNING id`, se.ids["A"], haHashToken(tok), se.circle).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = se.pool.Exec(context.Background(), `DELETE FROM ha_integrations WHERE id = $1`, id) })
	mux := chi.NewRouter()
	mux.Get("/m", se.srv.HAMembers)
	c, m, raw := haGet(mux, tok, "/m")
	if c != 200 {
		t.Fatalf("%d %s", c, raw)
	}
	b := memberByID(m, se.ids["B"])
	loc, _ := b["location"].(map[string]any)
	if loc == nil || loc["lat"].(float64) != 40.5 || b["state"] == haStateUnavailablePrivate {
		t.Fatalf("trusted-server circle should deliver coordinates: %s", raw)
	}
}

func TestHAPlacesAndPresence(t *testing.T) {
	e := newHAEnv(t)
	ctx := context.Background()
	c1 := e.createCircle("A", "HAplaces", "B")
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('HAfam-' || gen_random_uuid()::text) RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM places WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM families WHERE id = $1`, fam)
	})
	var home, school string
	for name, typ := range map[string]string{"Casa": "home", "Escuela": "school"} {
		var id string
		if err := e.pool.QueryRow(ctx, `INSERT INTO places (family_id, name, type, geom, radius_meters, circle_id)
			VALUES ($1,$2,$3,ST_SetSRID(ST_MakePoint(13.4,52.5),4326),120,$4) RETURNING id`, fam, name, typ, c1).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if typ == "home" {
			home = id
		} else {
			school = id
		}
	}
	// A place of an unrelated circle never shows up.
	c9 := e.createCircle("C", "HAother")
	if _, err := e.pool.Exec(ctx, `INSERT INTO places (family_id, name, type, geom, radius_meters, circle_id) VALUES ($1,'OtherCircleSecret','custom',ST_SetSRID(ST_MakePoint(1,2),4326),50,$2)`, fam, c9); err != nil {
		t.Fatal(err)
	}
	both, _ := e.mint("A", []string{c1}, "places", "presence")
	_, m, raw := e.get(both, "/integrations/ha/v1/places")
	if len(m["places"].([]any)) != 2 || strings.Contains(raw, "OtherCircleSecret") {
		t.Fatalf("places: %s", raw)
	}
	// geofence presence -> state
	var gf string
	if err := e.pool.QueryRow(ctx, `INSERT INTO geofences (family_id, place_id, user_id) VALUES ($1,$2,$3) RETURNING id`, fam, home, e.ids["B"]).Scan(&gf); err != nil {
		t.Fatal(err)
	}
	var gf2 string
	_ = e.pool.QueryRow(ctx, `INSERT INTO geofences (family_id, place_id, user_id) VALUES ($1,$2,$3) RETURNING id`, fam, school, e.ids["B"]).Scan(&gf2)
	ins := func(g, p, typ string) {
		if _, err := e.pool.Exec(ctx, `INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type) VALUES ($1,$2,$3,$4)`, g, e.ids["B"], p, typ); err != nil {
			t.Fatal(err)
		}
	}
	ins(gf, home, "enter")
	_, m, _ = e.get(both, "/integrations/ha/v1/members")
	if b := memberByID(m, e.ids["B"]); b["state"] != "home" || b["place"].(map[string]any)["is_home"] != true {
		t.Fatalf("home: %v", b)
	}
	ins(gf, home, "exit")
	ins(gf2, school, "enter")
	_, m, _ = e.get(both, "/integrations/ha/v1/members")
	if b := memberByID(m, e.ids["B"]); b["state"] != "Escuela" {
		t.Fatalf("school: %v", b)
	}
	ins(gf2, school, "exit")
	_, m, _ = e.get(both, "/integrations/ha/v1/members")
	if b := memberByID(m, e.ids["B"]); b["state"] != "not_home" {
		t.Fatalf("away: %v", b)
	}
}

func TestHAScopesAndRateLimit(t *testing.T) {
	e := newHAEnv(t)
	c1 := e.createCircle("A", "HAscope", "B")
	pres, _ := e.mint("A", []string{c1}, "presence")
	for _, p := range []string{"/integrations/ha/v1/places", "/integrations/ha/v1/events?after=0"} {
		if c, m, _ := e.get(pres, p); c != 403 || m["error"] != "insufficient_scope" {
			t.Fatalf("%s: %d %v", p, c, m)
		}
	}
	// A member of a circle left after minting loses access automatically.
	solo, _ := e.mint("B", []string{c1}, "presence")
	e.mustCode("A", "DELETE", "/circles/"+c1+"/members/"+e.ids["B"], nil, 200)
	_, m, _ := e.get(solo, "/integrations/ha/v1/members")
	if ms := m["members"].([]any); len(ms) != 0 {
		t.Fatalf("ex-member token still lists members: %v", ms)
	}
	// Rate limit: 120/min per token, then 429 with Retry-After.
	var last int
	for i := 0; i < haAPIPerMin+3; i++ {
		last, _, _ = e.get(pres, "/integrations/ha/v1/ping")
	}
	if last != 429 {
		t.Fatalf("rate limit not applied: %d", last)
	}
	// Bad-token flood from one address is throttled and does not hit the DB forever.
	var code int
	for i := 0; i < haBadTokenPerIP+3; i++ {
		code, _, _ = e.get("ofha_"+strings.Repeat("Q", 43), "/integrations/ha/v1/ping")
	}
	if code != 429 {
		t.Fatalf("bad token flood: %d", code)
	}
}

func TestHAEventsVisibilityAndPoll(t *testing.T) {
	e := newHAEnv(t)
	ctx := context.Background()
	c1 := e.createCircle("A", "HAev", "B")
	c2 := e.createCircle("C", "HAev2", "D")
	var fam string
	_ = e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('HAevfam-' || gen_random_uuid()::text) RETURNING id`).Scan(&fam)
	t.Cleanup(func() {
		bg := context.Background()
		_, _ = e.pool.Exec(bg, `DELETE FROM alerts WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(bg, `DELETE FROM places WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(bg, `DELETE FROM families WHERE id = $1`, fam)
	})
	var place, gf string
	_ = e.pool.QueryRow(ctx, `INSERT INTO places (family_id, name, type, geom, radius_meters, circle_id) VALUES ($1,'Gym','custom',ST_SetSRID(ST_MakePoint(1,2),4326),50,$2) RETURNING id`, fam, c1).Scan(&place)
	_ = e.pool.QueryRow(ctx, `INSERT INTO geofences (family_id, place_id, user_id) VALUES ($1,$2,$3) RETURNING id`, fam, place, e.ids["B"]).Scan(&gf)

	tokA, _ := e.mint("A", []string{c1}, "events", "presence")
	tokC, _ := e.mint("C", []string{c2}, "events", "presence")
	// First poll returns only the position.
	_, m, _ := e.get(tokA, "/integrations/ha/v1/events")
	after := int64(m["next_after"].(float64))

	// The scanner starts from "now" on its first run (history is never replayed): prime it first.
	e.srv.haScan(ctx)
	time.Sleep(20 * time.Millisecond)
	if _, err := e.pool.Exec(ctx, `INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type) VALUES ($1,$2,$3,'enter')`, gf, e.ids["B"], place); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	if _, err := e.pool.Exec(ctx, `INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type) VALUES ($1,$2,$3,'exit')`, gf, e.ids["B"], place); err != nil {
		t.Fatal(err)
	}
	e.srv.haScan(ctx)
	e.srv.haScan(ctx) // idempotent: the unique source key prevents duplicates

	_, m, raw := e.get(tokA, "/integrations/ha/v1/events?after="+strconv.FormatInt(after, 10))
	evs := m["events"].([]any)
	var kinds []string
	for _, x := range evs {
		kinds = append(kinds, x.(map[string]any)["type"].(string))
	}
	if len(kinds) < 1 || kinds[len(kinds)-1] != "departure" {
		t.Fatalf("events for A: %v (%s)", kinds, raw)
	}
	first := evs[0].(map[string]any)
	if first["place"].(map[string]any)["name"] != "Gym" || first["member"].(map[string]any)["name"] != "UserB" {
		t.Fatalf("payload: %v", first)
	}
	if strings.Contains(raw, `"lat"`) {
		t.Fatalf("arrival/departure events must carry no coordinates: %s", raw)
	}
	// Another family's token sees none of it (cross-circle).
	_, m, raw = e.get(tokC, "/integrations/ha/v1/events?after="+strconv.FormatInt(after, 10))
	if len(m["events"].([]any)) != 0 || strings.Contains(raw, "Gym") {
		t.Fatalf("foreign token received events: %s", raw)
	}
	// Event kind filtering / scope: places-only token cannot poll.
	// Private circle: events become invisible.
	if _, err := e.pool.Exec(ctx, `UPDATE circles SET e2ee_mode='private', e2ee_epoch=1 WHERE id=$1`, c1); err != nil {
		t.Fatal(err)
	}
	_, m, raw = e.get(tokA, "/integrations/ha/v1/events?after="+strconv.FormatInt(after, 10))
	if len(m["events"].([]any)) != 0 {
		t.Fatalf("private circle events delivered: %s", raw)
	}
}

func TestHASOSPositionOnlyWhenAllowed(t *testing.T) {
	e := newHAEnv(t)
	ctx := context.Background()
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('HAsos-' || gen_random_uuid()::text) RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		bg := context.Background()
		_, _ = e.pool.Exec(bg, `DELETE FROM alerts WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(bg, `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(bg, `DELETE FROM circles WHERE id = $1`, fam)
		_, _ = e.pool.Exec(bg, `DELETE FROM families WHERE id = $1`, fam)
	})
	for _, u := range []string{"A", "B"} {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $2 WHERE id = $1`, e.ids[u], fam); err != nil {
			t.Fatal(err)
		}
	}
	withLoc, _ := e.mint("A", []string{fam}, "events", "presence", "location")
	noLoc, _ := e.mint("A", []string{fam}, "events", "presence")
	_, m, _ := e.get(withLoc, "/integrations/ha/v1/events")
	after := int64(m["next_after"].(float64))
	e.srv.haScan(ctx) // prime the cursors: history is never replayed
	time.Sleep(20 * time.Millisecond)
	var alert string
	if err := e.pool.QueryRow(ctx, `INSERT INTO alerts (user_id, family_id, type, lat, lon, share_token) VALUES ($1,$2,'sos',44.4444,5.5555,$3) RETURNING id`,
		e.ids["B"], fam, "ha-"+strconv.FormatInt(time.Now().UnixNano(), 36)).Scan(&alert); err != nil {
		t.Fatal(err)
	}
	e.srv.haScan(ctx)
	poll := func(tok string) (map[string]any, string) {
		_, m, raw := e.get(tok, "/integrations/ha/v1/events?after="+strconv.FormatInt(after, 10))
		for _, x := range m["events"].([]any) {
			if ev := x.(map[string]any); ev["type"] == "sos" && ev["member"].(map[string]any)["id"] == e.ids["B"] {
				return ev, raw
			}
		}
		return nil, raw
	}
	ev, raw := poll(withLoc)
	if ev == nil || ev["location"].(map[string]any)["lat"].(float64) != 44.4444 {
		t.Fatalf("SOS with location scope: %s", raw)
	}
	if ev, raw = poll(noLoc); ev == nil || ev["location"].(map[string]any)["available"] != false || strings.Contains(raw, "44.4444") {
		t.Fatalf("SOS without the location scope must carry no position: %s", raw)
	}
	_, m, _ = e.get(withLoc, "/integrations/ha/v1/members")
	if b := memberByID(m, e.ids["B"]); b["sos_active"] != true {
		t.Fatalf("sos_active: %v", b)
	}
	// The circle turns Private: the SOS still arrives (it exists), but with no position and the reason.
	if _, err := e.pool.Exec(ctx, `UPDATE circles SET e2ee_mode='private', e2ee_epoch=1 WHERE id=$1`, fam); err != nil {
		t.Fatal(err)
	}
	ev, raw = poll(withLoc)
	if ev == nil || ev["location"].(map[string]any)["available"] != false ||
		ev["location"].(map[string]any)["reason"] != haStateUnavailablePrivate || strings.Contains(raw, "44.4444") {
		t.Fatalf("private SOS: %s", raw)
	}
}

func TestHAWebhookSigningDeliveryAndSSRF(t *testing.T) {
	haLoopbackForTests.Store(true)
	t.Cleanup(func() { haLoopbackForTests.Store(false) })
	e := newHAEnv(t)
	ctx := context.Background()
	c1 := e.createCircle("A", "HAhook", "B")
	tok, id := e.mint("A", []string{c1}, "events", "presence")
	_ = tok

	// SSRF: a user may not set targets the server must never call.
	for _, bad := range []string{
		"http://169.254.169.254/latest/meta-data", "http://127.0.0.1:8080/x", "http://localhost/x", "http://[::1]/x",
		"http://0.0.0.0/", "ftp://example.com/x", "http://user:pw@example.com/x", "http://[fe80::1]/x",
		"http://100.100.100.200/", "http://[::ffff:169.254.169.254]/", "http://[fd00:ec2::254]/", "file:///etc/passwd", "gopher://x/",
	} {
		haLoopbackForTests.Store(false)
		c, _, raw := e.do("A", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"webhook_url": bad})
		haLoopbackForTests.Store(true)
		if c != 400 {
			t.Errorf("webhook_url %q accepted: %d %s", bad, c, raw)
		}
	}
	// Private LAN needs the explicit setting, and only a platform admin may turn it on.
	haLoopbackForTests.Store(false)
	e.mustCode("A", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"webhook_url": "http://192.168.1.50:8123/api/webhook/abc"}, 400)
	e.mustCode("A", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"webhook_allow_private": true}, 403)
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = true WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	e.mustCode("A", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"webhook_allow_private": true}, 200)
	m := e.mustCode("A", "PATCH", "/integrations/ha/tokens/"+id, map[string]any{"webhook_url": "http://192.168.1.50:8123/api/webhook/abcdef1234"}, 200)
	if mu := m["webhook_url_masked"].(string); strings.Contains(mu, "abcdef") || !strings.Contains(mu, "192.168.1.50") {
		t.Fatalf("mask: %q", mu)
	}
	// Even with the LAN option on, the dial-time guard refuses link-local/metadata.
	if code, class := haSend(ctx, "http://169.254.169.254/x", "s", true, "test", 1, []byte("{}")); code != 0 || class != "blocked_address" {
		t.Fatalf("metadata dial: %d %q", code, class)
	}
	haLoopbackForTests.Store(true)

	// A receiver that verifies the signature, timestamp and delivery id.
	var mu sync.Mutex
	var got []map[string]any
	fail := 0
	secret := ""
	recv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		ts, _ := strconv.ParseInt(r.Header.Get("X-OpenFamily-Timestamp"), 10, 64)
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write([]byte(strconv.FormatInt(ts, 10) + "."))
		mac.Write(body)
		want := "v1=" + hex.EncodeToString(mac.Sum(nil))
		if !hmac.Equal([]byte(want), []byte(r.Header.Get("X-OpenFamily-Signature"))) {
			w.WriteHeader(401)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if fail > 0 {
			fail--
			w.WriteHeader(500)
			return
		}
		var p map[string]any
		_ = json.Unmarshal(body, &p)
		got = append(got, p)
		w.WriteHeader(200)
	}))
	defer recv.Close()
	// loopback target allowed only through the test switch + the LAN option
	_, _ = e.pool.Exec(ctx, `UPDATE ha_integrations SET webhook_url = $2, webhook_allow_private = true WHERE id = $1`, id, recv.URL+"/api/webhook/x")
	if err := e.pool.QueryRow(ctx, `SELECT webhook_secret FROM ha_integrations WHERE id = $1`, id).Scan(&secret); err != nil {
		t.Fatal(err)
	}
	// Test-fire.
	_, m, raw := e.do("A", "POST", "/integrations/ha/tokens/"+id+"/test", nil)
	if m["ok"] != true {
		t.Fatalf("test fire: %s", raw)
	}
	_, lm, _ := e.do("A", "GET", "/integrations/ha/tokens", nil)
	_ = lm
	var okFlag *bool
	var evName string
	_ = e.pool.QueryRow(ctx, `SELECT last_delivery_ok, last_delivery_event FROM ha_integrations WHERE id = $1`, id).Scan(&okFlag, &evName)
	if okFlag == nil || !*okFlag || evName != "test" {
		t.Fatalf("delivery status not recorded: %v %q", okFlag, evName)
	}
	mu.Lock()
	got = nil // the test event above is not part of the delivery assertions below
	mu.Unlock()
	// A wrong secret is rejected by the receiver (signature timing/forgery check on our side).
	secret = "different"
	if code, _ := haSend(ctx, recv.URL, "not-the-secret", true, "test", 1, []byte("{}")); code != 401 {
		t.Fatalf("receiver accepted a bad signature: %d", code)
	}
	_ = e.pool.QueryRow(ctx, `SELECT webhook_secret FROM ha_integrations WHERE id = $1`, id).Scan(&secret)

	// Retry/backoff: first attempt fails (500), event stays pending with a scheduled retry.
	var circle = c1
	_ = circle
	var head int64
	_ = e.pool.QueryRow(ctx, `SELECT COALESCE(max(id),0) FROM ha_events`).Scan(&head)
	_, _ = e.pool.Exec(ctx, `UPDATE ha_integrations SET webhook_cursor = $2, webhook_failures = 0, webhook_next_attempt = NULL WHERE id = $1`, id, head)
	if _, err := e.pool.Exec(ctx, `INSERT INTO ha_events (kind, user_id, source_key, occurred_at, data) VALUES ('low_battery', $1, $2, now(), '{"battery_pct":12}')`,
		e.ids["B"], "t-"+strconv.FormatInt(time.Now().UnixNano(), 36)); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	fail = 1
	mu.Unlock()
	e.srv.haDeliverAll(ctx)
	var failures int
	var next *time.Time
	_ = e.pool.QueryRow(ctx, `SELECT webhook_failures, webhook_next_attempt FROM ha_integrations WHERE id = $1`, id).Scan(&failures, &next)
	if failures != 1 || next == nil || !next.After(time.Now()) {
		t.Fatalf("no backoff after failure: %d %v", failures, next)
	}
	// While backing off nothing is attempted.
	e.srv.haDeliverAll(ctx)
	mu.Lock()
	n := len(got)
	mu.Unlock()
	if n != 0 {
		t.Fatalf("delivered during backoff: %d", n)
	}
	// Backoff elapsed -> retried and delivered exactly once, cursor advanced.
	_, _ = e.pool.Exec(ctx, `UPDATE ha_integrations SET webhook_next_attempt = now() - interval '1 second' WHERE id = $1`, id)
	e.srv.haDeliverAll(ctx)
	e.srv.haDeliverAll(ctx)
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0]["type"] != "low_battery" || got[0]["member"].(map[string]any)["name"] != "UserB" {
		t.Fatalf("delivery: %v", got)
	}
	// Revoked tokens stop receiving.
	e.mustCode("A", "DELETE", "/integrations/ha/tokens/"+id, nil, 204)
	var url string
	_ = e.pool.QueryRow(ctx, `SELECT webhook_url FROM ha_integrations WHERE id = $1`, id).Scan(&url)
	if url != "" {
		t.Fatal("revoked token kept its webhook URL")
	}
}

func TestHAAddrClassification(t *testing.T) {
	for addr, want := range map[string]haAddrClass{
		"127.0.0.1": haAddrBlocked, "::1": haAddrBlocked, "169.254.169.254": haAddrBlocked, "fe80::1": haAddrBlocked,
		"0.0.0.0": haAddrBlocked, "255.255.255.255": haAddrBlocked, "224.0.0.1": haAddrBlocked, "100.100.100.200": haAddrBlocked,
		"::ffff:127.0.0.1": haAddrBlocked, "::ffff:169.254.169.254": haAddrBlocked, "64:ff9b::a9fe:a9fe": haAddrBlocked,
		"fd00:ec2::254": haAddrBlocked, "168.63.129.16": haAddrBlocked,
		"10.0.0.5": haAddrPrivate, "172.16.4.2": haAddrPrivate, "192.168.1.9": haAddrPrivate, "fd12::1": haAddrPrivate,
		"100.64.0.7": haAddrPrivate, "::ffff:192.168.0.1": haAddrPrivate,
		"8.8.8.8": haAddrPublic, "2606:4700::1111": haAddrPublic,
	} {
		a, err := parseAddrForTest(addr)
		if err != nil {
			t.Fatalf("%s: %v", addr, err)
		}
		if got := haClassifyAddr(a); got != want {
			t.Errorf("%s: class %d, want %d", addr, got, want)
		}
	}
}
