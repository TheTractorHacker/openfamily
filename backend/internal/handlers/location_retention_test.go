package handlers

import (
	"context"
	"testing"
	"time"
)

// #18: a personal retention window shorter than the deployment ceiling, an
// immediate and periodic purge, and erasure of one's own history. Needs
// TEST_DATABASE_URL.

func TestLocationRetentionPersonalWindowAndErasure(t *testing.T) {
	e := newCircleEnv(t)
	e.rt.Get("/me/location-retention", e.srv.GetLocationRetention)
	e.rt.Put("/me/location-retention", e.srv.PutLocationRetention)
	e.rt.Delete("/me/locations", e.srv.DeleteMyLocations)
	ctx := context.Background()

	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, e.ids["A"]).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	var other string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, e.ids["B"]).Scan(&other); err != nil {
		t.Fatal(err)
	}
	ins := func(d string, ago time.Duration) {
		t.Helper()
		if _, err := e.pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom) VALUES ($1,$2,ST_SetSRID(ST_MakePoint(1,2),4326))`,
			d, time.Now().Add(-ago)); err != nil {
			t.Fatal(err)
		}
	}
	count := func(d string) int {
		t.Helper()
		var n int
		if err := e.pool.QueryRow(ctx, `SELECT count(*) FROM locations WHERE device_id = $1`, d).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	day := 24 * time.Hour
	ins(dev, 1*day)
	ins(dev, 5*day)
	ins(dev, 20*day)
	ins(other, 20*day)

	// Validation: 0, negative and above-ceiling are rejected.
	for _, d := range []int{0, -3, 100000} {
		e.mustCode("A", "PUT", "/me/location-retention", map[string]any{"days": d}, 400)
	}
	// Setting 7 days applies immediately and only to the caller.
	out := e.mustCode("A", "PUT", "/me/location-retention", map[string]any{"days": 7}, 200)
	if out["days"] != float64(7) {
		t.Fatalf("days=%v", out["days"])
	}
	if n := count(dev); n != 2 {
		t.Fatalf("after 7-day window caller has %d rows, want 2", n)
	}
	if n := count(other); n != 1 {
		t.Fatalf("other user's history was touched (%d rows)", n)
	}
	got := e.mustCode("A", "GET", "/me/location-retention", nil, 200)
	if got["days"] != float64(7) || got["max_days"] == nil {
		t.Fatalf("get=%v", got)
	}

	// The periodic job enforces it for rows that age out later.
	ins(dev, 10*day)
	if n, err := e.srv.PurgeUserRetention(ctx); err != nil || n < 1 {
		t.Fatalf("PurgeUserRetention n=%d err=%v", n, err)
	}
	if n := count(dev); n != 2 {
		t.Fatalf("after job caller has %d rows, want 2", n)
	}

	// Clearing the personal window keeps existing rows.
	e.mustCode("A", "PUT", "/me/location-retention", map[string]any{"days": nil}, 200)
	// Erase: older-than first, then everything.
	e.mustCode("A", "DELETE", "/me/locations?before="+time.Now().Add(-2*day).UTC().Format(time.RFC3339), nil, 200)
	if n := count(dev); n != 1 {
		t.Fatalf("after before-delete caller has %d rows, want 1", n)
	}
	e.mustCode("A", "DELETE", "/me/locations", nil, 200)
	if n := count(dev); n != 0 {
		t.Fatalf("after full delete caller has %d rows", n)
	}
	var pos int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM member_positions WHERE user_id = $1`, e.ids["A"]).Scan(&pos)
	if pos != 0 {
		t.Fatal("last known position not cleared by full erase")
	}
	if n := count(other); n != 1 {
		t.Fatal("erase touched another user's history")
	}
	e.mustCode("", "DELETE", "/me/locations", nil, 401)
}
