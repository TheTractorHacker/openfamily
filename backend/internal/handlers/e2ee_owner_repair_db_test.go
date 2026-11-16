package handlers

import (
	"bytes"
	"context"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// A key that replaced all of its user's keys (a reinstall without a backup) is approved in no circle, including
// circles the user creates afterwards. Before the fix that was a dead end for a new circle: turning Private on
// needs an approved key, approving oneself needs the owner-approval rule, and the rule could only be switched in a
// circle that was already Private. The creator can now walk it: rule on (password), approve own key (password),
// turn Private on. Approving a key that is already approved is an idempotent no-op.
func TestE2EEOwnerRepairFreshCircle(t *testing.T) {
	e := newE2EEEnv(t)
	e.setPassword("A", "correct horse battery")
	a := newTDev(t, e.ids["A"])
	e.register("A", a)
	// The reinstalled phone: a new root key that replaced the first one.
	a2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, a2, "device", nil, e2ee.ActReset, true), 201)

	c := e.createCircle("A", "Foleys")
	key := bytes.Repeat([]byte{9}, 32)
	approve := func(pw string) (int, map[string]any, string) {
		body := simpleAction(t, e2ee.ActApprove, a2, c, 0, a2.id, a2.fp)
		body["device_id"] = a2.id
		if pw != "" {
			body["password"] = pw
		}
		code, m, raw := e.do("A", "POST", "/circles/"+c+"/e2ee/approvals", body)
		return code, m, string(raw)
	}

	// Not approved: turning Private on is refused, and so is approving oneself without the rule.
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a2, mkWrap(t, c, 1, a2, a2, key)), 400)
	if code, m, raw := approve("correct horse battery"); code != 403 || m["can_enable_owner_approval"] != true {
		t.Fatalf("self approval without the rule: %d %s", code, raw)
	}

	// The rule can be switched on in the circle that is not Private yet (password needed).
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, true, "wrong"), 400)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, true, "correct horse battery"), 200)
	if code, m, raw := approve("correct horse battery"); code != 200 || m["self_approved"] != true {
		t.Fatalf("owner approval: %d %s", code, raw)
	}
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a2, mkWrap(t, c, 1, a2, a2, key)), 200)

	// Idempotent: the key is approved now, so a second approval (no password, even with the rule off again)
	// answers OK, adds no key-log entry and no approval row.
	logLen := func() int {
		var n int
		if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM e2ee_log`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := logLen()
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/owner-approval", ownerPolicyBody(t, a2, c, false, ""), 200)
	before++ // the rule change itself is one entry
	code, m, raw := approve("")
	if code != 200 || m["already_approved"] != true {
		t.Fatalf("repeated approval: %d %s", code, raw)
	}
	if got := logLen(); got != before {
		t.Fatalf("repeated approval changed the key log: %d -> %d", before, got)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM device_approvals WHERE device_id = $1 AND circle_id = $2`, a2.id, c).Scan(&n)
	if n != 1 {
		t.Fatalf("approval rows: %d", n)
	}

	// A first key (initial) is approved everywhere: approving it is the same no-op, never a self-approval refusal.
	b := newTDev(t, e.ids["B"])
	e.register("B", b)
	cb := e.createCircle("B", "Solo")
	body := simpleAction(t, e2ee.ActApprove, b, cb, 0, b.id, b.fp)
	body["device_id"] = b.id
	if code, m, raw := e.do("B", "POST", "/circles/"+cb+"/e2ee/approvals", body); code != 200 || m["already_approved"] != true {
		t.Fatalf("approving an initial key: %d %s", code, raw)
	}
}
