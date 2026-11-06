package e2ee

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
)

func sb(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func loadVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile("testdata/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// vectorRecordB is device B as registered (cross-signed) by device A, rebuilt
// from the frozen vectors.
func vectorRecordB(t *testing.T, v vectors) DeviceRecord {
	return DeviceRecord{
		DeviceID: v.IdentB.DeviceID, UserID: v.IdentB.UserID, Kind: "device",
		Ed25519Pub: sb(unhex(t, v.IdentB.EdPub)), X25519Pub: sb(unhex(t, v.IdentB.XPub)),
		Fingerprint: v.IdentB.Fingerprint, Signature: sb(unhex(t, v.IdentB.BindingSig)),
		RegisteredByDeviceID: v.IdentA.DeviceID, RegisteredByPub: sb(unhex(t, v.IdentA.EdPub)),
		RegistrationAction: int(ActRegister), RegistrationSignature: sb(unhex(t, v.LogAction.Signature)),
	}
}

func TestVerifyRegistrationVector(t *testing.T) {
	v := loadVectors(t)
	d := vectorRecordB(t, v)
	if !VerifyRegistration(d) {
		t.Fatal("registration from the frozen vectors must verify")
	}
	bad := d
	bad.Fingerprint = v.IdentA.Fingerprint // fingerprint not the hash of the published keys
	if VerifyRegistration(bad) {
		t.Fatal("wrong fingerprint accepted")
	}
	bad = d
	bad.RegisteredByPub = d.Ed25519Pub // not the voucher's key
	if VerifyRegistration(bad) {
		t.Fatal("wrong voucher key accepted")
	}
	bad = d
	bad.UserID = v.IdentA.UserID
	if VerifyRegistration(bad) {
		t.Fatal("record moved to another account accepted")
	}
	bad = d
	bad.RegistrationAction = int(ActRotate)
	if VerifyRegistration(bad) {
		t.Fatal("action swap accepted")
	}
	// A root key must be signed by itself.
	root := d
	root.RegisteredByDeviceID = root.DeviceID
	if VerifyRegistration(root) {
		t.Fatal("root claiming a foreign voucher key accepted")
	}
}

func TestLogVectorEntryVerifies(t *testing.T) {
	v := loadVectors(t)
	pub := sb(unhex(t, v.IdentA.EdPub))
	act := int(v.LogAction.Action)
	user, actor, subj := v.LogAction.UserID, v.LogAction.ActorDeviceID, v.LogAction.SubjectID
	ref, sig := v.LogAction.Ref, sb(unhex(t, v.LogAction.Signature))
	e := LogEntry{Seq: 1, PrevHash: v.LogAction.Prev, EntryHash: v.LogAction.EntryHash, Action: &act,
		UserID: &user, ActorDeviceID: &actor, ActorPub: &pub, SubjectID: &subj, Ref: &ref, Signature: &sig}
	head := LogHead{Seq: 1, Hash: unhex(t, v.LogAction.EntryHash)}
	if c := VerifyLogSlice(nil, []LogEntry{e}, head); !c.OK() || len(c.Events) != 1 {
		t.Fatalf("vector log entry: %+v", c)
	}
	bad := e
	other := actor[:len(actor)-1] + "b"
	bad.ActorDeviceID = &other
	if c := VerifyLogSlice(nil, []LogEntry{bad}, head); c.Problem != LogBadSignature {
		t.Fatalf("tampered actor: %v", c.Problem)
	}
}

// chain builds an n-entry log signed by one key; entries whose index is in
// redact are redacted (hash fields only).
type chain struct {
	entries []LogEntry
	hashes  [][]byte
}

func buildChain(t *testing.T, a ident, n int, redact map[int]bool) chain {
	t.Helper()
	var c chain
	prev := GenesisHash
	for i := 1; i <= n; i++ {
		ref := make([]byte, 32)
		ref[0] = byte(i)
		m, err := LogActionMessage(ActEpoch, uidA, devA, circ, "", uint32(i), ref)
		if err != nil {
			t.Fatal(err)
		}
		sig := ed25519.Sign(a.priv, m)
		h := LogEntryHash(prev, uint64(i), m, sig)
		e := LogEntry{Seq: int64(i), PrevHash: hex.EncodeToString(prev), EntryHash: hex.EncodeToString(h)}
		if redact[i] {
			e.Redacted = true
		} else {
			act, u, d, cc, ep := int(ActEpoch), uidA, devA, circ, i
			p, r, s := sb(a.ed), hex.EncodeToString(ref), sb(sig)
			e.Action, e.UserID, e.ActorDeviceID, e.ActorPub, e.CircleID, e.Epoch, e.Ref, e.Signature = &act, &u, &d, &p, &cc, &ep, &r, &s
		}
		c.entries = append(c.entries, e)
		c.hashes = append(c.hashes, h)
		prev = h
	}
	return c
}

func (c chain) head(n int) LogHead { return LogHead{Seq: int64(n), Hash: c.hashes[n-1]} }

func TestVerifyLogSlice(t *testing.T) {
	a := mk(t, 1)
	c := buildChain(t, a, 6, map[int]bool{2: true})
	if r := VerifyLogSlice(nil, c.entries, c.head(6)); !r.OK() || len(r.Events) != 5 {
		t.Fatalf("clean chain: %+v", r)
	}
	pin := c.head(3)
	if r := VerifyLogSlice(&pin, c.entries[2:], c.head(6)); !r.OK() || len(r.Events) != 3 || r.NewHead.Seq != 6 {
		t.Fatalf("from pin: %+v", r)
	}
	// Nothing new.
	if r := VerifyLogSlice(&pin, c.entries[2:3], pin); !r.OK() {
		t.Fatalf("same head: %+v", r)
	}
	// Rollback.
	pin6 := c.head(6)
	if r := VerifyLogSlice(&pin6, c.entries[:3], c.head(3)); r.Problem != LogRollback {
		t.Fatalf("rollback: %v", r.Problem)
	}
	// Fork: another chain with the same length but different content.
	b := mk(t, 9)
	f := buildChain(t, b, 6, nil)
	if r := VerifyLogSlice(&pin, f.entries[2:], f.head(6)); r.Problem != LogFork && r.Problem != LogBrokenChain {
		t.Fatalf("fork: %v", r.Problem)
	}
	// Gap in the middle.
	gap := append(append([]LogEntry{}, c.entries[:2]...), c.entries[3:]...)
	if r := VerifyLogSlice(nil, gap, c.head(6)); r.Problem != LogGap {
		t.Fatalf("gap: %v", r.Problem)
	}
	// Log that does not start at 1 when nothing is pinned.
	if r := VerifyLogSlice(nil, c.entries[1:], c.head(6)); r.Problem != LogGap {
		t.Fatalf("no start: %v", r.Problem)
	}
	// Broken linkage.
	br := append([]LogEntry{}, c.entries...)
	br[3].PrevHash = hex.EncodeToString(make([]byte, 32))
	if r := VerifyLogSlice(nil, br, c.head(6)); r.Problem != LogBrokenChain {
		t.Fatalf("linkage: %v", r.Problem)
	}
	// Forged signature (valid format, wrong key).
	fs := append([]LogEntry{}, c.entries...)
	other := sb(mk(t, 7).ed)
	fs[4].ActorPub = &other
	if r := VerifyLogSlice(nil, fs, c.head(6)); r.Problem != LogBadSignature {
		t.Fatalf("forged signature: %v", r.Problem)
	}
	// Content altered (epoch) -> signature fails.
	al := append([]LogEntry{}, c.entries...)
	ep := 99
	al[4].Epoch = &ep
	if r := VerifyLogSlice(nil, al, c.head(6)); r.Problem != LogBadSignature {
		t.Fatalf("altered content: %v", r.Problem)
	}
	// Entry hash altered but signature intact.
	bh := append([]LogEntry{}, c.entries...)
	bh[4].EntryHash = hex.EncodeToString(make([]byte, 32))
	if r := VerifyLogSlice(nil, bh, c.head(6)); r.Problem != LogBadHash {
		t.Fatalf("bad hash: %v", r.Problem)
	}
	// Reported head is not the last entry.
	if r := VerifyLogSlice(nil, c.entries, c.head(5)); r.Problem != LogBrokenChain {
		t.Fatalf("head: %v", r.Problem)
	}
	// Malformed visible entry.
	mf := append([]LogEntry{}, c.entries...)
	mf[0].Signature = nil
	if r := VerifyLogSlice(nil, mf, c.head(6)); r.Problem != LogMalformed {
		t.Fatalf("malformed: %v", r.Problem)
	}
	// Empty log.
	if r := VerifyLogSlice(nil, nil, LogHead{Hash: make([]byte, 32)}); !r.OK() {
		t.Fatalf("empty: %+v", r)
	}
	if r := VerifyLogSlice(nil, nil, c.head(2)); r.Problem != LogGap {
		t.Fatalf("empty but head: %v", r.Problem)
	}
}

func pagedFetch(c chain, page int) LogFetcher {
	return func(after int64) ([]LogEntry, LogHead, error) {
		end := min(int(after)+page, len(c.entries))
		return c.entries[after:end], c.head(len(c.entries)), nil
	}
}

func TestSyncLogPagesAndPins(t *testing.T) {
	a := mk(t, 1)
	c := buildChain(t, a, 11, map[int]bool{4: true, 5: true})
	r, err := SyncLog(nil, pagedFetch(c, 4))
	if err != nil || !r.OK() || r.NewHead.Seq != 11 || len(r.Events) != 9 {
		t.Fatalf("paged sync: %+v %v", r, err)
	}
	pin := c.head(7)
	r, err = SyncLog(&pin, pagedFetch(c, 3))
	if err != nil || !r.OK() || r.NewHead.Seq != 11 {
		t.Fatalf("paged from pin: %+v %v", r, err)
	}
	// Tamper deep inside a later page.
	t2 := buildChain(t, a, 11, nil)
	bad := "00" + t2.entries[8].EntryHash[2:]
	t2.entries[8].EntryHash = bad
	if r, _ := SyncLog(nil, pagedFetch(t2, 4)); r.OK() {
		t.Fatal("tampered later page accepted")
	}
	// Rollback after pinning 11.
	pin = c.head(11)
	short := buildChain(t, a, 11, nil)
	short.entries = short.entries[:8]
	short.hashes = short.hashes[:8]
	r, _ = SyncLog(&pin, func(after int64) ([]LogEntry, LogHead, error) {
		return short.entries[min(after, 8):], short.head(8), nil
	})
	if r.Problem != LogRollback {
		t.Fatalf("rollback: %v", r.Problem)
	}
	// Fetch errors are not log problems.
	if _, err = SyncLog(nil, func(int64) ([]LogEntry, LogHead, error) { return nil, LogHead{}, errors.New("net") }); err == nil {
		t.Fatal("fetch error swallowed")
	}
	// A server that never advances is caught.
	r, _ = SyncLog(nil, func(after int64) ([]LogEntry, LogHead, error) { return c.entries[:2], c.head(11), nil })
	if r.OK() {
		t.Fatal("stalled server accepted")
	}
}

// ------------------------------------------------------------- wraps

type wrapFixture struct {
	rec      EpochRecord
	wrap     WrapRecord
	key      []byte
	recipent ident
}

func buildWrap(t *testing.T) wrapFixture {
	t.Helper()
	pub, rcpt := mk(t, 1), mk(t, 2) // publisher/wrapper A, recipient B
	key := seed(0x42)
	commit, _ := KeyCommitment(key, circ, 1)
	m, _ := LogActionMessage(ActEnable, uidA, devA, circ, "", 1, commit)
	rec := EpochRecord{Epoch: 1, Action: int(ActEnable), PublisherUser: uidA, PublisherDev: devA,
		PublisherPub: sb(pub.ed), KeyCommitment: sb(commit), Signature: sb(ed25519.Sign(pub.priv, m))}
	aad, _ := WrapAAD(circ, 1, devB, devA)
	blob, err := Wrap(key, rcpt.x, aad)
	if err != nil {
		t.Fatal(err)
	}
	sm, _ := WrapSigMessage(circ, 1, devB, devA, blob)
	w := WrapRecord{Epoch: 1, RecipientDeviceID: devB, WrapperDeviceID: devA, WrapperEd25519Pub: sb(pub.ed),
		WrappedKey: sb(blob), Signature: sb(ed25519.Sign(pub.priv, sm))}
	return wrapFixture{rec, w, key, rcpt}
}

func TestOpenWrap(t *testing.T) {
	f := buildWrap(t)
	got, err := OpenWrap(circ, devB, f.recipent.xSecret, f.recipent.x, f.wrap, &f.rec)
	if err != nil || string(got) != string(f.key) {
		t.Fatalf("good wrap: %v", err)
	}
	reject := func(name string, mut func(w *WrapRecord, r *EpochRecord), rec bool) {
		t.Helper()
		w, r := f.wrap, f.rec
		mut(&w, &r)
		rp := &r
		if !rec {
			rp = nil
		}
		if _, err := OpenWrap(circ, devB, f.recipent.xSecret, f.recipent.x, w, rp); !errors.Is(err, ErrWrapRejected) {
			t.Fatalf("%s: want ErrWrapRejected, got %v", name, err)
		}
	}
	reject("missing epoch record", func(*WrapRecord, *EpochRecord) {}, false)
	reject("other recipient", func(w *WrapRecord, _ *EpochRecord) { w.RecipientDeviceID = devA }, true)
	reject("blob tampered", func(w *WrapRecord, _ *EpochRecord) {
		b, _ := base64.StdEncoding.DecodeString(w.WrappedKey)
		b[70] ^= 1
		w.WrappedKey = sb(b)
	}, true)
	reject("wrapper signature", func(w *WrapRecord, _ *EpochRecord) {
		b, _ := base64.StdEncoding.DecodeString(w.Signature)
		b[0] ^= 1
		w.Signature = sb(b)
	}, true)
	reject("epoch record signature", func(_ *WrapRecord, r *EpochRecord) {
		b, _ := base64.StdEncoding.DecodeString(r.Signature)
		b[0] ^= 1
		r.Signature = sb(b)
	}, true)
	reject("disable action is no epoch record", func(_ *WrapRecord, r *EpochRecord) { r.Action = int(ActDisable) }, true)
	reject("wrong commitment (publisher signed another key)", func(_ *WrapRecord, r *EpochRecord) {
		other, _ := KeyCommitment(seed(0x43), circ, 1)
		pub := mk(t, 1)
		m, _ := LogActionMessage(ActEnable, uidA, devA, circ, "", 1, other)
		r.KeyCommitment, r.Signature = sb(other), sb(ed25519.Sign(pub.priv, m))
	}, true)
	// A wrap that is valid for epoch 1 cannot be presented as epoch 2.
	reject("epoch replay", func(w *WrapRecord, r *EpochRecord) { w.Epoch, r.Epoch = 2, 2 }, true)
	// Wrong X25519 secret.
	if _, err := OpenWrap(circ, devB, mk(t, 3).xSecret, f.recipent.x, f.wrap, &f.rec); !errors.Is(err, ErrWrapRejected) {
		t.Fatalf("wrong secret: %v", err)
	}
	_ = fmt.Sprint
}

func TestAuthorizeFailsClosedWithoutIndexOrDevice(t *testing.T) {
	if err := AuthorizeSender(nil, nil, nil, nil); err == nil {
		t.Fatal("nil sender accepted")
	}
	d := &DeviceRecord{DeviceID: "x", UserID: "u1"}
	if err := AuthorizeSender(nil, nil, d, &CircleMember{UserID: "u2"}); err == nil {
		t.Fatal("user mismatch accepted")
	}
	ap := true
	d2 := &DeviceRecord{DeviceID: "x", UserID: "u1", Approved: &ap}
	if err := AuthorizeSender(nil, nil, d2, &CircleMember{UserID: "u1"}); err == nil {
		t.Fatal("accepted without a verified log")
	}
	if err := AuthorizeWrap(nil, nil, "c", "u", WrapRecord{}, &EpochRecord{}); err == nil {
		t.Fatal("wrap accepted without a log index")
	}
}

// ---- chain walk: key binding, revocation order, forged actor keys

type tlog struct {
	t       *testing.T
	entries []LogEntry
	prev    []byte
	keys    map[string]ed25519.PrivateKey
	recs    map[string]DeviceRecord
}

func newTLog(t *testing.T) *tlog {
	return &tlog{t: t, prev: GenesisHash, keys: map[string]ed25519.PrivateKey{}, recs: map[string]DeviceRecord{}}
}

const tUser = "11111111-1111-4111-8111-111111111111"

func tid(n byte) string { return fmt.Sprintf("%08x-0000-4000-8000-%012x", int(n), int(n)) }

// add appends a signed entry. signer's private key signs; asDevice/asPub are what the entry CLAIMS.
func (l *tlog) add(action byte, signer ed25519.PrivateKey, asDevice string, asPub []byte, subject string, ref []byte) {
	msg, err := LogActionMessage(action, tUser, asDevice, "", subject, 0, ref)
	if err != nil {
		l.t.Fatal(err)
	}
	sig := ed25519.Sign(signer, msg)
	seq := int64(len(l.entries) + 1)
	h := LogEntryHash(l.prev, uint64(seq), msg, sig)
	a, ep := int(action), 0
	u, pub, sg, r := tUser, sb(asPub), sb(sig), hex.EncodeToString(ref)
	l.entries = append(l.entries, LogEntry{Seq: seq, PrevHash: hex.EncodeToString(l.prev), EntryHash: hex.EncodeToString(h),
		Action: &a, UserID: &u, ActorDeviceID: &asDevice, ActorPub: &pub, SubjectID: &subject, Epoch: &ep, Ref: &r, Signature: &sg})
	l.prev = h
}

// device registers device n, vouched by voucher (0 = root).
func (l *tlog) device(n, voucher byte) DeviceRecord { return l.deviceAs(n, voucher, ActRegister) }

// deviceAs registers device n with the given log action (register, rotate, reset ...).
func (l *tlog) deviceAs(n, voucher, action byte) DeviceRecord {
	seed := make([]byte, 32)
	seed[0], seed[1] = n, 0x77
	priv := ed25519.NewKeyFromSeed(seed)
	ed := priv.Public().(ed25519.PublicKey)
	x := make([]byte, 32)
	x[0] = n
	x[31] = 9
	id := tid(n)
	l.keys[id] = priv
	fp, _ := Fingerprint(ed, x)
	by, byPriv, byPub := id, priv, []byte(ed)
	if voucher != 0 {
		by = tid(voucher)
		byPriv = l.keys[by]
		byPub = byPriv.Public().(ed25519.PublicKey)
	}
	bind, _ := BindingMessage(tUser, id, ed, x)
	msg, _ := LogActionMessage(action, tUser, by, "", id, 0, fp)
	ap := true
	rec := DeviceRecord{DeviceID: id, UserID: tUser, Kind: "device", Ed25519Pub: sb(ed), X25519Pub: sb(x),
		Fingerprint: hex.EncodeToString(fp), Signature: sb(ed25519.Sign(priv, bind)), RegisteredByDeviceID: by,
		RegisteredByPub: sb(byPub), RegistrationAction: int(action), RegistrationSignature: sb(ed25519.Sign(byPriv, msg)), Approved: &ap}
	l.add(action, byPriv, by, byPub, id, fp)
	l.recs[id] = rec
	return rec
}

func (l *tlog) revoke(n, by byte) {
	rec := l.recs[tid(n)]
	fp, _ := hex.DecodeString(rec.Fingerprint)
	k := l.keys[tid(by)]
	l.add(ActRevoke, k, tid(by), k.Public().(ed25519.PublicKey), tid(n), fp)
}

func (l *tlog) index() (*LogIndex, LogCheck) {
	head := l.entries[len(l.entries)-1]
	hh, _ := hex.DecodeString(head.EntryHash)
	c, idx, err := SyncLogFull(nil, func(after int64) ([]LogEntry, LogHead, error) {
		var out []LogEntry
		for _, e := range l.entries {
			if e.Seq > after {
				out = append(out, e)
			}
		}
		return out, LogHead{Seq: head.Seq, Hash: hh}, nil
	})
	if err != nil {
		l.t.Fatal(err)
	}
	return idx, c
}

func members(l *tlog, ids ...byte) []CircleMember {
	m := CircleMember{UserID: tUser, Role: "admin"}
	for _, n := range ids {
		m.Devices = append(m.Devices, l.recs[tid(n)])
	}
	return []CircleMember{m}
}

func TestChainWalkRealFlows(t *testing.T) {
	l := newTLog(t)
	root := l.device(1, 0)   // first phone
	phone2 := l.device(2, 1) // second phone vouched by the first
	viewer := l.device(3, 2) // viewer vouched by phone 2
	idx, c := l.index()
	if !c.OK() {
		t.Fatalf("honest log rejected: %v", c.Detail)
	}
	m := members(l, 1, 2, 3)
	for _, d := range []DeviceRecord{root, phone2, viewer} {
		d := d
		if err := AuthorizeSender(idx, m, &d, &m[0]); err != nil {
			t.Fatalf("honest device %s refused: %v", d.DeviceID, err)
		}
	}
}

func TestChainWalkRejectsVoucherWithForeignKey(t *testing.T) {
	l := newTLog(t)
	l.device(1, 0)
	l.device(2, 1)
	// An attacker signs a registration that CLAIMS to be vouched by device 1 but uses its own key.
	evilSeed := make([]byte, 32)
	evilSeed[0] = 0xEE
	evil := ed25519.NewKeyFromSeed(evilSeed)
	x := make([]byte, 32)
	x[0] = 0x66
	ed := ed25519.NewKeyFromSeed(append(make([]byte, 31), 0x55))
	edPub := ed.Public().(ed25519.PublicKey)
	fp, _ := Fingerprint(edPub, x)
	id := tid(9)
	bind, _ := BindingMessage(tUser, id, edPub, x)
	msg, _ := LogActionMessage(ActRegister, tUser, tid(1), "", id, 0, fp)
	ap := true
	forged := DeviceRecord{DeviceID: id, UserID: tUser, Kind: "device", Ed25519Pub: sb(edPub), X25519Pub: sb(x), Fingerprint: hex.EncodeToString(fp),
		Signature: sb(ed25519.Sign(ed, bind)), RegisteredByDeviceID: tid(1), RegisteredByPub: sb(evil.Public().(ed25519.PublicKey)),
		RegistrationAction: int(ActRegister), RegistrationSignature: sb(ed25519.Sign(evil, msg)), Approved: &ap}
	if !VerifyRegistration(forged) {
		t.Fatal("test setup: the forged record is internally consistent")
	}
	l.add(ActRegister, evil, tid(1), evil.Public().(ed25519.PublicKey), id, fp)
	l.recs[id] = forged
	// The log itself is untrustworthy: device 1 signs with two keys.
	if _, c := l.index(); c.OK() || c.Problem != LogMalformed {
		t.Fatalf("log with a forged actor_pub was accepted: %v %s", c.Problem, c.Detail)
	}
}

func TestChainWalkRejectsForgedVoucherNeverSeenSigning(t *testing.T) {
	// The voucher id exists (listed in the state with its real key) but never signed anything
	// in the log; the forged hop uses another key under its id. The state's key disagrees.
	l := newTLog(t)
	l.device(1, 0)
	real := l.device(2, 1) // listed, real key; never acts as actor in the log
	evil := ed25519.NewKeyFromSeed(append(make([]byte, 31), 0xEE))
	x := make([]byte, 32)
	ed := ed25519.NewKeyFromSeed(append(make([]byte, 31), 0x55))
	edPub := ed.Public().(ed25519.PublicKey)
	fp, _ := Fingerprint(edPub, x)
	id := tid(9)
	bind, _ := BindingMessage(tUser, id, edPub, x)
	msg, _ := LogActionMessage(ActRegister, tUser, real.DeviceID, "", id, 0, fp)
	ap := true
	forged := DeviceRecord{DeviceID: id, UserID: tUser, Kind: "device", Ed25519Pub: sb(edPub), X25519Pub: sb(x), Fingerprint: hex.EncodeToString(fp),
		Signature: sb(ed25519.Sign(ed, bind)), RegisteredByDeviceID: real.DeviceID, RegisteredByPub: sb(evil.Public().(ed25519.PublicKey)),
		RegistrationAction: int(ActRegister), RegistrationSignature: sb(ed25519.Sign(evil, msg)), Approved: &ap}
	l.add(ActRegister, evil, real.DeviceID, evil.Public().(ed25519.PublicKey), id, fp)
	l.recs[id] = forged
	idx, c := l.index()
	if !c.OK() {
		t.Fatalf("setup: log should verify (the voucher only appears once): %v", c.Detail)
	}
	m := members(l, 1, 2, 9)
	if err := AuthorizeSender(idx, m, &forged, &m[0]); err == nil {
		t.Fatal("device vouched by a forged voucher key accepted")
	}
	// Without the state listing the voucher, the forged key is the only evidence; the root hop still ties it:
	// the voucher's own registration is vouched by device 1 and cannot supply the forged key.
	if idx.ChainLogged(forged, nil) {
		t.Fatal("chain accepted a voucher key that its registration chain does not support")
	}
}

func TestChainWalkRootKeyMismatch(t *testing.T) {
	l := newTLog(t)
	root := l.device(1, 0)
	idx, _ := l.index()
	bad := root
	other := ed25519.NewKeyFromSeed(append(make([]byte, 31), 0x42))
	bad.RegisteredByPub = sb(other.Public().(ed25519.PublicKey))
	if idx.ChainLogged(bad, nil) {
		t.Fatal("root accepted with a key different from the logged one")
	}
	bad = root
	bad.Ed25519Pub = sb(other.Public().(ed25519.PublicKey)) // state lists another key than the root signs with
	if idx.ChainLogged(bad, nil) {
		t.Fatal("root accepted although the listed key differs from its logged signing key")
	}
}

func TestChainWalkRevocationOrder(t *testing.T) {
	// Registration BEFORE the voucher's revoke stays valid.
	l := newTLog(t)
	l.device(1, 0)
	w := l.device(2, 1)
	l.revoke(1, 1)
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	m := members(l, 1, 2) // a (lying) state still lists the revoked voucher
	if err := AuthorizeSender(idx, m, &w, &m[0]); err != nil {
		t.Fatalf("registration that predates the voucher's revoke refused: %v", err)
	}
	// Registration AFTER the voucher was revoked is refused (a revoked key cannot mint devices).
	l2 := newTLog(t)
	l2.device(1, 0)
	l2.revoke(1, 1)
	late := l2.device(3, 1)
	idx2, c2 := l2.index()
	if !c2.OK() {
		t.Fatal(c2.Detail)
	}
	m2 := members(l2, 1, 3)
	if err := AuthorizeSender(idx2, m2, &late, &m2[0]); err == nil {
		t.Fatal("device registered by an already revoked voucher accepted")
	}
	// A chain THROUGH a revoked middle voucher: W (by V) registered after V's revoke.
	l3 := newTLog(t)
	l3.device(1, 0)
	l3.device(2, 1)
	l3.revoke(2, 1)
	deep := l3.device(4, 2)
	idx3, _ := l3.index()
	m3 := members(l3, 1, 2, 4)
	if err := AuthorizeSender(idx3, m3, &deep, &m3[0]); err == nil {
		t.Fatal("chain through a revoked voucher accepted")
	}
}

func TestRevokedDeviceIsRefusedFromTheLog(t *testing.T) {
	l := newTLog(t)
	l.device(1, 0)
	w := l.device(2, 1)
	l.revoke(2, 1)
	idx, _ := l.index()
	m := members(l, 2) // a lying state still lists the revoked device
	if err := AuthorizeSender(idx, m, &w, &m[0]); err == nil {
		t.Fatal("log-revoked device accepted")
	}
}

func TestSyncLogFullHandlesOverlappingPages(t *testing.T) {
	l := newTLog(t)
	l.device(1, 0)
	for n := byte(2); n < 8; n++ {
		l.device(n, 1)
	}
	head := l.entries[len(l.entries)-1]
	hh, _ := hex.DecodeString(head.EntryHash)
	c, idx, err := SyncLogFull(nil, func(after int64) ([]LogEntry, LogHead, error) {
		var out []LogEntry
		for _, e := range l.entries {
			if e.Seq > after && len(out) < 3 { // small pages force the one-entry overlap
				out = append(out, e)
			}
		}
		return out, LogHead{Seq: head.Seq, Hash: hh}, nil
	})
	if err != nil || !c.OK() || idx == nil {
		t.Fatalf("paged full sync: %v %v %s", err, c.Problem, c.Detail)
	}
}

func TestChainWalkListedVoucherMustMatchItsLoggedRegistration(t *testing.T) {
	l := newTLog(t)
	l.device(1, 0)
	mid := l.device(2, 1)
	leaf := l.device(3, 2)
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	ok := members(l, 1, 2, 3)
	if err := AuthorizeSender(idx, ok, &leaf, &ok[0]); err != nil {
		t.Fatalf("honest chain refused: %v", err)
	}
	mut := map[string]func(*DeviceRecord){
		"fingerprint differs from the logged ref":            func(d *DeviceRecord) { d.Fingerprint = hex.EncodeToString(make([]byte, 32)) },
		"x25519 key swapped (fingerprint no longer matches)": func(d *DeviceRecord) { d.X25519Pub = sb(make([]byte, 32)) },
		"registration signature differs":                     func(d *DeviceRecord) { d.RegistrationSignature = sb(make([]byte, 64)) },
		"owned by another user":                              func(d *DeviceRecord) { d.UserID = "22222222-2222-4222-8222-222222222222" },
	}
	for name, f := range mut {
		t.Run(name, func(t *testing.T) {
			m := members(l, 1, 2, 3)
			for i := range m[0].Devices {
				if m[0].Devices[i].DeviceID == mid.DeviceID {
					f(&m[0].Devices[i])
				}
			}
			if err := AuthorizeSender(idx, m, &leaf, &m[0]); err == nil {
				t.Fatal("chain through a tampered listed voucher accepted")
			}
		})
	}
	// An unlisted voucher (even a root) is refused: its key is not bound by anything we can check.
	if err := AuthorizeSender(idx, members(l, 3), &leaf, &members(l, 3)[0]); err == nil {
		t.Fatal("chain with unlisted vouchers accepted")
	}
}

func TestRotationAndResetRetireKeys(t *testing.T) {
	// Rotation: the OLD key is retired at the rotate entry; devices it vouches for afterwards are refused,
	// the new key (registered by that very entry) and registrations before it stay valid.
	l := newTLog(t)
	l.device(1, 0)
	l.device(2, 1)
	before := l.device(3, 2)
	l.deviceAs(5, 2, ActRotate) // 2 rotates to 5
	after := l.device(6, 2)     // old key vouches after being rotated away
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	if !idx.Revoked(tid(2)) {
		t.Fatal("a rotation must retire the old key")
	}
	m := members(l, 1, 2, 3, 5, 6) // a lying state lists the rotated-away key
	if err := AuthorizeSender(idx, m, &after, &m[0]); err == nil {
		t.Fatal("device vouched by a rotated-away key AFTER the rotation accepted")
	}
	if err := AuthorizeSender(idx, m, &before, &m[0]); err != nil {
		t.Fatalf("registration before the rotation refused: %v", err)
	}
	rotated := l.recs[tid(5)]
	if err := AuthorizeSender(idx, m, &rotated, &m[0]); err != nil {
		t.Fatalf("the rotated-to key refused: %v", err)
	}
	old := l.recs[tid(2)]
	if err := AuthorizeSender(idx, m, &old, &m[0]); err == nil {
		t.Fatal("the rotated-away key itself accepted")
	}

	// Reset: a new root retires every earlier key of the user.
	l2 := newTLog(t)
	l2.device(1, 0)
	prev := l2.device(2, 1)
	root := l2.deviceAs(7, 0, ActReset)
	post := l2.device(8, 7)
	late := l2.device(9, 1) // the retired root vouching after the reset
	idx2, c2 := l2.index()
	if !c2.OK() {
		t.Fatal(c2.Detail)
	}
	m2 := members(l2, 1, 2, 7, 8, 9)
	if err := AuthorizeSender(idx2, m2, &prev, &m2[0]); err == nil {
		t.Fatal("a key retired by a reset accepted")
	}
	if err := AuthorizeSender(idx2, m2, &late, &m2[0]); err == nil {
		t.Fatal("device vouched by a key retired by a reset accepted")
	}
	for _, d := range []DeviceRecord{root, post} {
		d := d
		if err := AuthorizeSender(idx2, m2, &d, &m2[0]); err != nil {
			t.Fatalf("post-reset device %s refused: %v", d.DeviceID, err)
		}
	}
}

func TestOwnAccountDevicesMustChainToThePinnedApprover(t *testing.T) {
	l := newTLog(t)
	root := l.device(1, 0)
	phone := l.device(2, 1)  // approver
	viewer := l.device(3, 2) // the viewer itself would be this
	sibling := l.device(4, 1)
	idx, c := l.index()
	if !c.OK() {
		t.Fatal(c.Detail)
	}
	_ = viewer
	m := members(l, 1, 2, 3, 4)
	tr := Trust{Index: idx, Members: m, OwnUserID: tUser, Anchor: &Anchor{DeviceID: phone.DeviceID, EdPub: phone.Ed25519Pub}}
	for _, d := range []DeviceRecord{root, phone, sibling} {
		d := d
		if err := tr.AuthorizeSender(&d, &m[0]); err != nil {
			t.Fatalf("device %s of the approver's chain refused: %v", d.DeviceID, err)
		}
	}
	// A reset retires the earlier keys; build the unanchored case on its own log instead.
	l2 := newTLog(t)
	l2.device(1, 0)
	ph := l2.device(2, 1)
	other := l2.device(5, 0) // second ROOT of the same account, not related to the approver
	idx2, _ := l2.index()
	m2 := members(l2, 1, 2, 5)
	tr2 := Trust{Index: idx2, Members: m2, OwnUserID: tUser, Anchor: &Anchor{DeviceID: ph.DeviceID, EdPub: ph.Ed25519Pub}}
	if err := tr2.AuthorizeSender(&other, &m2[0]); err == nil {
		t.Fatal("own-account device with a different root accepted")
	}
	// No pinned approver: own-account devices are refused (fail closed).
	tr3 := Trust{Index: idx2, Members: m2, OwnUserID: tUser}
	if err := tr3.AuthorizeSender(&ph, &m2[0]); err == nil {
		t.Fatal("own-account device accepted without a pinned approver")
	}
	// Wrong key pinned for the approver id.
	bad := Trust{Index: idx2, Members: m2, OwnUserID: tUser, Anchor: &Anchor{DeviceID: ph.DeviceID, EdPub: other.Ed25519Pub}}
	if err := bad.AuthorizeSender(&ph, &m2[0]); err == nil {
		t.Fatal("accepted with an anchor whose key is not the approver's")
	}
}

func TestPinApprover(t *testing.T) {
	v := loadVectors(t)
	rec := vectorRecordB(t, v)
	sig := unhex(t, v.LogAction.Signature)
	a, err := PinApprover(rec, v.IdentB.DeviceID, v.IdentA.DeviceID, sig)
	if err != nil || a.DeviceID != v.IdentA.DeviceID || a.EdPub != sb(unhex(t, v.IdentA.EdPub)) {
		t.Fatalf("pin: %v %+v", err, a)
	}
	other := make([]byte, 64)
	for name, f := range map[string]func() error{
		"server chose another signature": func() error { _, e := PinApprover(rec, v.IdentB.DeviceID, v.IdentA.DeviceID, other); return e },
		"other approver id": func() error {
			_, e := PinApprover(rec, v.IdentB.DeviceID, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", sig)
			return e
		},
		"other device": func() error {
			_, e := PinApprover(rec, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", v.IdentA.DeviceID, sig)
			return e
		},
		"approver key swapped by the server": func() error {
			r := rec
			r.RegisteredByPub = sb(unhex(t, v.IdentB.EdPub))
			_, e := PinApprover(r, v.IdentB.DeviceID, v.IdentA.DeviceID, sig)
			return e
		},
	} {
		if f() == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}
