package main

import (
	"context"
	"encoding/hex"
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
