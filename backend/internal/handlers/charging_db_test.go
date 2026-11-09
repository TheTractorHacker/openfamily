package handlers

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

// Charging flag end to end against a real database (TEST_DATABASE_URL):
// stored on locations and member_positions, returned on the members list and
// the WebSocket snapshot, and optional in every direction (an old app that
// never sends it keeps working and reads as "unknown").

func chargingOf(t *testing.T, e *circleEnv, viewer, member string) (any, bool) {
	t.Helper()
	_, _, raw := e.do(viewer, "GET", "/family/members?circle_id=all", nil)
	var members []map[string]any
	if err := json.Unmarshal(raw, &members); err != nil {
		t.Fatalf("members: %s", raw)
	}
	for _, m := range members {
		if m["id"] == e.ids[member] {
			v, ok := m["charging"]
			return v, ok
		}
	}
	t.Fatalf("%s does not see %s", viewer, member)
	return nil, false
}

func TestChargingStoredAndReturned(t *testing.T) {
	e, _ := liveEnv(t)
	e.rt.Post("/locations/batch", e.srv.IngestLocationBatch)
	ctx := context.Background()
	a := e.ids["A"]
	circle := e.createCircle("A", "Charge", "B")
	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1,'android','t') RETURNING id`, a).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `DELETE FROM member_positions WHERE user_id=$1`, a); err != nil {
		t.Fatal(err)
	}
	base := time.Now().Add(-5 * time.Minute).UTC()
	ts := func(sec int) string { return base.Add(time.Duration(sec) * time.Second).Format(time.RFC3339Nano) }
	lat := func(m float64) float64 { return 40.0 + m/111320.0 }

	// Old app: no charging field at all. Accepted, stored as NULL, omitted on read.
	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(0), "lat": lat(0), "lon": -75.0, "battery_pct": 50.0}); c != 201 {
		t.Fatalf("old payload: %d %v", c, m)
	}
	var chg *bool
	_ = e.pool.QueryRow(ctx, `SELECT charging FROM member_positions WHERE user_id=$1`, a).Scan(&chg)
	if chg != nil {
		t.Fatalf("old payload stored charging=%v, want NULL", *chg)
	}
	if v, ok := chargingOf(t, e, "B", "A"); ok {
		t.Fatalf("unknown charging must be omitted, got %v", v)
	}

	// New app, charging: stored on both tables, shown to the circle, echoed in the ack.
	c, m := e.ingest("A", dev, ingestBody{"ts": ts(10), "lat": lat(500), "lon": -75.0, "battery_pct": 12.0, "charging": true})
	if c != 201 || m["charging"] != true {
		t.Fatalf("charging fix: %d %v", c, m)
	}
	var locChg *bool
	_ = e.pool.QueryRow(ctx, `SELECT charging FROM locations WHERE device_id=$1 ORDER BY ts DESC LIMIT 1`, dev).Scan(&locChg)
	if locChg == nil || !*locChg {
		t.Fatalf("locations.charging=%v", locChg)
	}
	if v, _ := chargingOf(t, e, "B", "A"); v != true {
		t.Fatalf("members charging=%v, want true", v)
	}
	// Compact view keeps it (the app's map list uses it).
	_, _, raw := e.do("B", "GET", "/family/members?circle_id=all&view=compact", nil)
	var compact []map[string]any
	_ = json.Unmarshal(raw, &compact)
	seen := false
	for _, mm := range compact {
		if mm["id"] == a {
			seen = mm["charging"] == true
		}
	}
	if !seen {
		t.Fatalf("compact view dropped charging: %s", raw)
	}
	// WebSocket snapshot carries it too.
	snap, err := e.srv.circleMembersSnapshot(ctx, []string{circle}, e.ids["B"])
	if err != nil {
		t.Fatal(err)
	}
	seen = false
	for _, mm := range snap {
		if mm.ID == a && mm.Charging != nil && *mm.Charging {
			seen = true
		}
	}
	if !seen {
		t.Fatal("ws snapshot has no charging=true for A")
	}

	// Stationary report (deduplicated): unplugged is applied to the last position.
	if c, m := e.ingest("A", dev, ingestBody{"ts": ts(20), "lat": lat(502), "lon": -75.0, "speed_mps": 0.0, "battery_pct": 13.0, "charging": false}); c != 200 || m["status"] != "deduplicated" {
		t.Fatalf("stationary: %d %v", c, m)
	}
	if v, _ := chargingOf(t, e, "B", "A"); v != false {
		t.Fatalf("after unplug charging=%v, want false", v)
	}
	// A stationary report with battery but without the flag (older app) clears it to unknown.
	if c, _ := e.ingest("A", dev, ingestBody{"ts": ts(25), "lat": lat(501), "lon": -75.0, "speed_mps": 0.0, "battery_pct": 13.0}); c != 200 {
		t.Fatalf("stationary old: %d", c)
	}
	if v, ok := chargingOf(t, e, "B", "A"); ok {
		t.Fatalf("battery without flag must reset charging to unknown, got %v", v)
	}

	// Batch upload (outbox replay) stores it as well.
	c, m, raw = e.do("A", "POST", "/locations/batch", map[string]any{"points": []map[string]any{
		{"device_id": dev, "ts": ts(30), "lat": lat(900), "lon": -75.0, "battery_pct": 40.0, "charging": true},
		{"device_id": dev, "ts": ts(31), "lat": lat(950), "lon": -75.0, "battery_pct": 41.0}, // old shape
	}})
	if c != 200 || m["stored"].(float64) != 2 {
		t.Fatalf("batch: %d %s", c, raw)
	}
	var n int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM locations WHERE device_id=$1 AND charging`, dev).Scan(&n)
	if n != 2 { // the 10 s fix and the first batch point
		t.Fatalf("charging rows=%d, want 2", n)
	}
	chg = nil
	_ = e.pool.QueryRow(ctx, `SELECT charging FROM member_positions WHERE user_id=$1`, a).Scan(&chg)
	if chg != nil {
		t.Fatalf("newest batch point had no flag: member charging=%v, want NULL", *chg)
	}
}

func TestLowBatteryAlertSkippedWhileCharging(t *testing.T) {
	s := &Server{}
	user := "charging-test-" + time.Now().Format("150405.000000")
	pct, yes := 5.0, true
	s.noteBattery(user, &pct, &yes)
	lowBattery.mu.Lock()
	marked := lowBattery.below[user]
	lowBattery.mu.Unlock()
	if marked {
		t.Fatal("a charging phone must not arm or fire the low battery alert")
	}
	// Unplugged while still low: the reading counts as a fresh drop.
	if !lowBattery.crossed(user, pct) {
		t.Fatal("after unplugging, a low reading must alert")
	}
}
