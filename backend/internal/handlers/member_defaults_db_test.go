package handlers

import (
	"context"
	"strings"
	"testing"
)

// Member defaults (docs/design/PRIVACY_PROCESSING.md section 23). Needs TEST_DATABASE_URL.
// Authorization (platform admin only) is covered by cmd/server TestAuthzMatrix, which walks
// every route registered in main.go.

func TestMemberDefaultsAPI(t *testing.T) {
	e := newLaneEnv(t)
	ctx := context.Background()
	e.route("GET", "/api/admin/settings/member-defaults", e.srv.AdminGetMemberDefaults)
	e.route("PUT", "/api/admin/settings/member-defaults", e.srv.AdminPutMemberDefaults)
	e.route("GET", "/api/admin/members-not-on-server", e.srv.AdminMembersNotOnServer)
	reset := func() {
		_, _ = e.pool.Exec(ctx, `UPDATE server_profile SET deployment_profile = NULL, member_default_lane = NULL, member_auto_apply = NULL WHERE id = 1`)
	}
	reset()
	t.Cleanup(reset)
	t.Setenv("DEPLOYMENT_PROFILE", "")

	// Unset profile reads as cloud: phone, prompt only.
	m := e.mustCode("A", "GET", "/api/admin/settings/member-defaults", nil, 200)
	if m["default_lane"] != "phone" || m["auto_apply"] != false || m["source"] != "profile" || m["remind_text"] == "" {
		t.Fatalf("cloud defaults: %v", m)
	}
	// Home: server + auto-apply, derived (not stored).
	e.sql(`UPDATE server_profile SET deployment_profile = 'home' WHERE id = 1`)
	m = e.mustCode("A", "GET", "/api/admin/settings/member-defaults", nil, 200)
	if m["default_lane"] != "server" || m["auto_apply"] != true || m["source"] != "profile" {
		t.Fatalf("home defaults: %v", m)
	}
	// The apps see it, read-only, on the existing route.
	_, app, _ := e.do("B", "GET", "/e2ee/server-device", nil)
	md, _ := app["member_defaults"].(map[string]any)
	if md["default_lane"] != "server" || md["auto_apply"] != true {
		t.Fatalf("app view: %v", app)
	}
	// Section 24: nothing saved by an administrator, so the circle's own signed default also counts.
	if md["follow_circle_default"] != true || m["follow_circle_default"] != true {
		t.Fatalf("follow_circle_default while derived: %v / %v", app, m)
	}

	// Validation.
	e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{}, 400)
	e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{"default_lane": "moon"}, 400)
	e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{"default_lane": "phone", "auto_apply": true}, 400)

	// The admin choice wins and is audited.
	m = e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{"auto_apply": false}, 200)
	if m["auto_apply"] != false || m["default_lane"] != "server" || m["source"] != "admin" {
		t.Fatalf("saved: %v", m)
	}
	// An administrator's saved choice is final: circles' own defaults no longer switch members on.
	_, app, _ = e.do("B", "GET", "/e2ee/server-device", nil)
	md, _ = app["member_defaults"].(map[string]any)
	if md["follow_circle_default"] != false || md["auto_apply"] != false {
		t.Fatalf("app view after an admin choice: %v", app)
	}
	m = e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{"default_lane": "phone"}, 200)
	if m["default_lane"] != "phone" || m["auto_apply"] != false {
		t.Fatalf("phone: %v", m)
	}
	m = e.mustCode("A", "PUT", "/api/admin/settings/member-defaults", map[string]any{"reset": true}, 200)
	if m["source"] != "profile" || m["auto_apply"] != true {
		t.Fatalf("reset: %v", m)
	}
	var audits int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'admin.member_defaults_changed'`).Scan(&audits)
	if audits < 3 {
		t.Fatalf("not audit-logged (%d)", audits)
	}
	// Exposure: the defaults record signs and stores no pref for anybody.
	if n := e.count(`SELECT count(*) FROM e2ee_processing_pref`); n != 0 {
		t.Fatalf("defaults created %d prefs", n)
	}
}

func TestMembersNotOnServer(t *testing.T) {
	e := newLaneEnv(t)
	e.route("GET", "/api/admin/members-not-on-server", e.srv.AdminMembersNotOnServer)
	e.enableAssist("allowed")
	e.setLane("B", e.b, "server", 1, 200)
	e.setLane("C", e.c, "phone", 1, 200)

	list := func() map[string]string {
		m := e.mustCode("A", "GET", "/api/admin/members-not-on-server", nil, 200)
		out := map[string]string{}
		for _, x := range m["members"].([]any) {
			it := x.(map[string]any)
			out[it["user_id"].(string)] = it["reason"].(string) + "|" + it["remind_text"].(string)
		}
		return out
	}
	got := list()
	if _, on := got[e.b.uid]; on {
		t.Fatalf("Ben is on the server and must not be listed: %v", got)
	}
	if !strings.HasPrefix(got[e.c.uid], "phone|") || got[e.c.uid] != "phone|" {
		t.Fatalf("Cleo chose the phone: listed, no reminder: %q", got[e.c.uid])
	}
	if r := got[e.a.uid]; !strings.HasPrefix(r, "no_choice|Please open the Orbitly app") {
		t.Fatalf("Anna has no choice yet: %q", r)
	}
	// A member whose app cannot sign lanes is reported as needing an update.
	e.sql(`UPDATE device_keys SET caps = '{}' WHERE device_id = $1`, e.a.id)
	if r := list()[e.a.uid]; !strings.HasPrefix(r, "needs_update|") {
		t.Fatalf("old app: %q", r)
	}
}
