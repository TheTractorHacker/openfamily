package handlers

import (
	"context"
	"strings"
	"testing"
)

// legacyFamily builds a real family row (the sync triggers mirror it into
// circles) with one admin and the listed members, and removes it afterwards.
func (e *circleEnv) legacyFamily(name, admin string, members ...string) string {
	e.t.Helper()
	ctx := context.Background()
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ($1) RETURNING id::text`, name).Scan(&fam); err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() {
		e.pool.Exec(ctx, `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam)
	})
	set := func(key, role string) {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = $2 WHERE id = $3`, fam, role, e.ids[key]); err != nil {
			e.t.Fatal(err)
		}
	}
	set(admin, "admin")
	for _, m := range members {
		set(m, "member")
	}
	return fam
}

// Two families: A admin + B member in c1; C admin + D member in c2 (D alone
// also has a platform-admin flag variant tested via P).
func TestUpdateFamilyMember(t *testing.T) {
	e := newCircleEnv(t)
	var audit []string
	e.srv.auditHook = func(u, f, a, d string) { audit = append(audit, a+"|"+d) }
	c1 := e.legacyFamily("Fam1", "A", "B", "P")
	_ = e.legacyFamily("Fam2", "C", "D")
	ctx := context.Background()
	// P: platform admin inside family 1.
	_ = c1
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = true WHERE id = $1`, e.ids["P"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE users SET phone = '+15550007777' WHERE id = $1`, e.ids["D"]); err != nil {
		t.Fatal(err)
	}

	type tc struct {
		name   string
		caller string
		target string
		body   any
		want   int
	}
	cases := []tc{
		{"admin edits name+phone", "A", "B", map[string]any{"name": "  Bobby ", "phone": "+15551230001"}, 200},
		{"admin clears phone", "A", "B", map[string]any{"phone": ""}, 200},
		{"admin edits self", "A", "A", map[string]any{"name": "Ann"}, 200},
		{"plain member forbidden", "B", "A", map[string]any{"name": "x"}, 403},
		{"other family admin gets 404", "C", "B", map[string]any{"name": "x"}, 404},
		{"other family member gets 404", "D", "B", map[string]any{"name": "x"}, 404},
		{"unrelated user gets 404", "E", "B", map[string]any{"name": "x"}, 404},
		{"unknown id 404", "A", "ZZ", map[string]any{"name": "x"}, 404},
		{"empty name", "A", "B", map[string]any{"name": "   "}, 400},
		{"long name", "A", "B", map[string]any{"name": strings.Repeat("x", maxAdminNameLength+1)}, 400},
		{"bad phone", "A", "B", map[string]any{"phone": "abc"}, 400},
		{"empty body", "A", "B", map[string]any{}, 400},
		{"phone taken", "A", "B", map[string]any{"phone": "+15550007777"}, 409},
		{"cannot edit platform admin", "A", "P", map[string]any{"name": "x"}, 403},
		{"plain-member platform admin uses /me not this", "P", "P", map[string]any{"name": "Pat"}, 403},
		{"email ignored not accepted alone", "A", "B", map[string]any{"email": "z@example.com"}, 400},
	}
	for _, c := range cases {
		path := "/family/members/" + e.ids[c.target]
		if c.name == "unknown id 404" {
			path = "/family/members/00000000-0000-0000-0000-00000000dead"
		}
		code, _, raw := e.do(c.caller, "PATCH", path, c.body)
		if code != c.want {
			t.Errorf("%s: got %d want %d: %s", c.name, code, c.want, raw)
		}
	}
	// Isolation: family 2 members untouched by family 1 attempts.
	var dName string
	_ = e.pool.QueryRow(ctx, `SELECT name FROM users WHERE id=$1`, e.ids["D"]).Scan(&dName)
	if dName != "UserD" {
		t.Errorf("D modified: %q", dName)
	}
	// Email must be unchanged.
	var email string
	_ = e.pool.QueryRow(ctx, `SELECT email FROM users WHERE id=$1`, e.ids["B"]).Scan(&email)
	if strings.HasPrefix(email, "z@") {
		t.Errorf("email changed")
	}
	var bName string
	_ = e.pool.QueryRow(ctx, `SELECT name FROM users WHERE id=$1`, e.ids["B"]).Scan(&bName)
	if bName != "Bobby" {
		t.Errorf("name not trimmed/stored: %q", bName)
	}
	// Audit has field names only.
	found := false
	for _, a := range audit {
		if strings.HasPrefix(a, "family.member_updated|") {
			found = true
			if strings.Contains(a, "Bobby") || strings.Contains(a, "+1555") {
				t.Errorf("audit leaks values: %s", a)
			}
		}
	}
	if !found {
		t.Error("no audit entry")
	}
	if code, _, _ := e.do("", "PATCH", "/family/members/"+e.ids["B"], map[string]any{"name": "x"}); code != 401 {
		t.Errorf("anon: %d", code)
	}
}

// GET /family/members returns phone only to admins of the family.
func TestListMembersPhoneOnlyForAdmins(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	// GET /family/members reads the legacy family, so build a real family row
	// (the sync triggers mirror it into circles).
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('Fam1') RETURNING id::text`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.pool.Exec(ctx, `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam); e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam) })
	if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = 'admin' WHERE id = $2`, fam, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = 'member', phone = '+15550009999' WHERE id = $2`, fam, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	for user, wantPhone := range map[string]bool{"A": true, "B": false} {
		_, _, raw := e.do(user, "GET", "/family/members", nil)
		if got := strings.Contains(string(raw), "+15550009999"); got != wantPhone {
			t.Errorf("%s sees phone=%v want %v: %s", user, got, wantPhone, raw)
		}
	}
}

// Name and phone are the person's own account fields: admin rights over a
// circle you merely share with them, or over a fellow admin, are not enough.
func TestUpdateFamilyMemberAuthorityLimits(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	_ = e.legacyFamily("FamX", "A", "B")
	_ = e.legacyFamily("FamY", "C", "D")
	// C also administers a separate Friends circle that B joins.
	_ = e.createCircle("C", "Friends", "B")
	if code, _, raw := e.do("C", "PATCH", "/family/members/"+e.ids["B"], map[string]any{"name": "Hijack", "phone": "+15550001111"}); code != 403 {
		t.Errorf("Friends-circle admin editing a user outside their family: got %d want 403: %s", code, raw)
	}
	// Promote D to admin of FamY: C may not edit a fellow admin, D may edit self.
	if _, err := e.pool.Exec(ctx, `UPDATE users SET role = 'admin' WHERE id = $1`, e.ids["D"]); err != nil {
		t.Fatal(err)
	}
	if code, _, raw := e.do("C", "PATCH", "/family/members/"+e.ids["D"], map[string]any{"name": "Hijack"}); code != 403 {
		t.Errorf("admin editing a co-admin: got %d want 403: %s", code, raw)
	}
	if code, _, raw := e.do("D", "PATCH", "/family/members/"+e.ids["D"], map[string]any{"name": "Dee"}); code != 200 {
		t.Errorf("admin editing self: got %d want 200: %s", code, raw)
	}
	var bName, bPhone string
	_ = e.pool.QueryRow(ctx, `SELECT name, COALESCE(phone,'') FROM users WHERE id = $1`, e.ids["B"]).Scan(&bName, &bPhone)
	if bName == "Hijack" || bPhone == "+15550001111" {
		t.Errorf("B was modified despite 403: %q %q", bName, bPhone)
	}
	// The member's own family admin still can.
	if code, _, raw := e.do("A", "PATCH", "/family/members/"+e.ids["B"], map[string]any{"name": "Bea"}); code != 200 {
		t.Errorf("own-family admin: got %d want 200: %s", code, raw)
	}
}
