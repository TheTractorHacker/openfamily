package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
	"github.com/jackc/pgx/v5/pgxpool"
)

func fp(v float64) *float64 { return &v }

func TestIsStationaryFix(t *testing.T) {
	cases := []struct {
		name       string
		dist       float64
		speed, acc *float64
		stationary bool
	}{
		{"parked jitter", 3, nil, nil, true},
		{"parked speed 0", 3, fp(0), fp(5), true},
		{"walking pace below threshold, small move", 4, fp(1.4), nil, true},
		{"driving slowly in traffic, tiny move", 2, fp(2.5), nil, false},
		{"driving fast", 40, fp(30), nil, false},
		{"moved a few meters no speed", 12, nil, fp(5), false},
		{"noisy fix widens radius", 18, fp(0.2), fp(20), true},
		{"noisy fix radius capped", 30, fp(0.2), fp(100), false},
		{"moving speed overrides noisy radius", 18, fp(5), fp(20), false},
	}
	for _, c := range cases {
		if got := isStationaryFix(c.dist, c.speed, c.acc); got != c.stationary {
			t.Errorf("%s: got %v want %v", c.name, got, c.stationary)
		}
	}
}

// 1 Hz sustained (and a 5x burst) must fit the per-user ingest budget, while a
// runaway loop is still stopped.
func TestIngestBudgetFitsOneHz(t *testing.T) {
	if ingestPerWindow < 60*3 {
		t.Fatalf("ingestPerWindow=%d too low for 1 Hz + retries", ingestPerWindow)
	}
	l := sms.NewLimiter()
	allowed := 0
	for i := 0; i < ingestPerWindow*2; i++ {
		if l.Allow("loc:u", ingestPerWindow, ingestWindow) {
			allowed++
		}
	}
	if allowed != ingestPerWindow {
		t.Fatalf("allowed %d, want exactly %d (loop must be stopped)", allowed, ingestPerWindow)
	}
	if batchRateLimit < 30 {
		t.Fatalf("batchRateLimit=%d too low for offline drains", batchRateLimit)
	}
}

func TestLiveWatchRegistryCoalescing(t *testing.T) {
	g := newLiveWatchRegistry()
	t0 := time.Unix(1000, 0)
	if !g.touch("v1", "t", t0) {
		t.Fatal("first watch must send a command")
	}
	for i := 0; i < 20; i++ { // many watchers, same instant
		if g.touch("viewer"+string(rune('a'+i)), "t", t0.Add(time.Second)) {
			t.Fatal("coalesced: no second command")
		}
	}
	if !g.boosted("t", t0.Add(10*time.Second)) {
		t.Fatal("should be boosted")
	}
	if g.touch("v1", "t", t0.Add(15*time.Second)) {
		t.Fatal("renewal within ttl must not resend")
	}
	// Watch kept alive by renewals: command refreshed once the old one nears expiry.
	if !g.touch("v1", "t", t0.Add(46*time.Second)) {
		t.Fatal("refresh expected after liveBoostRefreshAfter")
	}
	// Lapse, then a fresh watch sends a new command.
	g2 := newLiveWatchRegistry()
	g2.touch("v", "t", t0)
	if g2.boosted("t", t0.Add(liveWatchTTL+time.Second)) {
		t.Fatal("boost must lapse after ttl")
	}
	if !g2.touch("v", "t", t0.Add(liveWatchTTL+liveBoostMinInterval)) {
		t.Fatal("lapsed boost should send a new command")
	}
	if g.boosted("other", t0) {
		t.Fatal("unrelated target boosted")
	}
}

type cmdRecorder struct {
	mu   sync.Mutex
	sent []string // "target:body"
}

func (c *cmdRecorder) send(_ context.Context, user string, body []byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, user+":"+string(body))
	return true
}

func (c *cmdRecorder) wait(t *testing.T, n int) []string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		got := len(c.sent)
		c.mu.Unlock()
		if got >= n {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond) // let any unexpected extra land
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.sent...)
}

func liveEnv(t *testing.T) (*circleEnv, *cmdRecorder) {
	e := newCircleEnv(t)
	rec := &cmdRecorder{}
	e.srv.liveWatch = newLiveWatchRegistry()
	e.srv.liveBoostSend = rec.send
	e.rt.Post("/locations/watch", e.srv.WatchMember)
	e.rt.Post("/locations", e.srv.IngestLocation)
	return e, rec
}

func TestWatchAuthzMatrix(t *testing.T) {
	e, rec := liveEnv(t)
	// A,B,E in c1; B,C in c2; D in none.
	c1 := e.createCircle("A", "C1", "B", "E")
	c2 := e.createCircle("C", "C2", "B")

	watch := func(who, target, circle string) (int, map[string]any) {
		body := map[string]any{"user_id": e.ids[target]}
		if circle != "" {
			body["circle_id"] = circle
		}
		code, m, _ := e.do(who, "POST", "/locations/watch", body)
		return code, m
	}

	if code, m := watch("A", "B", ""); code != 200 || m["status"] != "watching" || m["ttl_s"].(float64) != 45 {
		t.Fatalf("A->B: %d %v", code, m)
	}
	if code, m := watch("E", "B", c1); code != 200 {
		t.Fatalf("E->B with circle: %d %v", code, m)
	}
	// Different-circle member cannot watch.
	if code, _ := watch("C", "A", ""); code != 404 {
		t.Fatalf("C->A (no shared circle) = %d, want 404", code)
	}
	// Outsider.
	if code, _ := watch("D", "B", ""); code != 404 {
		t.Fatalf("D->B = %d, want 404", code)
	}
	// Shared circle exists but circle_id names a circle the viewer is not in / target not in.
	if code, _ := watch("A", "B", c2); code != 404 {
		t.Fatalf("A->B via c2 (A not a member) = %d, want 404", code)
	}
	// Garbage ids are uniformly 404 / 400.
	if code, m, _ := e.do("A", "POST", "/locations/watch", map[string]any{"user_id": "not-a-uuid"}); code != 404 {
		t.Fatalf("bad id = %d %v, want 404", code, m)
	}
	if code, _, _ := e.do("A", "POST", "/locations/watch", map[string]any{}); code != 400 {
		t.Fatalf("missing user_id = %d, want 400", code)
	}
	// Self watch: ok, no boost, no command.
	if code, m := watch("A", "A", ""); code != 200 || m["status"] != "self" {
		t.Fatalf("self: %d %v", code, m)
	}
	if e.srv.liveBoosted(e.ids["A"]) {
		t.Fatal("self-watch must not boost")
	}

	// Two watchers on B (A and E) produced exactly one command, no coordinates.
	sent := rec.wait(t, 1)
	if len(sent) != 1 {
		t.Fatalf("commands=%v, want exactly 1", sent)
	}
	want := e.ids["B"] + `:{"type":"live_boost","ttl_s":60}`
	if sent[0] != want {
		t.Fatalf("command %q, want %q", sent[0], want)
	}
	if !e.srv.liveBoosted(e.ids["B"]) || e.srv.liveBoosted(e.ids["C"]) {
		t.Fatal("boost state wrong")
	}

	// B pauses sharing: nobody may boost B any more (E gets refused).
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	if code, _ := watch("E", "B", ""); code != 404 {
		t.Fatalf("watch of paused member = %d, want 404", code)
	}
	// ...but B can still be watched via c2 if sharing there (A not in c2, C is).
	if code, _ := watch("C", "B", ""); code != 200 {
		t.Fatalf("C->B via c2 = %d, want 200", code)
	}
}

func TestWatchRateLimited(t *testing.T) {
	e, _ := liveEnv(t)
	e.srv.LocationLimit = sms.NewLimiter()
	e.createCircle("A", "C1", "B")
	var last int
	for i := 0; i <= watchPerWindow; i++ {
		last, _, _ = e.do("A", "POST", "/locations/watch", map[string]any{"user_id": e.ids["B"]})
	}
	if last != 429 {
		t.Fatalf("got %d, want 429", last)
	}
}

type ingestBody = map[string]any

func (e *circleEnv) ingest(user, device string, b ingestBody) (int, map[string]any) {
	b["device_id"] = device
	code, m, _ := e.do(user, "POST", "/locations", b)
	return code, m
}

func TestIngestMovingNotDedupedAndOrdering(t *testing.T) {
	e, _ := liveEnv(t)
	ctx := context.Background()
	a := e.ids["A"]
	e.legacyFamily("LiveFam", "A", "B")
	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1,'android','t') RETURNING id`, a).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `DELETE FROM member_positions WHERE user_id=$1`, a); err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-2 * time.Minute).UTC()
	ts := func(sec int) string { return base.Add(time.Duration(sec) * time.Second).Format(time.RFC3339Nano) }
	lat := func(m float64) float64 { return 40.0 + m/111320.0 }

	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(0), "lat": lat(0), "lon": -75.0, "speed_mps": 0.0}); c != 201 {
		t.Fatalf("first: %d %v", c, m)
	}
	// Stationary jitter: collapsed.
	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(1), "lat": lat(3), "lon": -75.0, "speed_mps": 0.1}); c != 200 || m["status"] != "deduplicated" {
		t.Fatalf("stationary: %d %v", c, m)
	}
	// Slow traffic: 2 m move but 3 m/s reported -> stored every time.
	for i := 0; i < 5; i++ {
		c, m := e.ingest("A", dev, ingestBody{"ts": ts(2 + i), "lat": lat(float64(5 + 2*i)), "lon": -75.0, "speed_mps": 3.0, "heading_deg": 90.0 + float64(i)})
		if c != 201 {
			t.Fatalf("moving fix %d: %d %v (must be stored)", i, c, m)
		}
		if m["heading_deg"].(float64) != 90+float64(i) {
			t.Fatalf("ack heading: %v", m)
		}
	}
	// Moved well beyond the radius with no speed: stored.
	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(10), "lat": lat(200), "lon": -75.0, "heading_deg": 12.5}); c != 201 {
		t.Fatalf("moved: %d %v", c, m)
	}
	var rows int
	e.pool.QueryRow(ctx, `SELECT count(*) FROM locations WHERE device_id=$1`, dev).Scan(&rows)
	if rows != 7 {
		t.Fatalf("stored rows=%d, want 7 (1 first + 5 slow-moving + 1 moved; 1 stationary collapsed)", rows)
	}

	// Out-of-order: an older fix is rejected and cannot move the pin back.
	if c, _ := e.ingest("A", dev, ingestBody{"ts": ts(5), "lat": lat(1000), "lon": -75.0}); c != 400 {
		t.Fatalf("older fix status %d, want 400", c)
	}
	var gotLat float64
	var head *float64
	e.pool.QueryRow(ctx, `SELECT lat, heading_deg FROM member_positions WHERE user_id=$1`, a).Scan(&gotLat, &head)
	if gotLat != lat(200) || head == nil || *head != 12.5 {
		t.Fatalf("pin moved backwards or heading lost: lat=%v heading=%v", gotLat, head)
	}

	// Heading is on the members snapshot (REST), additive.
	_, _, raw := e.do("A", "GET", "/family/members", nil)
	var members []map[string]any
	_ = json.Unmarshal(raw, &members)
	found := false
	for _, mm := range members {
		if mm["id"] == a {
			found = true
			if mm["heading_deg"] != 12.5 {
				t.Fatalf("members heading_deg=%v", mm["heading_deg"])
			}
		}
	}
	if !found {
		t.Fatalf("A not in members list: %s", raw)
	}

	// Wrong owner / unknown device keep their status codes.
	if c, _ := e.ingest("B", dev, ingestBody{"ts": ts(30), "lat": 1.0, "lon": 1.0}); c != 403 {
		t.Fatalf("foreign device = %d, want 403", c)
	}
	if c, _ := e.ingest("A", "00000000-0000-0000-0000-000000000000", ingestBody{"lat": 1.0, "lon": 1.0}); c != 404 {
		t.Fatalf("unknown device = %d, want 404", c)
	}

	// live flag: absent until watched, true afterwards.
	if _, m := e.ingest("A", dev, ingestBody{"ts": ts(40), "lat": lat(400), "lon": -75.0, "speed_mps": 10.0}); m["live"] != nil {
		t.Fatalf("live present before watch: %v", m)
	}
	e.mustCode("B", "POST", "/locations/watch", map[string]any{"user_id": a}, 200)
	if _, m := e.ingest("A", dev, ingestBody{"ts": ts(41), "lat": lat(420), "lon": -75.0, "speed_mps": 10.0}); m["live"] != true {
		t.Fatalf("live missing after watch: %v", m)
	}
	// ...also on the stationary 200 path.
	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(42), "lat": lat(420), "lon": -75.0, "speed_mps": 0.0}); c != 200 || m["live"] != true {
		t.Fatalf("dedup live: %d %v", c, m)
	}
}

func TestWSLocationFrameHasHeading(t *testing.T) {
	b, _ := json.Marshal(wsLocation{Type: "location", HeadingDeg: fp(271.5)})
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if m["heading_deg"] != 271.5 {
		t.Fatalf("frame: %s", b)
	}
	b, _ = json.Marshal(wsLocation{Type: "location"})
	_ = json.Unmarshal(b, &m)
	if v, ok := m["heading_deg"]; !ok || v != nil {
		t.Fatalf("heading_deg must be present and null when unknown: %s", b)
	}
}

// BenchmarkIngestMoving measures the full POST /locations handler (device
// check + lock, stored insert, member_positions upsert, heartbeat, async
// geofence + broadcast submit) against real Postgres for a moving fix, the
// 1 Hz hot path. Needs TEST_DATABASE_URL (throwaway database).
func BenchmarkIngestMoving(b *testing.B) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		b.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		b.Fatal(err)
	}
	defer pool.Close()
	var uid, dev string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'Bench','x') RETURNING id`,
		"bench-"+time.Now().Format("150405.000000")+"@example.com").Scan(&uid); err != nil {
		b.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)
	if err := pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, uid).Scan(&dev); err != nil {
		b.Fatal(err)
	}
	srv := &Server{Pool: pool, hub: newHub(), LocationLimit: sms.NewLimiter()}
	srv.LocationLimit = nil
	base := time.Now().Add(-5 * time.Minute)
	claims := &auth.Claims{UserID: uid}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		body, _ := json.Marshal(map[string]any{
			"device_id": dev, "ts": base.Add(time.Duration(i+1) * 10 * time.Millisecond),
			"lat": 40.0 + float64(i%1000)*0.0001 + float64(i/1000)*0.5, "lon": -75.0, "speed_mps": 20.0, "heading_deg": 90.0,
		})
		req := httptest.NewRequest(http.MethodPost, "/locations", bytes.NewReader(body))
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), claims))
		rec := httptest.NewRecorder()
		srv.IngestLocation(rec, req)
		if rec.Code != 201 {
			b.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
	}
}
