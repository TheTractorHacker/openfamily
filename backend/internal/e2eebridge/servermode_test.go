package e2eebridge

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const srvToken = "0123456789abcdef0123456789abcdef-token"

// fakeIngest plays the Orbitly API's /internal/e2ee endpoints.
type fakeIngest struct {
	srv    *httptest.Server
	mu     sync.Mutex
	pins   []string
	posts  []map[string]any
	status int // forced status for ingest when != 0
	failN  int // answer 503 this many times first
	badTok int
}

func newFakeIngest(t *testing.T) *fakeIngest {
	f := &fakeIngest{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer "+srvToken {
			f.badTok++
			w.WriteHeader(401)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		switch {
		case r.Method == "PUT" && r.URL.Path == "/internal/e2ee/server-device":
			f.pins = append(f.pins, body["device_id"].(string))
			jw(w, 200, map[string]any{"ok": true})
		case r.Method == "POST" && r.URL.Path == "/internal/e2ee/ingest":
			if f.failN > 0 {
				f.failN--
				w.WriteHeader(503)
				return
			}
			if f.status != 0 {
				jw(w, f.status, map[string]string{"error": "refused", "code": "not_a_server_member_circle"})
				return
			}
			f.posts = append(f.posts, body)
			n := len(body["points"].([]any))
			jw(w, 200, map[string]any{"stored": n, "duplicate": 0, "rejected": map[string]int{}})
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeIngest) points() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []map[string]any
	for _, p := range f.posts {
		for _, x := range p["points"].([]any) {
			out = append(out, x.(map[string]any))
		}
	}
	return out
}

// serverWorld turns the standard world into a server-device world.
func serverWorld(t *testing.T) (*world, *fakeIngest) {
	w := newWorld(t)
	ing := newFakeIngest(t)
	w.id.f.Kind = "server"
	if err := w.st.saveIdentity(w.id); err != nil {
		t.Fatal(err)
	}
	w.bridge.rec.Kind = "server"
	w.cfg = &config{Mode: "server", Ingest: ingestCfg{URL: ing.srv.URL, token: srvToken}, PollSeconds: 15}
	return w, ing
}

func (w *world) consentFrom(by *tdev, user string, circle string) consentWire {
	m, err := e2ee.ServerConsentMessage(circle, user, w.id.f.DeviceID, w.id.fp)
	if err != nil {
		w.t.Fatal(err)
	}
	return consentWire{UserID: user, ApproverDeviceID: by.id, Signature: std(ed25519.Sign(by.priv, m))}
}

func (w *world) setConsents(cs ...consentWire) {
	w.of.mu.Lock()
	w.of.consents = cs
	w.of.mu.Unlock()
}

func (w *world) bothConsent() []consentWire {
	return []consentWire{w.consentFrom(w.phone, w.phone.user, w.of.circle), w.consentFrom(w.bob, w.bob.user, w.of.circle)}
}

func TestServerModeReadsOnlyAfterEveryMemberConsented(t *testing.T) {
	w, ing := serverWorld(t)
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	w.fix(w.bob, 1, 20, 48.1, 11.5)
	b := w.newBridge()

	w.cycleOK(b) // no consent at all
	if len(ing.points()) != 0 || w.of.hits["items-as-"+w.id.f.DeviceID] != 0 {
		t.Fatal("the circle was read without any consent")
	}
	w.setConsents(w.consentFrom(w.phone, w.phone.user, w.of.circle)) // only Alice
	w.cycleOK(b)
	if len(ing.points()) != 0 || w.of.hits["items-as-"+w.id.f.DeviceID] != 0 {
		t.Fatal("the circle was read with one of two consents")
	}
	w.setConsents(w.bothConsent()...)
	w.cycleOK(b)
	pts := ing.points()
	if len(pts) != 2 {
		t.Fatalf("ingested %d points", len(pts))
	}
	byUser := map[string]map[string]any{}
	for _, p := range pts {
		byUser[p["user_id"].(string)] = p
	}
	a := byUser[w.phone.user]
	if a == nil || a["sender_device_id"] != w.phone.id || a["kind"] != "fix" || a["lat"].(float64) != 52.52 || a["bat"].(float64) != 50 {
		t.Fatalf("alice point %v", a)
	}
	if ing.posts[0]["server_device_id"] != w.id.f.DeviceID || ing.posts[0]["circle_id"] != w.of.circle {
		t.Fatalf("batch envelope %v", ing.posts[0])
	}
	if len(ing.pins) != 0 { // pinning happens in `run`, not in a bare cycle
		t.Fatal("unexpected pin")
	}
	// Nothing new: nothing sent again.
	n := len(ing.posts)
	w.cycleOK(b)
	if len(ing.posts) != n {
		t.Fatal("idle cycle ingested")
	}
	// Alice's consent disappears (withdrawn): the next cycle reads nothing new.
	w.fix(w.phone, 2, 5, 52.6, 13.5)
	w.setConsents(w.consentFrom(w.bob, w.bob.user, w.of.circle))
	w.cycleOK(b)
	if len(ing.posts) != n {
		t.Fatal("ingested after a consent was withdrawn")
	}
}

func TestServerModeIgnoresForgedAndMisboundConsents(t *testing.T) {
	w, ing := serverWorld(t)
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	w.fix(w.bob, 1, 20, 48.1, 11.5)
	b := w.newBridge()
	good := w.bothConsent()
	other := newUUIDv4()
	otherFp := make([]byte, 32)
	wrongCircle := w.consentFrom(w.bob, w.bob.user, other)
	mFp, _ := e2ee.ServerConsentMessage(w.of.circle, w.bob.user, w.id.f.DeviceID, otherFp)
	wrongServer := consentWire{UserID: w.bob.user, ApproverDeviceID: w.bob.id, Signature: std(ed25519.Sign(w.bob.priv, mFp))}
	evil := newTDev(t, w.bob.user, "device", nil) // a key the log does not know
	m, _ := e2ee.ServerConsentMessage(w.of.circle, w.bob.user, w.id.f.DeviceID, w.id.fp)
	unlogged := consentWire{UserID: w.bob.user, ApproverDeviceID: evil.id, Signature: std(ed25519.Sign(evil.priv, m))}
	aliceForBob := w.consentFrom(w.phone, w.bob.user, w.of.circle) // Alice's key claiming Bob's consent
	for name, bad := range map[string]consentWire{"other circle": wrongCircle, "other server key": wrongServer, "key not in the log": unlogged, "signed by someone else": aliceForBob} {
		w.setConsents(good[0], bad)
		w.cycleOK(b)
		if len(ing.points()) != 0 {
			t.Fatalf("%s: a forged consent opened the circle", name)
		}
	}
	w.setConsents(good...)
	w.cycleOK(b)
	if len(ing.points()) != 2 {
		t.Fatal("valid consents did not open the circle")
	}
}

func TestServerModeIngestFailuresKeepCursor(t *testing.T) {
	w, ing := serverWorld(t)
	w.setConsents(w.bothConsent()...)
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	b := w.newBridge()

	ing.failN = 2 // transient: retried, then stored
	w.cycleOK(b)
	if len(ing.points()) != 1 {
		t.Fatalf("transient failure lost the point: %d", len(ing.points()))
	}
	w.fix(w.phone, 2, 10, 52.53, 13.41)
	ing.status = 409 // circle no longer a server member
	if err := b.cycle(t.Context()); err == nil {
		t.Fatal("a refused ingest was swallowed")
	}
	if got := b.rs.Recv.Cursor[w.of.circle]; got != 1 {
		t.Fatalf("cursor advanced to %d although the server refused the point", got)
	}
	ing.status = 0
	w.cycleOK(b)
	if len(ing.points()) != 2 {
		t.Fatal("the refused point was not delivered later")
	}
}

func TestServerModeWrongTokenStopsWithExit6(t *testing.T) {
	w, ing := serverWorld(t)
	w.setConsents(w.bothConsent()...)
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	w.cfg.Ingest.token = "x" + srvToken
	b := w.newBridge()
	err := b.cycle(t.Context())
	if err == nil || exitCodeFor(err) != exitDawarich {
		t.Fatalf("wrong token: %v", err)
	}
	if ing.badTok == 0 || len(ing.points()) != 0 {
		t.Fatal("expected a refused request and no points")
	}
}

func TestServerModeLogsHaveNoCoordinatesOrTokens(t *testing.T) {
	w, _ := serverWorld(t)
	w.setConsents(w.bothConsent()...)
	w.fix(w.phone, 1, 30, 52.123457, 13.654321)
	b := w.newBridge()
	w.cycleOK(b)
	logs := w.logBuf.String()
	for _, s := range append(w.secrets, srvToken, "52.1234", "13.6543") {
		if strings.Contains(logs, s) {
			t.Fatalf("%q leaked into the log", s)
		}
	}
}

func TestServerModeConfig(t *testing.T) {
	dir := t.TempDir()
	write := func(js string) string {
		p := filepath.Join(dir, "c.json")
		if err := os.WriteFile(p, []byte(js), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	env := func(k string) string {
		if k == "E2EE_SERVER_INGEST_TOKEN" {
			return srvToken
		}
		return ""
	}
	c, err := loadConfig(write(`{"mode":"server","ingest":{"url":"http://api:8080/"}}`), env)
	if err != nil || !c.serverMode() || c.Ingest.URL != "http://api:8080" || c.Ingest.token != srvToken || c.PollSeconds != 15 {
		t.Fatalf("server config: %+v %v", c, err)
	}
	if _, err := loadConfig(write(`{"mode":"server","ingest":{"url":"ftp://x"}}`), env); err == nil {
		t.Fatal("bad ingest url accepted")
	}
	if _, err := loadConfig(write(`{"mode":"server","ingest":{"url":"http://api:8080"}}`), func(string) string { return "short" }); err == nil {
		t.Fatal("short token accepted")
	}
	tf := filepath.Join(dir, "tok")
	_ = os.WriteFile(tf, []byte(srvToken+"\n"), 0o600)
	if c, err := loadConfig(write(`{"mode":"server","ingest":{"url":"http://api:8080","token_file":"`+tf+`"}}`), func(string) string { return "" }); err != nil || c.Ingest.token != srvToken {
		t.Fatalf("token file: %v", err)
	}
	if _, err := loadConfig(write(`{"mode":"banana","ingest":{"url":"http://api"}}`), env); err == nil {
		t.Fatal("unknown mode accepted")
	}
}

func TestServerModeRunPinsAndChecksKind(t *testing.T) {
	w, ing := serverWorld(t)
	w.setConsents(w.bothConsent()...)
	cfgPath := filepath.Join(t.TempDir(), "c.json")
	_ = os.WriteFile(cfgPath, []byte(`{"mode":"server","ingest":{"url":"`+ing.srv.URL+`"}}`), 0o600)
	env := map[string]string{"E2EE_BRIDGE_STATE": w.dir, "E2EE_SERVER_INGEST_TOKEN": srvToken}
	w.fix(w.phone, 1, 30, 52.52, 13.40)
	code, _, errs := runCLI(t, env, "", "run", "--config", cfgPath, "--once")
	if code != 0 {
		t.Fatalf("run: %d %s", code, errs)
	}
	if len(ing.pins) != 1 || ing.pins[0] != w.id.f.DeviceID {
		t.Fatalf("server device not pinned: %v", ing.pins)
	}
	if len(ing.points()) != 1 {
		t.Fatalf("points: %d", len(ing.points()))
	}
	// A Dawarich-bridge key must refuse to run in server mode (and vice versa).
	w.id.f.Kind = ""
	_ = w.st.saveIdentity(w.id)
	if code, _, errs := runCLI(t, env, "", "run", "--config", cfgPath, "--once"); code == 0 || !strings.Contains(errs, "disagree") {
		t.Fatalf("a service key ran in server mode: %d %s", code, errs)
	}
}

func TestEnrollKindServerShowsWarningAndRegistersServerKind(t *testing.T) {
	aliceID := newUUIDv4()
	of := newFakeOF(t, newUUIDv4(), aliceID)
	phone := newTDev(t, aliceID, "device", nil)
	of.members = []*tmember{{user: aliceID, name: "Alice", devs: []*tdev{phone}}}
	dir := filepath.Join(t.TempDir(), "state")
	env := map[string]string{"E2EE_BRIDGE_PASSWORD": of.password, "E2EE_BRIDGE_STATE": dir}
	code, out, errs := runCLI(t, env, "", "enroll", "--kind", "server", "--server", of.srv.URL, "--email", "a@example.org")
	if code != 0 {
		t.Fatalf("%d %s", code, errs)
	}
	if !strings.Contains(out, "Orbitly server") || !strings.Contains(out, "SERVER READ") || !strings.Contains(out, "Fingerprint:") {
		t.Fatalf("output:\n%s", out)
	}
	var reqCode string
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "REQUEST CODE") {
			reqCode = strings.TrimSpace(lines[i+2])
		}
	}
	rc := decodeRequest(t, reqCode)
	if rc.K != "server" || rc.N != "Orbitly server" {
		t.Fatalf("request code %+v", rc)
	}
	if code, _, errs := runCLI(t, env, "", "enroll", "--kind", "service"); code == 0 || !strings.Contains(errs, "new --state-dir") {
		t.Fatalf("a server state dir enrolled a service key: %d %s", code, errs)
	}
	fp, _ := e2ee.Fingerprint(mustB64(rc.E), mustB64(rc.X))
	msg, _ := e2ee.LogActionMessage(e2ee.ActRegister, aliceID, phone.id, "", rc.D, 0, fp)
	ap, _ := json.Marshal(approvalCode{A: phone.id, S: std(ed25519.Sign(phone.priv, msg))})
	code, _, errs = runCLI(t, env, "", "enroll", "--approval", encURL(ap))
	if code != 0 {
		t.Fatalf("approval: %d %s", code, errs)
	}
	if len(of.registered) == 0 || of.registered[len(of.registered)-1]["kind"] != "server" || of.registered[len(of.registered)-1]["can_upload"] != false {
		t.Fatalf("registration %v", of.registered)
	}
}

func mustB64(s string) []byte { b, _ := base64.StdEncoding.DecodeString(s); return b }

func encURL(b []byte) string { return base64.URLEncoding.EncodeToString(b) }

func decodeRequest(t *testing.T, code string) requestCode {
	t.Helper()
	raw, err := base64.URLEncoding.DecodeString(code)
	if err != nil {
		t.Fatal(err)
	}
	var rc requestCode
	if err := json.Unmarshal(raw, &rc); err != nil {
		t.Fatal(err)
	}
	return rc
}
