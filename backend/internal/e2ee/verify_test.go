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
