package handlers

import (
	"net/http"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

// Need TEST_DATABASE_URL (skipped otherwise), like checkins_db_test.go.
// fx.a is the creator, fx.b the subject (it has a push endpoint), fx.c a bystander.

func newBubbleRouter(fx *alertFixture) http.Handler {
	r := chi.NewRouter()
	r.Post("/bubbles", fx.srv.CreateBubble)
	r.Get("/bubbles", fx.srv.ListBubbles)
	r.Delete("/bubbles/{id}", fx.srv.DeleteBubble)
	r.Put("/sharing/pause", fx.srv.SetSharingPause)
	r.Delete("/sharing/pause", fx.srv.ClearSharingPause)
	return r
}

func bubbleSetPos(t *testing.T, fx *alertFixture, uid string, lat, lon float64, age string) {
	t.Helper()
	if _, err := fx.pool.Exec(context.Background(), `
		INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, $2, $3, now() - $4::interval)
		ON CONFLICT (user_id) DO UPDATE SET lat = EXCLUDED.lat, lon = EXCLUDED.lon, ts = EXCLUDED.ts`,
		uid, lat, lon, age); err != nil {
		t.Fatal(err)
	}
}

func (fx *alertFixture) pushTitles() []string {
	fx.push.mu.Lock()
	defer fx.push.mu.Unlock()
	var out []string
	for _, n := range fx.push.sent {
		out = append(out, n.Title+"|"+n.Body)
	}
	return out
}

func waitPushes(t *testing.T, fx *alertFixture, n int) []string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if got := fx.pushTitles(); len(got) >= n {
			return got
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fx.pushTitles()
}

func TestBubbleCreateAuthorization(t *testing.T) {
	fx := newAlertFixture(t)
	h := newBubbleRouter(fx)
	bubbleSetPos(t, fx, fx.b, 51.5, -0.12, "0 seconds")

	good := map[string]any{"subject_id": fx.b, "radius_m": 200, "duration_minutes": 60}
	with := func(k string, v any) map[string]any {
		m := map[string]any{}
		for kk, vv := range good {
			m[kk] = vv
		}
		m[k] = v
		return m
	}
	for name, body := range map[string]map[string]any{
		"radius low":  with("radius_m", 49),
		"radius high": with("radius_m", 5001),
		"short":       with("duration_minutes", 5),
		"long":        with("duration_minutes", 1441),
		"self":        with("subject_id", fx.a),
		"bad id":      with("subject_id", "nope"),
	} {
		if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, body); code != 400 {
			t.Fatalf("%s: %d", name, code)
		}
	}
	// Outsider (other family): uniform 404.
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, with("subject_id", fx.x)); code != 404 {
		t.Fatalf("outsider: %d", code)
	}
	// No position yet for c.
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, with("subject_id", fx.c)); code != 409 {
		t.Fatalf("no position: %d", code)
	}
	// Stale position.
	bubbleSetPos(t, fx, fx.c, 10, 10, "2 hours")
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, with("subject_id", fx.c)); code != 409 {
		t.Fatalf("stale position: %d", code)
	}

	code, b := callJSON(t, h, "POST", "/bubbles", fx.a, good)
	if code != 201 || b["lat"] != 51.5 || b["radius_m"] != 200.0 {
		t.Fatalf("create: %d %v", code, b)
	}
	id, _ := b["id"].(string)

	// Subject is told, without coordinates; the creator is named only if verbose.
	got := waitPushes(t, fx, 1)
	if len(got) != 1 || !strings.Contains(got[0], "created a Bubble around you until") || strings.Contains(got[0], "51.5") {
		t.Fatalf("subject push: %v", got)
	}
	if strings.Contains(got[0], "a Tester") {
		t.Fatalf("creator name leaked without VERBOSE_PUSH: %v", got)
	}

	// Creator sees geometry; subject sees existence only; bystander sees nothing.
	_, l := callJSON(t, h, "GET", "/bubbles", fx.a, nil)
	if bs, _ := l["bubbles"].([]any); len(bs) != 1 {
		t.Fatalf("creator list: %v", l)
	}
	_, l = callJSON(t, h, "GET", "/bubbles", fx.b, nil)
	am, _ := l["about_me"].([]any)
	if bs, _ := l["bubbles"].([]any); len(bs) != 0 || len(am) != 1 {
		t.Fatalf("subject list: %v", l)
	}
	if m := am[0].(map[string]any); m["lat"] != nil || m["lon"] != nil || m["radius_m"] != nil {
		t.Fatalf("subject must not get geometry: %v", m)
	}
	_, l = callJSON(t, h, "GET", "/bubbles", fx.c, nil)
	if bs, _ := l["bubbles"].([]any); len(bs) != 0 {
		t.Fatalf("bystander: %v", l)
	}
	// Only the creator can cancel.
	for _, uid := range []string{fx.b, fx.c, fx.x} {
		if code, _ := callJSON(t, h, "DELETE", "/bubbles/"+id, uid, nil); code != 404 {
			t.Fatalf("non-creator delete %s: %d", uid, code)
		}
	}
	// Re-creating replaces the previous one for the same pair.
	callJSON(t, h, "POST", "/bubbles", fx.a, good)
	_, l = callJSON(t, h, "GET", "/bubbles", fx.a, nil)
	if bs, _ := l["bubbles"].([]any); len(bs) != 1 || bs[0].(map[string]any)["id"] == id {
		t.Fatalf("replace: %v", l)
	}
	for _, x := range l["bubbles"].([]any) {
		if code, _ := callJSON(t, h, "DELETE", "/bubbles/"+x.(map[string]any)["id"].(string), fx.a, nil); code != 200 {
			t.Fatalf("delete: %d", code)
		}
	}
}

func TestBubblePausedSubject(t *testing.T) {
	fx := newAlertFixture(t)
	h := newBubbleRouter(fx)
	bubbleSetPos(t, fx, fx.b, 51.5, -0.12, "0 seconds")
	callJSON(t, h, "PUT", "/sharing/pause", fx.b, map[string]any{"minutes": 60})
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, map[string]any{"subject_id": fx.b, "radius_m": 100, "duration_minutes": 30}); code != 404 {
		t.Fatalf("create on paused subject: %d", code)
	}
	callJSON(t, h, "DELETE", "/sharing/pause", fx.b, nil)
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, map[string]any{"subject_id": fx.b, "radius_m": 100, "duration_minutes": 30}); code != 201 {
		t.Fatalf("create after resume: %d", code)
	}
	waitPushes(t, fx, 1)
	before := len(fx.pushTitles())

	// Subject pauses, then moves far away: no alert and no state change.
	callJSON(t, h, "PUT", "/sharing/pause", fx.b, map[string]any{"minutes": 60})
	fx.srv.evaluateBubbles(context.Background(), fx.b, -0.12+0.1, 51.5, time.Now())
	time.Sleep(100 * time.Millisecond)
	if n := len(fx.pushTitles()); n != before {
		t.Fatalf("alert while paused: %v", fx.pushTitles())
	}
	var inside bool
	if err := fx.pool.QueryRow(context.Background(), `SELECT last_inside FROM bubbles WHERE subject_id = $1`, fx.b).Scan(&inside); err != nil || !inside {
		t.Fatalf("state changed while paused: %v %v", inside, err)
	}
}

func TestBubbleTransitionAlerts(t *testing.T) {
	fx := newAlertFixture(t)
	h := newBubbleRouter(fx)
	ctx := context.Background()
	// The creator (a) gets alerts: give a an endpoint.
	if _, err := fx.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/a')`, fx.a); err != nil {
		t.Fatal(err)
	}
	bubbleSetPos(t, fx, fx.b, 51.5, -0.12, "0 seconds")
	code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, map[string]any{"subject_id": fx.b, "radius_m": 500, "duration_minutes": 60})
	if code != 201 {
		t.Fatalf("create: %d", code)
	}
	waitPushes(t, fx, 1)
	creatorPushes := func() []string {
		fx.push.mu.Lock()
		defer fx.push.mu.Unlock()
		var out []string
		for _, n := range fx.push.sent {
			if n.UnifiedPushEndpoint == "https://ntfy.example/a" {
				out = append(out, n.Title)
			}
		}
		return out
	}
	eval := func(dLon float64) {
		fx.srv.evaluateBubbles(ctx, fx.b, -0.12+dLon, 51.5, time.Now())
	}
	// ~0.001 deg lon at 51.5N is ~70 m; 0.01 is ~700 m.
	eval(0.001) // inside
	eval(0.003) // ~210 m, still inside
	time.Sleep(100 * time.Millisecond)
	if n := creatorPushes(); len(n) != 0 {
		t.Fatalf("alert while inside: %v", n)
	}
	eval(0.01) // left
	eval(0.011)
	eval(0.012) // still outside: no repeat
	time.Sleep(200 * time.Millisecond)
	n := creatorPushes()
	if len(n) != 1 || !strings.Contains(n[0], "left their Bubble") {
		t.Fatalf("leave alert: %v", n)
	}
	// Re-entry is silent unless asked for.
	eval(0)
	time.Sleep(100 * time.Millisecond)
	if n := creatorPushes(); len(n) != 1 {
		t.Fatalf("re-enter should be silent: %v", n)
	}
	// Leave again, now with re-enter alerts on.
	if _, err := fx.pool.Exec(ctx, `UPDATE bubbles SET notify_reenter = TRUE WHERE subject_id = $1`, fx.b); err != nil {
		t.Fatal(err)
	}
	eval(0.01)
	eval(0.005) // ~350 m: inside the radius but outside 90%? 350 < 450 -> inside
	time.Sleep(200 * time.Millisecond)
	n = creatorPushes()
	if len(n) != 3 || !strings.Contains(n[2], "entered their Bubble") {
		t.Fatalf("re-enter alert: %v", n)
	}
	// Coordinates never appear in any payload.
	for _, s := range fx.pushTitles() {
		if strings.Contains(s, "51.5") || strings.Contains(s, "-0.12") {
			t.Fatalf("coordinates in push: %s", s)
		}
	}
	// A point from before the Bubble existed is ignored.
	if _, err := fx.pool.Exec(ctx, `UPDATE bubbles SET last_inside = TRUE WHERE subject_id = $1`, fx.b); err != nil {
		t.Fatal(err)
	}
	fx.srv.evaluateBubbles(ctx, fx.b, 0.5, 51.5, time.Now().Add(-time.Hour))
	time.Sleep(100 * time.Millisecond)
	if n := creatorPushes(); len(n) != 3 {
		t.Fatalf("old point alerted: %v", n)
	}
}

func TestBubbleExpiry(t *testing.T) {
	fx := newAlertFixture(t)
	h := newBubbleRouter(fx)
	ctx := context.Background()
	bubbleSetPos(t, fx, fx.b, 51.5, -0.12, "0 seconds")
	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, map[string]any{"subject_id": fx.b, "radius_m": 100, "duration_minutes": 60}); code != 201 {
		t.Fatal("create")
	}
	if _, err := fx.pool.Exec(ctx, `UPDATE bubbles SET expires_at = now() - interval '1 second' WHERE creator_id = $1`, fx.a); err != nil {
		t.Fatal(err)
	}
	// Not served, and never alerts, even before the purge runs.
	_, l := callJSON(t, h, "GET", "/bubbles", fx.a, nil)
	if bs, _ := l["bubbles"].([]any); len(bs) != 0 {
		t.Fatalf("expired served: %v", l)
	}
	if am, _ := l["about_me"].([]any); len(am) != 0 {
		t.Fatalf("expired served: %v", l)
	}
	before := len(fx.pushTitles())
	fx.srv.evaluateBubbles(ctx, fx.b, 5, 51.5, time.Now())
	time.Sleep(100 * time.Millisecond)
	if len(fx.pushTitles()) != before {
		t.Fatal("expired bubble alerted")
	}
	// The background pass deletes it.
	fx.srv.purgeExpiredBubbles(ctx)
	var n int
	if err := fx.pool.QueryRow(ctx, `SELECT count(*) FROM bubbles WHERE creator_id = $1`, fx.a).Scan(&n); err != nil || n != 0 {
		t.Fatalf("purge: %d %v", n, err)
	}
}

func TestBubbleInsideHysteresis(t *testing.T) {
	if !bubbleInside(true, 100, 100) || bubbleInside(true, 101, 100) {
		t.Fatal("leave threshold")
	}
	if bubbleInside(false, 95, 100) || !bubbleInside(false, 90, 100) {
		t.Fatal("re-enter threshold")
	}
	if d := haversineM(51.5, -0.12, 51.5, -0.12+0.01); d < 650 || d > 750 {
		t.Fatalf("haversine: %f", d)
	}
}
