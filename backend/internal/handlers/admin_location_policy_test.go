package handlers

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func rangeQ() string {
	n := time.Now().UTC()
	return "from=" + n.Add(-2*time.Hour).Format(time.RFC3339) + "&to=" + n.Format(time.RFC3339)
}

// SEC-007: platform-admin location reads are denied by default
// (ADMIN_LOCATION_ACCESS unset), the denial is audit-logged, and an explicit
// opt-in restores the reads with an admin.location_view audit row.
// Needs TEST_DATABASE_URL.

func adminLocEnv(t *testing.T) (*circleEnv, *[]auditRow) {
	t.Helper()
	e := newCircleEnv(t)
	e.rt.Get("/api/admin/members", e.srv.AdminListMembers)
	e.rt.Get("/api/admin/families/{id}/members", e.srv.AdminListFamilyMembers)
	e.rt.Get("/api/admin/members/{id}/history", e.srv.AdminGetMemberHistory)
	e.rt.Get("/api/admin/members/{id}/history/export", e.srv.AdminExportMemberHistory)
	e.rt.Get("/api/admin/activity", e.srv.AdminActivityFeed)
	return e, auditCapture(e.srv)
}

func countAction(rows *[]auditRow, action string) int {
	n := 0
	for _, r := range *rows {
		if r.action == action {
			n++
		}
	}
	return n
}

func TestAdminLocationDeniedByDefault(t *testing.T) {
	e, rows := adminLocEnv(t)
	if e.srv.AdminLocationAccess {
		t.Fatal("AdminLocationAccess must be off in this test harness")
	}

	// Member list: users stay listed, positions are withheld.
	code, _, raw := e.do("A", "GET", "/api/admin/members", nil)
	if code != 200 {
		t.Fatalf("members code=%d %s", code, raw)
	}
	var list []map[string]any
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatal(err)
	}
	seen := false
	for _, m := range list {
		if m["id"] == e.ids["B"] {
			seen = true
		}
		for _, k := range []string{"lat", "lon", "ts", "battery_pct", "speed_mps", "accuracy_meters"} {
			if _, ok := m[k]; ok {
				t.Fatalf("member %v leaks %s with admin location access off", m["id"], k)
			}
		}
	}
	if !seen {
		t.Fatal("redacted list must still include the member")
	}
	if countAction(rows, "admin.location_denied") != 1 || countAction(rows, "admin.location_view") != 0 {
		t.Fatalf("audit rows: %+v", *rows)
	}

	// History and export are refused outright.
	e.mustCode("A", "GET", "/api/admin/members/"+e.ids["B"]+"/history?"+rangeQ(), nil, 403)
	code, _, raw = e.do("A", "GET", "/api/admin/members/"+e.ids["B"]+"/history/export?format=csv&"+rangeQ(), nil)
	if code != 403 || strings.Contains(string(raw), "10") && strings.Contains(string(raw), "20") && strings.Contains(string(raw), "lat") {
		t.Fatalf("export code=%d body=%s", code, raw)
	}
	if n := countAction(rows, "admin.location_denied"); n < 3 {
		t.Fatalf("expected denial rows for list, history and export, got %d: %+v", n, *rows)
	}
	if countAction(rows, "admin.location_view") != 0 {
		t.Fatalf("a denied deployment must not log successful views: %+v", *rows)
	}
}

func TestAdminLocationOptInAllowsAndAudits(t *testing.T) {
	e, rows := adminLocEnv(t)
	e.srv.AdminLocationAccess = true

	_, _, raw := e.do("A", "GET", "/api/admin/members", nil)
	var list []map[string]any
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatal(err)
	}
	got := false
	for _, m := range list {
		if m["id"] == e.ids["B"] && m["lat"] == float64(10) && m["lon"] == float64(20) {
			got = true
		}
	}
	if !got {
		t.Fatal("opt-in must expose last known positions")
	}
	e.mustCode("A", "GET", "/api/admin/members/"+e.ids["B"]+"/history?"+rangeQ(), nil, 200)
	if countAction(rows, "admin.location_view") < 2 {
		t.Fatalf("permitted reads must be audit-logged: %+v", *rows)
	}
	if countAction(rows, "admin.location_denied") != 0 {
		t.Fatalf("unexpected denial rows: %+v", *rows)
	}
}
