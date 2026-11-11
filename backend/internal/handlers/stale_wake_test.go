package handlers

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"
)

func TestStaleWakeOutageRule(t *testing.T) {
	cases := []struct {
		name               string
		candidates, active int
		want               bool
	}{
		{"one quiet phone is normal", 1, 3, false},
		{"four quiet phones are below the floor", 4, 4, false},
		{"five of five at once is an outage", 5, 5, true},
		{"five of ten is an outage", 5, 10, true},
		{"five of a hundred is not", 5, 100, false},
	}
	for _, c := range cases {
		if got := staleWakeOutage(c.candidates, c.active); got != c.want {
			t.Errorf("%s: staleWakeOutage(%d, %d) = %v, want %v", c.name, c.candidates, c.active, got, c.want)
		}
	}
}

func TestStaleWakeCommandIsTheExistingLocationRequest(t *testing.T) {
	// The phone's handler (LocationRefreshCommand.parse) only accepts this shape: pin that the worker reuses it.
	body, cmd, err := encodeLocationRequestCommand("rid", time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	if m["type"] != "location_request" || cmd.ExpiresAt.Sub(cmd.RequestedAt) > time.Minute {
		t.Fatalf("unexpected command %v", m)
	}
}

// One quiet phone is asked once per cooldown, only if it is the member's newest Android device, sharing and not
// paused; fresh phones, old drawer phones, paused members and iPhones are never asked; after the unanswered limit it
// stops until the phone reports again; every ask is recorded on the device row.
func TestStaleWakeAsksOnlyTheQuietNewestDevice(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	exec := func(q string, a ...any) {
		t.Helper()
		if _, err := fx.pool.Exec(ctx, q, a...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	id := func(q string, a ...any) string {
		t.Helper()
		var s string
		if err := fx.pool.QueryRow(ctx, q, a...).Scan(&s); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
		return s
	}
	now := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	mk := func(user, platform, endpoint string, seen time.Time) string {
		return id(`INSERT INTO devices (user_id, platform, unifiedpush_endpoint, last_seen) VALUES ($1,$2,$3,$4) RETURNING id::text`,
			user, platform, endpoint, seen)
	}
	// The fixture already gave b an Android device; make it the quiet newest one.
	quiet := id(`SELECT id::text FROM devices WHERE user_id = $1`, fx.b)
	exec(`UPDATE devices SET last_seen = $2 WHERE id = $1`, quiet, ago(30*time.Minute))
	// b's older phone in a drawer: quieter still, but not the newest.
	drawer := mk(fx.b, "android", "https://ntfy.example/drawer", ago(5*time.Hour))
	// c reports fine.
	fresh := mk(fx.c, "android", "https://ntfy.example/c", ago(3*time.Minute))
	// d is quiet but paused his sharing.
	paused := mk(fx.d, "android", "https://ntfy.example/d", ago(40*time.Minute))
	exec(`INSERT INTO sharing_pauses (user_id, paused_until) VALUES ($1, $2)`, fx.d, now.Add(time.Hour))
	// a is quiet but an iPhone (never woken by this worker) and another user is quiet without any push route.
	ios := mk(fx.a, "ios", "", ago(40*time.Minute))
	noRoute := mk(fx.x, "android", "", ago(40*time.Minute))
	mine := map[string]string{quiet: "quiet", drawer: "drawer", fresh: "fresh", paused: "paused", ios: "ios", noRoute: "noRoute"}

	var mu sync.Mutex
	var asked []string
	fx.srv.staleWakeSend = func(_ context.Context, body []byte, d staleWakeDevice) bool {
		var cmd map[string]any
		if err := json.Unmarshal(body, &cmd); err != nil || cmd["type"] != "location_request" {
			t.Errorf("not a location request: %s", body)
		}
		mu.Lock()
		defer mu.Unlock()
		if name, ok := mine[d.id]; ok {
			asked = append(asked, name)
		}
		return true
	}
	run := func(at time.Time) []string {
		t.Helper()
		exec(`UPDATE devices SET last_seen = $2 WHERE id = $1`, fresh, at.Add(-3*time.Minute)) // c keeps reporting
		mu.Lock()
		asked = nil
		mu.Unlock()
		if _, err := fx.srv.RunStaleWakeOnce(ctx, at); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), asked...)
	}
	want := func(step string, got []string, names ...string) {
		t.Helper()
		if len(got) != len(names) || (len(names) == 1 && got[0] != names[0]) {
			t.Fatalf("%s: asked %v, want %v", step, got, names)
		}
	}

	want("first run", run(now), "quiet")
	var count int
	var at *time.Time
	if err := fx.pool.QueryRow(ctx, `SELECT stale_wake_count, last_stale_wake_at FROM devices WHERE id = $1`, quiet).Scan(&count, &at); err != nil || count != 1 || at == nil {
		t.Fatalf("not recorded: %d %v %v", count, at, err)
	}
	want("inside the cooldown", run(now.Add(10*time.Minute)))
	want("after the cooldown", run(now.Add(16*time.Minute)), "quiet")

	// Unanswered asks stop at the limit.
	at2 := now.Add(16 * time.Minute)
	for i := 2; i < staleWakeMaxUnanswered; i++ {
		at2 = at2.Add(16 * time.Minute)
		want("unanswered ask", run(at2), "quiet")
	}
	at2 = at2.Add(16 * time.Minute)
	want("past the limit", run(at2))

	// The phone reports (last_seen moves past the last ask) and goes quiet again: it is asked again, count restarts.
	lastAsk := at2.Add(-16 * time.Minute)
	exec(`UPDATE devices SET last_seen = $2 WHERE id = $1`, quiet, lastAsk.Add(time.Minute))
	at2 = lastAsk.Add(17 * time.Minute)
	want("after it reported and went quiet again", run(at2), "quiet")
	if err := fx.pool.QueryRow(ctx, `SELECT stale_wake_count FROM devices WHERE id = $1`, quiet).Scan(&count); err != nil || count != 1 {
		t.Fatalf("count after a report = %d (%v), want 1", count, err)
	}

	// Quiet for longer than the give-up window: left alone.
	exec(`UPDATE devices SET last_seen = $2, last_stale_wake_at = NULL, stale_wake_count = 0 WHERE id = $1`, quiet, at2.Add(-staleWakeGiveUp-time.Hour))
	// (The drawer phone is now the member's newest device, and is quiet, so it is the one asked.)
	want("abandoned phone", run(at2.Add(time.Minute)), "drawer")
}

// Two runs at the same moment (two server processes) ask a device once.
func TestStaleWakeClaimIsAtomic(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	var dev string
	if err := fx.pool.QueryRow(ctx, `SELECT id::text FROM devices WHERE user_id = $1`, fx.b).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, err := fx.pool.Exec(ctx, `UPDATE devices SET last_seen = $2 WHERE id = $1`, dev, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	wins := 0
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if fx.srv.claimStaleWake(ctx, dev, now) {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("%d claims won, want exactly 1", wins)
	}
}
