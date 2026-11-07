package handlers

import (
	"context"
	"testing"
	"time"
)

// Lanes: the built-in Dawarich export reads only the plaintext `locations` table.
// Members who keep their data on the phone never have rows there (ingest refuses
// them, a lane withdrawal purges their copies), so their points never reach
// Dawarich. Needs TEST_DATABASE_URL.
func TestDawarichExportNeverCarriesAPhoneLaneMember(t *testing.T) {
	e := readyLanes(t) // A and B: server lane; C: phone lane (no pref)
	ctx := context.Background()
	if err := e.srv.EnsureDawarichSchema(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	if c, m, raw := e.ingest(e.point("fix", e.a, now, 52.1, 13.1), e.point("fix", e.b, now, 52.2, 13.2), e.point("fix", e.c, now, 41.8781, -87.6298)); c != 200 || m["stored"].(float64) != 2 {
		t.Fatalf("%d %s", c, raw)
	}
	users := func() map[string]bool {
		out := map[string]bool{}
		// the unmapped target (main account) and one per-person mapping each
		since := time.Now().Add(-48 * time.Hour)
		for _, tgt := range []dawarichTarget{{Key: "k", Since: since}, {UserID: e.ids["A"], Key: "k", Since: since}, {UserID: e.ids["B"], Key: "k", Since: since}, {UserID: e.ids["C"], Key: "k", Since: since}} {
			pts, err := e.srv.nextDawarichBatch(ctx, tgt)
			if err != nil {
				t.Fatal(err)
			}
			for _, p := range pts {
				var uid string
				_ = e.pool.QueryRow(ctx, `SELECT user_id::text FROM devices WHERE id = $1`, p.deviceID).Scan(&uid)
				out[uid] = true
			}
		}
		return out
	}
	got := users()
	if !got[e.ids["A"]] || !got[e.ids["B"]] || got[e.ids["C"]] {
		t.Fatalf("export reaches %v; want A and B but not the phone-lane member C", got)
	}
	// B opts out: the purge removes B's copies in the same transaction, so B leaves the export too.
	e.setLane("B", e.b, "phone", 0, 200)
	got = users()
	if got[e.ids["B"]] || got[e.ids["C"]] || !got[e.ids["A"]] {
		t.Fatalf("after B opted out the export reaches %v", got)
	}
	// ...and a later fix of B is refused by ingest, so it cannot be exported either.
	if c, m, _ := e.ingest(e.point("fix", e.b, now.Add(time.Minute), 52.3, 13.3)); c != 200 || m["stored"].(float64) != 0 {
		t.Fatal("ingest accepted an opted-out member")
	}
	if got = users(); got[e.ids["B"]] {
		t.Fatal("opted-out member exported")
	}
}

// Defence in depth: a row planted DIRECTLY in `locations` for a phone-lane member,
// tagged with the lanes circle, is not exported by any reader that is not the member
// themself (Dawarich batch + pending counter, history, history export predicate),
// while a legitimate server-lane row and the member's own untagged (non-private)
// rows still are.
func TestPlantedLocationOfPhoneLaneMemberIsNotExported(t *testing.T) {
	e := readyLanes(t) // A, B server lane; C phone lane
	ctx := context.Background()
	if err := e.srv.EnsureDawarichSchema(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	e.ingest(e.point("fix", e.a, now.Add(-time.Minute), 52.1, 13.1)) // legit server-lane row (tagged)
	var cdev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, e.ids["C"]).Scan(&cdev); err != nil {
		t.Fatal(err)
	}
	e.locAt(cdev, now.Add(-3*time.Minute), 41.5, e.circle) // PLANTED, tagged with the lanes circle
	e.locAt(cdev, now.Add(-2*time.Minute), 42.5, nil)      // legit: untagged non-private row
	since := now.Add(-48 * time.Hour)
	pts, err := e.srv.nextDawarichBatch(ctx, dawarichTarget{Key: "k", Since: since})
	if err != nil {
		t.Fatal(err)
	}
	var aRows, cRows int
	for _, p := range pts {
		switch p.deviceID {
		case cdev:
			cRows++
			if !p.ts.Equal(now.Add(-2 * time.Minute)) {
				t.Fatalf("the planted C row reached Dawarich (ts %v)", p.ts)
			}
		default:
			aRows++
		}
	}
	if aRows < 1 || cRows != 1 {
		t.Fatalf("dawarich batch: server-lane rows %d (want >=1), C untagged rows %d (want 1)", aRows, cRows)
	}
	hist, err := e.srv.loadHistoryPoints(ctx, e.ids["C"], now.Add(-time.Hour), now)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 1 || hist[0].Lat < 42 || hist[0].Lat > 43 {
		t.Fatalf("history of C: %+v (want only the untagged row)", hist)
	}
	if h, _ := e.srv.loadHistoryPoints(ctx, e.ids["A"], now.Add(-time.Hour), now); len(h) != 1 {
		t.Fatalf("server-lane member's history lost: %d", len(h))
	}
	var n int
	row := e.pool.QueryRow(ctx, `SELECT COUNT(*) FROM locations l JOIN devices d ON d.id = l.device_id
		WHERE d.user_id = $1 AND (l.e2ee_circle_id IS NULL OR e2ee_member_server_ok(l.e2ee_circle_id, d.user_id))`, e.ids["C"])
	if err := row.Scan(&n); err != nil || n != 1 {
		t.Fatalf("predicate used by the history export/trips readers: %d %v", n, err)
	}
}

// A row planted directly in member_positions (or locations) for a member who keeps
// their data on the phone is not served by the plaintext readers: Home Assistant,
// the public share-link view, the admin snapshot; and the post-purge last-position
// recompute never promotes a tagged row of a circle the member is not server-readable in.
func TestPlantedPositionOfPhoneLaneMemberIsNotServed(t *testing.T) {
	e := readyLanes(t) // A, B server lane; C phone lane
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	e.ingest(e.point("fix", e.a, now, 52.1, 13.1))
	for _, u := range []string{"C"} {
		if _, err := e.pool.Exec(ctx, `INSERT INTO member_positions (user_id, lat, lon, ts, updated_at) VALUES ($1, 41.8781, -87.6298, $2, now())
			ON CONFLICT (user_id) DO UPDATE SET lat = 41.8781, lon = -87.6298, ts = $2, updated_at = now()`, e.ids[u], now); err != nil {
			t.Fatal(err)
		}
	}
	if !e.srv.memberKeepsDataOnPhone(ctx, e.ids["C"]) || e.srv.memberKeepsDataOnPhone(ctx, e.ids["A"]) {
		t.Fatal("test premise: C keeps data on the phone, A does not")
	}
	// Home Assistant
	pos, err := e.srv.haPositions(ctx, []string{e.ids["A"], e.ids["C"]})
	if err != nil {
		t.Fatal(err)
	}
	if pos[e.ids["C"]] != nil || pos[e.ids["A"]] == nil {
		t.Fatalf("HA positions: %v", pos)
	}
	// Public share link of C and of A
	for u, want := range map[string]bool{"C": false, "A": true} {
		tok := u + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
		tok = tok[:43]
		if _, err := e.pool.Exec(ctx, `INSERT INTO share_links (user_id, token_hash, label, expires_at) VALUES ($1,$2,'t', now() + interval '1 hour')`,
			e.ids[u], hashShareToken(tok)); err != nil {
			t.Fatal(err)
		}
		row, ok := e.srv.lookupShareView(ctx, tok)
		if !ok {
			t.Fatalf("share link of %s not found", u)
		}
		if (row.data.Lat != nil) != want {
			t.Fatalf("share view of %s: lat=%v want position=%v", u, row.data.Lat, want)
		}
	}
	// Admin snapshot
	snap, err := e.srv.adminMembersSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, m := range snap {
		switch m.ID {
		case e.ids["C"]:
			seen++
			if m.Lat != nil || m.Lon != nil || !m.KeepsDataOnPhone {
				t.Fatalf("admin snapshot leaks C: %+v", m)
			}
		case e.ids["A"]:
			seen++
			if m.Lat == nil {
				t.Fatal("admin snapshot lost the server-lane member's position")
			}
		}
	}
	if seen != 2 {
		t.Fatalf("members in snapshot: %d", seen)
	}
	// Recompute after a purge: B's newest remaining location is a tagged row of a circle B
	// is not server-readable in; it must not become the last position. The older untagged one wins.
	// The fixture seeds every user a last-known position (lat 10) stamped with the wall clock at
	// setup; the ingest upsert only moves it forward, so the ingested point must be newer than that.
	nowB := time.Now().UTC().Truncate(time.Millisecond)
	e.ingest(e.point("fix", e.b, nowB, 10, 1))
	var mts time.Time
	if err := e.pool.QueryRow(ctx, `SELECT ts FROM member_positions WHERE user_id = $1`, e.ids["B"]).Scan(&mts); err != nil || !mts.Equal(nowB) {
		t.Fatalf("test premise: B's last position is the ingested point (ts %v, want %v, err %v)", mts, nowB, err)
	}
	dev := e.userDevice("B")
	e.locAt(dev, nowB.Add(-time.Hour), 77, "99999999-9999-4999-8999-999999999999")
	e.locAt(dev, nowB.Add(-2*time.Hour), 33, nil)
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 200)
	if lat, ok := e.lastLat("B"); !ok || lat != 33 {
		t.Fatalf("last position after purge = %v %v, want 33", lat, ok)
	}
}
