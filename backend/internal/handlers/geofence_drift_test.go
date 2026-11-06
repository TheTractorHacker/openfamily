package handlers

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestGeofenceFixUsable(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	cases := []struct {
		acc  *float64
		want bool
	}{
		{nil, true}, {f(5), true}, {f(geofenceMaxAccuracyMeters), true},
		{f(geofenceMaxAccuracyMeters + 0.1), false}, {f(500), false},
	}
	for _, c := range cases {
		if got := geofenceFixUsable(c.acc); got != c.want {
			t.Errorf("geofenceFixUsable(%v)=%v want %v", c.acc, got, c.want)
		}
	}
}

// Drift fixture: a phone resting inside a 100 m place reports a burst of
// low-accuracy fixes hundreds of metres away (cell/Wi-Fi fallback). No exit
// event may be recorded; a later accurate fix that really is outside must
// produce exactly one exit. Needs TEST_DATABASE_URL.
func TestGeofenceNoAlertOnLowAccuracyDrift(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	mk := func(q string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, q, args...).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	tag := fmt.Sprint(time.Now().UnixNano())
	fam := mk(`INSERT INTO families (name) VALUES ('drift') RETURNING id`)
	user := mk(`INSERT INTO users (email, name, password_hash, family_id, role) VALUES ($1,'D','x',$2,'admin') RETURNING id`, "drift"+tag+"@example.com", fam)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM geofence_events WHERE user_id = $1`, user)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, user)
		_, _ = pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam)
	})
	place := mk(`INSERT INTO places (family_id, name, geom, radius_meters) VALUES ($1,'Home',ST_SetSRID(ST_MakePoint(-75, 40), 4326), 100) RETURNING id`, fam)
	mk(`INSERT INTO geofences (family_id, place_id) VALUES ($1,$2) RETURNING id`, fam, place)

	s := &Server{Pool: pool, hub: newHub()}
	acc := func(v float64) *float64 { return &v }
	events := func() int {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM geofence_events WHERE user_id = $1`, user).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	now := time.Now().UTC()

	// Baseline: an accurate fix at the centre.
	s.evaluateGeofences(ctx, user, -75, 40, now, acc(8))
	// Drift burst: ~330 m north (0.003 deg lat) with 300-800 m accuracy.
	for i, a := range []float64{300, 450, 800, 250} {
		s.evaluateGeofences(ctx, user, -75, 40.003, now.Add(time.Duration(i+1)*time.Second), acc(a))
	}
	if n := events(); n != 0 {
		t.Fatalf("drift fixtures produced %d geofence events, want 0", n)
	}
	// A real, accurate departure fires exactly one exit.
	s.evaluateGeofences(ctx, user, -75, 40.003, now.Add(time.Minute), acc(10))
	if n := events(); n != 1 {
		t.Fatalf("accurate departure produced %d events, want 1", n)
	}
}
