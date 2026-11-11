package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

// fakeClock is an injectable clock for the backoff tracker.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func TestDawarichBackoffDelaySchedule(t *testing.T) {
	want := map[int]time.Duration{
		0: 0, 1: 2 * time.Minute, 2: 4 * time.Minute, 3: 8 * time.Minute,
		4: 16 * time.Minute, 5: 32 * time.Minute, 6: time.Hour, 7: time.Hour, 500: time.Hour,
	}
	for n, d := range want {
		if got := dawarichBackoffDelay(n); got != d {
			t.Errorf("delay after %d failures = %v, want %v", n, got, d)
		}
	}
}

func TestDawarichBackoffWaitsThenRetriesAndResets(t *testing.T) {
	clk := &fakeClock{t: time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)}
	b := &dawarichBackoff{now: clk.now}
	if !b.due("") {
		t.Fatal("a destination that never failed must be due")
	}
	f := b.failure("", "boom")
	if f.Failures != 1 || !f.Next.Equal(clk.t.Add(2*time.Minute)) {
		t.Fatalf("first failure: %+v", f)
	}
	clk.advance(119 * time.Second)
	if b.due("") {
		t.Fatal("must still wait 1 second before the retry")
	}
	if !b.due("other") {
		t.Fatal("another destination is not held back by this one")
	}
	clk.advance(time.Second)
	if !b.due("") {
		t.Fatal("retry time reached, must be due")
	}
	f = b.failure("", "boom")
	if f.Failures != 2 || !f.Next.Equal(clk.t.Add(4*time.Minute)) {
		t.Fatalf("second failure: %+v", f)
	}
	if n, next, msg := b.snapshot(""); n != 2 || !next.Equal(f.Next) || msg != "boom" {
		t.Fatalf("snapshot = %d %v %q", n, next, msg)
	}
	if got := b.success(""); got != 2 {
		t.Fatalf("success reported %d failures, want 2", got)
	}
	if !b.due("") {
		t.Fatal("success must clear the wait")
	}
	if n, _, _ := b.snapshot(""); n != 0 {
		t.Fatal("success must clear the count")
	}
	// A fresh failure after success starts again at the first step.
	if f = b.failure("", "boom"); f.Failures != 1 || !f.Next.Equal(clk.t.Add(2*time.Minute)) {
		t.Fatalf("after success: %+v", f)
	}
	b.reset()
	if !b.due("") {
		t.Fatal("reset must make every destination due")
	}
}

func TestDawarichBackoffCapsAtOneHour(t *testing.T) {
	clk := &fakeClock{t: time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)}
	b := &dawarichBackoff{now: clk.now}
	var f dawarichFailure
	for i := 0; i < 20; i++ {
		f = b.failure("", "down")
		clk.advance(time.Hour)
	}
	if got := f.Next.Sub(clk.t.Add(-time.Hour)); got != time.Hour {
		t.Fatalf("wait after many failures = %v, want 1h", got)
	}
}

func TestDawarichBackoffLogsAreRateLimited(t *testing.T) {
	clk := &fakeClock{t: time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)}
	b := &dawarichBackoff{now: clk.now}
	if f := b.failure("", "down"); !f.Log || f.Suppressed != 0 {
		t.Fatalf("first failure must be logged: %+v", f)
	}
	logged := 0
	var lastSuppressed int
	// A day of identical failures, one per minute: well under 100 log lines.
	for i := 0; i < 24*60; i++ {
		clk.advance(time.Minute)
		if f := b.failure("", "down"); f.Log {
			logged++
			lastSuppressed = f.Suppressed
		}
	}
	// One every 30 minutes (the first minute-step lands on the 30th minute).
	if logged < 40 || logged > 50 {
		t.Fatalf("logged %d lines in 24 hours of identical failures, want about 48", logged)
	}
	if lastSuppressed != 29 {
		t.Fatalf("suppressed count on the last line = %d, want 29", lastSuppressed)
	}
	// A different message is logged at once.
	clk.advance(time.Minute)
	if f := b.failure("", "Dawarich answered 401"); !f.Log {
		t.Fatal("a changed message must be logged immediately")
	}
}

// dawarichTestEnv wires a real database, a fake Dawarich server and a fake
// clock to one Server. answer decides the status per API key.
type dawarichTestEnv struct {
	*circleEnv
	clk   *fakeClock
	hits  atomic.Int64
	url   string
	state func(key string) int
}

func newDawarichTestEnv(t *testing.T, state func(key string) int) *dawarichTestEnv {
	e := &dawarichTestEnv{circleEnv: newCircleEnv(t), state: state}
	ctx := context.Background()
	e.clk = &fakeClock{t: time.Now().UTC().Truncate(time.Second)}
	e.srv.dawarichBO.now = e.clk.now
	e.srv.TM = auth.NewTokenManager("test-secret-test-secret-test-secret-00", time.Hour, time.Hour)
	if err := e.srv.EnsureDawarichSchema(ctx); err != nil {
		t.Fatal(err)
	}
	clean := func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM dawarich_settings; DELETE FROM dawarich_user_map; DELETE FROM dawarich_cursor`)
	}
	clean()
	t.Cleanup(clean)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.hits.Add(1)
		key := r.Header.Get("Authorization")
		if len(key) > 7 {
			key = key[7:]
		}
		w.WriteHeader(e.state(key))
	}))
	t.Cleanup(ts.Close)
	e.url = ts.URL
	e.route("PUT", "/admin/dawarich", e.srv.AdminPutDawarich)
	return e
}

// fix stores one location for user's device, newer than the sync start.
func (e *dawarichTestEnv) fix(user string, ago time.Duration) {
	e.t.Helper()
	ctx := context.Background()
	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, e.ids[user]).Scan(&dev); err != nil {
		e.t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom, source)
		VALUES ($1, $2, ST_SetSRID(ST_MakePoint(5, 6), 4326), 'x')`, dev, time.Now().Add(-ago)); err != nil {
		e.t.Fatal(err)
	}
}

func (e *dawarichTestEnv) saveSettings(key string) {
	e.t.Helper()
	sealed, err := e.srv.sealDawarichKey(key)
	if err != nil {
		e.t.Fatal(err)
	}
	if _, err := e.pool.Exec(context.Background(), `
		INSERT INTO dawarich_settings (id, base_url, api_key, enabled, send_unmapped, since)
		VALUES (1, $1, $2, TRUE, TRUE, now() - interval '48 hours')`, e.url, sealed); err != nil {
		e.t.Fatal(err)
	}
}

func (e *dawarichTestEnv) row() dawarichRow {
	e.t.Helper()
	r, ok, err := e.srv.readDawarich(context.Background())
	if err != nil || !ok {
		e.t.Fatalf("readDawarich: %v %v", ok, err)
	}
	return r
}

// An unreachable-style failure (the server answers 503): the loop backs off,
// the error, failure count and next retry are stored, the log is quiet, and one
// success clears all of it and records the last successful delivery.
func TestDawarichSyncBacksOffStoresStateAndRecovers(t *testing.T) {
	var status atomic.Int64
	status.Store(503)
	e := newDawarichTestEnv(t, func(string) int { return int(status.Load()) })
	ctx := context.Background()
	e.saveSettings("main-key")
	e.fix("A", time.Minute)
	t0 := e.clk.now()

	e.srv.syncDawarichOnce(ctx, false)
	if e.hits.Load() != 1 {
		t.Fatalf("hits = %d, want 1", e.hits.Load())
	}
	r := e.row()
	if r.Failures != 1 || r.LastError != "Dawarich answered 503" || r.LastOKAt != nil ||
		r.NextRetryAt == nil || !r.NextRetryAt.Truncate(time.Second).Equal(t0.Add(2*time.Minute)) {
		t.Fatalf("after first failure: %+v", r)
	}

	// The next tick, one minute later, does not call Dawarich and keeps the error.
	e.clk.advance(time.Minute)
	e.srv.syncDawarichOnce(ctx, false)
	if e.hits.Load() != 1 {
		t.Fatalf("attempt during backoff: hits = %d, want 1", e.hits.Load())
	}
	if r = e.row(); r.Failures != 1 || r.LastError == "" {
		t.Fatalf("a skipped pass changed the stored state: %+v", r)
	}

	// At the retry time it tries again and waits longer.
	e.clk.advance(time.Minute)
	e.srv.syncDawarichOnce(ctx, false)
	if e.hits.Load() != 2 {
		t.Fatalf("hits = %d, want 2", e.hits.Load())
	}
	if r = e.row(); r.Failures != 2 || !r.NextRetryAt.Truncate(time.Second).Equal(e.clk.now().Add(4*time.Minute)) {
		t.Fatalf("after second failure: %+v", r)
	}

	// Dawarich comes back. "Sync now" bypasses the wait; the state resets.
	status.Store(200)
	e.srv.syncDawarichOnce(ctx, true)
	if e.hits.Load() != 3 {
		t.Fatalf("hits = %d, want 3", e.hits.Load())
	}
	r = e.row()
	if r.Failures != 0 || r.LastError != "" || r.NextRetryAt != nil || r.LastOKAt == nil || r.TotalSent < 1 {
		t.Fatalf("after recovery: %+v", r)
	}
}

// One person's failing Dawarich account does not hold back the others, a
// success elsewhere does not erase the failing account's message, and changing
// the settings starts the wait over.
func TestDawarichBackoffIsPerDestinationAndSettingsChangeResets(t *testing.T) {
	e := newDawarichTestEnv(t, func(key string) int {
		if key == "bad-key" {
			return 401
		}
		return 200
	})
	ctx := context.Background()
	e.saveSettings("bad-key") // main account (everyone not mapped) is rejected
	sealed, err := e.srv.sealDawarichKey("good-key")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO dawarich_user_map (user_id, api_key, enabled, since)
		VALUES ($1, $2, TRUE, now() - interval '48 hours')`, e.ids["B"], sealed); err != nil {
		t.Fatal(err)
	}
	e.fix("A", time.Minute) // unmapped: goes to the main account
	e.fix("B", time.Minute) // mapped: goes to B's own account

	e.srv.syncDawarichOnce(ctx, false)
	r := e.row()
	if r.Failures != 1 || r.LastError != "Dawarich answered 401 (check the API key)" {
		t.Fatalf("main account state: %+v", r)
	}
	var okAt *time.Time
	var failures int
	var lastErr string
	if err := e.pool.QueryRow(ctx, `SELECT last_ok_at, failures, last_error FROM dawarich_user_map WHERE user_id = $1`,
		e.ids["B"]).Scan(&okAt, &failures, &lastErr); err != nil {
		t.Fatal(err)
	}
	if okAt == nil || failures != 0 || lastErr != "" {
		t.Fatalf("mapped account must be delivered and clean: %v %d %q", okAt, failures, lastErr)
	}

	// While the main account waits, the pass that only B takes part in must
	// not wipe the main account's stored error.
	e.fix("B", 30*time.Second)
	hits := e.hits.Load()
	e.clk.advance(time.Minute)
	e.srv.syncDawarichOnce(ctx, false)
	if e.hits.Load() != hits+1 { // only B's new fix was sent; main was skipped
		t.Fatalf("hits went %d -> %d, want exactly one more (B only)", hits, e.hits.Load())
	}
	if r = e.row(); r.Failures != 1 || r.LastError == "" {
		t.Fatalf("a pass where only B was tried cleared the main account's error: %+v", r)
	}

	// An admin saves the settings again: the stored state clears at once and
	// the main account is tried on the very next tick, not after the old wait.
	e.mustCode("A", "PUT", "/admin/dawarich", map[string]any{
		"base_url": e.url, "api_key": "bad-key", "enabled": true, "send_unmapped": true,
	}, 200)
	if r = e.row(); r.Failures != 0 || r.LastError != "" || r.NextRetryAt != nil {
		t.Fatalf("settings save must clear the failure state: %+v", r)
	}
	hits = e.hits.Load()
	e.srv.syncDawarichOnce(ctx, false)
	if e.hits.Load() <= hits {
		t.Fatal("after a settings change the main account must be tried again immediately")
	}
	if r = e.row(); r.Failures != 1 {
		t.Fatalf("still rejected, so failures restart at 1: %+v", r)
	}
}
