package handlers

import (
	"context"
	"testing"
	"time"
)

func TestRuleAllows(t *testing.T) {
	cases := []struct {
		mode, ev string
		want     bool
	}{
		{"both", "enter", true}, {"both", "exit", true},
		{"arrivals", "enter", true}, {"arrivals", "exit", false},
		{"departures", "enter", false}, {"departures", "exit", true},
		{"off", "enter", false}, {"off", "exit", false},
		{"weird", "exit", true}, // fail open
	}
	for _, c := range cases {
		if got := ruleAllows(c.mode, c.ev); got != c.want {
			t.Errorf("ruleAllows(%s,%s)=%v want %v", c.mode, c.ev, got, c.want)
		}
	}
}

func TestPlaceAlertSuppressed(t *testing.T) {
	e, fam, _ := newPlaceCircleEnv(t)
	ctx := context.Background()
	a, b, c := e.ids["A"], e.ids["B"], e.ids["C"]
	var placeID, other string
	for i, dst := range []*string{&placeID, &other} {
		if err := e.pool.QueryRow(ctx, `INSERT INTO places (family_id, name, geom, radius_meters)
			VALUES ($1, 'q', ST_SetSRID(ST_MakePoint(-75, 40), 4326), 200) RETURNING id`, fam).Scan(dst); err != nil {
			t.Fatal(i, err)
		}
	}
	night := time.Date(2026, 1, 5, 23, 30, 0, 0, time.UTC)
	noon := time.Date(2026, 1, 5, 12, 0, 0, 0, time.UTC)

	// Backward compatible: no rows, nobody suppressed.
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "enter", night); len(s) != 0 {
		t.Fatalf("default should suppress nobody: %v", s)
	}

	// B: quiet 22:00-07:00 UTC (crosses midnight). C: same window expressed in
	// UTC+05:30, i.e. 03:30-12:30 local, so it covers noon UTC but not 23:30 UTC.
	ins := func(u string, qs, qe int, tz string) {
		if _, err := e.pool.Exec(ctx, `INSERT INTO user_quiet_hours (user_id, quiet_start, quiet_end, tz) VALUES ($1,$2,$3,$4)`, u, qs, qe, tz); err != nil {
			t.Fatal(err)
		}
	}
	ins(b, 22*60, 7*60, "UTC")
	ins(c, 22*60, 7*60, "UTC+05:30")
	// 23:30 UTC = 05:00 next day at +05:30 -> C is in quiet hours too.
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "enter", night); !s[b] || !s[c] {
		t.Errorf("night: %v", s)
	}
	// 12:00 UTC = 17:30 at +05:30 -> neither.
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "exit", noon); s[b] || s[c] {
		t.Errorf("noon: %v", s)
	}
	// 17:00 UTC = 22:30 at +05:30 -> only C.
	five := time.Date(2026, 1, 5, 17, 0, 0, 0, time.UTC)
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "exit", five); s[b] || !s[c] {
		t.Errorf("17:00 UTC: %v", s)
	}

	// Per-place rules: B arrivals-only, C off at placeID only.
	if _, err := e.pool.Exec(ctx, `INSERT INTO place_alert_rules (user_id, subject_id, place_id, mode) VALUES
		($1,$3,$4,'arrivals'), ($2,$3,$4,'off')`, b, c, a, placeID); err != nil {
		t.Fatal(err)
	}
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "exit", noon); !s[b] || !s[c] {
		t.Errorf("exit: B(arrivals only) and C(off) must be suppressed: %v", s)
	}
	if s := placeAlertSuppressed(ctx, e.pool, a, placeID, "enter", noon); s[b] || !s[c] {
		t.Errorf("enter: only C: %v", s)
	}
	// Other place and other subject unaffected.
	if s := placeAlertSuppressed(ctx, e.pool, a, other, "exit", noon); len(s) != 0 {
		t.Errorf("other place: %v", s)
	}
	if s := placeAlertSuppressed(ctx, e.pool, b, placeID, "exit", noon); len(s) != 0 {
		t.Errorf("other subject: %v", s)
	}
}

// Emergencies never consult quiet hours or place rules: notifySharers-style
// callers pass memberCat "" for SOS, and notifSuppressed ignores such categories.
func TestEmergenciesIgnoreQuietHours(t *testing.T) {
	e, _, _ := newPlaceCircleEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO user_quiet_hours (user_id, quiet_start, quiet_end, tz) VALUES ($1, 0, 1439, 'UTC')`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	for _, cat := range []string{"sos", "help", "crash", "check_in", ""} {
		if s := notifSuppressed(ctx, e.pool, e.ids["A"], cat, time.Now()); len(s) != 0 {
			t.Errorf("category %q suppressed %v", cat, s)
		}
	}
}

func TestQuietHoursAndRulesAPI(t *testing.T) {
	e, fam, _ := newPlaceCircleEnv(t)
	ctx := context.Background()
	e.rt.Get("/me/quiet-hours", e.srv.GetQuietHours)
	e.rt.Put("/me/quiet-hours", e.srv.PutQuietHours)
	e.rt.Get("/members/{id}/place-alert-rules", e.srv.ListPlaceAlertRules)
	e.rt.Put("/members/{id}/place-alert-rules/{placeId}", e.srv.PutPlaceAlertRule)

	got := e.mustCode("B", "GET", "/me/quiet-hours", nil, 200)
	if got["quiet_start"] != nil {
		t.Fatalf("default: %v", got)
	}
	e.mustCode("B", "PUT", "/me/quiet-hours", map[string]any{"quiet_start": "22:00", "quiet_end": "22:00"}, 400)
	e.mustCode("B", "PUT", "/me/quiet-hours", map[string]any{"quiet_start": "22:00"}, 400)
	e.mustCode("B", "PUT", "/me/quiet-hours", map[string]any{"quiet_start": "22:00", "quiet_end": "07:00", "timezone": "Nope/Zone"}, 400)
	got = e.mustCode("B", "PUT", "/me/quiet-hours", map[string]any{"quiet_start": "22:00", "quiet_end": "07:00", "timezone": "Europe/Paris"}, 200)
	if got["quiet_start"] != "22:00" || got["timezone"] != "Europe/Paris" {
		t.Fatalf("saved: %v", got)
	}
	got = e.mustCode("B", "PUT", "/me/quiet-hours", map[string]any{"quiet_start": nil, "quiet_end": nil}, 200)
	if got["quiet_start"] != nil {
		t.Fatalf("cleared: %v", got)
	}

	var placeID string
	if err := e.pool.QueryRow(ctx, `INSERT INTO places (family_id, name, geom, radius_meters)
		VALUES ($1, 'r', ST_SetSRID(ST_MakePoint(-75, 40), 4326), 200) RETURNING id`, fam).Scan(&placeID); err != nil {
		t.Fatal(err)
	}
	a := e.ids["A"]
	base := "/members/" + a + "/place-alert-rules"
	e.mustCode("B", "PUT", base+"/"+placeID, map[string]any{"mode": "bogus"}, 400)
	e.mustCode("B", "PUT", base+"/not-a-uuid", map[string]any{"mode": "off"}, 404)
	e.mustCode("B", "PUT", "/members/"+e.ids["B"]+"/place-alert-rules/"+placeID, map[string]any{"mode": "off"}, 400)
	e.mustCode("B", "PUT", base+"/"+placeID, map[string]any{"mode": "departures"}, 200)
	var n int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM place_alert_rules WHERE user_id=$1 AND mode='departures'`, e.ids["B"]).Scan(&n)
	if n != 1 {
		t.Fatalf("rule rows = %d", n)
	}
	got = e.mustCode("B", "GET", base, nil, 200)
	if l, _ := got["rules"].([]any); len(l) != 1 {
		t.Fatalf("list: %v", got)
	}
	e.mustCode("B", "PUT", base+"/"+placeID, map[string]any{"mode": "both"}, 200)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM place_alert_rules WHERE user_id=$1`, e.ids["B"]).Scan(&n)
	if n != 0 {
		t.Fatalf("both should clear the row, have %d", n)
	}
}

func TestMemberPlaceAlertsSwitch(t *testing.T) {
	e, _, _ := newPlaceCircleEnv(t)
	ctx := context.Background()
	e.rt.Get("/members/{id}/place-alerts", e.srv.GetMemberPlaceAlerts)
	e.rt.Put("/members/{id}/place-alerts", e.srv.PutMemberPlaceAlerts)
	a, b, c := e.ids["A"], e.ids["B"], e.ids["C"]
	path := "/members/" + a + "/place-alerts"

	if got := e.mustCode("B", "GET", path, nil, 200); got["enabled"] != true {
		t.Fatalf("default should be enabled: %v", got)
	}
	e.mustCode("B", "PUT", path, map[string]any{}, 400)
	e.mustCode("B", "PUT", "/members/"+b+"/place-alerts", map[string]any{"enabled": false}, 400)
	if got := e.mustCode("B", "PUT", path, map[string]any{"enabled": false}, 200); got["enabled"] != false {
		t.Fatalf("put: %v", got)
	}
	if got := e.mustCode("B", "GET", path, nil, 200); got["enabled"] != false {
		t.Fatalf("get after put: %v", got)
	}
	// Only B is suppressed; C (and the default for everyone else) is unaffected.
	now := time.Date(2026, 1, 5, 12, 0, 0, 0, time.UTC)
	s := placeAlertSuppressed(ctx, e.pool, a, "", "enter", now)
	if !s[b] || s[c] {
		t.Fatalf("suppression must only affect the viewer who switched off: %v", s)
	}
	if got := e.mustCode("C", "GET", path, nil, 200); got["enabled"] != true {
		t.Fatalf("C unaffected: %v", got)
	}
	// Switching back on lifts it.
	e.mustCode("B", "PUT", path, map[string]any{"enabled": true}, 200)
	if s := placeAlertSuppressed(ctx, e.pool, a, "", "exit", now); s[b] {
		t.Fatalf("re-enabled: %v", s)
	}
}
