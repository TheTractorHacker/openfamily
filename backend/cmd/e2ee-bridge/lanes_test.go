package main

// Phase 3 (processing lanes): the server-device sidecar and the Dawarich bridge in
// lanes circles. The world is built from the Phase 1 vectors
// (internal/e2ee/testdata/lanes.json): the circle, the sender / admin / recipient
// identities, CK, SK, the sealed server-line item and the SK / CK wraps are the
// vector bytes; policy, prefs and the key log are signed on the fly with the vector keys.

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

type laneIdent struct {
	UserID     string `json:"user_id"`
	DeviceID   string `json:"device_id"`
	EdSeedHex  string `json:"ed_seed_hex"`
	EdPubHex   string `json:"ed_pub_hex"`
	XSecretHex string `json:"x_secret_hex"`
	XPubHex    string `json:"x_pub_hex"`
}

type laneVec struct {
	CircleID    string    `json:"circle_id"`
	CKHex       string    `json:"ck_hex"`
	SKHex       string    `json:"sk_hex"`
	Sender      laneIdent `json:"sender"`
	Admin       laneIdent `json:"admin"`
	Recipient   laneIdent `json:"recipient"`
	ServerDev   string    `json:"server_device_id"`
	ServerFPHex string    `json:"server_fingerprint_hex"`
	Items       []struct {
		Name       string `json:"name"`
		Line       int    `json:"line"`
		Gen        uint32 `json:"gen"`
		Seq        uint64 `json:"seq"`
		PayloadHex string `json:"payload_hex"`
	} `json:"items"`
	Wraps []struct {
		Name          string `json:"name"`
		Line          int    `json:"line"`
		Gen           uint32 `json:"gen"`
		BlobHex       string `json:"blob_hex"`
		SigHex        string `json:"sig_hex"`
		CommitmentHex string `json:"commitment_hex"`
	} `json:"wraps"`
}

func hx(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func vecIdentity(t *testing.T, d laneIdent) *identity {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(hx(t, d.EdSeedHex))
	xs := hx(t, d.XSecretHex)
	xk, err := ecdh.X25519().NewPrivateKey(xs)
	if err != nil {
		t.Fatal(err)
	}
	id := &identity{edPriv: priv, edPub: priv.Public().(ed25519.PublicKey), xSecret: xs, xPub: xk.PublicKey().Bytes()}
	if hex.EncodeToString(id.edPub) != d.EdPubHex || hex.EncodeToString(id.xPub) != d.XPubHex {
		t.Fatal("vector identity does not reproduce its public keys")
	}
	id.fp, err = e2ee.Fingerprint(id.edPub, id.xPub)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

type lanesWorld struct {
	t    *testing.T
	v    laneVec
	of   *fakeOF
	ing  *fakeIngest
	dw   *fakeDawarich
	st   *store
	kind string

	sender, admin, owner, pat, bdev *tdev
	bid                             *identity
	ck, sk                          []byte
	srvID                           string
	srvFP                           []byte

	cfg    *config
	logBuf *bytes.Buffer
	nowT   time.Time

	policy *e2ee.PolicyStatement
	hist   []e2ee.PolicyStatement
	prefs  map[string]*e2ee.PrefStatement
	seq    map[string]uint64
}

func newLanesWorld(t *testing.T, kind string) *lanesWorld {
	t.Helper()
	raw, err := os.ReadFile("../../internal/e2ee/testdata/lanes.json")
	if err != nil {
		t.Fatal(err)
	}
	w := &lanesWorld{t: t, kind: kind, logBuf: &bytes.Buffer{}, prefs: map[string]*e2ee.PrefStatement{}, seq: map[string]uint64{}}
	if err := json.Unmarshal(raw, &w.v); err != nil {
		t.Fatal(err)
	}
	v := w.v
	w.ck, w.sk = hx(t, v.CKHex), hx(t, v.SKHex)
	w.nowT = time.UnixMilli(1700000000456).Add(time.Hour).UTC()
	w.of = newFakeOF(t, v.CircleID, v.Recipient.UserID)
	w.ing = newFakeIngest(t)
	w.dw = newFakeDawarich(t)

	w.sender = finishTDev(t, v.Sender.UserID, "device", v.Sender.DeviceID, vecIdentity(t, v.Sender), nil)
	w.admin = finishTDev(t, v.Admin.UserID, "device", v.Admin.DeviceID, vecIdentity(t, v.Admin), nil)
	w.owner = newTDev(t, v.Recipient.UserID, "device", nil)
	w.pat = newTDev(t, newUUIDv4(), "device", nil)
	w.bid = vecIdentity(t, v.Recipient)
	w.bdev = finishTDev(t, v.Recipient.UserID, kind, v.Recipient.DeviceID, w.bid, w.owner)
	w.of.members = []*tmember{
		{user: v.Recipient.UserID, name: "Owner", devs: []*tdev{w.owner, w.bdev}},
		{user: v.Sender.UserID, name: "Sam", devs: []*tdev{w.sender}},
		{user: v.Admin.UserID, name: "Admin", admin: true, devs: []*tdev{w.admin}},
		{user: w.pat.user, name: "Pat", devs: []*tdev{w.pat}},
	}
	w.of.mu.Lock()
	for _, d := range []*tdev{w.sender, w.admin, w.owner, w.pat} {
		w.of.logReg(d, d)
	}
	w.of.logReg(w.bdev, w.owner)
	w.of.mu.Unlock()
	w.of.publishEpoch(w.admin, 3, w.ck) // CK epoch 3 (the vector CK); nobody wraps it to the sidecar

	dir := t.TempDir() + "/state"
	w.st, err = openStore(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	id, err := w.st.createIdentity("Lanes sidecar")
	if err != nil {
		t.Fatal(err)
	}
	id.f.UserID, id.f.Server, id.f.RegisteredAt = v.Recipient.UserID, w.of.srv.URL, t0.Format(time.RFC3339)
	id.f.ApprovedBy, id.f.ApproverEdPub = w.owner.id, std(w.owner.edPub)
	if kind == "server" {
		id.f.Kind = "server"
	}
	if err := w.st.saveIdentity(id); err != nil {
		t.Fatal(err)
	}
	w.of.mu.Lock()
	tp := w.of.newTokens()
	w.of.mu.Unlock()
	if err := w.st.writeSecret(fileSession, session{Server: w.of.srv.URL, RefreshToken: tp.RefreshToken, UserID: v.Recipient.UserID}); err != nil {
		t.Fatal(err)
	}

	if kind == "server" {
		w.srvID, w.srvFP = v.Recipient.DeviceID, w.bid.fp
		w.cfg = &config{Mode: "server", Ingest: ingestCfg{URL: w.ing.srv.URL, token: srvToken}, PollSeconds: 15}
	} else {
		w.srvID, w.srvFP = v.ServerDev, hx(t, v.ServerFPHex)
		w.of.serverDev = map[string]any{"enabled": true, "device": map[string]any{"device_id": w.srvID, "fingerprint": v.ServerFPHex}}
		w.cfg = &config{Dawarich: dawarichCfg{BaseURL: w.dw.srv.URL, APIKey: "MAINKEY-secret", SendUnmapped: true},
			Users: map[string]userCfg{v.Sender.UserID: {APIKey: "SAMKEY-secret", Label: "sam"}}, PollSeconds: 30}
	}

	// policy generation 2 with the vector commitment; the SK wrap of the vector
	commit := hx(t, v.Wraps[0].CommitmentHex)
	if got, _ := e2ee.KeyCommitmentLine(w.sk, v.CircleID, e2ee.LineServer, 2); !bytes.Equal(got, commit) {
		t.Fatal("vector commitment mismatch")
	}
	w.setPolicy(true, 2, commit)
	w.of.skWraps = []e2ee.SKWrap{w.vectorSKWrap("sk_gen2", "server")}
	w.setPref(w.sender, e2ee.LineServer, 2)
	w.setPref(w.pat, e2ee.LinePhone, 0)
	w.of.proc = w.procJSON
	return w
}

func (w *lanesWorld) vectorSKWrap(name, line string) e2ee.SKWrap {
	for _, x := range w.v.Wraps {
		if x.Name == name {
			return e2ee.SKWrap{Epoch: int(x.Gen), RecipientDeviceID: w.v.Recipient.DeviceID, WrapperDeviceID: w.admin.id,
				WrapperEd25519Pub: std(w.admin.edPub), WrappedKey: std(hx(w.t, x.BlobHex)), Signature: std(hx(w.t, x.SigHex)), KeyLine: line}
		}
	}
	w.t.Fatalf("no vector wrap %s", name)
	return e2ee.SKWrap{}
}

func rnd(n int) []byte { b := make([]byte, n); _, _ = rand.Read(b); return b }

// setPolicy signs and logs a policy statement (admin phone) and records it as the served one.
func (w *lanesWorld) setPolicy(assist bool, gen uint32, commit []byte) *e2ee.PolicyStatement {
	w.t.Helper()
	nonce := rnd(16)
	msg, err := e2ee.ProcessingPolicyMessage(w.v.CircleID, w.admin.user, assist, e2ee.LinePhone, e2ee.OptOutAllowed, gen, commit, nonce)
	if err != nil {
		w.t.Fatal(err)
	}
	w.of.mu.Lock()
	w.of.appendLog(e2ee.ActProcessingPolicy, w.admin, w.admin.user, w.v.CircleID, "", gen, e2ee.ProcessingRef(msg), false)
	seq := int64(len(w.of.logEntries))
	w.of.mu.Unlock()
	st := e2ee.PolicyStatement{LogSeq: seq, AdminUserID: w.admin.user, ActorDeviceID: w.admin.id, ServerAssist: assist, DefaultForNew: "phone",
		MemberOptOut: "allowed", SKGen: int(gen), Commitment: std(commit), Nonce: std(nonce), Signature: std(ed25519.Sign(w.admin.priv, msg))}
	w.policy = &st
	w.hist = append(w.hist, st)
	return &st
}

// setPref signs and logs a member's lane statement naming the server key and serves it.
func (w *lanesWorld) setPref(m *tdev, lane e2ee.Line, gen uint32) *e2ee.PrefStatement {
	w.t.Helper()
	return w.setPrefFor(m, lane, gen, w.srvID, w.srvFP, true)
}

func (w *lanesWorld) setPrefFor(m *tdev, lane e2ee.Line, gen uint32, srvID string, srvFP []byte, serve bool) *e2ee.PrefStatement {
	w.t.Helper()
	nonce := rnd(16)
	sid, fp, subject := "00000000-0000-0000-0000-000000000000", make([]byte, 32), ""
	if lane == e2ee.LineServer {
		sid, fp, subject = srvID, srvFP, srvID
	}
	msg, err := e2ee.ProcessingPrefMessage(w.v.CircleID, m.user, lane, gen, sid, fp, nonce)
	if err != nil {
		w.t.Fatal(err)
	}
	w.of.mu.Lock()
	w.of.appendLog(e2ee.ActProcessingPref, m, m.user, w.v.CircleID, subject, gen, e2ee.ProcessingRef(msg), false)
	seq := int64(len(w.of.logEntries))
	w.of.mu.Unlock()
	st := &e2ee.PrefStatement{Lane: lane.String(), SKGen: int(gen), ServerDeviceID: sid, ServerFingerprint: std(fp), Nonce: std(nonce),
		ApproverDeviceID: m.id, Signature: std(ed25519.Sign(m.priv, msg)), LogSeq: &seq}
	if serve {
		w.prefs[m.user] = st
	}
	return st
}

func (w *lanesWorld) procJSON() any {
	mem := []map[string]any{}
	for _, m := range w.of.members {
		e := map[string]any{"user_id": m.user}
		if p := w.prefs[m.user]; p != nil {
			e["pref"] = p
		}
		mem = append(mem, e)
	}
	pol := map[string]any{"server_assist": w.policy != nil && w.policy.ServerAssist, "history": w.hist}
	if w.policy != nil {
		pol["statement"], pol["sk_gen"] = w.policy, w.policy.SKGen
	}
	return map[string]any{"policy": pol, "legacy": map[string]any{"active": false}, "members": mem}
}

func (w *lanesWorld) newBridge() *bridge {
	w.t.Helper()
	var sess session
	if err := w.st.readSecret(fileSession, &sess); err != nil {
		w.t.Fatal(err)
	}
	id, err := w.st.loadIdentity()
	if err != nil {
		w.t.Fatal(err)
	}
	id.edPriv, id.edPub, id.xSecret, id.xPub, id.fp = w.bid.edPriv, w.bid.edPub, w.bid.xSecret, w.bid.xPub, w.bid.fp
	id.f.DeviceID, id.f.Ed25519Pub, id.f.X25519Pub = w.v.Recipient.DeviceID, std(w.bid.edPub), std(w.bid.xPub)
	api := newAPIClient(sess.Server, sess.RefreshToken, func(rt string) error { sess.RefreshToken = rt; return w.st.writeSecret(fileSession, sess) })
	api.bo = fastBO()
	log := slog.New(slog.NewTextHandler(w.logBuf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	b, err := newBridge(w.st, id, api, w.cfg, log)
	if err != nil {
		w.t.Fatal(err)
	}
	b.sink.setBackoff(fastBO())
	b.now = func() time.Time { return w.nowT }
	if ds, ok := b.sink.(*dawarichSink); ok {
		ds.now = b.now
	}
	return b
}

func (w *lanesWorld) cycleOK(b *bridge) {
	w.t.Helper()
	if err := b.cycle(context.Background()); err != nil {
		w.t.Fatalf("cycle: %v", err)
	}
}

func (w *lanesWorld) vectorItem() fakeItem {
	for _, it := range w.v.Items {
		if it.Line == 1 {
			return w.of.addLineItem(w.v.Sender.DeviceID, int64(it.Seq), "fix", int(it.Gen), hx(w.t, it.PayloadHex), "server")
		}
	}
	w.t.Fatal("no server-line vector item")
	return fakeItem{}
}

func (w *lanesWorld) nextSeq(d *tdev) uint64 { w.seq[d.id]++; return 100 + w.seq[d.id] }

func (w *lanesWorld) ts(ageSec int) uint64 {
	return uint64(w.nowT.Add(-time.Duration(ageSec) * time.Second).UnixMilli())
}

// sealed returns a payload sealed as `by` on the given line.
func (w *lanesWorld) sealed(by *tdev, line e2ee.Line, key []byte, gen uint32, seq uint64, lat float64) []byte {
	w.t.Helper()
	body, _ := json.Marshal(map[string]any{"lat": lat, "lon": 13.4, "acc": 5.0})
	var n [e2ee.NonceLen]byte
	_, _ = rand.Read(n[:])
	ct, err := e2ee.SealItemV2(key, w.v.CircleID, line, gen, by.id, by.priv, "fix", seq, w.ts(30), body, n)
	if err != nil {
		w.t.Fatal(err)
	}
	return ct
}

func (w *lanesWorld) serverItem(by *tdev, lat float64) {
	seq := w.nextSeq(by)
	w.of.addLineItem(by.id, int64(seq), "fix", 2, w.sealed(by, e2ee.LineServer, w.sk, 2, seq, lat), "server")
}

func (w *lanesWorld) rejected(b *bridge, why string) int64 { return b.rs.Stats.Rejected[why] }

func (w *lanesWorld) pts() []map[string]any { return w.ing.points() }

// ---------------------------------------------------------------- tests

func TestLanesServerModeIngestsOnlyServerLaneAuthors(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.vectorItem()           // the Phase 1 vector: Sam (lane server), line server, gen 2
	w.serverItem(w.pat, 1.5) // Pat's lane is phone, yet the item is validly sealed under SK
	// Pat's item with the right header but junk behind it: if the sidecar decrypted it
	// the verdict would be bad_ciphertext; the lane check must come first.
	junk := append([]byte{2, 1, 0, 0, 0, 2}, rnd(120)...)
	w.of.addLineItem(w.pat.id, 900, "fix", 2, junk, "server")
	// the admin has no pref at all
	w.of.addLineItem(w.admin.id, 901, "fix", 2, junk, "server")
	b := w.newBridge()
	w.cycleOK(b)

	pts := w.pts()
	if len(pts) != 1 {
		t.Fatalf("ingested %d points, want 1 (Sam only)", len(pts))
	}
	if pts[0]["user_id"] != w.v.Sender.UserID || pts[0]["sender_device_id"] != w.v.Sender.DeviceID || pts[0]["lat"].(float64) != 52.52 || pts[0]["lon"].(float64) != 13.405 || pts[0]["kind"] != "fix" {
		t.Fatalf("point %v", pts[0])
	}
	if got := w.rejected(b, "deferred_author_not_server_lane"); got != 3 {
		t.Fatalf("deferred_author_not_server_lane = %d, want 3 (rejected: %v)", got, b.rs.Stats.Rejected)
	}
	if w.rejected(b, "bad_ciphertext") != 0 {
		t.Fatal("an item of a phone-lane author was decrypted")
	}
	h := w.of.hits
	if h["wraps-line-server"] == 0 || h["wraps-line-"] != 0 || h["wraps-line-phone"] != 0 || h["wraps-line-all"] != 0 {
		t.Fatalf("wrap requests %v: the sidecar must ask for the server line only", h)
	}
	if h["items-line-server"] == 0 || h["items-line-phone"] != 0 || h["items-line-all"] != 0 {
		t.Fatalf("item requests %v", h)
	}
	if h["GET /circles/"+w.v.CircleID+"/e2ee/server-member"] != 0 {
		t.Fatal("the legacy consent endpoint was used for a lanes circle")
	}
	if len(b.keys.epochs(w.v.CircleID)) != 0 || len(b.keys.epochs(skID(w.v.CircleID))) != 1 {
		t.Fatalf("keys: CK epochs %v, SK gens %v", b.keys.epochs(w.v.CircleID), b.keys.epochs(skID(w.v.CircleID)))
	}
	// Idle cycle: nothing new, nothing sent again; cursor is the server line's.
	n := len(w.ing.posts)
	w.cycleOK(b)
	if len(w.ing.posts) != n {
		t.Fatal("idle cycle ingested")
	}
	if b.rs.Recv.Cursor[skID(w.v.CircleID)] == 0 || b.rs.Recv.Cursor[w.v.CircleID] != 0 {
		t.Fatalf("cursors %v", b.rs.Recv.Cursor)
	}
	for _, s := range []string{"52.52", "13.405", std(w.sk), hex.EncodeToString(w.sk)} {
		if strings.Contains(w.logBuf.String(), s) {
			t.Fatalf("%q leaked into the log", s)
		}
	}
}

func TestLanesRejectsWrongLineAndTamperedItems(t *testing.T) {
	w := newLanesWorld(t, "server")
	b := w.newBridge()
	vecP := ""
	for _, it := range w.v.Items {
		if it.Line == 0 {
			vecP = it.PayloadHex
		}
	}
	sam := w.sender
	// a) the vector phone-line v2 item (CK, gen 3) relayed in the server list
	w.of.addLineItem(sam.id, 7, "fix", 3, hx(t, vecP), "server")
	// b) a v1 item sealed under CK (old format) in the server list
	var n [e2ee.NonceLen]byte
	v1, err := e2ee.SealItem(w.ck, w.v.CircleID, 3, sam.id, sam.priv, "fix", 11, w.ts(10), []byte(`{"lat":1,"lon":2}`), n)
	if err != nil {
		t.Fatal(err)
	}
	w.of.addLineItem(sam.id, 11, "fix", 3, v1, "server")
	// c) a v2 PHONE-line item (sealed under CK, header line 0) in the server list
	w.of.addLineItem(sam.id, 12, "fix", 3, w.sealed(sam, e2ee.LinePhone, w.ck, 3, 12, 3), "server")
	// d) SK item whose header generation differs from the declared one
	good := w.sealed(sam, e2ee.LineServer, w.sk, 2, 13, 4)
	tamperedGen := append([]byte{}, good...)
	tamperedGen[5] = 9
	w.of.addLineItem(sam.id, 13, "fix", 2, tamperedGen, "server")
	// e) ciphertext bit flipped
	flip := append([]byte{}, w.sealed(sam, e2ee.LineServer, w.sk, 2, 14, 5)...)
	flip[len(flip)-3] ^= 1
	w.of.addLineItem(sam.id, 14, "fix", 2, flip, "server")
	// f) sealed under SK but signed claiming another device id (sender mismatch)
	other := w.sealed(w.pat, e2ee.LineServer, w.sk, 2, 15, 6)
	w.of.addLineItem(sam.id, 15, "fix", 2, other, "server")
	// g) a result purpose is never requested; if a server returns one anyway it is dropped
	w.of.addLineItem(sam.id, 16, "trip", 2, good, "server")
	// h) the one good item
	w.of.addLineItem(sam.id, 17, "fix", 2, w.sealed(sam, e2ee.LineServer, w.sk, 2, 17, 7.5), "server")
	w.cycleOK(b)

	pts := w.pts()
	if len(pts) != 1 || pts[0]["lat"].(float64) != 7.5 {
		t.Fatalf("points %v (rejected %v)", pts, b.rs.Stats.Rejected)
	}
	r := b.rs.Stats.Rejected
	if r["line_mismatch"] != 3 || r["malformed"] != 1 || r["bad_ciphertext"] != 2 {
		t.Fatalf("rejections %v", r)
	}
}

func TestLanesPrefWithdrawalReplayAndForgery(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.vectorItem()
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.pts()) != 1 {
		t.Fatal("baseline: Sam's item was not ingested")
	}
	old := w.prefs[w.sender.user]

	// Sam withdraws (new log entry, lane phone). A lying server keeps serving the OLD
	// lane-server statement: it is no longer his newest pref in the verified log. With
	// nobody in the server lane the circle is not read at all.
	w.setPrefFor(w.sender, e2ee.LinePhone, 0, "", nil, false)
	w.prefs[w.sender.user] = old
	w.serverItem(w.sender, 11)
	w.cycleOK(b)
	if len(w.pts()) != 1 || !strings.Contains(w.logBuf.String(), "no member has a verified server lane") {
		t.Fatal("a replayed lane-server statement was honoured after the withdrawal")
	}
	// the honest phone statement: also nothing
	w.prefs[w.sender.user] = w.setPrefFor(w.sender, e2ee.LinePhone, 0, "", nil, false)
	w.serverItem(w.sender, 12)
	w.cycleOK(b)
	if len(w.pts()) != 1 {
		t.Fatalf("points %d after the withdrawal", len(w.pts()))
	}
	// Sam opts in again (decision: the lane is evaluated at read time, so the server-line
	// items that were waiting are read now; an honest phone puts none there while in the phone lane).
	w.setPref(w.sender, e2ee.LineServer, 2)
	w.serverItem(w.sender, 13)
	w.cycleOK(b)
	if len(w.pts()) != 4 || w.pts()[3]["lat"].(float64) != 13 {
		t.Fatalf("after opting in again: %d points", len(w.pts()))
	}

	// A statement signed by a key the log does not know (planted by the server), and a
	// statement signed correctly but not logged: neither opens the lane.
	for name, mk := range map[string]func(){
		"unlogged key": func() {
			evil := newTDev(t, w.sender.user, "device", nil)
			st := *w.prefs[w.pat.user]
			nonce := rnd(16)
			msg, _ := e2ee.ProcessingPrefMessage(w.v.CircleID, w.pat.user, e2ee.LineServer, 2, w.srvID, w.srvFP, nonce)
			st.Lane, st.SKGen, st.ServerDeviceID, st.ServerFingerprint = "server", 2, w.srvID, std(w.srvFP)
			st.Nonce, st.ApproverDeviceID, st.Signature = std(nonce), evil.id, std(ed25519.Sign(evil.priv, msg))
			w.prefs[w.pat.user] = &st
		},
		"signed, never logged": func() {
			nonce := rnd(16)
			msg, _ := e2ee.ProcessingPrefMessage(w.v.CircleID, w.pat.user, e2ee.LineServer, 2, w.srvID, w.srvFP, nonce)
			w.prefs[w.pat.user] = &e2ee.PrefStatement{Lane: "server", SKGen: 2, ServerDeviceID: w.srvID, ServerFingerprint: std(w.srvFP),
				Nonce: std(nonce), ApproverDeviceID: w.pat.id, Signature: std(ed25519.Sign(w.pat.priv, msg))}
		},
		"names another server key": func() {
			w.prefs[w.pat.user] = w.setPrefFor(w.pat, e2ee.LineServer, 2, w.v.ServerDev, hx(t, w.v.ServerFPHex), false)
		},
		"sk_gen above the policy": func() {
			w.prefs[w.pat.user] = w.setPrefFor(w.pat, e2ee.LineServer, 7, w.srvID, w.srvFP, false)
		},
	} {
		mk()
		w.serverItem(w.pat, 99)
		w.cycleOK(b)
		for _, p := range w.pts() {
			if p["user_id"] == w.pat.user {
				t.Fatalf("%s: Pat's data was ingested", name)
			}
		}
	}
}

func TestLanesPolicyMustVerifyAndBeNewest(t *testing.T) {
	w := newLanesWorld(t, "server")
	first := *w.policy
	w.vectorItem()
	b := w.newBridge()
	// A newer policy (same generation, settings change) exists in the log, but the server serves the old one.
	w.setPolicy(true, 2, hx(t, w.v.Wraps[0].CommitmentHex))
	w.policy = &first
	w.cycleOK(b)
	if len(w.pts()) != 0 || !strings.Contains(w.logBuf.String(), "served policy does not verify") {
		t.Fatalf("a stale policy was accepted (points %d)", len(w.pts()))
	}
	// Tampered statement fields (assist flipped by the server).
	w.hist = nil
	w.setPolicy(true, 2, hx(t, w.v.Wraps[0].CommitmentHex))
	bad := *w.policy
	bad.MemberOptOut = "required_server"
	w.policy = &bad
	w.cycleOK(b)
	if len(w.pts()) != 0 {
		t.Fatal("a tampered policy was accepted")
	}
	// A policy signed by a non-admin member.
	w.setPolicy(true, 2, hx(t, w.v.Wraps[0].CommitmentHex))
	imp := *w.policy
	imp.AdminUserID, imp.ActorDeviceID = w.sender.user, w.sender.id
	w.policy = &imp
	w.cycleOK(b)
	if len(w.pts()) != 0 {
		t.Fatal("a policy attributed to a non-admin was accepted")
	}
	// The log holds a policy but the server serves none.
	w.policy = nil
	w.cycleOK(b)
	if len(w.pts()) != 0 {
		t.Fatal("no policy served, yet points were read")
	}
	// The real one: works.
	w.hist = nil
	w.setPolicy(true, 2, hx(t, w.v.Wraps[0].CommitmentHex))
	w.cycleOK(b)
	if len(w.pts()) != 1 {
		t.Fatalf("the verified newest policy did not open the circle: %d", len(w.pts()))
	}
}

func TestLanesPolicyOffStopsWithExit3AndDropsTheKey(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.vectorItem()
	b := w.newBridge()
	w.cycleOK(b)
	if len(w.pts()) != 1 || len(b.keys.epochs(skID(w.v.CircleID))) != 1 {
		t.Fatal("baseline")
	}
	w.setPolicy(false, 2, hx(t, w.v.Wraps[0].CommitmentHex))
	w.of.skWraps = nil // the server deleted the SK wraps
	err := b.cycle(context.Background())
	if err == nil || exitCodeFor(err) != exitRevoked {
		t.Fatalf("policy off: err %v (exit %d), want exit 3", err, exitCodeFor(err))
	}
	if len(b.keys.epochs(skID(w.v.CircleID))) != 0 {
		t.Fatal("the server key was kept after the policy went off")
	}
	k2, _ := w.st.loadCircleKeys()
	if len(k2.epochs(skID(w.v.CircleID))) != 0 {
		t.Fatal("the server key is still on disk")
	}
	// loop() turns it into the process exit code.
	if code := b.loop(context.Background(), time.Millisecond, true); code != exitRevoked {
		t.Fatalf("loop exit %d", code)
	}
	// A device that never held an SK just waits.
	w2 := newLanesWorld(t, "server")
	w2.setPolicy(false, 2, hx(t, w2.v.Wraps[0].CommitmentHex))
	w2.cycleOK(w2.newBridge())
}

func TestLanesServerHandsOutACKWrapAlarm(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.vectorItem()
	b := w.newBridge()
	// The server answers key_line=server with the vector's CK wrap (phone line, gen 3).
	w.of.skWraps = []e2ee.SKWrap{w.vectorSKWrap("ck_v3_gen3", "phone")}
	err := b.cycle(context.Background())
	if err == nil || !isAlarm(err) || exitCodeFor(err) != exitAlarm {
		t.Fatalf("expected the CK alarm (exit 7), got %v", err)
	}
	if len(b.keys.epochs(w.v.CircleID)) != 0 || len(b.keys.epochs(skID(w.v.CircleID))) != 0 || len(w.pts()) != 0 {
		t.Fatal("a key or data was kept after the alarm")
	}
	if code := b.loop(context.Background(), time.Millisecond, true); code != exitAlarm {
		t.Fatalf("loop exit %d, want 7", code)
	}
	if !strings.Contains(w.logBuf.String(), "SECURITY ALARM") {
		t.Fatal("the alarm was not logged")
	}
	// A CK wrap mislabelled as server line does not open either (no policy for that generation, line check).
	w2 := newLanesWorld(t, "server")
	w2.of.skWraps = []e2ee.SKWrap{w2.vectorSKWrap("ck_v3_gen3", "server")}
	b2 := w2.newBridge()
	w2.cycleOK(b2)
	if len(b2.keys.epochs(skID(w2.v.CircleID))) != 0 || b2.rs.Stats.Rejected["wrap_rejected"] != 1 {
		t.Fatalf("mislabelled CK wrap stored: %v %v", b2.keys.epochs(skID(w2.v.CircleID)), b2.rs.Stats.Rejected)
	}
}

func TestLanesRefusesAnSKThatReusesTheCK(t *testing.T) {
	w := newLanesWorld(t, "server")
	// The admin phone wraps the CK bytes as the "server key" gen 2 and signs a policy for them.
	commit, _ := e2ee.KeyCommitmentLine(w.ck, w.v.CircleID, e2ee.LineServer, 2)
	w.hist = nil
	w.setPolicy(true, 2, commit)
	aad, _ := e2ee.WrapAADLine(w.v.CircleID, e2ee.LineServer, 2, w.v.Recipient.DeviceID, w.admin.id)
	blob, err := e2ee.Wrap(w.ck, w.bid.xPub, aad)
	if err != nil {
		t.Fatal(err)
	}
	sm, _ := e2ee.WrapSigMessageLine(w.v.CircleID, e2ee.LineServer, 2, w.v.Recipient.DeviceID, w.admin.id, blob)
	w.of.skWraps = []e2ee.SKWrap{{Epoch: 2, RecipientDeviceID: w.v.Recipient.DeviceID, WrapperDeviceID: w.admin.id, WrapperEd25519Pub: std(w.admin.edPub),
		WrappedKey: std(blob), Signature: std(ed25519.Sign(w.admin.priv, sm)), KeyLine: "server"}}
	b := w.newBridge()
	err = b.cycle(context.Background())
	if err == nil || !isAlarm(err) || exitCodeFor(err) != exitAlarm || !strings.Contains(err.Error(), "reuses CK") {
		t.Fatalf("SK = CK was not refused with the alarm: %v", err)
	}
	if len(b.keys.epochs(skID(w.v.CircleID))) != 0 {
		t.Fatal("the reused key was stored")
	}
}

func TestLanesMissingWrapsAreReportedAndHealLater(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.of.skWraps = nil
	w.of.pending = []map[string]any{{"device_id": newUUIDv4(), "user_name": "Newbie"}, {"device_id": newUUIDv4(), "user_name": "Newbie"}}
	w.vectorItem()
	b := w.newBridge()
	w.cycleOK(b)
	logs := w.logBuf.String()
	if len(w.pts()) != 0 || !strings.Contains(logs, "holds no server key for the current generation") || !strings.Contains(logs, "lack the current server key") || !strings.Contains(logs, "devices=2") {
		t.Fatalf("missing wraps not reported:\n%s", logs)
	}
	if w.of.hits["pending-line-server"] == 0 {
		t.Fatal("the pending queue of the server line was not consulted")
	}
	// An admin phone wraps SK; the sidecar notices after its key backoff.
	w.of.skWraps = []e2ee.SKWrap{w.vectorSKWrap("sk_gen2", "server")}
	w.nowT = w.nowT.Add(time.Minute)
	w.cycleOK(b)
	if len(w.pts()) != 1 {
		t.Fatalf("after the wrap arrived: %d points", len(w.pts()))
	}
}

func TestLanesRollbackIsPerLine(t *testing.T) {
	w := newLanesWorld(t, "server")
	w.vectorItem() // gen 2, signed ts = vector time
	b := w.newBridge()
	// This device first saw SK generation 3 long before the item was signed, and the
	// grace passed: a gen-2 item signed after that moment is a rollback. (The phone line
	// state is independent: CK epoch 3 existing changes nothing.)
	g := e2ee.NewRollbackGuard()
	_ = g.Observe(e2ee.LineServer, 3, int64(1700000000456)-1000)
	b.saveGuard(w.v.CircleID, g)
	w.cycleOK(b)
	if len(w.pts()) != 0 || b.rs.Stats.Rejected["epoch_rollback"] != 1 {
		t.Fatalf("rollback not enforced: %d points, %v", len(w.pts()), b.rs.Stats.Rejected)
	}
	// The same guard state survives a restart (it is persisted).
	if err := b.save(); err != nil {
		t.Fatal(err)
	}
	b2 := w.newBridge()
	if b2.rs.Recv.SKGuard[w.v.CircleID] == nil || b2.rs.Recv.SKGuard[w.v.CircleID].High["1"] != 3 {
		t.Fatalf("guard not persisted: %+v", b2.rs.Recv.SKGuard[w.v.CircleID])
	}
}

func TestLanesDawarichBridgeForwardsOnlyServerLaneMembers(t *testing.T) {
	w := newLanesWorld(t, "service")
	w.vectorItem()
	w.serverItem(w.pat, 1.5) // phone-lane member, SK-sealed: never forwarded
	w.serverItem(w.admin, 2.5)
	b := w.newBridge()
	w.cycleOK(b)
	pts := w.dw.points()
	if len(pts) != 1 || pts[0].Unique != w.v.Sender.DeviceID || pts[0].Key != "SAMKEY-secret" || pts[0].Lat != 52.52 {
		t.Fatalf("dawarich got %+v (rejected %v)", pts, b.rs.Stats.Rejected)
	}
	if w.rejected(b, "deferred_author_not_server_lane") != 2 || b.rs.Stats.Dropped["unmapped_user"] != 0 {
		t.Fatalf("rejected %v dropped %v", b.rs.Stats.Rejected, b.rs.Stats.Dropped)
	}
	if w.of.hits["items-line-phone"] != 0 || w.of.hits["wraps-line-"] != 0 || len(b.keys.epochs(w.v.CircleID)) != 0 {
		t.Fatalf("the bridge touched the phone line: %v", w.of.hits)
	}
	// A pref naming a server key that is not the pinned one does not count either.
	w.setPrefFor(w.pat, e2ee.LineServer, 2, newUUIDv4(), rnd(32), true)
	w.serverItem(w.pat, 9)
	w.cycleOK(b)
	if len(w.dw.points()) != 1 {
		t.Fatal("a lane statement naming a foreign server key opened the lane")
	}
}

// A circle that never had a lanes policy (legacy trusted-server circle) keeps the
// old flow: the lanes API is not even asked, consents + CK wrap drive it.
func TestLegacyCircleDoesNotUseLanes(t *testing.T) {
	w, ing := serverWorld(t)
	w.setConsents(w.bothConsent()...)
	w.of.proc = func() any { t.Error("the lanes API was used for a circle without a policy"); return map[string]any{} }
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	b := w.newBridge()
	w.cycleOK(b)
	if len(ing.points()) != 1 || w.of.hits["GET /circles/"+w.of.circle+"/e2ee/processing"] != 0 {
		t.Fatalf("legacy flow changed: %d points", len(ing.points()))
	}
}
