package handlers

import (
	"context"
	"encoding/json"
	"net/url"
	"testing"
	"time"
)

// A person who joins a circle reads the others' history only from their own
// join time on; the others (and the person's own data) are not limited.
func TestNewMemberReadsHistoryOnlyFromJoinTime(t *testing.T) {
	e := newCircleEnv(t)
	e.rt.Get("/family/members/{id}/history", e.srv.GetMemberHistory)
	ctx := context.Background()
	c := e.createCircle("A", "Floor", "B") // both backdated
	joined := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	// A is the newcomer: joined one hour ago.
	if _, err := e.pool.Exec(ctx, `UPDATE circle_members SET joined_at = $3 WHERE circle_id = $1 AND user_id = $2`, c, e.ids["A"], joined); err != nil {
		t.Fatal(err)
	}
	seed := func(user string, ago time.Duration, lat float64) {
		var dev string
		if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, e.ids[user]).Scan(&dev); err != nil {
			t.Fatal(err)
		}
		if _, err := e.pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom, source) VALUES ($1,$2,ST_SetSRID(ST_MakePoint(5,$3),4326),'x')`,
			dev, time.Now().Add(-ago), lat); err != nil {
			t.Fatal(err)
		}
	}
	seed("B", 3*time.Hour, 10) // before A joined
	seed("B", 20*time.Minute, 20)
	seed("A", 3*time.Hour, 30) // A's own, before joining

	n := time.Now().UTC()
	q := "?" + url.Values{"from": {n.Add(-6 * time.Hour).Format(time.RFC3339)}, "to": {n.Format(time.RFC3339)}}.Encode()
	trail := func(viewer, subject string) []trailPoint {
		code, _, raw := e.do(viewer, "GET", "/family/members/"+e.ids[subject]+"/history"+q, nil)
		if code != 200 {
			t.Fatalf("%s reads %s: %d %s", viewer, subject, code, raw)
		}
		var out struct {
			Trail []trailPoint `json:"trail"`
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatal(err)
		}
		return out.Trail
	}
	if got := trail("A", "B"); len(got) != 1 || got[0].Lat < 19 || got[0].Lat > 21 {
		t.Fatalf("newcomer sees %+v of B; want only the point after the join", got)
	}
	if got := trail("A", "A"); len(got) != 1 {
		t.Fatalf("own history is limited: %+v", got)
	}
	if got := trail("B", "B"); len(got) != 2 {
		t.Fatalf("B's own history: %+v", got)
	}
	// A request wholly before the join is empty, not an error.
	old := "?" + url.Values{"from": {n.Add(-5 * time.Hour).Format(time.RFC3339)}, "to": {n.Add(-2 * time.Hour).Format(time.RFC3339)}}.Encode()
	if code, _, raw := e.do("A", "GET", "/family/members/"+e.ids["B"]+"/history"+old, nil); code != 200 {
		t.Fatalf("pre-join window: %d %s", code, raw)
	} else {
		var out struct {
			Trail []trailPoint `json:"trail"`
		}
		_ = json.Unmarshal(raw, &out)
		if len(out.Trail) != 0 {
			t.Fatalf("pre-join window leaks %d points", len(out.Trail))
		}
	}

	// Trips use the same floor.
	if !s2ok(e, "B", "A", time.Now().Add(-10*time.Minute)) || s2ok(e, "B", "A", time.Now().Add(-3*time.Hour)) {
		t.Fatal("trip floor wrong for the newcomer")
	}
	if !s2ok(e, "B", "B", time.Now().Add(-3*time.Hour)) {
		t.Fatal("own trips must never be limited")
	}
}

// s2ok: may viewer read subject's trip that started at t?
func s2ok(e *circleEnv, subject, viewer string, at time.Time) bool {
	return e.srv.tripVisibleSinceJoin(context.Background(), e.ids[viewer], e.ids[subject], at)
}

func TestClampFrom(t *testing.T) {
	now := time.Now()
	if got := clampFrom(now.Add(-time.Hour), time.Time{}); !got.Equal(now.Add(-time.Hour)) {
		t.Fatal("zero floor must not clamp")
	}
	if got := clampFrom(now.Add(-time.Hour), now.Add(-time.Minute)); !got.Equal(now.Add(-time.Minute)) {
		t.Fatal("floor must raise from")
	}
	if got := clampFrom(now, now.Add(-time.Minute)); !got.Equal(now) {
		t.Fatal("a later from stays")
	}
}
