package e2ee

import (
	"crypto/ed25519"
	"encoding/hex"
	"testing"
)

// A server key kept across an owner key reset (ActServerAttach, action 13).

func (l *tlog) attach(actor, server byte) {
	k := l.keys[tid(actor)]
	rec := l.recs[tid(server)]
	fp, _ := hex.DecodeString(rec.Fingerprint)
	l.add(ActServerAttach, k, tid(actor), k.Public().(ed25519.PublicKey), tid(server), fp)
}

// serverFlow: owner phone 1, owner phone 2 (vouched by 1), server key 3 (approved by phone 2).
func serverFlow(t *testing.T) *tlog {
	l := newTLog(t)
	l.device(1, 0)
	l.device(2, 1)
	l.device(3, 2)
	rec := l.recs[tid(3)]
	rec.Kind = "server"
	l.recs[tid(3)] = rec
	return l
}

func TestServerKeyKeptAcrossResetOnlyWithTheNewRootsAttach(t *testing.T) {
	// No attach: the reset retires the server key like every other earlier key.
	l := serverFlow(t)
	l.deviceAs(7, 0, ActReset)
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	if !idx.Revoked(tid(3)) {
		t.Fatal("a reset without an attach must retire the server key")
	}

	// With the new root's attach: kept, and its chain now hangs on the new phone.
	l = serverFlow(t)
	l.deviceAs(7, 0, ActReset)
	l.attach(7, 3)
	idx, c = l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	if idx.Revoked(tid(3)) {
		t.Fatal("the attached server key is retired")
	}
	if !idx.Revoked(tid(2)) || !idx.Revoked(tid(1)) {
		t.Fatal("the old phones must stay retired by the reset")
	}
	srv, root := l.recs[tid(3)], l.recs[tid(7)]
	m := members(l, 7, 3) // the old phones are no longer listed
	if err := AuthorizeSender(idx, m, &srv, &m[0]); err != nil {
		t.Fatalf("the kept server key is refused: %v", err)
	}
	// The embedded device's anchor moves to the new phone: the kept key and the new phone both chain to it.
	tr := Trust{Index: idx, Members: m, OwnUserID: tUser, Anchor: &Anchor{DeviceID: root.DeviceID, EdPub: root.Ed25519Pub}}
	for _, d := range []DeviceRecord{srv, root} {
		d := d
		if err := tr.AuthorizeSender(&d, &m[0]); err != nil {
			t.Fatalf("%s refused with the new anchor: %v", d.DeviceID, err)
		}
	}
	// The OLD anchor (a retired phone) no longer anchors anything.
	old := l.recs[tid(2)]
	trOld := Trust{Index: idx, Members: m, OwnUserID: tUser, Anchor: &Anchor{DeviceID: old.DeviceID, EdPub: old.Ed25519Pub}}
	if err := trOld.AuthorizeSender(&root, &m[0]); err == nil {
		t.Fatal("the new phone is anchored by a retired phone")
	}
	if a, _, _, ok := idx.AttachVoucher(tid(3)); !ok || a != tid(7) {
		t.Fatalf("attach voucher = %q %v", a, ok)
	}
}

func TestServerAttachNegativeCases(t *testing.T) {
	cases := map[string]func(l *tlog){
		"signed by the old retired phone": func(l *tlog) {
			l.deviceAs(7, 0, ActReset)
			l.attach(1, 3)
		},
		"signed by an ordinary phone of the new root (not the root of the reset)": func(l *tlog) {
			l.deviceAs(7, 0, ActReset)
			l.device(8, 7)
			l.attach(8, 3)
		},
		"attach logged BEFORE the reset": func(l *tlog) {
			l.attach(2, 3)
			l.deviceAs(7, 0, ActReset)
		},
		"a second reset retires the key again": func(l *tlog) {
			l.deviceAs(7, 0, ActReset)
			l.attach(7, 3)
			l.deviceAs(9, 0, ActReset)
		},
		"attach after another reset (not the one its actor made)": func(l *tlog) {
			l.deviceAs(7, 0, ActReset)
			l.deviceAs(9, 0, ActReset)
			l.attach(7, 3)
		},
	}
	for name, build := range cases {
		l := serverFlow(t)
		build(l)
		idx, c := l.index()
		if !c.OK() {
			t.Fatalf("%s: %s", name, c.Detail)
		}
		if !idx.Revoked(tid(3)) {
			t.Errorf("%s: the server key survived", name)
		}
	}

	// An attach naming a different fingerprint than the registration is not for that key.
	l := serverFlow(t)
	l.deviceAs(7, 0, ActReset)
	k := l.keys[tid(7)]
	l.add(ActServerAttach, k, tid(7), k.Public().(ed25519.PublicKey), tid(3), make([]byte, 32))
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	if !idx.Revoked(tid(3)) {
		t.Error("an attach with another fingerprint kept the key")
	}

	// A forged attach claiming the new root's id but signed with another key breaks the log (key conflict).
	l = serverFlow(t)
	l.deviceAs(7, 0, ActReset)
	rec := l.recs[tid(3)]
	fp, _ := hex.DecodeString(rec.Fingerprint)
	other := l.keys[tid(1)]
	l.add(ActServerAttach, other, tid(7), other.Public().(ed25519.PublicKey), tid(3), fp)
	if _, c := l.index(); c.OK() {
		t.Error("a forged actor key in an attach entry was accepted")
	}
}

func TestServerAttachActionIsPartOfTheSignedMessage(t *testing.T) {
	fp := make([]byte, 32)
	a, err1 := LogActionMessage(ActServerAttach, tUser, tid(7), "", tid(3), 0, fp)
	b, err2 := LogActionMessage(ActReset, tUser, tid(7), "", tid(3), 0, fp)
	if err1 != nil || err2 != nil || string(a) == string(b) {
		t.Fatal("an attach signature could be replayed as another action")
	}
	if _, err := LogActionMessage(ActServerAttach+1, tUser, tid(7), "", tid(3), 0, fp); err == nil {
		t.Fatal("an unknown action code is accepted")
	}
}
