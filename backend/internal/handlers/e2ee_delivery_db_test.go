package handlers

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// Needs TEST_DATABASE_URL (skipped otherwise).

func deliveryOf(t *testing.T, rep map[string]any, user string) map[string]any {
	t.Helper()
	for _, m := range rep["members"].([]any) {
		mm := m.(map[string]any)
		if mm["user_id"] == user {
			return mm
		}
	}
	t.Fatalf("member %s missing from %v", user, rep)
	return nil
}

// The report names the reason each member is silent, from metadata only.
func TestDeliveryReportReasons(t *testing.T) {
	e := newChanEnv(t)
	e.route("GET", "/circles/{id}/delivery", e.srv.E2EEDelivery)
	ctx := context.Background()
	get := func() map[string]any { return e.mustCode("A", "GET", "/circles/"+e.circle+"/delivery", nil, 200) }

	// Everyone holds a key wrap and nobody has sent yet: "never_sent", not "no location yet".
	rep := get()
	for _, n := range []string{"A", "B", "C"} {
		if r := deliveryOf(t, rep, e.ids[n])["reason"]; r != "never_sent" {
			t.Fatalf("%s before any item: %v", n, r)
		}
	}
	if rep["summary"] != "nobody_sending" {
		t.Fatalf("summary %v", rep["summary"])
	}

	// B sends a sealed fix: B is ok and shows when it last arrived.
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte(`{"lat":1,"lon":2}`)))
	rep = get()
	b := deliveryOf(t, rep, e.ids["B"])
	if b["reason"] != "ok" || b["last_item_at"] == nil || b["last_fix_at"] == nil {
		t.Fatalf("B: %v", b)
	}
	if rep["summary"] != "some_not_sending" {
		t.Fatalf("summary %v", rep["summary"])
	}

	// C's phone never got a wrap: the reason is the key, not silence.
	if _, err := e.pool.Exec(ctx, `DELETE FROM circle_key_wraps WHERE circle_id = $1 AND recipient_device_id = $2`, e.circle, e.c.id); err != nil {
		t.Fatal(err)
	}
	if r := deliveryOf(t, get(), e.ids["C"])["reason"]; r != "no_key_wrap" {
		t.Fatalf("C without wrap: %v", r)
	}

	// Sharing paused beats everything else.
	if _, err := e.pool.Exec(ctx, `UPDATE circle_members SET sharing_enabled = FALSE WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	if r := deliveryOf(t, get(), e.ids["B"])["reason"]; r != "sharing_paused" {
		t.Fatalf("B paused: %v", r)
	}

	// An app too old for the sealed channel.
	if _, err := e.pool.Exec(ctx, `INSERT INTO app_client_versions (user_id, app_version, platform) VALUES ($1, '0.15.0', 'android')`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	a := deliveryOf(t, get(), e.ids["A"])
	if a["reason"] != "update_needed" || a["app_bucket"] != "update_needed" || a["you"] != true {
		t.Fatalf("A old app: %v", a)
	}

	// Privacy: nothing position-like is in the answer, and outsiders get nothing.
	_, _, raw := e.do("A", "GET", "/circles/"+e.circle+"/delivery", nil)
	var any map[string]any
	_ = json.Unmarshal(raw, &any)
	for _, banned := range []string{`"lat"`, `"lon"`, "ciphertext", "accuracy"} {
		if strings.Contains(string(raw), banned) {
			t.Fatalf("delivery report leaks %s: %s", banned, raw)
		}
	}
	if code, _, _ := e.do("D", "GET", "/circles/"+e.circle+"/delivery", nil); code != 404 && code != 403 {
		t.Fatalf("outsider got %d", code)
	}
}

func familyLatOf(t *testing.T, raw []byte, user string) *float64 {
	t.Helper()
	var list []map[string]any
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
	for _, m := range list {
		if m["id"] == user {
			if v, ok := m["lat"].(float64); ok {
				return &v
			}
			return nil
		}
	}
	t.Fatalf("member %s not listed: %s", user, raw)
	return nil
}

// A member of a normal circle still shows on /family/members and in the socket
// snapshot after the lanes change that hid phone-only members' server positions.
func TestNormalCircleMembersStillHavePositions(t *testing.T) {
	e := newE2EEEnv(t)
	c := e.createCircle("A", "Plain", "B")
	_, _, raw := e.do("A", "GET", "/family/members?circle_id="+c, nil)
	if familyLatOf(t, raw, e.ids["B"]) == nil {
		t.Fatalf("normal circle member B has no position: %s", raw)
	}
	snap, err := e.srv.circleMembersSnapshot(context.Background(), []string{c}, e.ids["A"])
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, m := range snap {
		if m.ID == e.ids["B"] {
			found = m.Lat != nil
		}
	}
	if !found {
		t.Fatalf("socket snapshot lacks B's position: %+v", snap)
	}
}

// A private circle member on the server lane stays visible; a phone-only member is not
// (their position lives in sealed items). A phone-only member who is ALSO in a normal
// circle stays visible to that circle.
func TestPrivateServerLaneAndMixedMembership(t *testing.T) {
	e := readyLanes(t)
	e.route("GET", "/family/members", e.srv.ListMembers)
	// A and B are server-lane, C is phone-only.
	_, _, raw := e.do("B", "GET", "/family/members?circle_id="+e.circle, nil)
	if familyLatOf(t, raw, e.ids["A"]) == nil {
		t.Fatalf("server-lane member A hidden: %s", raw)
	}
	if familyLatOf(t, raw, e.ids["C"]) != nil {
		t.Fatalf("phone-only member C leaked a server position: %s", raw)
	}
	snap, err := e.srv.circleMembersSnapshot(context.Background(), []string{e.circle}, e.ids["B"])
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range snap {
		if m.ID == e.ids["A"] && m.Lat == nil {
			t.Fatalf("socket snapshot lacks server-lane A")
		}
		if m.ID == e.ids["C"] && m.Lat != nil {
			t.Fatalf("socket snapshot leaked phone-only C")
		}
	}
	// C also sits in a normal circle with D: D sees C there.
	plain := e.createCircle("C", "Plain", "D")
	_, _, raw = e.do("D", "GET", "/family/members?circle_id="+plain, nil)
	if familyLatOf(t, raw, e.ids["C"]) == nil {
		t.Fatalf("C is in a normal circle but D sees no position: %s", raw)
	}
}
