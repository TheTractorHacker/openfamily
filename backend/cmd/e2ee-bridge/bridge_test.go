package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

func ms(t time.Time) float64 { return float64(t.UnixMilli()) }

func TestHappyPathMappingAndHistoryMerge(t *testing.T) {
	w := newWorld(t)
	w.cfg.Dawarich.SendUnmapped = true
	// Alice: two live fixes and a history chunk covering both plus an earlier point,
	// all in one pull. Bob has no per-person mapping and goes to the main key.
	w.fix(w.phone, 1, 120, 52.5200, 13.4050)
	w.fix(w.phone, 2, 60, 52.5210, 13.4060)
	w.history(w.phone, 3,
		[]any{ms(w.nowT.Add(-180 * time.Second)), 52.5190, 13.4040, 12.0},
		[]any{ms(w.nowT.Add(-120 * time.Second)), 52.5200, 13.4050, 9.0}, // same ts as fix 1: no duplicate
		[]any{ms(w.nowT.Add(-60 * time.Second)), 52.5210, 13.4060},
		[]any{ms(w.nowT.Add(-30 * time.Second)), 999.0, 13.0}, // invalid latitude: skipped
	)
	w.fix(w.bob, 1, 30, 48.1, 11.5)
	b := w.newBridge()
	w.cycleOK(b)

	pts := w.dw.points()
	var alice, bob []gotPoint
	for _, p := range pts {
		if p.Key == "ALICEKEY-secret" {
			alice = append(alice, p)
		} else if p.Key == "MAINKEY-secret" {
			bob = append(bob, p)
		}
	}
	if len(alice) != 3 || len(bob) != 1 || len(pts) != 4 {
		t.Fatalf("alice=%d bob=%d total=%d", len(alice), len(bob), len(pts))
	}
	for i := 1; i < len(alice); i++ {
		if !alice[i].Ts.After(alice[i-1].Ts) {
			t.Fatal("points not in time order")
		}
	}
	p := alice[1] // the fix at -120s
	if p.Name != "Alice" || p.Unique != w.phone.id || p.Lat != 52.5200 || p.Lon != 13.4050 {
		t.Fatalf("bad mapping %+v", p)
	}
	if !p.Ts.Equal(w.nowT.Add(-120*time.Second)) || p.Props["timestamp"] != w.nowT.Add(-120*time.Second).Format(time.RFC3339) {
		t.Fatalf("bad timestamp %v", p.Props["timestamp"])
	}
	// The live fix (with its extras) wins over the history copy of the same instant.
	if p.Props["horizontal_accuracy"] != 8.5 {
		t.Fatalf("accuracy %v", p.Props["horizontal_accuracy"])
	}
	if bob[0].Name != "Bob" || bob[0].Unique != w.bob.id {
		t.Fatalf("bob %+v", bob[0])
	}
	if got := alice[2].Props["battery_level"]; got != 0.5 {
		t.Fatalf("battery %v", got)
	}
	if b.rs.Recv.Cursor[w.of.circle] != 4 {
		t.Fatalf("cursor %d", b.rs.Recv.Cursor[w.of.circle])
	}
	if w.of.hits["items-as-"+w.id.f.DeviceID] == 0 {
		t.Fatal("pull did not use as_device")
	}
	// Batch layout: GeoJSON features.
	feat := w.dw.posts[0].Feats[0]
	if feat["type"] != "Feature" || feat["geometry"].(map[string]any)["type"] != "Point" {
		t.Fatalf("not GeoJSON: %v", feat)
	}
	// A second pass with nothing new posts nothing.
	n := w.dw.postCount()
	w.cycleOK(b)
	if w.dw.postCount() != n {
		t.Fatal("idle cycle posted")
	}
}

func TestFixBodyFieldsAndUnmapped(t *testing.T) {
	w := newWorld(t) // send_unmapped false: bob is dropped
	w.fix(w.phone, 1, 10, 1.5, -2.5)
	w.fix(w.bob, 1, 10, 3, 4)
	b := w.newBridge()
	w.cycleOK(b)
	pts := w.dw.points()
	if len(pts) != 1 {
		t.Fatalf("points %d", len(pts))
	}
	p := pts[0]
	if p.Props["altitude"] != 31.0 || p.Props["speed"] != 1.5 || p.Props["battery_level"] != 0.5 || p.Props["horizontal_accuracy"] != 8.5 {
		t.Fatalf("props %v", p.Props)
	}
	if b.rs.Stats.Dropped["unmapped_user"] != 1 {
		t.Fatalf("dropped %v", b.rs.Stats.Dropped)
	}
}

func TestDedupeAcrossRestartAndLostState(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 100, 52.1, 13.1)
	w.fix(w.phone, 2, 50, 52.2, 13.2)
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.dw.points()) != 2 {
		t.Fatal("first run")
	}
	// Restart with state kept: nothing is pulled twice, nothing re-sent.
	b2 := w.newBridge()
	w.cycleOK(b2)
	if len(w.dw.points()) != 2 {
		t.Fatalf("restart duplicated: %d", len(w.dw.points()))
	}
	// Receiver state lost but the delivery marks kept: items are re-read and dropped by the marks.
	rs, _ := w.st.loadRunState()
	rs.Recv = recvState{}
	rs.normalize()
	if err := w.st.saveRunState(rs); err != nil {
		t.Fatal(err)
	}
	b3 := w.newBridge()
	w.cycleOK(b3)
	if len(w.dw.points()) != 2 {
		t.Fatalf("lost receiver state duplicated: %d", len(w.dw.points()))
	}
	if b3.rs.Stats.Dropped["already_sent"] == 0 {
		t.Fatal("expected already_sent drops")
	}
	// ALL state lost (state.json wiped): Dawarich is asked for its newest point.
	w.st.remove(fileState)
	newest := w.nowT.Add(-50 * time.Second).Unix()
	w.dw.mu.Lock()
	w.dw.newest = `[{"id":1,"timestamp":` + itoa(newest) + `,"latitude":52.2,"longitude":13.2}]`
	w.dw.mu.Unlock()
	w.fix(w.phone, 3, 10, 52.3, 13.3)
	b4 := w.newBridge()
	w.cycleOK(b4)
	pts := w.dw.points()
	if len(pts) != 3 || pts[2].Lat != 52.3 {
		t.Fatalf("after wipe want exactly one new point, got %d", len(pts))
	}
	w.dw.mu.Lock()
	defer w.dw.mu.Unlock()
	// One query for the first send after the first start, one for the first send after the wipe;
	// the restarts that had nothing to send did not ask.
	if len(w.dw.queries) != 2 {
		t.Fatalf("queries: %v", w.dw.queries)
	}
	q := w.dw.queries[1]
	if !strings.Contains(q, "per_page=1") || !strings.Contains(q, "order=desc") || !strings.Contains(q, "start_at=") || !strings.Contains(q, "end_at=") {
		t.Fatalf("newest-point query: %v", q)
	}
	if w.dw.keys[1] != "ALICEKEY-secret" {
		t.Fatalf("query key %q", w.dw.keys[0])
	}
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestNewestPointQueryFailureIsUnknown(t *testing.T) {
	w := newWorld(t) // fake answers 404 to the query
	w.fix(w.phone, 1, 10, 52.1, 13.1)
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.dw.points()) != 1 {
		t.Fatal("unknown floor must not block delivery")
	}
	// Shapes the parser tolerates.
	for _, c := range []struct {
		in   string
		ok   bool
		ts   int64
		name string
	}{
		{`[{"timestamp":1700000000}]`, true, 1700000000, ""},
		{`{"points":[{"tracked_at":"2023-11-14T22:13:20Z","device_id":"Alice"}]}`, true, 1700000000, "Alice"},
		{`[{"timestamp":1700000000000,"device_id":7}]`, true, 1700000000, ""},
		{`[]`, false, 0, ""},
		{`<html>`, false, 0, ""},
		{`{"error":"x"}`, false, 0, ""},
	} {
		ts, name, _, ok := parseNewestPoint([]byte(c.in))
		if ok != c.ok || ts != c.ts || name != c.name {
			t.Fatalf("%s -> %v %v %q", c.in, ok, ts, name)
		}
	}
}

func TestHistoryAfterLiveNoDuplicates(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 100, 52.1, 13.1)
	w.fix(w.phone, 2, 40, 52.2, 13.2)
	b := w.newBridge()
	w.cycleOK(b)
	// Later page: the chunk repeats both live points and adds one genuinely newer.
	w.history(w.phone, 3,
		[]any{ms(w.nowT.Add(-100 * time.Second)), 52.1, 13.1},
		[]any{ms(w.nowT.Add(-40 * time.Second)), 52.2, 13.2},
		[]any{ms(w.nowT.Add(-5 * time.Second)), 52.3, 13.3},
	)
	w.cycleOK(b)
	pts := w.dw.points()
	if len(pts) != 3 || pts[2].Lat != 52.3 {
		t.Fatalf("got %d points", len(pts))
	}
	seen := map[int64]bool{}
	for _, p := range pts {
		if seen[p.Ts.Unix()] {
			t.Fatal("duplicate timestamp delivered")
		}
		seen[p.Ts.Unix()] = true
	}
}

func TestEpochRotationDefersThenProcesses(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 100, 52.1, 13.1)
	b := w.newBridge()
	w.cycleOK(b)
	// Epoch 2 is published (the circle epoch bumps) but the phone has not wrapped it for the bridge yet.
	key2 := randSeed(t)
	w.of.publishEpoch(w.phone, 2, key2) // no recipients
	ts := uint64(w.nowT.Add(-30 * time.Second).UnixMilli())
	w.of.sealItem(key2, 2, w.phone, "fix", 2, ts, map[string]any{"lat": 10.0, "lon": 20.0})
	ts2 := uint64(w.nowT.Add(-20 * time.Second).UnixMilli())
	w.of.sealItem(key2, 2, w.phone, "fix", 3, ts2, map[string]any{"lat": 11.0, "lon": 21.0})
	w.fix(w.bob, 1, 5, 1, 1) // later epoch-1 item behind the deferred ones (bob unmapped: dropped, but handled)
	cursorBefore := b.rs.Recv.Cursor[w.of.circle]
	w.cycleOK(b)
	if len(w.dw.points()) != 1 {
		t.Fatalf("epoch 2 items must wait for their key, got %d points", len(w.dw.points()))
	}
	if got := b.rs.Recv.Cursor[w.of.circle]; got != cursorBefore {
		t.Fatalf("cursor passed a deferred item: %d -> %d", cursorBefore, got)
	}
	if len(b.rs.Recv.Deferred) != 2 {
		t.Fatalf("deferred %v", b.rs.Recv.Deferred)
	}
	// Retries are backed off: another cycle at the same time does not hit /wraps again.
	wraps := w.of.hits["GET /circles/"+w.of.circle+"/e2ee/wraps"]
	w.cycleOK(b)
	if got := w.of.hits["GET /circles/"+w.of.circle+"/e2ee/wraps"]; got > wraps+1 {
		t.Fatalf("wraps polled without backoff: %d -> %d", wraps, got)
	}
	// The phone wraps epoch 2 for the bridge; after the backoff the items are processed.
	w.of.addWrap(w.bridge, w.of.makeWrap(w.phone, w.bridge, 2, key2))
	w.nowT = w.nowT.Add(11 * time.Minute)
	w.cycleOK(b)
	pts := w.dw.points()
	if len(pts) != 3 {
		t.Fatalf("after the key arrived want 3 points, got %d", len(pts))
	}
	if len(b.rs.Recv.Deferred) != 0 {
		t.Fatalf("deferred not cleared: %v", b.rs.Recv.Deferred)
	}
	if got := b.rs.Recv.Cursor[w.of.circle]; got != 4 {
		t.Fatalf("cursor %d", got)
	}
}

func TestRevokedBridgeStopsWithExit3(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 10, 1, 1)
	w.of.mu.Lock()
	w.of.itemsStatus, w.of.itemsCode = 403, "no_approved_device"
	w.of.mu.Unlock()
	b := w.newBridge()
	code := b.loop(context.Background(), time.Millisecond, false)
	if code != exitRevoked {
		t.Fatalf("exit %d", code)
	}
	if n := w.of.hits["GET /circles/"+w.of.circle+"/e2ee/items"]; n != 1 {
		t.Fatalf("looped: %d pulls", n)
	}
	if !strings.Contains(w.logBuf.String(), "STOPPING") {
		t.Fatal("no clear message")
	}
}

func TestRejectionsAreDroppedAndCounted(t *testing.T) {
	w := newWorld(t)
	ts := uint64(w.nowT.Add(-10 * time.Second).UnixMilli())
	good := map[string]any{"lat": 52.0, "lon": 13.0}
	// 1 good item
	w.of.sealItem(w.key1, 1, w.phone, "fix", 1, ts, good)
	// 2 tampered ciphertext
	it := w.of.sealItem(w.key1, 1, w.phone, "fix", 2, ts, good)
	w.of.mu.Lock()
	w.of.items[len(w.of.items)-1].CT[len(it.CT)-3] ^= 0x01
	w.of.mu.Unlock()
	// 3 forged sender: bob signs, but the item claims alice's device id (AAD/signature bound to alice's id)
	forged := *w.bob
	forged.id = w.phone.id
	w.of.sealItem(w.key1, 1, &forged, "fix", 3, ts, good)
	// 4 bad signature: a random key signs under alice's device id
	rnd, _ := deriveIdentity(randSeed(t))
	w.of.sealItem(w.key1, 1, &tdev{id: w.phone.id, priv: rnd.edPriv}, "fix", 4, ts, good)
	// 5 seq mismatch: signed seq 5, relayed as 6
	w.of.sealItem(w.key1, 1, w.phone, "fix", 5, ts, good)
	w.of.mu.Lock()
	w.of.items[len(w.of.items)-1].Seq = 6
	w.of.mu.Unlock()
	// 6 duplicate of seq 1 (a replay of the identical ciphertext)
	w.of.addItem(w.phone.id, 1, "fix", 1, append([]byte{}, w.of.items[0].CT...))
	// 7 clock skew: an hour into the future
	w.of.sealItem(w.key1, 1, w.phone, "fix", 7, uint64(w.nowT.Add(time.Hour).UnixMilli()), good)
	// 8 sender that is not approved
	pend := newTDev(t, w.id.f.UserID, "device", w.phone)
	pend.approved = false
	w.of.mu.Lock()
	w.of.members[0].devs = append(w.of.members[0].devs, pend)
	w.of.mu.Unlock()
	w.of.sealItem(w.key1, 1, pend, "fix", 1, ts, good)
	// 9 recovery key as sender
	rec := newTDev(t, w.id.f.UserID, "recovery", w.phone)
	w.of.mu.Lock()
	w.of.members[0].devs = append(w.of.members[0].devs, rec)
	w.of.mu.Unlock()
	w.of.sealItem(w.key1, 1, rec, "fix", 1, ts, good)
	// 10 unusable body (latitude out of range) from a good sender
	w.of.sealItem(w.key1, 1, w.phone, "fix", 10, ts, map[string]any{"lat": 123.0, "lon": 1.0})
	// 11 sender whose registration signature is broken
	badReg := newTDev(t, w.id.f.UserID, "device", w.phone)
	badReg.rec.RegistrationSignature = std(make([]byte, 64))
	w.of.mu.Lock()
	w.of.members[0].devs = append(w.of.members[0].devs, badReg)
	w.of.mu.Unlock()
	w.of.sealItem(w.key1, 1, badReg, "fix", 1, ts, good)
	// 12 unknown (e.g. since-revoked) sender with authentic ciphertext
	ghost := newTDev(t, w.id.f.UserID, "device", w.phone)
	w.of.sealItem(w.key1, 1, ghost, "fix", 1, ts, good)
	// 13 wrong epoch header relayed
	it13 := w.of.sealItem(w.key1, 1, w.phone, "fix", 13, ts, good)
	w.of.mu.Lock()
	w.of.items[len(w.of.items)-1].Epoch = 2
	_ = it13
	w.of.mu.Unlock()

	b := w.newBridge()
	w.cycleOK(b)
	if got := len(w.dw.points()); got != 1 {
		t.Fatalf("only the good item may be delivered, got %d", got)
	}
	rej := b.rs.Stats.Rejected
	want := map[string]int64{"bad_ciphertext": 2, "bad_signature": 1, "seq_mismatch": 1, "duplicate": 1, "clock_skew": 1,
		"sender_not_member": 2, "bad_body": 1, "sender_registration_invalid": 1, "malformed": 1}
	// forged sender (item 3) is a signature failure too, so 2 signature failures: bob's key and the random key.
	want["bad_signature"] = 2
	want["bad_ciphertext"] = 1
	for k, v := range want {
		if rej[k] != v {
			t.Errorf("rejected[%s] = %d, want %d (all: %v)", k, rej[k], v, rej)
		}
	}
	if len(b.rs.Recv.Deferred) != 1 {
		t.Fatalf("the unknown sender must be deferred, got %v", b.rs.Recv.Deferred)
	}
	// The unknown sender is retried for a while, then dropped so the cursor can pass.
	w.nowT = w.nowT.Add(unknownSenderTTL + time.Minute)
	// (item timestamps are now old but still valid)
	w.cycleOK(b)
	if len(b.rs.Recv.Deferred) != 0 || b.rs.Stats.Rejected["unknown_sender_expired"] != 1 {
		t.Fatalf("unknown sender not dropped: %v %v", b.rs.Recv.Deferred, b.rs.Stats.Rejected)
	}
	if got := b.rs.Recv.Cursor[w.of.circle]; got != w.of.nextID {
		t.Fatalf("cursor %d != %d", got, w.of.nextID)
	}
}

func TestEpochRollbackRule(t *testing.T) {
	w := newWorld(t)
	key2 := randSeed(t)
	w.of.publishEpoch(w.phone, 2, key2, w.bridge)
	now := w.nowT
	w.of.sealItem(key2, 2, w.phone, "fix", 5, uint64(now.Add(-60*time.Second).UnixMilli()), map[string]any{"lat": 1.0, "lon": 1.0})
	b := w.newBridge()
	w.cycleOK(b)
	// A fresh item (higher seq) of the same device under the OLD epoch is a rollback.
	w.of.sealItem(w.key1, 1, w.phone, "fix", 6, uint64(now.Add(-30*time.Second).UnixMilli()), map[string]any{"lat": 2.0, "lon": 2.0})
	w.cycleOK(b)
	if b.rs.Stats.Rejected["epoch_rollback"] != 1 || len(w.dw.points()) != 1 {
		t.Fatalf("rollback: %v, points %d", b.rs.Stats.Rejected, len(w.dw.points()))
	}
	// Backlog (lower seq) under the old epoch whose signed time precedes first sight of epoch 2 is fine.
	w.of.sealItem(w.key1, 1, w.phone, "fix", 4, uint64(now.Add(-3600*time.Second).UnixMilli()), map[string]any{"lat": 3.0, "lon": 3.0})
	w.cycleOK(b)
	// Accepted by the rollback rule; older than what was already delivered, so not re-sent.
	if b.rs.Stats.Accepted != 2 || b.rs.Stats.Rejected["epoch_rollback"] != 1 {
		t.Fatalf("backlog: accepted %d rejected %v", b.rs.Stats.Accepted, b.rs.Stats.Rejected)
	}
}

func TestLogTamperStopsBeforeAnyPull(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 10, 1, 1)
	// The server rewrites one visible entry's epoch.
	w.of.mu.Lock()
	w.of.rawLogHook = func(es []e2ee.LogEntry) []e2ee.LogEntry {
		for i := range es {
			if !es[i].Redacted && es[i].Epoch != nil {
				ep := *es[i].Epoch + 5
				es[i].Epoch = &ep
			}
		}
		return es
	}
	w.of.mu.Unlock()
	b := w.newBridge()
	code := b.loop(context.Background(), time.Millisecond, false)
	if code != exitLog {
		t.Fatalf("exit %d", code)
	}
	if w.of.hits["GET /circles/"+w.of.circle+"/e2ee/items"] != 0 || len(w.dw.points()) != 0 {
		t.Fatal("pulled/delivered despite a failed log")
	}
	if !strings.Contains(w.logBuf.String(), "KEY TRANSPARENCY LOG VERIFICATION FAILED") {
		t.Fatal("no loud message")
	}
}

func TestLogRollbackAndPinPersisted(t *testing.T) {
	w := newWorld(t)
	b := w.newBridge()
	w.cycleOK(b)
	if b.rs.LogSeq != int64(len(w.of.logHashes)) || b.rs.LogSeq < 3 {
		t.Fatalf("pin %d", b.rs.LogSeq)
	}
	rs, _ := w.st.loadRunState()
	if rs.LogSeq != b.rs.LogSeq {
		t.Fatal("pin not persisted")
	}
	// The server now serves a shorter log: rollback.
	w.of.mu.Lock()
	w.of.logEntries, w.of.logHashes = w.of.logEntries[:2], w.of.logHashes[:2]
	w.of.mu.Unlock()
	b2 := w.newBridge()
	err := b2.cycle(context.Background())
	var le *logError
	if err == nil || !asLogErr(err, &le) || le.problem != e2ee.LogRollback {
		t.Fatalf("want rollback, got %v", err)
	}
}

func asLogErr(err error, out **logError) bool {
	le, ok := err.(*logError)
	if ok {
		*out = le
	}
	return ok
}

func TestWrongCommitmentRejected(t *testing.T) {
	w := newWorld(t)
	// Epoch 2 is published with a commitment for key A but the wrap carries key B.
	keyA, keyB := randSeed(t), randSeed(t)
	w.of.publishEpoch(w.phone, 2, keyA)
	w.of.addWrap(w.bridge, w.of.makeWrap(w.phone, w.bridge, 2, keyB))
	w.of.sealItem(keyB, 2, w.phone, "fix", 1, uint64(w.nowT.UnixMilli()), map[string]any{"lat": 1.0, "lon": 1.0})
	b := w.newBridge()
	w.cycleOK(b)
	if b.keys.get(w.of.circle, 2) != nil {
		t.Fatal("key with a wrong commitment was stored")
	}
	if b.rs.Stats.Rejected["wrap_rejected"] == 0 || len(w.dw.points()) != 0 {
		t.Fatalf("rejected=%v points=%d", b.rs.Stats.Rejected, len(w.dw.points()))
	}
}

func TestForgedEpochRecordAndWrapperRejected(t *testing.T) {
	w := newWorld(t)
	// A record signed by an unregistered key of the server's choosing.
	evil := newTDev(t, w.id.f.UserID, "device", nil)
	key := randSeed(t)
	commit, _ := e2ee.KeyCommitment(key, w.of.circle, 2)
	m, _ := e2ee.LogActionMessage(e2ee.ActEpoch, w.phone.user, w.phone.id, w.of.circle, "", 2, commit)
	w.of.mu.Lock()
	w.of.records = append(w.of.records, e2ee.EpochRecord{Epoch: 2, Action: 6, PublisherUser: w.phone.user, PublisherDev: w.phone.id,
		PublisherPub: std(evil.edPub), KeyCommitment: std(commit), Signature: std(ed25519.Sign(evil.priv, m))})
	w.of.epoch = 2
	w.of.mu.Unlock()
	w.of.addWrap(w.bridge, w.of.makeWrap(evil, w.bridge, 2, key))
	b := w.newBridge()
	w.cycleOK(b)
	if b.keys.get(w.of.circle, 2) != nil || b.rs.Stats.Rejected["wrap_rejected"] == 0 {
		t.Fatal("forged epoch record accepted")
	}
}

func TestDawarich5xxRetryThenSuccess(t *testing.T) {
	w := newWorld(t)
	w.dw.fail = 2
	w.fix(w.phone, 1, 10, 52.1, 13.1)
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.dw.points()) != 1 || w.dw.postCount() != 1 {
		t.Fatalf("retry delivered %d points in %d posts", len(w.dw.points()), w.dw.postCount())
	}
}

func TestCursorNotAdvancedWhenDawarichDown(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 100, 52.1, 13.1)
	w.fix(w.phone, 2, 50, 52.2, 13.2)
	w.dw.mu.Lock()
	w.dw.failAll = true
	w.dw.mu.Unlock()
	b := w.newBridge()
	if err := b.cycle(context.Background()); err == nil {
		t.Fatal("expected an error while Dawarich is down")
	}
	if b.rs.Recv.Cursor[w.of.circle] != 0 {
		t.Fatalf("cursor advanced to %d", b.rs.Recv.Cursor[w.of.circle])
	}
	disk, _ := w.st.loadRunState()
	if disk.Recv.Cursor[w.of.circle] != 0 || len(disk.Recv.Dev) != 0 {
		t.Fatalf("receiver state persisted for an undelivered page: %+v", disk.Recv)
	}
	// Dawarich recovers: nothing was lost, nothing duplicated.
	w.dw.mu.Lock()
	w.dw.failAll = false
	w.dw.mu.Unlock()
	w.cycleOK(b)
	if len(w.dw.points()) != 2 || b.rs.Recv.Cursor[w.of.circle] != 2 {
		t.Fatalf("points %d cursor %d", len(w.dw.points()), b.rs.Recv.Cursor[w.of.circle])
	}
}

func TestPartialBatchFailureKeepsDeliveredMarks(t *testing.T) {
	w := newWorld(t)
	// 600 points = two batches (500 + 100); Dawarich accepts only the first.
	pts := make([][]any, 0, 600)
	for i := 0; i < 600; i++ {
		pts = append(pts, []any{ms(w.nowT.Add(-time.Duration(700-i) * time.Second)), 50.0 + float64(i)/10000, 10.0})
	}
	w.history(w.phone, 1, pts...)
	w.dw.mu.Lock()
	w.dw.limitPosts, w.dw.allowPosts = true, 1
	w.dw.mu.Unlock()
	b := w.newBridge()
	if err := b.cycle(context.Background()); err == nil {
		t.Fatal("expected a failure on the second batch")
	}
	if got := len(w.dw.points()); got != 500 {
		t.Fatalf("first batch: %d", got)
	}
	w.dw.mu.Lock()
	w.dw.limitPosts = false
	w.dw.mu.Unlock()
	w.cycleOK(b)
	got := w.dw.points()
	if len(got) != 600 {
		t.Fatalf("want exactly 600 points in total, got %d", len(got))
	}
	seen := map[int64]bool{}
	for _, p := range got {
		if seen[p.Ts.Unix()] {
			t.Fatal("duplicate delivered after a partial failure")
		}
		seen[p.Ts.Unix()] = true
	}
}

func TestAuthRefreshRotationPersisted(t *testing.T) {
	w := newWorld(t)
	w.fix(w.phone, 1, 10, 1, 1)
	var before session
	_ = w.st.readSecret(fileSession, &before)
	b := w.newBridge()
	w.cycleOK(b) // first request refreshes (no access token in memory)
	var after session
	_ = w.st.readSecret(fileSession, &after)
	if after.RefreshToken == before.RefreshToken || after.RefreshToken == "" {
		t.Fatal("rotated refresh token not persisted")
	}
	// The consumed token is dead on the server: a bridge restarted with the persisted one still works.
	w.of.mu.Lock()
	w.of.expire = true // next request: 401 -> refresh -> retry
	w.of.mu.Unlock()
	w.fix(w.phone, 2, 5, 2, 2)
	w.cycleOK(b)
	var later session
	_ = w.st.readSecret(fileSession, &later)
	if later.RefreshToken == after.RefreshToken {
		t.Fatal("refresh token not rotated after a 401")
	}
	b2 := w.newBridge()
	w.cycleOK(b2)
	// Persisted file never contains the access token.
	raw, _ := os.ReadFile(filepath.Join(w.dir, fileSession))
	if strings.Contains(string(raw), "access-") {
		t.Fatal("access token written to disk")
	}
	// A dead refresh token ends in the re-login exit code.
	w.of.mu.Lock()
	w.of.refresh = map[string]bool{}
	w.of.access = map[string]bool{}
	w.of.mu.Unlock()
	b3 := w.newBridge()
	if code := b3.loop(context.Background(), time.Millisecond, false); code != exitReauth {
		t.Fatalf("exit %d", code)
	}
}

func TestNoSecretsOrCoordinatesInLogs(t *testing.T) {
	w := newWorld(t)
	w.cfg.Dawarich.SendUnmapped = true
	w.fix(w.phone, 1, 10, 52.123456, 13.654321)
	w.history(w.phone, 2, []any{ms(w.nowT), 52.777777, 13.888888})
	it := w.fix(w.bob, 1, 10, 48.135125, 11.581981)
	_ = it
	w.dw.fail = 1
	b := w.newBridge()
	w.cycleOK(b)
	// A failing cycle too.
	w.of.mu.Lock()
	w.of.itemsStatus, w.of.itemsCode = 403, "no_approved_device"
	w.of.mu.Unlock()
	_ = b.loop(context.Background(), time.Millisecond, true)
	logs := w.logBuf.String()
	if logs == "" {
		t.Fatal("no logs captured")
	}
	forbidden := append([]string{"52.123", "13.654", "52.777", "13.888", "48.135", "11.581", hex.EncodeToString(w.key1),
		base64.StdEncoding.EncodeToString(w.id.edPriv.Seed()), "access-", "refresh-"}, w.secrets...)
	for _, s := range forbidden {
		if strings.Contains(logs, s) {
			t.Fatalf("log output contains %q", s)
		}
	}
}

func TestStateFilesPermissionsAndPassphrase(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "s")
	st, err := openStore(dir, []byte("correct horse"))
	if err != nil {
		t.Fatal(err)
	}
	id, err := st.createIdentity("n")
	if err != nil {
		t.Fatal(err)
	}
	keys, _ := st.loadCircleKeys()
	ckey := randSeed(t)
	if err := keys.put("c1", 1, ckey); err != nil {
		t.Fatal(err)
	}
	if err := st.writeSecret(fileSession, session{Server: "http://x", RefreshToken: "REFRESH-TOKEN-XYZ"}); err != nil {
		t.Fatal(err)
	}
	if err := st.saveRunState(newRunState()); err != nil {
		t.Fatal(err)
	}
	di, _ := os.Stat(dir)
	if di.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v", di.Mode().Perm())
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		fi, _ := e.Info()
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %v", e.Name(), fi.Mode().Perm())
		}
		if strings.Contains(e.Name(), ".tmp") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}
	seed, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	kf, _ := os.ReadFile(filepath.Join(dir, fileKeys))
	sf, _ := os.ReadFile(filepath.Join(dir, fileSession))
	for name, raw := range map[string][]byte{"identity": seed, "keys": kf, "session": sf} {
		for _, s := range []string{std(ckey), "REFRESH-TOKEN-XYZ", std(id.edPriv.Seed())} {
			if strings.Contains(string(raw), s) {
				t.Fatalf("%s file holds a secret in the clear", name)
			}
		}
		if !strings.Contains(string(raw), `"sealed"`) {
			t.Fatalf("%s file is not sealed", name)
		}
	}
	// Right passphrase round-trips; wrong or missing fails closed.
	st2, _ := openStore(dir, []byte("correct horse"))
	id2, err := st2.loadIdentity()
	if err != nil || id2.f.DeviceID != id.f.DeviceID {
		t.Fatalf("reload: %v", err)
	}
	k2, err := st2.loadCircleKeys()
	if err != nil || !bytes.Equal(k2.get("c1", 1), ckey) {
		t.Fatalf("keys reload: %v", err)
	}
	st3, _ := openStore(dir, []byte("wrong"))
	if _, err := st3.loadIdentity(); err != errBadPass {
		t.Fatalf("wrong passphrase: %v", err)
	}
	st4, _ := openStore(dir, nil)
	if _, err := st4.loadIdentity(); err != errLocked {
		t.Fatalf("no passphrase: %v", err)
	}
	// A sealed blob cannot be moved to another file.
	var b box
	_ = st.readJSON(fileKeys, &b)
	if _, err := st.open("other.json", b); err != errBadPass {
		t.Fatalf("blob accepted under another label: %v", err)
	}
	// Public facts stay readable for `status` without the passphrase.
	if pub, err := st4.publicIdentity(); err != nil || pub.DeviceID != id.f.DeviceID {
		t.Fatal("public identity unreadable")
	}
}

func TestPlainStateIsSealedWhenPassphraseAppears(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "s")
	st, _ := openStore(dir, nil)
	id, _ := st.createIdentity("n")
	raw, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	if !strings.Contains(string(raw), `"plain"`) {
		t.Fatal("expected a plain identity file without passphrase")
	}
	st2, _ := openStore(dir, []byte("pw"))
	if _, err := st2.loadIdentity(); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(filepath.Join(dir, fileIdentity))
	if strings.Contains(string(raw), std(id.edPriv.Seed())) || !strings.Contains(string(raw), `"sealed"`) {
		t.Fatal("identity was not re-sealed")
	}
}

func TestPassphraseSealedBridgeRunsEndToEnd(t *testing.T) {
	w := newWorld(t)
	// Re-seal everything with a passphrase and run from the sealed store.
	st, _ := openStore(w.dir, []byte("pp"))
	if _, err := st.loadIdentity(); err != nil {
		t.Fatal(err)
	}
	var sess session
	_ = w.st.readSecret(fileSession, &sess)
	_ = st.writeSecret(fileSession, sess)
	w.st = st
	w.fix(w.phone, 1, 10, 52.5, 13.5)
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.dw.points()) != 1 {
		t.Fatal("sealed bridge did not deliver")
	}
	raw, _ := os.ReadFile(filepath.Join(w.dir, fileKeys))
	if strings.Contains(string(raw), std(w.key1)) {
		t.Fatal("circle key stored in the clear")
	}
}
