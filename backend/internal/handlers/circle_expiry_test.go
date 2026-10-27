package handlers

import (
	"context"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
)

// DB tests for temporary circles (need TEST_DATABASE_URL; skipped otherwise).

func (e *circleEnv) tempCircle(creator string, hours int, members ...string) string {
	e.t.Helper()
	id := e.mustCode(creator, "POST", "/circles", map[string]any{"name": "Trip", "duration_hours": hours}, 201)["id"].(string)
	for _, m := range members {
		inv := e.mustCode(creator, "POST", "/circles/"+id+"/invites", map[string]any{}, 201)
		e.mustCode(m, "POST", "/circles/join", map[string]string{"code": inv["code"].(string)}, 200)
	}
	return id
}

// lapse moves a temporary circle's expiry into the past by d.
func (e *circleEnv) lapse(id string, d time.Duration) {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE circles SET expires_at = now() - make_interval(secs => $2) WHERE id = $1`, id, d.Seconds()); err != nil {
		e.t.Fatal(err)
	}
}

func TestTempCircleCreateValidationAndListing(t *testing.T) {
	e := newCircleEnv(t)
	for _, body := range []map[string]any{
		{"name": "x", "duration_hours": 0},
		{"name": "x", "duration_hours": 721},
		{"name": "x", "duration_hours": 24, "expires_at": time.Now().Add(48 * time.Hour)},
		{"name": "x", "expires_at": time.Now().Add(-time.Hour)},
		{"name": "x", "expires_at": time.Now().Add(31 * 24 * time.Hour)},
	} {
		e.mustCode("A", "POST", "/circles", body, 400)
	}
	id := e.tempCircle("A", 48)
	perm := e.createCircle("A", "Perm")
	_, _, raw := e.do("A", "GET", "/circles", nil)
	list := string(raw)
	if !contains(list, id) || !contains(list, perm) || !contains(list, `"expires_at":"`) {
		t.Fatalf("listing should include both circles with expires_at: %s", list)
	}
	e.lapse(id, time.Minute)
	_, _, raw = e.do("A", "GET", "/circles", nil)
	if contains(string(raw), id) || !contains(string(raw), perm) {
		t.Fatalf("expired circle must vanish from the list: %s", raw)
	}
	e.mustCode("A", "GET", "/circles/"+id+"/members", nil, 404)
}

func contains(s, sub string) bool { return len(sub) > 0 && indexOf(s, sub) >= 0 }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestTempCircleVisibilityCutOffAtExpiry(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	id := e.tempCircle("A", 24, "B")
	az := circles.New(e.pool)
	a, b := e.ids["A"], e.ids["B"]

	check := func(live bool) {
		t.Helper()
		sw, err := az.SharedWith(ctx, a, b)
		if err != nil {
			t.Fatal(err)
		}
		sc, _ := az.SharingCircles(ctx, b)
		own, sharing, _ := az.OwnAndSharingCircles(ctx, b)
		ids, _ := az.CircleIDs(ctx, b)
		vis, _ := az.LocationVisibility(ctx, a, []string{id})
		mc, _ := az.MemberCircles(ctx, a, []string{id})
		co, _ := az.CoMembers(ctx, a, []string{b})
		_, memErr := az.RequireMember(ctx, a, id)
		_, admErr := az.RequireAdmin(ctx, a, id)
		got := map[string]bool{
			"SharedWith":         len(sw) == 1,
			"SharingCircles":     len(sc) == 1,
			"OwnAndSharing.own":  len(own) == 1,
			"OwnAndSharing.shr":  len(sharing) == 1,
			"CircleIDs":          len(ids) == 1,
			"LocationVisibility": vis[b],
			"MemberCircles":      len(mc[b]) == 1 && mc[b][0].ExpiresAt != nil,
			"CoMembers":          co[b],
			"RequireMember":      memErr == nil,
			"RequireAdmin":       admErr == nil,
		}
		for k, v := range got {
			if v != live {
				t.Errorf("%s: got %v want %v (live=%v)", k, v, live, live)
			}
		}
	}
	check(true)
	e.lapse(id, time.Minute)
	check(false)
}

func TestTempCircleEndedEarly(t *testing.T) {
	e := newCircleEnv(t)
	id := e.tempCircle("A", 24, "B")
	e.mustCode("B", "PATCH", "/circles/"+id, map[string]any{"end": true}, 403)
	e.mustCode("C", "PATCH", "/circles/"+id, map[string]any{"end": true}, 404)
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"end": true}, 200)
	if sw, _ := circles.New(e.pool).SharedWith(context.Background(), e.ids["A"], e.ids["B"]); len(sw) != 0 {
		t.Fatalf("ended circle still shares: %v", sw)
	}
	// An early end cannot be undone by extending.
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 404)
}

func TestTempCircleExtendAndAuthorization(t *testing.T) {
	e := newCircleEnv(t)
	id := e.tempCircle("A", 24, "B")
	e.mustCode("B", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 403)
	e.mustCode("C", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 404)
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 0}, 400)
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24 * 30}, 400) // 24h + 30d > 30d from now? base+720h
	out := e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 200)
	if out["expires_at"] == nil {
		t.Fatalf("expires_at missing: %v", out)
	}
	// Permanent circles cannot be extended or ended.
	perm := e.createCircle("A", "Perm")
	e.mustCode("A", "PATCH", "/circles/"+perm, map[string]any{"end": true}, 409)
	e.mustCode("A", "PATCH", "/circles/"+perm, map[string]any{"extend_hours": 5}, 409)

	// A lapsed circle in its grace period can be revived by its admin only.
	e.lapse(id, time.Hour)
	e.mustCode("B", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 403)
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"name": "Renamed"}, 404)
	e.mustCode("A", "PATCH", "/circles/"+id, map[string]any{"extend_hours": 24}, 200)
	if sw, _ := circles.New(e.pool).SharedWith(context.Background(), e.ids["A"], e.ids["B"]); len(sw) != 1 {
		t.Fatalf("revived circle should share again: %v", sw)
	}
}

func TestTempCircleInvitesRefusedAfterExpiry(t *testing.T) {
	e := newCircleEnv(t)
	id := e.tempCircle("A", 24)
	inv := e.mustCode("A", "POST", "/circles/"+id+"/invites", map[string]any{}, 201)
	code := inv["code"].(string)
	e.lapse(id, time.Minute)
	e.mustCode("C", "POST", "/circles/join", map[string]string{"code": code}, 400)
	e.mustCode("A", "POST", "/circles/"+id+"/invites", map[string]any{}, 404)
	tx, err := e.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if _, _, err := e.srv.consumeInviteCode(context.Background(), tx, code); err == nil {
		t.Fatal("legacy redeem path must refuse an expired circle's code")
	}
}

func TestTempCircleChatAndUnreadNotServedAfterExpiry(t *testing.T) {
	e := newCircleEnv(t)
	id := e.tempCircle("A", 24, "B")
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1, $2, 'hi')`, id, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	var n int
	q := `SELECT count(*) FROM live_circle_members WHERE circle_id = $1 AND user_id = $2`
	_ = e.pool.QueryRow(context.Background(), q, id, e.ids["B"]).Scan(&n)
	if n != 1 {
		t.Fatal("member should be live")
	}
	e.lapse(id, time.Minute)
	_ = e.pool.QueryRow(context.Background(), q, id, e.ids["B"]).Scan(&n)
	if n != 0 {
		t.Fatal("lapsed circle must have no live members (chat/unread/push read this)")
	}
	if _, err := circles.New(e.pool).RequireMember(context.Background(), e.ids["B"], id); err == nil {
		t.Fatal("chat authorizes through RequireMember; must be refused")
	}
}

func TestPurgeTemporaryCircles(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	old := e.tempCircle("A", 24, "B")
	recent := e.tempCircle("A", 24)
	endedOld := e.tempCircle("A", 24)
	perm := e.createCircle("A", "Perm")
	e.lapse(old, tempCircleGrace+time.Hour)
	e.lapse(recent, time.Hour)
	e.lapse(endedOld, 2*time.Hour)
	if _, err := e.pool.Exec(ctx, `UPDATE circles SET ended_at = now() - interval '8 days' WHERE id = $1`, endedOld); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1, $2, 'x')`, old, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.srv.PurgeTemporaryCircles(ctx); err != nil {
		t.Fatal(err)
	}
	exists := func(id string) bool {
		var n int
		_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM circles WHERE id = $1`, id).Scan(&n)
		return n == 1
	}
	if exists(old) || exists(endedOld) {
		t.Fatal("circles past the grace period should be deleted")
	}
	if !exists(recent) || !exists(perm) {
		t.Fatal("circles inside the grace period / permanent ones must survive")
	}
	var n int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM chat_messages WHERE circle_id = $1`, old).Scan(&n)
	if n != 0 {
		t.Fatal("chat rows should cascade")
	}
}
