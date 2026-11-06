package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

var std = base64.StdEncoding.EncodeToString

// ---------------------------------------------------------------- devices

type tdev struct {
	id, user, kind string
	priv           ed25519.PrivateKey
	edPub, xPub    []byte
	xSec           []byte
	approved       bool
	rec            e2ee.DeviceRecord
}

func randSeed(t *testing.T) []byte {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// newTDev makes a device of `user`; regBy == nil makes it a root key.
func newTDev(t *testing.T, user, kind string, regBy *tdev) *tdev {
	t.Helper()
	id, err := deriveIdentity(randSeed(t))
	if err != nil {
		t.Fatal(err)
	}
	return finishTDev(t, user, kind, newUUIDv4(), id, regBy)
}

func finishTDev(t *testing.T, user, kind, devID string, id *identity, regBy *tdev) *tdev {
	d := &tdev{id: devID, user: user, kind: kind, priv: id.edPriv, edPub: id.edPub, xPub: id.xPub, xSec: id.xSecret, approved: true}
	by := d
	if regBy != nil {
		by = regBy
	}
	bind, _ := e2ee.BindingMessage(user, devID, d.edPub, d.xPub)
	msg, err := e2ee.LogActionMessage(e2ee.ActRegister, user, by.id, "", devID, 0, id.fp)
	if err != nil {
		t.Fatal(err)
	}
	d.rec = e2ee.DeviceRecord{
		DeviceID: devID, UserID: user, Kind: kind, Ed25519Pub: std(d.edPub), X25519Pub: std(d.xPub),
		Fingerprint: hex.EncodeToString(id.fp), Signature: std(ed25519.Sign(d.priv, bind)),
		RegisteredByDeviceID: by.id, RegisteredByPub: std(by.edPub), RegistrationAction: int(e2ee.ActRegister),
		RegistrationSignature: std(ed25519.Sign(by.priv, msg)), Initial: regBy == nil, Label: kind,
	}
	return d
}

func (d *tdev) record() e2ee.DeviceRecord {
	r := d.rec
	a := d.approved
	r.Approved = &a
	return r
}

// ---------------------------------------------------------------- fake OpenFamily

type fakeItem struct {
	ID      int64
	Dev     string
	Seq     int64
	Purpose string
	Epoch   int
	CT      []byte
}

type tmember struct {
	user, name string
	devs       []*tdev
}

type fakeOF struct {
	t   *testing.T
	srv *httptest.Server
	mu  sync.Mutex

	circle  string
	mode    string
	epoch   int
	members []*tmember
	records []e2ee.EpochRecord
	wraps   map[string][]e2ee.WrapRecord // recipient device -> wraps
	items   []fakeItem
	nextID  int64

	logEntries []e2ee.LogEntry
	logHashes  [][]byte

	// auth
	password string
	userID   string
	access   map[string]bool
	refresh  map[string]bool
	tokenN   int
	expire   bool // next authenticated request answers 401 once

	// injected behaviour
	itemsStatus int
	itemsCode   string
	hits        map[string]int
	registered  []map[string]any
	revoked     []map[string]any
	rawLogHook  func(entries []e2ee.LogEntry) []e2ee.LogEntry
}

func newFakeOF(t *testing.T, circle, user string) *fakeOF {
	f := &fakeOF{t: t, circle: circle, mode: "private", epoch: 0, wraps: map[string][]e2ee.WrapRecord{},
		password: "pw-secret-123", userID: user, access: map[string]bool{}, refresh: map[string]bool{}, hits: map[string]int{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeOF) newTokens() tokenPair {
	f.tokenN++
	tp := tokenPair{AccessToken: fmt.Sprintf("access-%d-%x", f.tokenN, f.tokenN*7919), RefreshToken: fmt.Sprintf("refresh-%d-%x", f.tokenN, f.tokenN*104729)}
	f.access[tp.AccessToken], f.refresh[tp.RefreshToken] = true, true
	return tp
}

func jw(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (f *fakeOF) findDev(id string) *tdev {
	for _, m := range f.members {
		for _, d := range m.devs {
			if d.id == id {
				return d
			}
		}
	}
	return nil
}

func (f *fakeOF) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	path := r.URL.Path
	f.hits[r.Method+" "+path]++
	body, _ := io.ReadAll(r.Body)
	switch {
	case path == "/auth/login":
		var req struct{ Email, Password string }
		_ = json.Unmarshal(body, &req)
		if req.Password != f.password {
			jw(w, 401, map[string]string{"error": "invalid credentials"})
			return
		}
		jw(w, 200, f.newTokens())
		return
	case path == "/auth/refresh":
		var req struct {
			RefreshToken string `json:"refresh_token"`
		}
		_ = json.Unmarshal(body, &req)
		if !f.refresh[req.RefreshToken] {
			jw(w, 401, map[string]string{"error": "invalid refresh token"})
			return
		}
		delete(f.refresh, req.RefreshToken) // rotating: one use
		jw(w, 200, f.newTokens())
		return
	}
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !f.access[tok] {
		jw(w, 401, map[string]string{"error": "unauthenticated"})
		return
	}
	if f.expire {
		f.expire = false
		delete(f.access, tok)
		jw(w, 401, map[string]string{"error": "token expired"})
		return
	}
	switch {
	case path == "/me":
		jw(w, 200, map[string]string{"id": f.userID})
	case path == "/circles":
		jw(w, 200, []circleOut{{ID: f.circle, Name: "Family", E2EEMode: f.mode, E2EEEpoch: f.epoch}})
	case path == "/circles/"+f.circle+"/e2ee":
		out := circleState{CircleID: f.circle, Mode: f.mode, Epoch: f.epoch, Epochs: append([]e2ee.EpochRecord{}, f.records...)}
		for _, m := range f.members {
			mo := memberOut{UserID: m.user, Name: m.name, Role: "member", Devices: []e2ee.DeviceRecord{}}
			for _, d := range m.devs {
				mo.Devices = append(mo.Devices, d.record())
			}
			out.Members = append(out.Members, mo)
		}
		jw(w, 200, out)
	case path == "/circles/"+f.circle+"/e2ee/wraps":
		jw(w, 200, map[string]any{"circle_id": f.circle, "wraps": append([]e2ee.WrapRecord{}, f.wraps[r.URL.Query().Get("device_id")]...)})
	case path == "/circles/"+f.circle+"/e2ee/items":
		if f.itemsStatus != 0 {
			jw(w, f.itemsStatus, map[string]string{"error": "denied", "code": f.itemsCode})
			return
		}
		f.serveItems(w, r)
	case path == "/e2ee/log":
		after, _ := strconv.Atoi(r.URL.Query().Get("after"))
		entries := f.logEntries
		if f.rawLogHook != nil {
			entries = f.rawLogHook(append([]e2ee.LogEntry{}, entries...))
		}
		end := min(after+500, len(entries))
		page := []e2ee.LogEntry{}
		if after < len(entries) {
			page = entries[after:end]
		}
		head := map[string]any{"seq": len(f.logHashes), "hash": ""}
		if n := len(f.logHashes); n > 0 {
			head["hash"] = hex.EncodeToString(f.logHashes[n-1])
		}
		jw(w, 200, map[string]any{"entries": page, "head": head})
	case path == "/e2ee/devices" && r.Method == "POST":
		var req map[string]any
		_ = json.Unmarshal(body, &req)
		f.registered = append(f.registered, req)
		if err := f.verifyRegistration(req); err != nil {
			jw(w, 400, map[string]string{"error": err.Error()})
			return
		}
		rec := e2ee.DeviceRecord{DeviceID: req["device_id"].(string), UserID: f.userID, Kind: "service",
			Ed25519Pub: req["ed25519_pub"].(string), X25519Pub: req["x25519_pub"].(string), Signature: req["signature"].(string),
			RegisteredByDeviceID: req["actor_device_id"].(string), RegistrationAction: 1, RegistrationSignature: req["log_signature"].(string)}
		ed, _ := base64.StdEncoding.DecodeString(rec.Ed25519Pub)
		x, _ := base64.StdEncoding.DecodeString(rec.X25519Pub)
		fp, _ := e2ee.Fingerprint(ed, x)
		rec.Fingerprint = hex.EncodeToString(fp)
		if d := f.findDev(rec.RegisteredByDeviceID); d != nil {
			rec.RegisteredByPub = std(d.edPub)
		}
		jw(w, 201, rec)
	case strings.HasPrefix(path, "/e2ee/devices/") && r.Method == "DELETE":
		var req map[string]any
		_ = json.Unmarshal(body, &req)
		req["_id"] = strings.TrimPrefix(path, "/e2ee/devices/")
		f.revoked = append(f.revoked, req)
		jw(w, 200, map[string]string{"status": "ok"})
	default:
		jw(w, 404, map[string]string{"error": "not found " + path})
	}
}

// verifyRegistration checks the cross-signature like the real server.
func (f *fakeOF) verifyRegistration(req map[string]any) error {
	actor := f.findDev(req["actor_device_id"].(string))
	if actor == nil {
		return fmt.Errorf("cross-signing key is not an active key of the caller")
	}
	ed, _ := base64.StdEncoding.DecodeString(req["ed25519_pub"].(string))
	x, _ := base64.StdEncoding.DecodeString(req["x25519_pub"].(string))
	bind, _ := base64.StdEncoding.DecodeString(req["signature"].(string))
	if err := e2ee.VerifyBinding(f.userID, req["device_id"].(string), ed, x, bind); err != nil {
		return fmt.Errorf("signature does not verify")
	}
	fp, _ := e2ee.Fingerprint(ed, x)
	sig, _ := base64.StdEncoding.DecodeString(req["log_signature"].(string))
	if err := e2ee.VerifyLogAction(actor.edPub, e2ee.ActRegister, f.userID, actor.id, "", req["device_id"].(string), 0, fp, sig); err != nil {
		return fmt.Errorf("log signature does not verify")
	}
	return nil
}

func (f *fakeOF) serveItems(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	after, _ := strconv.ParseInt(q.Get("after"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 {
		limit = 100
	}
	purposes := map[string]bool{}
	for _, p := range strings.Split(q.Get("purpose"), ",") {
		if p != "" {
			purposes[p] = true
		}
	}
	type outItem struct {
		ID         int64  `json:"id"`
		DeviceID   string `json:"device_id"`
		Seq        int64  `json:"seq"`
		Purpose    string `json:"purpose"`
		Epoch      int    `json:"epoch"`
		Ciphertext string `json:"ciphertext"`
	}
	out := []outItem{}
	more := false
	for _, it := range f.items {
		if it.ID <= after || (len(purposes) > 0 && !purposes[it.Purpose]) {
			continue
		}
		if len(out) == limit {
			more = true
			break
		}
		out = append(out, outItem{it.ID, it.Dev, it.Seq, it.Purpose, it.Epoch, std(it.CT)})
	}
	next := after
	if len(out) > 0 {
		next = out[len(out)-1].ID
	}
	f.hits["items-as-"+q.Get("as_device")]++
	jw(w, 200, map[string]any{"items": out, "next_cursor": next, "has_more": more})
}

// ---- log building

func (f *fakeOF) appendLog(action byte, actor *tdev, user, circle, subject string, epoch uint32, ref []byte, redact bool) {
	var prev = e2ee.GenesisHash
	if n := len(f.logHashes); n > 0 {
		prev = f.logHashes[n-1]
	}
	if ref == nil {
		ref = make([]byte, 32)
	}
	msg, err := e2ee.LogActionMessage(action, user, actor.id, circle, subject, epoch, ref)
	if err != nil {
		f.t.Fatal(err)
	}
	sig := ed25519.Sign(actor.priv, msg)
	seq := int64(len(f.logHashes) + 1)
	h := e2ee.LogEntryHash(prev, uint64(seq), msg, sig)
	e := e2ee.LogEntry{Seq: seq, PrevHash: hex.EncodeToString(prev), EntryHash: hex.EncodeToString(h), Redacted: redact}
	if !redact {
		a, ep := int(action), int(epoch)
		p, r, s := std(actor.edPub), hex.EncodeToString(ref), std(sig)
		e.Action, e.UserID, e.ActorDeviceID, e.ActorPub, e.Epoch, e.Ref, e.Signature = &a, &user, &actor.id, &p, &ep, &r, &s
		if circle != "" {
			e.CircleID = &circle
		}
		if subject != "" {
			e.SubjectID = &subject
		}
	}
	f.logEntries = append(f.logEntries, e)
	f.logHashes = append(f.logHashes, h)
}

// publishEpoch: `publisher` publishes epoch n with `key`, wraps it for `recips`.
func (f *fakeOF) publishEpoch(publisher *tdev, n int, key []byte, recips ...*tdev) {
	f.mu.Lock()
	defer f.mu.Unlock()
	commit, _ := e2ee.KeyCommitment(key, f.circle, uint32(n))
	action := e2ee.ActEpoch
	if n == 1 {
		action = e2ee.ActEnable
	}
	f.appendLog(action, publisher, publisher.user, f.circle, "", uint32(n), commit, false)
	last := f.logEntries[len(f.logEntries)-1]
	f.records = append(f.records, e2ee.EpochRecord{Epoch: n, Action: int(action), PublisherUser: publisher.user,
		PublisherDev: publisher.id, PublisherPub: std(publisher.edPub), KeyCommitment: std(commit), Signature: *last.Signature})
	f.epoch = n
	for _, r := range recips {
		f.wraps[r.id] = append(f.wraps[r.id], f.makeWrap(publisher, r, n, key))
	}
}

func (f *fakeOF) makeWrap(wrapper, to *tdev, n int, key []byte) e2ee.WrapRecord {
	aad, _ := e2ee.WrapAAD(f.circle, uint32(n), to.id, wrapper.id)
	blob, err := e2ee.Wrap(key, to.xPub, aad)
	if err != nil {
		f.t.Fatal(err)
	}
	sm, _ := e2ee.WrapSigMessage(f.circle, uint32(n), to.id, wrapper.id, blob)
	return e2ee.WrapRecord{Epoch: n, RecipientDeviceID: to.id, WrapperDeviceID: wrapper.id, WrapperEd25519Pub: std(wrapper.edPub),
		WrappedKey: std(blob), Signature: std(ed25519.Sign(wrapper.priv, sm))}
}

func (f *fakeOF) addWrap(to *tdev, w e2ee.WrapRecord) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wraps[to.id] = append(f.wraps[to.id], w)
}

// sealItem appends an item sealed by `by` (claimed as device `claim`).
func (f *fakeOF) sealItem(key []byte, epoch int, by *tdev, purpose string, seq, tsMs uint64, body any) fakeItem {
	f.t.Helper()
	b, _ := json.Marshal(body)
	var nonce [e2ee.NonceLen]byte
	_, _ = rand.Read(nonce[:])
	ct, err := e2ee.SealItem(key, f.circle, uint32(epoch), by.id, by.priv, purpose, seq, tsMs, b, nonce)
	if err != nil {
		f.t.Fatal(err)
	}
	return f.addItem(by.id, int64(seq), purpose, epoch, ct)
}

func (f *fakeOF) addItem(dev string, seq int64, purpose string, epoch int, ct []byte) fakeItem {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	it := fakeItem{ID: f.nextID, Dev: dev, Seq: seq, Purpose: purpose, Epoch: epoch, CT: ct}
	f.items = append(f.items, it)
	return it
}

// ---------------------------------------------------------------- fake Dawarich

type fakeDawarich struct {
	t          *testing.T
	srv        *httptest.Server
	mu         sync.Mutex
	posts      []dawPost
	fail       int // answer 503 this many times first
	failAll    bool
	limitPosts bool
	allowPosts int
	status     int    // forced status for posts when != 0
	newest     string // JSON answer to the newest-point query ("" -> 404)
	queries    []string
	keys       []string
}

type dawPost struct {
	Key   string
	Feats []map[string]any
}

func newFakeDawarich(t *testing.T) *fakeDawarich {
	d := &fakeDawarich{t: t}
	d.srv = httptest.NewServer(http.HandlerFunc(d.serve))
	t.Cleanup(d.srv.Close)
	return d
}

func (d *fakeDawarich) serve(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/v1/points":
		d.queries = append(d.queries, r.URL.RawQuery)
		d.keys = append(d.keys, key)
		if d.newest == "" {
			w.WriteHeader(404)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(d.newest))
	case r.Method == "POST" && r.URL.Path == "/api/v1/points":
		if d.failAll || d.fail > 0 {
			if d.fail > 0 {
				d.fail--
			}
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(503)
			return
		}
		if d.limitPosts && len(d.posts) >= d.allowPosts {
			w.WriteHeader(503)
			return
		}
		if d.status != 0 {
			w.WriteHeader(d.status)
			return
		}
		var req struct {
			Locations []map[string]any `json:"locations"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		d.posts = append(d.posts, dawPost{Key: key, Feats: req.Locations})
		w.WriteHeader(201)
	default:
		w.WriteHeader(404)
	}
}

// points returns every delivered point as (key, tsUnix, lon, lat, name, unique).
type gotPoint struct {
	Key, Name, Unique string
	Ts                time.Time
	Lat, Lon          float64
	Props             map[string]any
}

func (d *fakeDawarich) points() []gotPoint {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []gotPoint
	for _, p := range d.posts {
		for _, f := range p.Feats {
			props := f["properties"].(map[string]any)
			coords := f["geometry"].(map[string]any)["coordinates"].([]any)
			ts, _ := time.Parse(time.RFC3339, props["timestamp"].(string))
			out = append(out, gotPoint{Key: p.Key, Name: props["device_id"].(string), Unique: props["unique_id"].(string),
				Ts: ts, Lon: coords[0].(float64), Lat: coords[1].(float64), Props: props})
		}
	}
	return out
}

func (d *fakeDawarich) postCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.posts)
}

// ---------------------------------------------------------------- world

type world struct {
	t       *testing.T
	of      *fakeOF
	dw      *fakeDawarich
	dir     string
	st      *store
	id      *identity
	phone   *tdev // alice's phone (epoch publisher)
	bob     *tdev
	bridge  *tdev // the bridge's own record
	key1    []byte
	cfg     *config
	logBuf  *bytes.Buffer
	nowT    time.Time
	secrets []string // strings that must never appear in logs
}

var t0 = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

func fastBO() backoff {
	return backoff{Base: time.Millisecond, Max: 2 * time.Millisecond, Attempts: 4, Sleep: func(ctx context.Context, d time.Duration) error { return ctx.Err() }}
}

func init() { kdfMemKiB, kdfTime = 64, 1 }

func newWorld(t *testing.T) *world {
	t.Helper()
	aliceID, bobID := newUUIDv4(), newUUIDv4()
	circle := newUUIDv4()
	w := &world{t: t, of: newFakeOF(t, circle, aliceID), dw: newFakeDawarich(t), nowT: t0, logBuf: &bytes.Buffer{}}
	w.dir = t.TempDir() + "/state"
	st, err := openStore(w.dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	w.st = st
	w.id, err = st.createIdentity("Test bridge")
	if err != nil {
		t.Fatal(err)
	}
	w.id.f.UserID = aliceID
	w.id.f.Server = w.of.srv.URL
	w.id.f.RegisteredAt = t0.Format(time.RFC3339)
	if err := st.saveIdentity(w.id); err != nil {
		t.Fatal(err)
	}
	w.phone = newTDev(t, aliceID, "device", nil)
	w.bob = newTDev(t, bobID, "device", nil)
	w.bridge = finishTDev(t, aliceID, "service", w.id.f.DeviceID, w.id, w.phone)
	w.of.members = []*tmember{{user: aliceID, name: "Alice", devs: []*tdev{w.phone, w.bridge}}, {user: bobID, name: "Bob", devs: []*tdev{w.bob}}}
	// A redacted entry of another tenant, then the registrations, then epoch 1.
	other := newTDev(t, newUUIDv4(), "device", nil)
	w.of.appendLog(e2ee.ActRegister, other, other.user, "", other.id, 0, make([]byte, 32), true)
	fpPhone, _ := hex.DecodeString(w.phone.rec.Fingerprint)
	w.of.appendLog(e2ee.ActRegister, w.phone, aliceID, "", w.phone.id, 0, fpPhone, false)
	w.key1 = randSeed(t)
	w.of.publishEpoch(w.phone, 1, w.key1, w.bridge)
	st0 := tokenPair{}
	w.of.mu.Lock()
	st0 = w.of.newTokens()
	w.of.mu.Unlock()
	if err := st.writeSecret(fileSession, session{Server: w.of.srv.URL, RefreshToken: st0.RefreshToken, UserID: aliceID}); err != nil {
		t.Fatal(err)
	}
	w.cfg = &config{Dawarich: dawarichCfg{BaseURL: w.dw.srv.URL, APIKey: "MAINKEY-secret", SendUnmapped: false},
		Users: map[string]userCfg{aliceID: {APIKey: "ALICEKEY-secret", Label: "alice"}}, PollSeconds: 30}
	w.secrets = []string{st0.RefreshToken, "MAINKEY-secret", "ALICEKEY-secret", w.of.password, std(w.key1)}
	return w
}

func (w *world) newBridge() *bridge {
	w.t.Helper()
	var sess session
	if err := w.st.readSecret(fileSession, &sess); err != nil {
		w.t.Fatal(err)
	}
	id, err := w.st.loadIdentity()
	if err != nil {
		w.t.Fatal(err)
	}
	api := newAPIClient(sess.Server, sess.RefreshToken, func(rt string) error {
		sess.RefreshToken = rt
		return w.st.writeSecret(fileSession, sess)
	})
	api.bo = fastBO()
	log := slog.New(slog.NewTextHandler(w.logBuf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	b, err := newBridge(w.st, id, api, w.cfg, log)
	if err != nil {
		w.t.Fatal(err)
	}
	b.sink.bo = fastBO()
	b.now = func() time.Time { return w.nowT }
	b.sink.now = b.now
	return b
}

func (w *world) cycleOK(b *bridge) {
	w.t.Helper()
	if err := b.cycle(context.Background()); err != nil {
		w.t.Fatalf("cycle: %v", err)
	}
}

// fix seals a live fix of `by` for alice's circle at epoch 1.
func (w *world) fix(by *tdev, seq uint64, ageSec int, lat, lon float64) fakeItem {
	ts := uint64(w.nowT.Add(-time.Duration(ageSec) * time.Second).UnixMilli())
	return w.of.sealItem(w.key1, 1, by, "fix", seq, ts, map[string]any{"lat": lat, "lon": lon, "acc": 8.5, "alt": 31.0, "spd": 1.5, "bat": 50.0, "mo": "walk"})
}

func (w *world) history(by *tdev, seq uint64, pts ...[]any) fakeItem {
	ts := uint64(w.nowT.UnixMilli())
	return w.of.sealItem(w.key1, 1, by, "history", seq, ts, map[string]any{"pts": pts})
}

func hexKey(b []byte) string { return hex.EncodeToString(b) }

var _ = ecdh.X25519
