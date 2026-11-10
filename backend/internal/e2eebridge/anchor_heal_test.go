package e2eebridge

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// A server key kept across an owner reset whose live anchor move never happened (the process died between the
// commit and the move, or the write failed): the device still names the retired phone as its anchor. The trust it
// builds must find the new root phone on its own, from the verified log only.
func TestTrustFindsTheKeptAnchorFromTheLogWhenTheLiveMoveWasMissed(t *testing.T) {
	const user = "11111111-1111-4111-8111-111111111111"
	oldID, newID, srvID := "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"
	key := func(n byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(bytesOf(n)) }
	oldPriv, newPriv := key(1), key(2)
	srvEd, srvX := key(3).Public().(ed25519.PublicKey), bytesOf(9)
	fp, _ := e2ee.Fingerprint(srvEd, srvX)

	var entries []e2ee.LogEntry
	prev := e2ee.GenesisHash
	add := func(action byte, priv ed25519.PrivateKey, actor, subject string, ref []byte) {
		msg, err := e2ee.LogActionMessage(action, user, actor, "", subject, 0, ref)
		if err != nil {
			t.Fatal(err)
		}
		sig := ed25519.Sign(priv, msg)
		seq := int64(len(entries) + 1)
		h := e2ee.LogEntryHash(prev, uint64(seq), msg, sig)
		a, ep := int(action), 0
		u, pub, sg, r := user, base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)), base64.StdEncoding.EncodeToString(sig), hex.EncodeToString(ref)
		entries = append(entries, e2ee.LogEntry{Seq: seq, PrevHash: hex.EncodeToString(prev), EntryHash: hex.EncodeToString(h), Action: &a, UserID: &u,
			ActorDeviceID: &actor, ActorPub: &pub, SubjectID: &subject, Epoch: &ep, Ref: &r, Signature: &sg})
		prev = h
	}
	oldFP, _ := e2ee.Fingerprint(oldPriv.Public().(ed25519.PublicKey), bytesOf(7))
	newFP, _ := e2ee.Fingerprint(newPriv.Public().(ed25519.PublicKey), bytesOf(8))
	add(e2ee.ActRegister, oldPriv, oldID, oldID, oldFP)
	add(e2ee.ActRegister, oldPriv, oldID, srvID, fp)
	add(e2ee.ActReset, newPriv, newID, newID, newFP)
	index := func() *e2ee.LogIndex {
		head := entries[len(entries)-1]
		hh, _ := hex.DecodeString(head.EntryHash)
		c, idx, err := e2ee.SyncLogFull(nil, func(after int64) ([]e2ee.LogEntry, e2ee.LogHead, error) {
			var out []e2ee.LogEntry
			for _, e := range entries {
				if e.Seq > after {
					out = append(out, e)
				}
			}
			return out, e2ee.LogHead{Seq: int64(len(entries)), Hash: hh}, nil
		})
		if err != nil || !c.OK() {
			t.Fatalf("log: %v %+v", err, c)
		}
		return idx
	}

	id := &identity{fp: fp}
	id.f.DeviceID, id.f.UserID, id.f.RegisteredAt = srvID, user, "2026-11-07T22:14:20Z"
	id.f.ApprovedBy, id.f.ApproverEdPub = oldID, base64.StdEncoding.EncodeToString(oldPriv.Public().(ed25519.PublicKey))
	b := &bridge{id: id, logIdx: index()}

	// Reset without an attach: nothing re-anchors the key (the API revokes it; the stored anchor is left alone).
	if a := b.trust(&circleState{}).Anchor; a == nil || a.DeviceID != oldID {
		t.Fatalf("without an attach the stored anchor must stay: %+v", a)
	}
	// The new root phone's attach is in the log: the anchor is derived from it.
	add(e2ee.ActServerAttach, newPriv, newID, srvID, fp)
	b.logIdx = index()
	a := b.trust(&circleState{}).Anchor
	if a == nil || a.DeviceID != newID || a.EdPub != base64.StdEncoding.EncodeToString(newPriv.Public().(ed25519.PublicKey)) {
		t.Fatalf("the anchor was not derived from the log: %+v", a)
	}
	// A different fingerprint of the same id is not this key: the stored anchor stays.
	b.id = &identity{fp: bytesOf(5), f: id.f}
	if a := b.trust(&circleState{}).Anchor; a == nil || a.DeviceID != oldID {
		t.Fatalf("an attach for another fingerprint moved the anchor: %+v", a)
	}
}

func bytesOf(n byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = n
	}
	return b
}
