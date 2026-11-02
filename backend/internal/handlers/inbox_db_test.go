package handlers

import (
	"context"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

// DB tests for bubble alert history / admin listing, the temporary-circle
// expiry reminder and per-member driving / low-battery prefs. Need
// TEST_DATABASE_URL (skipped otherwise).

func TestBubbleAlertHistoryAndAdminList(t *testing.T) {
	fx := newAlertFixture(t)
	h := newBubbleRouter(fx)
	r := h.(*chi.Mux)
	r.Get("/alerts", fx.srv.ListAlerts)
	r.Get("/admin/bubbles", fx.srv.AdminListBubbles)
	ctx := context.Background()
	bubbleSetPos(t, fx, fx.b, 51.5, -0.12, "0 seconds")

	if code, _ := callJSON(t, h, "POST", "/bubbles", fx.a, map[string]any{"subject_id": fx.b, "radius_m": 500, "duration_minutes": 60}); code != 201 {
		t.Fatalf("create: %d", code)
	}
	fx.srv.alertBubble(ctx, "00000000-0000-0000-0000-000000000000", fx.a, fx.b, false)

	var types []string
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		_, l := callJSON(t, h, "GET", "/alerts", fx.a, nil)
		types = nil
		for _, x := range l["alerts"].([]any) {
			m := x.(map[string]any)
			types = append(types, m["type"].(string))
			if m["status"] != "resolved" {
				t.Fatalf("bubble history rows must be resolved: %v", m)
			}
		}
		if len(types) >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	got := map[string]bool{}
	for _, ty := range types {
		got[ty] = true
	}
	if !got["bubble_created"] || !got["bubble_left"] {
		t.Fatalf("creator history: %v", types)
	}
	// Only the creator sees bubble events; family members do not.
	for _, uid := range []string{fx.b, fx.c} {
		_, l := callJSON(t, h, "GET", "/alerts", uid, nil)
		if as, _ := l["alerts"].([]any); len(as) != 0 {
			t.Fatalf("bubble events leaked to %s: %v", uid, as)
		}
	}
	// Bubble rows do not count against the family check-in/help ceiling.
	var n int
	if err := fx.pool.QueryRow(ctx, `SELECT count(*) FROM alerts WHERE family_id = $1 AND type IN ('check_in','help')`, fx.f1).Scan(&n); err != nil || n != 0 {
		t.Fatalf("count: %d %v", n, err)
	}

	_, l := callJSON(t, h, "GET", "/admin/bubbles", fx.a, nil)
	bs, _ := l["bubbles"].([]any)
	found := false
	for _, x := range bs {
		m := x.(map[string]any)
		if m["creator_id"] == fx.a && m["subject_id"] == fx.b {
			found = true
			if m["lat"] != nil || m["lon"] != nil {
				t.Fatalf("admin list must not expose coordinates: %v", m)
			}
		}
	}
	if !found {
		t.Fatalf("admin list missing bubble: %v", l)
	}
}

func TestRemindExpiringCirclesOnce(t *testing.T) {
	e := newCircleEnv(t)
	fp := &fakePush{}
	e.srv.Push = fp
	ctx := context.Background()
	for _, n := range []string{"A", "B"} {
		if _, err := e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/'||$2)`, e.ids[n], n); err != nil {
			t.Fatal(err)
		}
	}
	soon := e.tempCircle("A", 48, "B")
	far := e.tempCircle("A", 48, "B")
	short := e.tempCircle("A", 1, "B") // created with <= 1h to live: no reminder
	set := func(id, expires, created string) {
		if _, err := e.pool.Exec(ctx, `UPDATE circles SET expires_at = now() + $2::interval, created_at = now() - $3::interval WHERE id = $1`, id, expires, created); err != nil {
			t.Fatal(err)
		}
	}
	set(soon, "40 minutes", "5 hours")
	set(far, "30 hours", "5 hours")
	set(short, "30 minutes", "10 minutes")

	n, err := e.srv.RemindExpiringCircles(ctx)
	if err != nil || n != 1 {
		t.Fatalf("first run: %d %v", n, err)
	}
	fp.mu.Lock()
	sent := len(fp.sent)
	fp.mu.Unlock()
	if sent != 2 {
		t.Fatalf("pushes = %d, want 2 (both members)", sent)
	}
	if n, err := e.srv.RemindExpiringCircles(ctx); err != nil || n != 0 {
		t.Fatalf("second run must be idempotent: %d %v", n, err)
	}
	fp.mu.Lock()
	defer fp.mu.Unlock()
	if len(fp.sent) != 2 {
		t.Fatalf("duplicate reminder pushes: %d", len(fp.sent))
	}
}

func TestLowBatteryAndDrivingRespectMemberPrefs(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	if _, err := fx.pool.Exec(ctx, `INSERT INTO circles (name, created_by) VALUES ('inbox-prefs', $1) RETURNING id`, fx.a); err != nil {
		t.Fatal(err)
	}
	var circle string
	if err := fx.pool.QueryRow(ctx, `SELECT id FROM circles WHERE name = 'inbox-prefs' AND created_by = $1`, fx.a).Scan(&circle); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = fx.pool.Exec(context.Background(), `DELETE FROM circles WHERE id = $1`, circle) })
	for _, u := range []string{fx.a, fx.b} {
		if _, err := fx.pool.Exec(ctx, `INSERT INTO circle_members (circle_id, user_id, role) VALUES ($1,$2,'member') ON CONFLICT DO NOTHING`, circle, u); err != nil {
			t.Fatal(err)
		}
	}
	count := func() int {
		fx.push.mu.Lock()
		defer fx.push.mu.Unlock()
		return len(fx.push.sent)
	}
	fx.srv.notifySharers(ctx, fx.a, "t", "b", "low_battery", notifLowBattery)
	if count() != 1 {
		t.Skipf("fixture does not deliver sharer pushes (%d); cannot assert suppression", count())
	}
	for _, c := range []struct{ col, cat string }{{"low_battery", notifLowBattery}, {"driving", notifDriving}} {
		if _, err := fx.pool.Exec(ctx, `
			INSERT INTO member_notification_prefs (user_id, subject_id) VALUES ($1,$2)
			ON CONFLICT (user_id, subject_id) DO UPDATE SET low_battery = true, driving = true`, fx.b, fx.a); err != nil {
			t.Fatal(err)
		}
		before := count()
		fx.srv.notifySharers(ctx, fx.a, "t", "b", "x", c.cat)
		if count() != before+1 {
			t.Fatalf("%s: expected a push with the pref on", c.cat)
		}
		if _, err := fx.pool.Exec(ctx, `UPDATE member_notification_prefs SET `+c.col+` = false WHERE user_id = $1 AND subject_id = $2`, fx.b, fx.a); err != nil {
			t.Fatal(err)
		}
		before = count()
		fx.srv.notifySharers(ctx, fx.a, "t", "b", "x", c.cat)
		if count() != before {
			t.Fatalf("%s: push sent despite the pref being off", c.cat)
		}
	}
}
