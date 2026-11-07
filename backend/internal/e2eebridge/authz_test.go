package e2eebridge

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Fail-closed authorization of wrappers, publishers and senders against the
// verified circle state AND the verified transparency log.

// prepared returns a bridge whose log is verified and whose state is current, plus
// the wrap addressed to it.
func prepared(t *testing.T, w *world) (*bridge, *circleState, e2ee.WrapRecord) {
	t.Helper()
	b := w.newBridge()
	if err := b.verifyLog(context.Background()); err != nil {
		t.Fatal(err)
	}
	st, err := b.fetchState(context.Background(), w.of.circle)
	if err != nil {
		t.Fatal(err)
	}
	return b, st, w.of.wraps[w.bridge.id][0]
}

func TestAcceptWrapBaseline(t *testing.T) {
	w := newWorld(t)
	b, st, wr := prepared(t, w)
	if _, err := b.acceptWrap(w.of.circle, st, wr); err != nil {
		t.Fatalf("the honest wrap must be accepted: %v", err)
	}
}

func TestAcceptWrapFailsClosed(t *testing.T) {
	cases := map[string]func(w *world, st *circleState, wr *e2ee.WrapRecord){
		"publisher missing from state": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			for i := range st.Members {
				var keep []e2ee.DeviceRecord
				for _, d := range st.Members[i].Devices {
					if d.DeviceID != w.phone.id {
						keep = append(keep, d)
					}
				}
				st.Members[i].Devices = keep
			}
		},
		"publisher key differs": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			st.Epochs[0].PublisherPub = std(w.bob.edPub)
		},
		"publisher revoked": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			d, _ := st.device(w.phone.id)
			now := t0
			d.RevokedAt = &now
		},
		"publisher not approved": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			d, _ := st.device(w.phone.id)
			f := false
			d.Approved = &f
		},
		"publisher not an admin": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			_, m := st.device(w.phone.id)
			m.Role = "member"
		},
		"epoch record not in the log": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			st.Epochs[0].KeyCommitment = std(make([]byte, 32))
		},
		"wrapper missing from state": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			wr.WrapperDeviceID = newUUIDv4()
		},
		"wrapper key differs": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			wr.WrapperEd25519Pub = std(w.bob.edPub)
		},
		"wrapper is another member's device": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			// Bob is neither the epoch publisher nor the recipient's own device.
			*wr = w.of.makeWrap(w.bob, w.bridge, 1, w.key1)
		},
		"wrapper registration forged": func(w *world, st *circleState, wr *e2ee.WrapRecord) {
			d, _ := st.device(w.phone.id)
			d.RegistrationSignature = std(make([]byte, 64))
		},
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			b, st, wr := prepared(t, w)
			wr2 := wr
			mut(w, st, &wr2)
			if _, err := b.acceptWrap(w.of.circle, st, wr2); err == nil {
				t.Fatal("wrap accepted")
			}
		})
	}
}

func TestAcceptWrapWithoutVerifiedLogIsRefused(t *testing.T) {
	w := newWorld(t)
	b := w.newBridge() // verifyLog never ran
	st, err := b.fetchState(context.Background(), w.of.circle)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.acceptWrap(w.of.circle, st, w.of.wraps[w.bridge.id][0]); err == nil {
		t.Fatal("accepted without a verified log")
	}
}

func TestWrapperNotInLogIsRefused(t *testing.T) {
	w := newWorld(t)
	// A second phone of alice, validly cross-signed but never logged, wraps the key.
	phone2 := newTDev(t, w.phone.user, "device", w.phone)
	w.of.members[0].devs = append(w.of.members[0].devs, phone2)
	w.of.wraps[w.bridge.id] = []e2ee.WrapRecord{w.of.makeWrap(phone2, w.bridge, 1, w.key1)}
	b, st, wr := prepared(t, w)
	if _, err := b.acceptWrap(w.of.circle, st, wr); err == nil {
		t.Fatal("wrap from an unlogged device accepted")
	}
	// Once the device is in the log the same wrap is fine (own device of the recipient's user).
	w.of.mu.Lock()
	w.of.logReg(phone2, w.phone)
	w.of.mu.Unlock()
	b, st, wr = prepared(t, w)
	if _, err := b.acceptWrap(w.of.circle, st, wr); err != nil {
		t.Fatalf("logged own device must be accepted: %v", err)
	}
}

func TestRevokedInLogIsRefused(t *testing.T) {
	w := newWorld(t)
	// The log says the publisher phone was revoked, though the (lying) state still lists it.
	fp, _ := hex.DecodeString(w.phone.rec.Fingerprint)
	w.of.mu.Lock()
	w.of.appendLog(e2ee.ActRevoke, w.phone, w.phone.user, "", w.phone.id, 0, fp, false)
	w.of.mu.Unlock()
	b, st, wr := prepared(t, w)
	if _, err := b.acceptWrap(w.of.circle, st, wr); err == nil {
		t.Fatal("wrap from a log-revoked publisher accepted")
	}
}

func TestSenderFromAnotherUserListedUnderMemberIsDropped(t *testing.T) {
	w := newWorld(t)
	w.cfg.Dawarich.SendUnmapped = false
	// The server lists BOB's device under ALICE, hoping Bob's positions are filed to Alice's account.
	w.of.mu.Lock()
	w.of.members[0].devs = append(w.of.members[0].devs, w.bob)
	w.of.members[1].devs = nil
	w.of.mu.Unlock()
	w.fix(w.bob, 1, 30, 48.1, 11.5)
	b := w.newBridge()
	w.cycleOK(b)
	if n := len(w.dw.points()); n != 0 {
		t.Fatalf("%d points delivered for a device listed under the wrong member", n)
	}
	if b.rs.Stats.Rejected[string(rNotMember)] == 0 {
		t.Fatalf("expected sender_not_member, got %v", b.rs.Stats.Rejected)
	}
}

func TestSenderNotInLogIsNotTrusted(t *testing.T) {
	w := newWorld(t)
	// A validly cross-signed phone that the log does not contain.
	ghost := newTDev(t, w.phone.user, "device", w.phone)
	w.of.members[0].devs = append(w.of.members[0].devs, ghost)
	w.fix(ghost, 1, 30, 1, 2)
	b := w.newBridge()
	w.cycleOK(b)
	if n := len(w.dw.points()); n != 0 {
		t.Fatalf("%d points delivered from a device missing in the log", n)
	}
}

func TestSenderRevokedAtIsDropped(t *testing.T) {
	w := newWorld(t)
	now := t0
	w.bob.rec.RevokedAt = &now
	w.fix(w.bob, 1, 30, 1, 2)
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.dw.points()) != 0 {
		t.Fatal("revoked sender delivered")
	}
}

func TestRegistrationCacheIsKeyedByWholeRecord(t *testing.T) {
	w := newWorld(t)
	st := &circleState{}
	good := w.phone.record()
	if !st.registrationOK(&good) {
		t.Fatal("honest record rejected")
	}
	// Same device_id and registration_signature, but another key: must be re-verified and fail.
	bad := good
	bad.X25519Pub = std(w.bob.xPub)
	if st.registrationOK(&bad) {
		t.Fatal("cache served a stale verdict for a different record")
	}
	// And the reverse order.
	st2 := &circleState{}
	if st2.registrationOK(&bad) || !st2.registrationOK(&good) {
		t.Fatal("poisoned cache")
	}
}

// A server that reports another key for the approving phone must not get that key pinned.
func TestEnrollRefusesAnApproverKeySwappedByTheServer(t *testing.T) {
	aliceID := newUUIDv4()
	of := newFakeOF(t, newUUIDv4(), aliceID)
	phone := newTDev(t, aliceID, "device", nil)
	evil := newTDev(t, aliceID, "device", nil)
	of.members = []*tmember{{user: aliceID, name: "Alice", devs: []*tdev{phone}}}
	dir := filepath.Join(t.TempDir(), "state")
	env := map[string]string{"E2EE_BRIDGE_PASSWORD": of.password, "E2EE_BRIDGE_STATE": dir}
	_, out, errs := runCLI(t, env, "", "enroll", "--server", of.srv.URL, "--email", "a@example.org")
	var rc requestCode
	for i, l := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.HasPrefix(l, "REQUEST CODE") {
			raw, _ := base64.URLEncoding.DecodeString(strings.TrimSpace(strings.Split(strings.TrimSpace(out), "\n")[i+2]))
			_ = json.Unmarshal(raw, &rc)
		}
	}
	if rc.D == "" {
		t.Fatalf("no request code: %s", errs)
	}
	fp, _ := hex.DecodeString(hexOfRC(rc))
	msg, _ := e2ee.LogActionMessage(e2ee.ActRegister, aliceID, phone.id, "", rc.D, 0, fp)
	ap, _ := json.Marshal(approvalCode{A: phone.id, S: std(ed25519.Sign(phone.priv, msg))})
	of.mu.Lock()
	of.swapApprover = evil
	of.mu.Unlock()
	code, _, errs := runCLI(t, env, "", "enroll", "--approval", base64.URLEncoding.EncodeToString(ap))
	if code == 0 || !strings.Contains(errs, "does not match") {
		t.Fatalf("a swapped approver key was accepted: %d %s", code, errs)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	var f identityFile
	_ = json.Unmarshal(raw, &f)
	if f.ApproverEdPub != "" || f.RegisteredAt != "" {
		t.Fatalf("identity was marked registered / pinned: %+v", f)
	}
}

func hexOfRC(rc requestCode) string {
	ed, _ := base64.StdEncoding.DecodeString(rc.E)
	x, _ := base64.StdEncoding.DecodeString(rc.X)
	fp, _ := e2ee.Fingerprint(ed, x)
	return hex.EncodeToString(fp)
}

// Devices of the bridge's OWN account must chain to the pinned approving phone: a
// second root of the account (e.g. made up by the server) and a bridge without a pin
// are refused; the approver's own chain is fine.
func TestOwnAccountDevicesMustChainToTheApprover(t *testing.T) {
	w := newWorld(t)
	b, st, _ := prepared(t, w)
	fake := newTDev(t, w.phone.user, "device", nil) // a second root of alice's account
	w.of.mu.Lock()
	w.of.members[0].devs = append(w.of.members[0].devs, fake)
	w.of.logReg(fake, fake)
	w.of.mu.Unlock()
	b2, st2, _ := prepared(t, w)
	_ = b
	_ = st
	dev, mem := st2.device(fake.id)
	if err := b2.trust(st2).AuthorizeSender(dev, mem); err == nil {
		t.Fatal("an own-account device with an unrelated root was accepted")
	}
	ph, memP := st2.device(w.phone.id)
	if err := b2.trust(st2).AuthorizeSender(ph, memP); err != nil {
		t.Fatalf("the approving phone itself was refused: %v", err)
	}
	// No pinned approver: own-account devices are refused.
	b2.id.f.ApproverEdPub = ""
	if err := b2.trust(st2).AuthorizeSender(ph, memP); err == nil {
		t.Fatal("own-account device accepted without a pinned approver")
	}
	// ...and so is every wrap.
	if _, err := b2.acceptWrap(w.of.circle, st2, w.of.wraps[w.bridge.id][0]); err == nil {
		t.Fatal("wrap accepted without a pinned approver")
	}
}
