package handlers

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// Needs TEST_DATABASE_URL (skipped otherwise). A phone is simulated by tdev.

type tdev struct {
	id, uid string
	priv    ed25519.PrivateKey
	xsec    []byte
	ed, x   []byte
	fp      []byte
}

func newTDev(t *testing.T, uid string) *tdev {
	t.Helper()
	seed := make([]byte, 32)
	_, _ = rand.Read(seed)
	es, xs, _ := e2ee.DeriveIdentity(seed)
	priv := ed25519.NewKeyFromSeed(es)
	xk, _ := ecdh.X25519().NewPrivateKey(xs)
	idb := make([]byte, 16)
	_, _ = rand.Read(idb)
	idb[6], idb[8] = idb[6]&0x0f|0x40, idb[8]&0x3f|0x80
	id := fmt.Sprintf("%x-%x-%x-%x-%x", idb[0:4], idb[4:6], idb[6:8], idb[8:10], idb[10:])
	d := &tdev{id: id, uid: uid, priv: priv, xsec: xs, ed: priv.Public().(ed25519.PublicKey), x: xk.PublicKey().Bytes()}
	d.fp, _ = e2ee.Fingerprint(d.ed, d.x)
	return d
}

func b64s(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// regBody builds a registration request. actor == nil makes d a root.
func regBody(t *testing.T, d *tdev, kind string, actor *tdev, action byte, reset bool) map[string]any {
	t.Helper()
	bm, err := e2ee.BindingMessage(d.uid, d.id, d.ed, d.x)
	if err != nil {
		t.Fatal(err)
	}
	signer := d
	actorID := d.id
	if actor != nil {
		signer, actorID = actor, actor.id
	}
	lm, err := e2ee.LogActionMessage(action, d.uid, actorID, "", d.id, 0, d.fp)
	if err != nil {
		t.Fatal(err)
	}
	b := map[string]any{"device_id": d.id, "kind": kind, "ed25519_pub": b64s(d.ed), "x25519_pub": b64s(d.x),
		"signature": b64s(ed25519.Sign(d.priv, bm)), "label": "test", "log_signature": b64s(ed25519.Sign(signer.priv, lm)), "reset": reset}
	if actor != nil {
		b["actor_device_id"] = actor.id
	}
	return b
}

func (e *circleEnv) route(method, path string, h func(http.ResponseWriter, *http.Request)) {
	e.rt.MethodFunc(method, path, h)
}

func newE2EEEnv(t *testing.T) *circleEnv {
	e := newCircleEnv(t)
	e.route("POST", "/e2ee/devices", e.srv.E2EERegisterDevice)
	e.route("GET", "/e2ee/me", e.srv.E2EEMyDevices)
	e.route("POST", "/e2ee/devices/{id}/rotate", e.srv.E2EERotateDevice)
	e.route("DELETE", "/e2ee/devices/{id}", e.srv.E2EERevokeDevice)
	e.route("GET", "/e2ee/users/{user_id}/devices", e.srv.E2EEUserDevices)
	e.route("GET", "/circles/{id}/e2ee", e.srv.E2EECircleState)
	e.route("GET", "/circles/{id}/e2ee/wraps", e.srv.E2EEMyWraps)
	e.route("GET", "/circles/{id}/e2ee/pending", e.srv.E2EEPending)
	e.route("POST", "/circles/{id}/e2ee/enable", e.srv.E2EEEnable)
	e.route("POST", "/circles/{id}/e2ee/wraps", e.srv.E2EESubmitWraps)
	e.route("POST", "/circles/{id}/e2ee/epoch", e.srv.E2EEBumpEpoch)
	e.route("POST", "/circles/{id}/e2ee/disable", e.srv.E2EEDisable)
	e.route("POST", "/circles/{id}/e2ee/approvals", e.srv.E2EEApproveDevice)
	e.route("GET", "/e2ee/log", e.srv.E2EELog)
	return e
}

func (e *circleEnv) register(user string, d *tdev) {
	e.t.Helper()
	e.mustCode(user, "POST", "/e2ee/devices", regBody(e.t, d, "device", nil, e2ee.ActRegister, false), 201)
}

func mkWrap(t *testing.T, circle string, epoch int, wrapper, rcpt *tdev, key []byte) map[string]any {
	t.Helper()
	aad, err := e2ee.WrapAAD(circle, uint32(epoch), rcpt.id, wrapper.id)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := e2ee.Wrap(key, rcpt.x, aad)
	if err != nil {
		t.Fatal(err)
	}
	sm, _ := e2ee.WrapSigMessage(circle, uint32(epoch), rcpt.id, wrapper.id, blob)
	return map[string]any{"recipient_device_id": rcpt.id, "wrapper_device_id": wrapper.id,
		"wrapped_key": b64s(blob), "signature": b64s(ed25519.Sign(wrapper.priv, sm))}
}

// epochBody builds an enable/epoch request signed by actor.
func epochBody(t *testing.T, action byte, circle string, epoch int, actor *tdev, wraps ...map[string]any) map[string]any {
	t.Helper()
	ids := make([]string, len(wraps))
	blobs := make([][]byte, len(wraps))
	for i, w := range wraps {
		ids[i] = w["recipient_device_id"].(string)
		blobs[i], _ = base64.StdEncoding.DecodeString(w["wrapped_key"].(string))
	}
	lm, err := e2ee.LogActionMessage(action, actor.uid, actor.id, circle, "", uint32(epoch), e2ee.WrapsDigest(ids, blobs))
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"epoch": epoch, "wraps": wraps, "actor_device_id": actor.id, "log_signature": b64s(ed25519.Sign(actor.priv, lm))}
}

func simpleAction(t *testing.T, action byte, actor *tdev, circle string, epoch int, subject string, ref []byte) map[string]any {
	lm, err := e2ee.LogActionMessage(action, actor.uid, actor.id, circle, subject, uint32(epoch), ref)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"actor_device_id": actor.id, "log_signature": b64s(ed25519.Sign(actor.priv, lm))}
}

func TestE2EERegistrationValidation(t *testing.T) {
	e := newE2EEEnv(t)
	a := newTDev(t, e.ids["A"])
	good := regBody(t, a, "device", nil, e2ee.ActRegister, false)

	clone := func(mod func(m map[string]any)) map[string]any {
		m := map[string]any{}
		for k, v := range good {
			m[k] = v
		}
		mod(m)
		return m
	}
	bad := map[string]map[string]any{
		"bad signature": clone(func(m map[string]any) {
			s, _ := base64.StdEncoding.DecodeString(m["signature"].(string))
			s[3] ^= 1
			m["signature"] = b64s(s)
		}),
		"short key":        clone(func(m map[string]any) { m["ed25519_pub"] = b64s(a.ed[:16]) }),
		"zero x25519":      clone(func(m map[string]any) { m["x25519_pub"] = b64s(make([]byte, 32)) }),
		"zero ed25519":     clone(func(m map[string]any) { m["ed25519_pub"] = b64s(make([]byte, 32)) }),
		"swapped x25519":   clone(func(m map[string]any) { m["x25519_pub"] = b64s(newTDev(t, a.uid).x) }),
		"not base64":       clone(func(m map[string]any) { m["x25519_pub"] = "!!!" }),
		"bad device id":    clone(func(m map[string]any) { m["device_id"] = "DEVICE" }),
		"bad kind":         clone(func(m map[string]any) { m["kind"] = "admin" }),
		"bad log sig":      clone(func(m map[string]any) { m["log_signature"] = b64s(make([]byte, 64)) }),
		"recovery as root": clone(func(m map[string]any) { m["kind"] = "recovery" }),
	}
	for name, body := range bad {
		if code, _, raw := e.do("A", "POST", "/e2ee/devices", body); code != 400 {
			t.Errorf("%s: got %d want 400: %s", name, code, raw)
		}
	}
	// A key signed for user B cannot be registered by user A.
	other := newTDev(t, e.ids["B"])
	if code, _, raw := e.do("A", "POST", "/e2ee/devices", regBody(t, other, "device", nil, e2ee.ActRegister, false)); code != 400 {
		t.Errorf("binding for another user accepted: %d %s", code, raw)
	}
	// Private-looking fields are never accepted or stored.
	m := e.mustCode("A", "POST", "/e2ee/devices", good, 201)
	if m["fingerprint"] != e2ee.FingerprintHex(a.fp) || m["digits"] != e2ee.DigitGroups(a.fp) {
		t.Fatalf("server fingerprint differs from client derivation: %v", m)
	}
	// Idempotent.
	e.mustCode("A", "POST", "/e2ee/devices", good, 200)
	// Same key under another account is a conflict.
	stolen := regBody(t, a, "device", nil, e2ee.ActRegister, false)
	if code, _, _ := e.do("B", "POST", "/e2ee/devices", stolen); code != 400 && code != 409 {
		t.Errorf("registering A's key as B: %d", code)
	}
	// My record.
	me := e.mustCode("A", "GET", "/e2ee/me", nil, 200)
	if len(me["devices"].([]any)) != 1 {
		t.Fatalf("me: %v", me)
	}
}

func TestE2EECrossSigningAndRecoveryKind(t *testing.T) {
	e := newE2EEEnv(t)
	d1 := newTDev(t, e.ids["A"])
	e.register("A", d1)
	// Second root while the first is active needs a cross-signature.
	d2 := newTDev(t, e.ids["A"])
	code, m, _ := e.do("A", "POST", "/e2ee/devices", regBody(t, d2, "device", nil, e2ee.ActRegister, false))
	if code != 409 || m["error"] != "cross_signature_required" {
		t.Fatalf("unsigned second device: %d %v", code, m)
	}
	// Cross-signed by an outsider's key does not work: actor must be A's key.
	mallory := newTDev(t, e.ids["B"])
	e.register("B", mallory)
	forged := regBody(t, d2, "device", mallory, e2ee.ActRegister, false)
	if code, _, _ := e.do("A", "POST", "/e2ee/devices", forged); code != 400 {
		t.Fatalf("cross-signature by another user's key: %d", code)
	}
	// Properly cross-signed.
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, d2, "device", d1, e2ee.ActRegister, false), 201)
	// Recovery identity: cross-signed with the recovery action, one active at a time.
	rec := newTDev(t, e.ids["A"])
	got := e.mustCode("A", "POST", "/e2ee/devices", regBody(t, rec, "recovery", d1, e2ee.ActRecovery, false), 201)
	if got["kind"] != "recovery" {
		t.Fatalf("kind %v", got["kind"])
	}
	rec2 := newTDev(t, e.ids["A"])
	if code, _, _ := e.do("A", "POST", "/e2ee/devices", regBody(t, rec2, "recovery", d1, e2ee.ActRecovery, false)); code != 409 {
		t.Fatalf("second active recovery identity: %d", code)
	}
	// A new phone restores: registers a device cross-signed by the recovery key.
	d3 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, d3, "device", rec, e2ee.ActRegister, false), 201)
	// Reset: a root replacing all keys; everything else becomes revoked.
	d4 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, d4, "device", nil, e2ee.ActReset, true), 201)
	list := e.mustCode("A", "GET", "/e2ee/users/"+e.ids["A"]+"/devices", nil, 200)["devices"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["device_id"] != d4.id {
		t.Fatalf("reset must leave only the new root active: %v", list)
	}
}

func TestE2EEUserDeviceVisibility(t *testing.T) {
	e := newE2EEEnv(t)
	e.createCircle("A", "C", "B")
	a, b, d := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"]), newTDev(t, e.ids["D"])
	e.register("A", a)
	e.register("B", b)
	e.register("D", d)
	e.mustCode("A", "GET", "/e2ee/users/"+e.ids["B"]+"/devices", nil, 200)
	e.mustCode("B", "GET", "/e2ee/users/"+e.ids["A"]+"/devices", nil, 200)
	e.mustCode("A", "GET", "/e2ee/users/"+e.ids["A"]+"/devices", nil, 200)
	// No shared circle: uniform 404, for existing and for unknown users alike.
	e.mustCode("A", "GET", "/e2ee/users/"+e.ids["D"]+"/devices", nil, 404)
	e.mustCode("D", "GET", "/e2ee/users/"+e.ids["A"]+"/devices", nil, 404)
	e.mustCode("A", "GET", "/e2ee/users/00000000-0000-4000-8000-000000000000/devices", nil, 404)
	e.mustCode("A", "GET", "/e2ee/users/not-a-uuid/devices", nil, 404)
	// Revoked keys are not listed; revoking someone else's key is a 404.
	if code, _, _ := e.do("B", "DELETE", "/e2ee/devices/"+a.id, simpleAction(t, e2ee.ActRevoke, b, "", 0, a.id, a.fp)); code != 404 {
		t.Fatalf("revoking another user's key: %d", code)
	}
	e.mustCode("A", "DELETE", "/e2ee/devices/"+a.id, simpleAction(t, e2ee.ActRevoke, a, "", 0, a.id, a.fp), 200)
	if l := e.mustCode("B", "GET", "/e2ee/users/"+e.ids["A"]+"/devices", nil, 200)["devices"].([]any); len(l) != 0 {
		t.Fatalf("revoked key listed: %v", l)
	}
}

func TestE2EECircleLifecycleAndEpochs(t *testing.T) {
	e := newE2EEEnv(t)
	c := e.createCircle("A", "Private", "B", "C")
	a, b, cc := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"]), newTDev(t, e.ids["C"])
	e.register("A", a)
	e.register("B", b)
	e.register("C", cc)
	key1 := bytes.Repeat([]byte{1}, 32)

	// Not a member: 404. Plain member: 403.
	enable := epochBody(t, e2ee.ActEnable, c, 1, b, mkWrap(t, c, 1, b, b, key1))
	e.mustCode("D", "POST", "/circles/"+c+"/e2ee/enable", enable, 404)
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/enable", enable, 403)

	// Admin: bad epoch, no self wrap, bad wrap signature, wrap to a non-member.
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 2, a, mkWrap(t, c, 2, a, a, key1)), 409)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, b, key1)), 400)
	w := mkWrap(t, c, 1, a, a, key1)
	w["signature"] = b64s(make([]byte, 64))
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, w), 400)
	dd := newTDev(t, e.ids["D"])
	e.register("D", dd)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key1), mkWrap(t, c, 1, a, dd, key1)), 400)
	// Wrong log signature (signed by someone else) is refused.
	badLog := epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key1))
	badLog["log_signature"] = epochBody(t, e2ee.ActEnable, c, 1, b, mkWrap(t, c, 1, b, b, key1))["log_signature"]
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", badLog, 400)
	// A failed enable changed nothing.
	if st := e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200); st["mode"] != "off" || st["epoch"].(float64) != 0 {
		t.Fatalf("state after failed enables: %v", st)
	}

	// Good enable at epoch 1, wrapped to A and B only; C is pending.
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key1), mkWrap(t, c, 1, a, b, key1)), 200)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key1)), 409)
	pend := e.mustCode("B", "GET", "/circles/"+c+"/e2ee/pending", nil, 200)["pending"].([]any)
	if len(pend) != 1 || pend[0].(map[string]any)["device_id"] != cc.id || pend[0].(map[string]any)["approved"] != true {
		t.Fatalf("pending: %v", pend)
	}
	e.mustCode("D", "GET", "/circles/"+c+"/e2ee/pending", nil, 404)

	// A member wraps for C (cross-user wrapping is allowed for members); replay ignored.
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/wraps", map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, c, 1, b, cc, key1)}}, 200)
	// A wrap claiming a wrapper device that is not the caller's is refused.
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/wraps", map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, c, 1, a, cc, key1)}}, 400)
	// Wrong epoch for a member submission.
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/wraps", map[string]any{"epoch": 2, "wraps": []any{mkWrap(t, c, 2, b, cc, key1)}}, 409)

	// Wraps are served only to their recipient's owner (IDOR).
	own := e.mustCode("C", "GET", "/circles/"+c+"/e2ee/wraps?device_id="+cc.id, nil, 200)["wraps"].([]any)
	if len(own) != 1 {
		t.Fatalf("C wraps: %v", own)
	}
	if other := e.mustCode("B", "GET", "/circles/"+c+"/e2ee/wraps?device_id="+cc.id, nil, 200)["wraps"].([]any); len(other) != 0 {
		t.Fatalf("B read C's wraps: %v", other)
	}
	e.mustCode("D", "GET", "/circles/"+c+"/e2ee/wraps?device_id="+cc.id, nil, 404)
	// The served wrap opens with C's key and only C's.
	w0 := own[0].(map[string]any)
	blob, _ := base64.StdEncoding.DecodeString(w0["wrapped_key"].(string))
	aad, _ := e2ee.WrapAAD(c, 1, cc.id, b.id)
	if got, err := e2ee.Unwrap(blob, cc.xsec, cc.x, aad); err != nil || !bytes.Equal(got, key1) {
		t.Fatalf("recipient could not open its wrap: %v", err)
	}

	// Removing C forces a re-key and drops C's wraps.
	e.mustCode("A", "DELETE", "/circles/"+c+"/members/"+e.ids["C"], nil, 200)
	st := e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200)
	if st["rekey_required"] != true {
		t.Fatalf("removal did not require a re-key: %v", st)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM circle_key_wraps WHERE recipient_device_id = $1`, cc.id).Scan(&n)
	if n != 0 {
		t.Fatalf("removed member keeps %d wraps", n)
	}
	// Epoch: must be exactly current+1, admin only, removed member cannot receive.
	key2 := bytes.Repeat([]byte{2}, 32)
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 2, b, mkWrap(t, c, 2, b, b, key2)), 403)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 1, a, mkWrap(t, c, 1, a, a, key2)), 409) // rollback
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 3, a, mkWrap(t, c, 3, a, a, key2)), 409) // skip
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 2, a, mkWrap(t, c, 2, a, a, key2), mkWrap(t, c, 2, a, cc, key2)), 400)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 2, a, mkWrap(t, c, 2, a, a, key2), mkWrap(t, c, 2, a, b, key2)), 200)
	st = e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200)
	if st["epoch"].(float64) != 2 || st["rekey_required"] != false {
		t.Fatalf("after bump: %v", st)
	}
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/epoch", epochBody(t, e2ee.ActEpoch, c, 2, a, mkWrap(t, c, 2, a, a, key2)), 409)

	// Revoking B's device forces another re-key and B's wraps disappear.
	e.mustCode("B", "DELETE", "/e2ee/devices/"+b.id, simpleAction(t, e2ee.ActRevoke, b, "", 0, b.id, b.fp), 200)
	if st = e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200); st["rekey_required"] != true {
		t.Fatalf("device revoke did not require a re-key: %v", st)
	}
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM circle_key_wraps WHERE recipient_device_id = $1`, b.id).Scan(&n)
	if n != 0 {
		t.Fatalf("revoked device keeps %d wraps", n)
	}
	for _, m := range st["members"].([]any) {
		for _, dv := range m.(map[string]any)["devices"].([]any) {
			if dv.(map[string]any)["device_id"] == b.id {
				t.Fatal("revoked device listed in circle state")
			}
		}
	}
	// Disable keeps the epoch counter; re-enable continues from it.
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/disable", simpleAction(t, e2ee.ActDisable, b, c, 2, "", nil), 403)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/disable", simpleAction(t, e2ee.ActDisable, a, c, 2, "", nil), 200)
	st = e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200)
	if st["mode"] != "off" || st["epoch"].(float64) != 2 {
		t.Fatalf("after disable: %v", st)
	}
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key1)), 409)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 3, a, mkWrap(t, c, 3, a, a, key1)), 200)
}

func TestE2EEReplacementDeviceNeedsApproval(t *testing.T) {
	e := newE2EEEnv(t)
	c := e.createCircle("A", "Approve", "B")
	a, b := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"])
	e.register("A", a)
	e.register("B", b)
	key := bytes.Repeat([]byte{5}, 32)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key), mkWrap(t, c, 1, a, b, key)), 200)

	// B's phone is lost; B re-registers as a NEW ROOT (reset). It is not cross-signed.
	b2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, b2, "device", nil, e2ee.ActReset, true), 201)
	pend := e.mustCode("A", "GET", "/circles/"+c+"/e2ee/pending", nil, 200)["pending"].([]any)
	if len(pend) != 1 || pend[0].(map[string]any)["approved"] != false || pend[0].(map[string]any)["user_name"] == "" {
		t.Fatalf("pending must show the replacement as waiting for approval: %v", pend)
	}
	// The server refuses to store a wrap for it.
	wrap := map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, c, 1, a, b2, key)}}
	code, _, raw := e.do("A", "POST", "/circles/"+c+"/e2ee/wraps", wrap)
	if code != 400 || !strings.Contains(string(raw), "approval") {
		t.Fatalf("unapproved wrap: %d %s", code, raw)
	}
	// B cannot approve itself; a plain member cannot approve; the admin can.
	approve := func(user string, by *tdev, d *tdev) int {
		body := simpleAction(t, e2ee.ActApprove, by, c, 0, d.id, d.fp)
		body["device_id"] = d.id
		code, _, _ := e.do(user, "POST", "/circles/"+c+"/e2ee/approvals", body)
		return code
	}
	if code := approve("B", b2, b2); code != 403 {
		t.Fatalf("self approval: %d", code)
	}
	if code := approve("A", b2, b2); code != 400 { // wrong actor (not caller's key)
		t.Fatalf("approval signed by the subject: %d", code)
	}
	if code := approve("A", a, b2); code != 200 {
		t.Fatalf("admin approval: %d", code)
	}
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/wraps", wrap, 200)
	// Approval is per circle: it does not carry over to another circle.
	c2 := e.createCircle("A", "Other", "B")
	var ap int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM device_approvals WHERE device_id=$1 AND circle_id=$2`, b2.id, c2).Scan(&ap)
	if ap != 0 {
		t.Fatal("approval leaked to another circle")
	}
	// The earlier cross-signed path needs no approval: a second device of A.
	a2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, a2, "device", a, e2ee.ActRegister, false), 201)
	e.mustCode("B", "POST", "/circles/"+c+"/e2ee/wraps", map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, c, 1, b2, a2, key)}}, 200)
}

func TestE2EELogChainAndRedaction(t *testing.T) {
	e := newE2EEEnv(t)
	e.createCircle("A", "L", "B")
	a, b, d := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"]), newTDev(t, e.ids["D"])
	e.register("A", a)
	e.register("B", b)
	e.register("D", d)
	resp := e.mustCode("A", "GET", "/e2ee/log?after=0", nil, 200)
	entries := resp["entries"].([]any)
	head := resp["head"].(map[string]any)
	if len(entries) == 0 || head["hash"] == "" {
		t.Fatalf("log empty: %v", resp)
	}
	var sawD, sawB, sawRedacted bool
	prev := ""
	for _, raw := range entries {
		en := raw.(map[string]any)
		if prev != "" && en["prev_hash"] != prev {
			t.Fatalf("chain broken at seq %v", en["seq"])
		}
		prev = en["entry_hash"].(string)
		if en["redacted"] == true {
			sawRedacted = true
			if en["user_id"] != nil || en["actor_device_id"] != nil {
				t.Fatalf("redacted entry leaks ids: %v", en)
			}
			continue
		}
		if en["user_id"] == e.ids["D"] {
			sawD = true
		}
		if en["user_id"] == e.ids["B"] {
			sawB = true
		}
	}
	if sawD {
		t.Fatal("log leaked a user with whom no circle is shared")
	}
	if !sawB || !sawRedacted {
		t.Fatalf("expected B visible and D redacted (visible B=%v redacted=%v)", sawB, sawRedacted)
	}
	// The stored log cannot be edited or deleted.
	if _, err := e.pool.Exec(context.Background(), `UPDATE e2ee_log SET epoch = 9 WHERE seq = 1`); err == nil {
		t.Fatal("e2ee_log UPDATE succeeded")
	}
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM e2ee_log WHERE seq = 1`); err == nil {
		t.Fatal("e2ee_log DELETE succeeded")
	}
	// Operator verification of the whole chain and all signatures.
	var out bytes.Buffer
	if err := PrintE2EELogHead(context.Background(), e.pool, &out); err != nil {
		t.Fatalf("log verification: %v", err)
	}
	if !strings.Contains(out.String(), "head hash") {
		t.Fatalf("log head output: %s", out.String())
	}
	var fp bytes.Buffer
	if err := PrintE2EEFingerprints(context.Background(), e.pool, &fp, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fp.String(), e2ee.ShortFingerprint(a.fp)) {
		t.Fatalf("fingerprint CLI output lacks A's key: %s", fp.String())
	}
}

func TestE2EERateLimits(t *testing.T) {
	e := newE2EEEnv(t)
	e.srv.AuthLimit = sms.NewLimiter()
	for i := 0; i < e2eeRegisterPerUser; i++ {
		e.mustCode("E", "POST", "/e2ee/devices", map[string]any{}, 400)
	}
	e.mustCode("E", "POST", "/e2ee/devices", map[string]any{}, 429)
	// Another user is unaffected.
	e.mustCode("P", "POST", "/e2ee/devices", map[string]any{}, 400)
}

// No key, signature, wrap or fingerprint material may reach logs or audit rows
// (regression guard for "never log keys/ciphertext").
func TestE2EENoSecretsInLogsOrAudit(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)

	e := newE2EEEnv(t)
	c := e.createCircle("A", "NoLogs", "B")
	a, b := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"])
	body := regBody(t, a, "device", nil, e2ee.ActRegister, false)
	e.mustCode("A", "POST", "/e2ee/devices", body, 201)
	e.register("B", b)
	key := bytes.Repeat([]byte{8}, 32)
	w1, w2 := mkWrap(t, c, 1, a, a, key), mkWrap(t, c, 1, a, b, key)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, w1, w2), 200)
	e.mustCode("A", "POST", "/e2ee/devices", map[string]any{"ed25519_pub": "AAAA"}, 400)

	secrets := []string{b64s(key), fmt.Sprintf("%x", key), b64s(a.xsec), fmt.Sprintf("%x", a.xsec), b64s(a.priv.Seed()),
		body["signature"].(string), body["log_signature"].(string), w1["wrapped_key"].(string), w2["wrapped_key"].(string),
		w1["signature"].(string), body["ed25519_pub"].(string)}
	rows, err := e.pool.Query(context.Background(), `SELECT action || ' ' || detail FROM audit_log WHERE user_id = $1 OR user_id = $2`, e.ids["A"], e.ids["B"])
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var audit strings.Builder
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		audit.WriteString(s + "\n")
	}
	if !strings.Contains(audit.String(), "e2ee.enabled") {
		t.Fatalf("audit rows missing: %s", audit.String())
	}
	for _, sct := range secrets {
		if strings.Contains(buf.String(), sct) || strings.Contains(audit.String(), sct) {
			t.Fatalf("secret material %q… leaked into logs or audit", sct[:8])
		}
	}
}

func TestE2EERotateRequiresOldKeySignature(t *testing.T) {
	e := newE2EEEnv(t)
	c := e.createCircle("A", "Rot", "B")
	a, b := newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"])
	e.register("A", a)
	e.register("B", b)
	key := bytes.Repeat([]byte{3}, 32)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, a, mkWrap(t, c, 1, a, a, key), mkWrap(t, c, 1, a, b, key)), 200)

	rotBody := func(nd *tdev, actor *tdev) map[string]any {
		body := regBody(t, nd, "device", nil, e2ee.ActRotate, false)
		delete(body, "actor_device_id")
		lm, _ := e2ee.LogActionMessage(e2ee.ActRotate, nd.uid, actor.id, "", nd.id, 0, nd.fp)
		body["log_signature"] = b64s(ed25519.Sign(actor.priv, lm))
		return body
	}
	nb := newTDev(t, e.ids["B"])
	// Signed by the NEW key instead of the old one: refused.
	e.mustCode("B", "POST", "/e2ee/devices/"+b.id+"/rotate", rotBody(nb, nb), 400)
	// Someone else cannot rotate B's key.
	if code, _, _ := e.do("A", "POST", "/e2ee/devices/"+b.id+"/rotate", rotBody(nb, a)); code != 400 && code != 404 {
		t.Fatalf("rotating another user's key: %d", code)
	}
	// The old key vouches for the new one.
	got := e.mustCode("B", "POST", "/e2ee/devices/"+b.id+"/rotate", rotBody(nb, b), 201)
	if got["registered_by_device_id"] != b.id {
		t.Fatalf("rotation not chained to the old key: %v", got)
	}
	list := e.mustCode("A", "GET", "/e2ee/users/"+e.ids["B"]+"/devices", nil, 200)["devices"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["device_id"] != nb.id {
		t.Fatalf("old key still active after rotation: %v", list)
	}
	// Rotation flags the circle for a re-key and drops the old key's wrap.
	st := e.mustCode("A", "GET", "/circles/"+c+"/e2ee", nil, 200)
	if st["rekey_required"] != true {
		t.Fatalf("rotation did not require a re-key: %v", st)
	}
	// The rotated key is cross-signed, so it needs no admin approval, but it holds no wrap yet.
	pend := e.mustCode("A", "GET", "/circles/"+c+"/e2ee/pending", nil, 200)["pending"].([]any)
	if len(pend) != 1 || pend[0].(map[string]any)["approved"] != true {
		t.Fatalf("pending after rotation: %v", pend)
	}
}
