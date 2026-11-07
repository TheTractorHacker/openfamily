package handlers

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Trusted-server mode (docs/design/E2EE.md). Needs TEST_DATABASE_URL.

const testServerToken = "0123456789abcdef0123456789abcdef-test-token"

type srvEnv struct {
	*chanEnv
	s *tdev // the OpenFamily server device (owned by A's account)
}

func newSrvEnv(t *testing.T) *srvEnv { return newSrvEnvOpt(t, true) }

// newSrvEnvOpt: legacy = the circle is in the pre-lanes trusted-server mode.
func newSrvEnvOpt(t *testing.T, legacy bool) *srvEnv {
	t.Setenv("E2EE_SERVER_INGEST_TOKEN", testServerToken)
	e := newChanEnv(t)
	e.route("PUT", "/internal/e2ee/server-device", e.srv.E2EEPinServerDevice)
	e.route("POST", "/internal/e2ee/ingest", e.srv.E2EEServerIngest)
	e.route("GET", "/e2ee/server-device", e.srv.E2EEServerDevice)
	e.route("GET", "/circles/{id}/e2ee/server-member", e.srv.E2EEServerMemberState)
	e.route("PUT", "/circles/{id}/e2ee/server-consent", e.srv.E2EEPutServerConsent)
	e.route("DELETE", "/circles/{id}/e2ee/server-consent", e.srv.E2EEDeleteServerConsent)
	e.route("DELETE", "/circles/{id}/e2ee/server-copies", e.srv.E2EEPurgeServerCopies)
	e.route("GET", "/circles", e.srv.ListCircles)
	e.route("PUT", "/e2ee/devices/{id}/caps", e.srv.E2EEPutDeviceCaps)
	e.route("GET", "/circles/{id}/e2ee/processing", e.srv.E2EEProcessingState)
	e.route("PUT", "/circles/{id}/e2ee/processing-policy", e.srv.E2EEPutProcessingPolicy)
	e.route("PUT", "/circles/{id}/e2ee/processing-pref", e.srv.E2EEPutProcessingPref)
	e.route("POST", "/circles/{id}/e2ee/processing-upgrade", e.srv.E2EEUpgradeProcessing)
	e.route("GET", "/admin/e2ee/keys", e.srv.AdminE2EEKeys)
	t.Cleanup(func() { _, _ = e.pool.Exec(context.Background(), `DELETE FROM e2ee_server_device`) })
	// These tests cover the pre-lanes trusted-server mode. Only circles that existed
	// before migration 220 can be in it (the migration flags them); simulate that.
	if legacy {
		if _, err := e.pool.Exec(context.Background(), `UPDATE circles SET server_legacy_ck = TRUE WHERE id = $1`, e.circle); err != nil {
			t.Fatal(err)
		}
	}
	s := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s, "server", e.a, e2ee.ActRegister, false), 201)
	return &srvEnv{chanEnv: e, s: s}
}

// tok sends a request authenticated only by the bearer token (no user session).
func (e *srvEnv) tok(token, method, path string, body any) (int, map[string]any, string) {
	e.t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	var m map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	return rec.Code, m, rec.Body.String()
}

func (e *srvEnv) pin() { e.t.Helper(); e.pinCode(200) }
func (e *srvEnv) pinCode(want int) {
	e.t.Helper()
	if c, _, raw := e.tok(testServerToken, "PUT", "/internal/e2ee/server-device", map[string]string{"device_id": e.s.id}); c != want {
		e.t.Fatalf("pin: %d %s", c, raw)
	}
}

func (e *srvEnv) wrapServer() {
	e.t.Helper()
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"epoch": 1,
		"wraps": []any{mkWrap(e.t, e.circle, 1, e.a, e.s, e.key)}}, 200)
}

func consentSig(t *testing.T, circle string, member, approver, server *tdev) string {
	t.Helper()
	m, err := e2ee.ServerConsentMessage(circle, member.uid, server.id, server.fp)
	if err != nil {
		t.Fatal(err)
	}
	return b64s(ed25519.Sign(approver.priv, m))
}

func (e *srvEnv) consent(user string, d *tdev, want int) {
	e.t.Helper()
	e.mustCode(user, "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{
		"server_device_id": e.s.id, "approver_device_id": d.id, "signature": consentSig(e.t, e.circle, d, d, e.s)}, want)
}

func (e *srvEnv) consentAll() {
	e.t.Helper()
	e.consent("A", e.a, 200)
	e.consent("B", e.b, 200)
	e.consent("C", e.c, 200)
}

// rotate publishes epoch n (an admin phone), wrapping for the given phones and the
// server key, which clears a pending rekey.
func (e *srvEnv) rotate(n int, phones ...*tdev) {
	e.t.Helper()
	var ws []map[string]any
	for _, d := range append(phones, e.s) {
		ws = append(ws, mkWrap(e.t, e.circle, n, e.a, d, e.key))
	}
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/epoch", epochBody(e.t, e2ee.ActEpoch, e.circle, n, e.a, ws...), 200)
}

func (e *srvEnv) serverMember() bool {
	var v bool
	_ = e.pool.QueryRow(context.Background(), `SELECT e2ee_server_member($1)`, e.circle).Scan(&v)
	return v
}

func (e *srvEnv) point(kind string, d *tdev, ts time.Time, lat, lon float64) map[string]any {
	return map[string]any{"kind": kind, "user_id": d.uid, "sender_device_id": d.id, "ts_ms": ts.UnixMilli(), "lat": lat, "lon": lon, "acc": 5.0}
}

func (e *srvEnv) ingest(pts ...map[string]any) (int, map[string]any, string) {
	return e.tok(testServerToken, "POST", "/internal/e2ee/ingest", map[string]any{"circle_id": e.circle, "server_device_id": e.s.id, "points": pts})
}

// readyEnv: pinned, wrapped and consented by everyone.
func readyEnv(t *testing.T) *srvEnv {
	e := newSrvEnv(t)
	e.pin()
	e.wrapServer()
	e.consentAll()
	if !e.serverMember() {
		t.Fatal("circle is not a server-member circle after pin, wrap and all consents")
	}
	return e
}

func rejectedCount(m map[string]any, reason string) int {
	r, _ := m["rejected"].(map[string]any)
	n, _ := r[reason].(float64)
	return int(n)
}

// ---------------------------------------------------------------- default off

func TestServerMemberOffByDefault(t *testing.T) {
	t.Setenv("E2EE_SERVER_INGEST_TOKEN", "")
	e := newChanEnv(t)
	e.route("PUT", "/internal/e2ee/server-device", e.srv.E2EEPinServerDevice)
	e.route("POST", "/internal/e2ee/ingest", e.srv.E2EEServerIngest)
	e.route("PUT", "/circles/{id}/e2ee/server-consent", e.srv.E2EEPutServerConsent)
	s := newTDev(t, e.ids["A"])
	if c, _, _ := (&srvEnv{chanEnv: e}).tok(testServerToken, "POST", "/internal/e2ee/ingest", map[string]any{}); c != 404 {
		t.Fatalf("ingest answered %d on a server without the mode", c)
	}
	if c, _, _ := (&srvEnv{chanEnv: e}).tok(testServerToken, "PUT", "/internal/e2ee/server-device", map[string]any{"device_id": s.id}); c != 404 {
		t.Fatalf("pin answered %d on a server without the mode", c)
	}
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s, "server", e.a, e2ee.ActRegister, false), 403)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{}, 409)
	// A short token does not enable the mode either.
	t.Setenv("E2EE_SERVER_INGEST_TOKEN", "short")
	if serverMemberEnabled() {
		t.Fatal("a token shorter than 32 characters enabled the mode")
	}
}

// -------------------------------------------------- the flag is derived, not set

func TestServerMemberNeedsPinWrapAndEveryConsent(t *testing.T) {
	e := newSrvEnv(t)
	check := func(step string, want bool) {
		t.Helper()
		if got := e.serverMember(); got != want {
			t.Fatalf("%s: server_member=%v want %v", step, got, want)
		}
	}
	check("registered only", false)
	e.pin()
	e.consentAll() // consents without a wrap of the server key
	check("consents but no wrap", false)
	e.wrapServer()
	check("pin, wrap, consents", true)
	// Plaintext enforcement relaxes only now.
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 201)

	// One member withdraws: back to phase-2 behaviour at once, and a new epoch is requested.
	e.mustCode("C", "DELETE", "/circles/"+e.circle+"/e2ee/server-consent", nil, 200)
	check("one consent withdrawn", false)
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Work", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
	var rekey bool
	_ = e.pool.QueryRow(context.Background(), `SELECT e2ee_rekey_required FROM circles WHERE id = $1`, e.circle).Scan(&rekey)
	if !rekey {
		t.Fatal("withdrawing a consent did not request a new key epoch")
	}
	e.consent("C", e.c, 200)
	check("consent restored but the new key epoch is still pending", false)
	e.rotate(2, e.a, e.b, e.c)
	check("consent restored and new epoch published", true)
}

func TestServerMemberOneMissingConsentKeepsPhase2(t *testing.T) {
	e := newSrvEnv(t)
	e.pin()
	e.wrapServer()
	e.consent("A", e.a, 200)
	e.consent("B", e.b, 200) // C never consents
	if e.serverMember() {
		t.Fatal("circle became a server member without every member's consent")
	}
	// Every phase-2 rule still holds.
	e.mustCode("B", "POST", "/locations", map[string]any{"device_id": e.b.id, "lat": 52.1, "lon": 13.1}, 409)
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
	var n int
	if err := e.pool.QueryRow(context.Background(), `INSERT INTO places (family_id, name, geom, radius_meters)
		VALUES ($1,'x', ST_SetSRID(ST_MakePoint(1,2),4326), 50) RETURNING 1`, e.circle).Scan(&n); err == nil {
		t.Fatal("the database trigger let a plaintext place into a private circle without a server member")
	}
	if c, _, raw := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4)); c != 409 {
		t.Fatalf("ingest into a circle with a missing consent: %d %s", c, raw)
	}
	_, items, _ := e.do("B", "GET", "/circles/"+e.circle, nil)
	_ = items
	if sh, _ := circles.New(e.pool).SharedWith(context.Background(), e.ids["A"], e.ids["B"]); len(sh) != 0 {
		t.Fatalf("a private circle without a server member is visible to plaintext readers: %v", sh)
	}
}

// ---------------------------------------------------------- consent integrity

func TestServerConsentCannotBeForgedOrMoved(t *testing.T) {
	e := newSrvEnv(t)
	e.pin()
	e.wrapServer()
	put := func(user string, body map[string]any, want int) {
		t.Helper()
		e.mustCode(user, "PUT", "/circles/"+e.circle+"/e2ee/server-consent", body, want)
	}
	good := consentSig(t, e.circle, e.b, e.b, e.s)
	// Signed by another person's key.
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.a.id, "signature": good}, 400)
	// A's key signing on B's behalf: B names A's device -> not B's key.
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.a.id, "signature": consentSig(t, e.circle, e.b, e.a, e.s)}, 400)
	// Signature for another circle.
	other := e.createCircle("B", "Other")
	om, _ := e2ee.ServerConsentMessage(other, e.b.uid, e.s.id, e.s.fp)
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": b64s(ed25519.Sign(e.b.priv, om))}, 400)
	// Signature naming another server fingerprint.
	m2, _ := e2ee.ServerConsentMessage(e.circle, e.b.uid, e.s.id, e.c.fp)
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": b64s(ed25519.Sign(e.b.priv, m2))}, 400)
	// A server-kind key that is not THE pinned key.
	fake := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, fake, "server", e.b, e2ee.ActRegister, false), 201)
	put("B", map[string]any{"server_device_id": fake.id, "approver_device_id": e.b.id, "signature": consentSig(t, e.circle, e.b, e.b, fake)}, 409)
	// A non-member cannot consent for a circle (404, no probing).
	e.mustCode("D", "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": good}, 404)
	// A viewer/service key is not a phone key and cannot be the approver.
	web := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, web, "web", e.b, e2ee.ActRegister, false), 201)
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": web.id, "signature": consentSig(t, e.circle, e.b, web, e.s)}, 400)
	// The valid one works.
	put("B", map[string]any{"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": good}, 200)
}

func TestServerMemberKeyBelongsOnlyToTokenHolder(t *testing.T) {
	e := newSrvEnv(t)
	// No token / wrong token / a user session only.
	for name, tk := range map[string]string{"none": "", "wrong": "x" + testServerToken, "prefix": testServerToken[:20]} {
		if c, _, _ := e.tok(tk, "PUT", "/internal/e2ee/server-device", map[string]string{"device_id": e.s.id}); c != 401 {
			t.Fatalf("pin with %s token: %d", name, c)
		}
	}
	req := httptest.NewRequest("POST", "/internal/e2ee/ingest", strings.NewReader(`{}`))
	req.Header.Set("X-Test-User", e.ids["A"]) // a signed-in circle admin, but no token
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("a user session reached the internal ingest: %d", rec.Code)
	}
	// A phone key cannot be pinned as the server device.
	if c, _, _ := e.tok(testServerToken, "PUT", "/internal/e2ee/server-device", map[string]string{"device_id": e.b.id}); c != 404 {
		t.Fatalf("pinned a phone key: %d", c)
	}
	// A circle admin cannot make the circle a server member by any user API.
	for _, p := range []string{"/circles/" + e.circle + "/e2ee/server-member", "/e2ee/server-device"} {
		_, m, _ := e.do("A", "GET", p, nil)
		if m["server_member"] == true {
			t.Fatal("state says server_member before any pin/wrap/consent")
		}
	}
	e.pin()
	// A second server key cannot displace the pinned one while it is active.
	s2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, s2, "server", e.b, e2ee.ActRegister, false), 201)
	if c, _, _ := e.tok(testServerToken, "PUT", "/internal/e2ee/server-device", map[string]string{"device_id": s2.id}); c != 409 {
		t.Fatalf("a second server key displaced the pinned one: %d", c)
	}
	// A root (self-signed) server key is refused: a phone must vouch for it.
	r := newTDev(t, e.ids["D"])
	e.mustCode("D", "POST", "/e2ee/devices", regBody(t, r, "server", nil, e2ee.ActRegister, false), 400)
}

// A database writer who plants a consent row cannot make the server ingest:
// the consent signature is re-verified in Go against the member's phone key.
func TestServerIngestRejectsPlantedConsentRows(t *testing.T) {
	e := newSrvEnv(t)
	e.pin()
	e.wrapServer()
	e.consent("A", e.a, 200)
	e.consent("B", e.b, 200)
	// C never consented; a DB writer inserts a row with a junk signature.
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO e2ee_server_consents (circle_id, user_id, server_device_id, approver_device_id, signature)
		VALUES ($1,$2,$3,$4,$5)`, e.circle, e.ids["C"], e.s.id, e.c.id, make([]byte, 64)); err != nil {
		t.Fatal(err)
	}
	if !e.serverMember() {
		t.Fatal("test premise: the SQL view of the planted row should say yes")
	}
	if c, _, raw := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4)); c != 409 {
		t.Fatalf("ingest accepted a planted consent: %d %s", c, raw)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations WHERE e2ee_circle_id = $1`, e.circle).Scan(&n)
	if n != 0 {
		t.Fatalf("%d plaintext rows were written", n)
	}
}

// ---------------------------------------------------------------------- ingest

func TestServerIngestStoresVerifiedPositions(t *testing.T) {
	e := readyEnv(t)
	now := time.Now()
	c, m, raw := e.ingest(e.point("fix", e.b, now, 52.5, 13.4), e.point("history", e.b, now.Add(-2*time.Hour), 52.4, 13.3))
	if c != 200 || m["stored"].(float64) != 2 {
		t.Fatalf("ingest: %d %s", c, raw)
	}
	// Idempotent: the same points again are duplicates, no new rows.
	c, m, raw = e.ingest(e.point("fix", e.b, now, 52.5, 13.4), e.point("history", e.b, now.Add(-2*time.Hour), 52.4, 13.3))
	if c != 200 || m["stored"].(float64) != 0 || m["duplicate"].(float64) != 2 {
		t.Fatalf("replay: %d %s", c, raw)
	}
	var cnt int
	var lat float64
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations WHERE e2ee_circle_id = $1 AND source = 'e2ee_server'`, e.circle).Scan(&cnt)
	if cnt != 2 {
		t.Fatalf("stored rows: %d", cnt)
	}
	_ = e.pool.QueryRow(context.Background(), `SELECT lat FROM member_positions WHERE user_id = $1`, e.ids["B"]).Scan(&lat)
	if lat != 52.5 {
		t.Fatalf("last position is %v (an older backfill point must not win)", lat)
	}
	// The members see it through the normal visibility rules; the server-side Dawarich
	// batch reads it from the normal table.
	az := circles.New(e.pool)
	if sh, _ := az.SharedWith(context.Background(), e.ids["A"], e.ids["B"]); len(sh) != 1 || sh[0] != e.circle {
		t.Fatalf("server-member circle not visible to members: %v", sh)
	}
	if err := e.srv.EnsureDawarichSchema(context.Background()); err != nil {
		t.Fatal(err)
	}
	pts, err := e.srv.nextDawarichBatch(context.Background(), dawarichTarget{UserID: e.ids["B"], Key: "k", Since: now.Add(-48 * time.Hour)})
	if err != nil || len(pts) != 2 {
		t.Fatalf("Dawarich server sync did not pick the server-decrypted points up: %d %v", len(pts), err)
	}
	// Circle state is reported to clients.
	_, st, _ := e.do("A", "GET", "/circles/"+e.circle+"/e2ee/server-member", nil)
	if cs, _ := st["consents"].([]any); len(cs) != 3 || st["server_member"] != true || st["my_consent"] != true {
		t.Fatalf("state: %v", st)
	}
	code, _, raw2 := e.do("A", "GET", "/circles", nil)
	if code != 200 || !strings.Contains(string(raw2), `"e2ee_server_member":true`) {
		t.Fatalf("circle list does not carry e2ee_server_member: %s", raw2)
	}
}

func TestServerIngestAuthorizationAndIDOR(t *testing.T) {
	e := readyEnv(t)
	now := time.Now()
	// Bad bearer.
	if c, _, _ := e.tok("nope", "POST", "/internal/e2ee/ingest", map[string]any{}); c != 401 {
		t.Fatalf("bad token: %d", c)
	}
	// Wrong server device id.
	if c, _, _ := e.tok(testServerToken, "POST", "/internal/e2ee/ingest", map[string]any{"circle_id": e.circle, "server_device_id": e.a.id,
		"points": []any{e.point("fix", e.b, now, 1, 2)}}); c != 403 {
		t.Fatalf("not the server device: %d", c)
	}
	// Another (non-private, non-server) circle by id.
	std := e.createCircle("D", "Std", "E")
	if c, _, _ := e.tok(testServerToken, "POST", "/internal/e2ee/ingest", map[string]any{"circle_id": std, "server_device_id": e.s.id,
		"points": []any{e.point("fix", e.b, now, 1, 2)}}); c != 409 {
		t.Fatalf("other circle: %d", c)
	}
	d := newTDev(t, e.ids["D"])
	e.register("D", d)
	// A point whose sender key is not a member's, whose user is spoofed, or that is
	// from an outsider.
	spoof := e.point("fix", e.b, now.Add(time.Second), 3, 4)
	spoof["user_id"] = e.ids["C"] // B's key claiming to be C
	outsider := e.point("fix", d, now.Add(2*time.Second), 5, 6)
	notKey := e.point("fix", e.b, now.Add(3*time.Second), 7, 8)
	notKey["sender_device_id"] = e.s.id // the server key itself is not a phone key
	badLat := e.point("fix", e.b, now.Add(4*time.Second), 91, 8)
	future := e.point("fix", e.b, now.Add(time.Hour), 7, 8)
	ancient := e.point("history", e.b, now.Add(-1000*24*time.Hour), 7, 8)
	c, m, raw := e.ingest(spoof, outsider, notKey, badLat, future, ancient)
	if c != 200 || m["stored"].(float64) != 0 {
		t.Fatalf("hostile points were stored: %d %s", c, raw)
	}
	if rejectedCount(m, "sender_not_allowed") != 3 || rejectedCount(m, "bad_coordinates") != 1 || rejectedCount(m, "bad_time") != 2 {
		t.Fatalf("reasons: %s", raw)
	}
	// Request limits.
	if c, _, _ := e.ingest(); c != 400 {
		t.Fatalf("empty batch: %d", c)
	}
	big := make([]map[string]any, 501)
	for i := range big {
		big[i] = e.point("fix", e.b, now, 1, 2)
	}
	if c, _, _ := e.ingest(big...); c != 400 {
		t.Fatalf("501 points: %d", c)
	}
	// Sharing paused / disabled for the circle: not ingested.
	e.mustCode("B", "PUT", "/circles/"+e.circle+"/sharing", map[string]any{"enabled": false}, 200)
	if c, m, raw := e.ingest(e.point("fix", e.b, now.Add(5*time.Second), 9, 9)); c != 200 || rejectedCount(m, "sender_not_allowed") != 1 {
		t.Fatalf("member with sharing off was ingested: %d %s", c, raw)
	}
}

func TestServerIngestStopsAtRevoke(t *testing.T) {
	e := readyEnv(t)
	now := time.Now()
	if c, _, raw := e.ingest(e.point("fix", e.b, now, 52.5, 13.4)); c != 200 {
		t.Fatalf("%d %s", c, raw)
	}
	// The owner's phone revokes the server key.
	e.mustCode("A", "DELETE", "/e2ee/devices/"+e.s.id, simpleAction(t, e2ee.ActRevoke, e.a, "", 0, e.s.id, e.s.fp), 200)
	if e.serverMember() {
		t.Fatal("circle is still a server member after the server key was revoked")
	}
	if c, _, raw := e.ingest(e.point("fix", e.b, now.Add(time.Second), 52.6, 13.5)); c != 403 {
		t.Fatalf("ingest after revoke: %d %s", c, raw)
	}
	// Phase-2 enforcement is back.
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
	e.mustCode("B", "POST", "/locations", map[string]any{"device_id": e.b.id, "lat": 52.1, "lon": 13.1}, 409)
	var rekey bool
	_ = e.pool.QueryRow(context.Background(), `SELECT e2ee_rekey_required FROM circles WHERE id = $1`, e.circle).Scan(&rekey)
	if !rekey {
		t.Fatal("revoking the server key did not flag the circle for a new epoch")
	}
	// The copies stay until someone purges them; the circle admin can.
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations WHERE e2ee_circle_id = $1`, e.circle).Scan(&n)
	if n != 1 {
		t.Fatalf("expected the earlier copy to remain until purged, have %d", n)
	}
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies?scope=circle", nil, 403) // member, not admin
	m := e.mustCode("A", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies?scope=circle", nil, 200)
	if m["locations_deleted"].(float64) != 1 {
		t.Fatalf("purge: %v", m)
	}
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations WHERE e2ee_circle_id = $1`, e.circle).Scan(&n)
	if n != 0 {
		t.Fatalf("%d server copies left after purge", n)
	}
	var mp int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM member_positions WHERE user_id = $1 AND lat = 52.5`, e.ids["B"]).Scan(&mp)
	if mp != 0 {
		t.Fatal("the server-derived last position survived the purge")
	}
}

func TestServerPurgeMineOnlyTouchesOwnCopies(t *testing.T) {
	e := readyEnv(t)
	now := time.Now()
	e.ingest(e.point("history", e.b, now.Add(-time.Hour), 1, 2), e.point("history", e.c, now.Add(-time.Hour), 3, 4))
	m := e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 200)
	if m["locations_deleted"].(float64) != 1 {
		t.Fatalf("scope=mine deleted %v rows", m["locations_deleted"])
	}
	var c int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id
		WHERE l.e2ee_circle_id = $1 AND d.user_id = $2`, e.circle, e.ids["C"]).Scan(&c)
	if c != 1 {
		t.Fatal("C's copy was removed by B")
	}
	e.mustCode("D", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 404)
}

func TestServerIngestStopsWhenConsentWithdrawn(t *testing.T) {
	e := readyEnv(t)
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-consent", nil, 200)
	if c, _, raw := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4)); c != 409 {
		t.Fatalf("ingest after a consent was withdrawn: %d %s", c, raw)
	}
	// A member leaving also drops their consent (a rejoin must consent again).
	e.consent("B", e.b, 200)
	e.rotate(2, e.a, e.b, e.c)
	if !e.serverMember() {
		t.Fatal("not a server member again")
	}
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM e2ee_server_consents WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]).Scan(&n)
	if n != 0 {
		t.Fatal("a removed member's consent record survived")
	}
}

func TestServerMemberServerKeyCannotBeRotatedAndStaysReadOnly(t *testing.T) {
	e := newSrvEnv(t)
	n := newTDev(t, e.ids["A"])
	rot := regBody(t, n, "server", nil, e2ee.ActRotate, false)
	delete(rot, "actor_device_id")
	lm, _ := e2ee.LogActionMessage(e2ee.ActRotate, n.uid, e.s.id, "", n.id, 0, n.fp)
	rot["log_signature"] = b64s(ed25519.Sign(e.s.priv, lm))
	e.mustCode("A", "POST", "/e2ee/devices/"+e.s.id+"/rotate", rot, 400)
	// Even if the registration asks for can_upload, a server key never uploads.
	x := newTDev(t, e.ids["A"])
	b := regBody(t, x, "server", e.a, e2ee.ActRegister, false)
	b["can_upload"] = true
	e.mustCode("A", "POST", "/e2ee/devices", b, 201)
	var cu bool
	_ = e.pool.QueryRow(context.Background(), `SELECT can_upload FROM device_keys WHERE device_id = $1`, x.id).Scan(&cu)
	if cu {
		t.Fatal("a server key got can_upload")
	}
}

// Positions are never written into the log lines, and the audit rows carry counts only.
func TestServerIngestLogsNoPlaintext(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)
	e := readyEnv(t)
	var audit []string
	e.srv.auditHook = func(u, f, a, d string) { audit = append(audit, a+"|"+d) }
	lat, lon := 52.123457, 13.654321
	if c, _, raw := e.ingest(e.point("fix", e.b, time.Now(), lat, lon), e.point("fix", e.b, time.Now(), 95, 1)); c != 200 {
		t.Fatalf("%d %s", c, raw)
	}
	for _, needle := range []string{"52.1234", "13.6543", fmt.Sprint(lat), testServerToken, b64s(e.s.priv.Seed())} {
		if strings.Contains(buf.String(), needle) || strings.Contains(strings.Join(audit, "\n"), needle) {
			t.Fatalf("%q leaked into logs or audit", needle)
		}
	}
	if len(audit) == 0 || !strings.Contains(strings.Join(audit, "\n"), "e2ee.server_ingest") {
		t.Fatalf("no audit entry: %v", audit)
	}
}

// A server-member circle's places are evaluated by the server (single source of truth).
func TestServerMemberGeofencingRuns(t *testing.T) {
	e := readyEnv(t)
	ctx := context.Background()
	if e.srv.circleBlocksPlaintext(ctx, e.circle) {
		t.Fatal("geofence evaluation would still be skipped for a server-member circle")
	}
	if !e.srv.circleIsPrivate(ctx, e.circle) {
		t.Fatal("the circle must still be private")
	}
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 52.5, "lon": 13.4, "radius_meters": 200, "circle_id": e.circle}, 201)
	var places int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM places WHERE COALESCE(circle_id, family_id) = $1`, e.circle).Scan(&places)
	if places != 1 {
		t.Fatalf("places: %d", places)
	}
	c, m, raw := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4))
	if c != 200 || m["stored"].(float64) != 1 {
		t.Fatalf("%d %s", c, raw)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO geofences (family_id, place_id) SELECT $1, id FROM places WHERE COALESCE(circle_id, family_id) = $1`, e.circle); err != nil {
		t.Fatalf("a geofence for a server-member circle was refused: %v", err)
	}
	// The server evaluates the places against the ingested fix (single source of truth).
	e.srv.evaluateGeofences(ctx, e.ids["B"], 13.4, 52.5, time.Now(), nil)
	var inside bool
	if err := e.pool.QueryRow(ctx, `SELECT s.inside FROM geofence_states s JOIN geofences g ON g.id = s.geofence_id
		WHERE s.user_id = $1 AND g.family_id = $2`, e.ids["B"], e.circle).Scan(&inside); err != nil || !inside {
		t.Fatalf("server geofence evaluation did not run for the server-member circle: inside=%v err=%v", inside, err)
	}
	// Revoking switches evaluation back off for the circle.
	e.mustCode("A", "DELETE", "/e2ee/devices/"+e.s.id, simpleAction(t, e2ee.ActRevoke, e.a, "", 0, e.s.id, e.s.fp), 200)
	if !e.srv.circleBlocksPlaintext(ctx, e.circle) {
		t.Fatal("the circle is not protected again after the server key was revoked")
	}
}

// A member who also sits in a normal circle is not ingested: the position would
// reach that circle's plaintext table; the phone already uploads it there.
func TestServerIngestSkipsMembersOfStandardCircles(t *testing.T) {
	e := readyEnv(t)
	now := time.Now()
	e.createCircle("B", "Std", "D")
	c, m, raw := e.ingest(e.point("fix", e.b, now, 52.5, 13.4), e.point("fix", e.c, now, 52.6, 13.5))
	if c != 200 || m["stored"].(float64) != 1 || rejectedCount(m, "sender_not_allowed") != 1 {
		t.Fatalf("a member of a standard circle was ingested: %d %s", c, raw)
	}
}

// Switching private mode off ends the consents; turning it on again starts from zero.
func TestServerConsentsEndWhenPrivateModeEnds(t *testing.T) {
	e := readyEnv(t)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/disable", simpleAction(t, e2ee.ActDisable, e.a, e.circle, 1, "", nil), 200)
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM e2ee_server_consents WHERE circle_id = $1`, e.circle).Scan(&n)
	if n != 0 {
		t.Fatalf("%d consents survived turning private mode off", n)
	}
	if e.serverMember() {
		t.Fatal("a non-private circle is a server member")
	}
	if c, _, _ := e.ingest(e.point("fix", e.b, time.Now(), 1, 2)); c != 409 {
		t.Fatalf("ingest into a normal circle: %d", c)
	}
}

// The legacy-plaintext purge must not delete the legitimate server-side places of a server-member circle.
func TestServerMemberCircleKeepsItsPlacesOnPurgePlaintext(t *testing.T) {
	e := readyEnv(t)
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 201)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/purge-plaintext", nil, 409)
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM places WHERE COALESCE(circle_id, family_id) = $1`, e.circle).Scan(&n)
	if n != 1 {
		t.Fatalf("places after purge attempt: %d", n)
	}
}

// Every live member must consent, including one who holds no phone key yet.
func TestServerMemberRequiresConsentOfEveryLiveMember(t *testing.T) {
	e := readyEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = 'member' WHERE id = $2`, e.circle, e.ids["D"]); err != nil {
		t.Fatal(err)
	}
	if e.serverMember() {
		t.Fatal("a new member without any key or consent did not close the circle")
	}
	if c, _, raw := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4)); c != 409 {
		t.Fatalf("ingest while a member has not consented: %d %s", c, raw)
	}
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
	e.mustCode("D", "POST", "/locations", map[string]any{"device_id": e.a.id, "lat": 52.1, "lon": 13.1}, 409)
	// D registers a phone key and consents: open again.
	d := newTDev(t, e.ids["D"])
	e.register("D", d)
	e.rotate(2, e.a, e.b, e.c, d)
	if e.serverMember() {
		t.Fatal("a member who has not consented yet")
	}
	e.mustCode("D", "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{
		"server_device_id": e.s.id, "approver_device_id": d.id, "signature": consentSig(t, e.circle, d, d, e.s)}, 200)
	if !e.serverMember() {
		t.Fatal("not a server member after everyone consented and the epoch was published")
	}
}

// A member leaving ends server-member status until a new epoch is published.
func TestServerMemberEndsWhenAMemberLeavesUntilRekey(t *testing.T) {
	e := readyEnv(t)
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"]); err != nil {
		t.Fatal(err)
	}
	if e.serverMember() {
		t.Fatal("still a server member while the key epoch is pending")
	}
	if c, _, _ := e.ingest(e.point("fix", e.b, time.Now(), 52.5, 13.4)); c != 409 {
		t.Fatalf("ingest before rekey: %d", c)
	}
	e.rotate(2, e.a, e.b)
	if !e.serverMember() {
		t.Fatal("not a server member after the rekey")
	}
}

func (e *srvEnv) userDevice(user string) string {
	var id string
	if err := e.pool.QueryRow(context.Background(), `SELECT id::text FROM devices WHERE user_id = $1 ORDER BY created_at LIMIT 1`, e.ids[user]).Scan(&id); err != nil {
		e.t.Fatal(err)
	}
	return id
}

func (e *srvEnv) locAt(dev string, ts time.Time, lat float64, circle any) {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO locations (device_id, ts, geom, source, e2ee_circle_id)
		VALUES ($1,$2, ST_SetSRID(ST_MakePoint(5, $3), 4326), 'x', $4)`, dev, ts, lat, circle); err != nil {
		e.t.Fatal(err)
	}
}

func (e *srvEnv) lastLat(user string) (float64, bool) {
	var lat float64
	if err := e.pool.QueryRow(context.Background(), `SELECT lat FROM member_positions WHERE user_id = $1`, e.ids[user]).Scan(&lat); err != nil {
		return 0, false
	}
	return lat, true
}

func TestServerPurgeKeepsPositionsFromOtherSources(t *testing.T) {
	e := readyEnv(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	other := "99999999-9999-4999-8999-999999999999" // a second server-member circle's copy
	// B: server copy of this circle is the newest point; an older point came from
	// another server-member circle and an even older one from a plaintext circle.
	e.ingest(e.point("fix", e.b, now, 10, 1))
	dev := e.userDevice("B")
	e.locAt(dev, now.Add(-time.Hour), 20, other)
	e.locAt(dev, now.Add(-2*time.Hour), 30, nil)
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 200)
	if lat, ok := e.lastLat("B"); !ok || lat != 20 {
		t.Fatalf("last position after purge = %v %v, want the other circle's 20", lat, ok)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM locations WHERE device_id = $1 AND e2ee_circle_id IS NULL OR e2ee_circle_id = $2`, dev, other).Scan(&n)
	if n != 2 {
		t.Fatalf("other sources lost rows: %d", n)
	}

	// C: the position is the other circle's (newer than this circle's copy): untouched.
	e.ingest(e.point("history", e.c, now.Add(-3*time.Hour), 40, 1))
	devC := e.userDevice("C")
	e.locAt(devC, now, 50, other)
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 50, 5, $2)
		ON CONFLICT (user_id) DO UPDATE SET lat = 50, ts = $2`, e.ids["C"], now); err != nil {
		t.Fatal(err)
	}
	e.mustCode("C", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 200)
	if lat, _ := e.lastLat("C"); lat != 50 {
		t.Fatalf("a position from another circle was changed: %v", lat)
	}

	// A: a plaintext-circle position is the newest; the purge of an older server copy leaves it.
	e.ingest(e.point("history", e.a, now.Add(-time.Hour), 60, 1))
	devA := e.userDevice("A")
	e.locAt(devA, now, 70, nil)
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 70, 5, $2)
		ON CONFLICT (user_id) DO UPDATE SET lat = 70, ts = $2`, e.ids["A"], now); err != nil {
		t.Fatal(err)
	}
	e.mustCode("A", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies?scope=circle", nil, 200)
	if lat, _ := e.lastLat("A"); lat != 70 {
		t.Fatalf("plaintext position was removed: %v", lat)
	}
}
