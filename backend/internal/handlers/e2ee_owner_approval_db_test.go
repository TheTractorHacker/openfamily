package handlers

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

func ownerPolicyBody(t *testing.T, actor *tdev, circle string, on bool, password string) map[string]any {
	t.Helper()
	ref, err := e2ee.OwnerApprovalRef(circle, actor.uid, on)
	if err != nil {
		t.Fatal(err)
	}
	b := simpleAction(t, e2ee.ActOwnerApproval, actor, circle, 0, "", ref)
	b["enabled"] = on
	if password != "" {
		b["password"] = password
	}
	return b
}

func (e *circleEnv) setPassword(user, pw string) {
	e.t.Helper()
	h, err := auth.HashPassword(pw)
	if err != nil {
		e.t.Fatal(err)
	}
	if _, err := e.pool.Exec(context.Background(), `UPDATE users SET password_hash = $2 WHERE id = $1`, e.ids[user], h); err != nil {
		e.t.Fatal(err)
	}
}

// The sole admin (and creator) of a Private circle resets their phone key. Their
// new key can be approved by themselves only under the owner-approval policy,
// only with a fresh password, and never by an admin who did not create the circle.
func TestE2EEOwnerApproval(t *testing.T) {
	e := newE2EEEnv(t)
	e.setPassword("A", "correct horse battery")
	e.setPassword("B", "b-password-123")
	c := e.createCircle("A", "Owner", "B")
	a, b := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"])
	e.register("A", a)
	e.register("B", b)
	key := bytes.Repeat([]byte{7}, 32)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key), mkWrap(t, c, 1, a, b, key)), 200)

	// A sets the phone up again: a new root key that nobody vouches for.
	a2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, a2, "device", nil, e2ee.ActReset, true), 201)

	approve := func(user string, by, d *tdev, pw string) (int, map[string]any, string) {
		body := simpleAction(t, e2ee.ActApprove, by, c, 0, d.id, d.fp)
		body["device_id"] = d.id
		if pw != "" {
			body["password"] = pw
		}
		code, m, raw := e.do(user, "POST", "/circles/"+c+"/e2ee/approvals", body)
		return code, m, string(raw)
	}

	// Policy off: 403 with the actionable text for a sole admin who created the circle.
	code, m, raw := approve("A", a2, a2, "correct horse battery")
	if code != 403 || m["code"] != codeSelfApproval || m["sole_admin"] != true || m["can_enable_owner_approval"] != true ||
		!strings.Contains(raw, "only admin") || !strings.Contains(raw, "turn on owner approval") {
		t.Fatalf("policy off: %d %s", code, raw)
	}

	// Turning the policy on: creator only, signed, and with the password.
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, b, c, true, "b-password-123"), 403) // B is no admin
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, true, ""), 400)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, true, "wrong password"), 400)
	bad := ownerPolicyBody(t, a2, c, false, "correct horse battery") // signature says "off"
	bad["enabled"] = true
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", bad, 400)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, true, "correct horse battery"), 200)
	st := e.mustCode("B", "GET", "/circles/"+c+"/e2ee", nil, 200)
	if st["owner_approval"] != true || st["created_by"] != e.ids["A"] {
		t.Fatalf("circle state: %v", st)
	}

	// The log entry is signed by A's key and verifies; old apps see it redacted.
	findPolicy := func(q string) map[string]any {
		var found map[string]any
		entries := e.mustCode("B", "GET", "/e2ee/log?after=0"+q, nil, 200)["entries"].([]any)
		for _, x := range entries {
			en := x.(map[string]any)
			if en["action"] != nil && int(en["action"].(float64)) == int(e2ee.ActOwnerApproval) {
				found = en
			}
		}
		return found
	}
	if findPolicy("") != nil {
		t.Fatal("an app that did not ask for owner-approval entries got one unredacted")
	}
	en := findPolicy("&owner_approval=1")
	if en == nil || en["user_id"] != e.ids["A"] || en["circle_id"] != c {
		t.Fatalf("policy entry: %v", en)
	}
	ref, _ := hex.DecodeString(en["ref"].(string))
	pub, _ := base64.StdEncoding.DecodeString(en["actor_ed25519_pub"].(string))
	sig, _ := base64.StdEncoding.DecodeString(en["signature"].(string))
	if want, _ := e2ee.OwnerApprovalRef(c, e.ids["A"], true); !bytes.Equal(ref, want) {
		t.Fatal("policy ref is not the signed 'on' statement")
	}
	if e2ee.VerifyLogAction(pub, e2ee.ActOwnerApproval, e.ids["A"], a2.id, c, "", 0, ref, sig) != nil {
		t.Fatal("policy entry signature does not verify")
	}

	// On + creator, but no fresh authentication: refused.
	if code, _, raw := approve("A", a2, a2, ""); code != 400 {
		t.Fatalf("self approval without password: %d %s", code, raw)
	}
	if code, _, raw := approve("A", a2, a2, "stale or wrong"); code != 400 {
		t.Fatalf("self approval with a wrong password: %d %s", code, raw)
	}
	// On + creator + fresh password: approved, and marked as such.
	if code, m, raw := approve("A", a2, a2, "correct horse battery"); code != 200 || m["self_approved"] != true {
		t.Fatalf("owner approval: %d %s", code, raw)
	}
	var self bool
	_ = e.pool.QueryRow(context.Background(), `SELECT self_approved FROM device_approvals WHERE device_id = $1 AND circle_id = $2`, a2.id, c).Scan(&self)
	if !self {
		t.Fatal("approval not marked self_approved")
	}
	st = e.mustCode("B", "GET", "/circles/"+c+"/e2ee", nil, 200)
	for _, mm := range st["members"].([]any) {
		for _, dd := range mm.(map[string]any)["devices"].([]any) {
			d := dd.(map[string]any)
			if d["device_id"] == a2.id && (d["approved"] != true || d["owner_approved"] != true) {
				t.Fatalf("a2 in circle state: %v", d)
			}
		}
	}
	// The owner can now publish the new circle key to their new phone.
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 2, a2, mkWrap(t, c, 2, a2, a2, key), mkWrap(t, c, 2, a2, b, key)), 200)

	// A non-creator admin can never approve their own device, policy or not.
	e.mustCode("A", "PATCH", "/circles/"+c+"/members/"+e.ids["B"], map[string]string{"role": "admin"}, 200)
	b2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, b2, "device", nil, e2ee.ActReset, true), 201)
	if code, m, raw := approve("B", b2, b2, "b-password-123"); code != 403 || m["can_enable_owner_approval"] != false {
		t.Fatalf("non-creator self approval: %d %s", code, raw)
	}
	// ...and cannot turn the policy on, but any admin may turn it off (no password needed).
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, b2, c, true, "b-password-123"), 403)
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, b2, c, false, ""), 200)

	// Policy off again: A's next replacement needs B; the text points at the other admin.
	a3 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, a3, "device", nil, e2ee.ActReset, true), 201)
	code, m, raw = approve("A", a3, a3, "correct horse battery")
	if code != 403 || m["sole_admin"] != false || !strings.Contains(raw, "Another circle admin") {
		t.Fatalf("policy off with a second admin: %d %s", code, raw)
	}
	// Approving someone else is unchanged and needs no password.
	if code, m, raw := approve("A", a3, b2, ""); code != 200 || m["self_approved"] != false {
		t.Fatalf("approval of another member: %d %s", code, raw)
	}
}
