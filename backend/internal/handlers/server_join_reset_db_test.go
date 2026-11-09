package handlers

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

// An owner key reset revokes the built-in server device's key too (it is a key of the owner's
// account). The API tells the device at once, so it makes a new key within seconds (not after the
// ~90 s self-repair), names the revoked key in "replaces", and the owner's NEW phone approves it with
// its own signature. Needs TEST_DATABASE_URL.
func TestBuiltinServerDeviceRejoinsAfterOwnerReset(t *testing.T) {
	t.Setenv("E2EE_SERVER_INGEST_TOKEN", testServerToken)
	e := newChanEnv(t)
	e.route("PUT", "/internal/e2ee/server-device", e.srv.E2EEPinServerDevice)
	e.route("GET", "/e2ee/server-device", e.srv.E2EEServerDevice)
	e.route("GET", "/e2ee/server-join", e.srv.E2EEServerJoin)
	e.route("POST", "/e2ee/server-join/approve", e.srv.E2EEServerJoinApprove)
	e.route("GET", "/circles", e.srv.ListCircles)
	e.route("GET", "/e2ee/log", e.srv.E2EELog)
	ctx := context.Background()
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `DELETE FROM e2ee_server_device`) })
	// A runs the server; B is an ordinary member, later also a server administrator.
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = TRUE WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if b := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "); len(b) == 36 {
			r.Header.Set("X-Test-User", b)
		}
		e.rt.ServeHTTP(w, r)
	}))
	defer ts.Close()
	dir := filepath.Join(t.TempDir(), "server-device")
	dev, err := e2eebridge.OpenEmbedded(e2eebridge.EmbeddedOptions{Dir: dir, BaseURL: ts.URL, Token: testServerToken, Poll: 5 * time.Second,
		MintAccess: func(_ context.Context, uid string) (string, error) { return uid, nil }})
	if err != nil {
		t.Fatal(err)
	}
	e.srv.ServerDevice = dev

	approve := func(user string, phone *tdev, want int) string {
		t.Helper()
		m := e.mustCode(user, "GET", "/e2ee/server-join", nil, 200)
		req, _ := m["request"].(map[string]any)
		if req == nil {
			t.Fatalf("%s gets no request: %v", user, m)
		}
		id, _ := req["device_id"].(string)
		fp, _ := hex.DecodeString(req["fingerprint"].(string))
		lm, err := e2ee.LogActionMessage(e2ee.ActRegister, e.ids[user], phone.id, "", id, 0, fp)
		if err != nil {
			t.Fatal(err)
		}
		e.mustCode(user, "POST", "/e2ee/server-join/approve", map[string]any{"device_id": id, "actor_device_id": phone.id,
			"log_signature": b64s(ed25519.Sign(phone.priv, lm))}, want)
		return id
	}
	waitPinned := func(id string) {
		t.Helper()
		deadline := time.Now().Add(20 * time.Second)
		for {
			m := e.mustCode("B", "GET", "/e2ee/server-device", nil, 200)
			if d, _ := m["device"].(map[string]any); d != nil && d["device_id"] == id {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("the built-in device never pinned %s: %v", id, m)
			}
			time.Sleep(200 * time.Millisecond)
		}
	}

	first := approve("A", e.a, 200)
	rctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		dev.Run(rctx)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
		}
	}()
	waitPinned(first)

	// B's reset revokes only B's keys: the server key (A's) stays, and nothing waits.
	b2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, b2, "device", nil, e2ee.ActReset, true), 201)
	time.Sleep(time.Second)
	if in := dev.Info(); in.DeviceID != first || !in.Registered {
		t.Fatalf("a member's reset touched the server key: %+v", in)
	}

	// A resets from a new phone: every key of A's account goes, the server's included.
	a2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, a2, "device", nil, e2ee.ActReset, true), 201)
	var revoked bool
	if err := e.pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM device_keys WHERE device_id = $1`, first).Scan(&revoked); err != nil || !revoked {
		t.Fatalf("the reset must revoke the server key: %v %v", err, revoked)
	}
	// Within seconds (the old self-repair needed three answers ~30 s apart) a new key waits.
	var m map[string]any
	deadline := time.Now().Add(10 * time.Second)
	for {
		m = e.mustCode("A", "GET", "/e2ee/server-join", nil, 200)
		if req, _ := m["request"].(map[string]any); req != nil && req["device_id"] != first {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no new server key after the owner's reset: %v", m)
		}
		time.Sleep(100 * time.Millisecond)
	}
	req := m["request"].(map[string]any)
	if req["replaces"] != first || req["kind"] != "server" || req["user_id"] != e.ids["A"] {
		t.Fatalf("the new key's request must name the revoked key: %v", req)
	}
	// Public data only: nothing of the server's private key in any answer.
	for _, raw := range []map[string]any{m, e.mustCode("B", "GET", "/e2ee/server-join", nil, 200), e.mustCode("A", "GET", "/e2ee/server-device", nil, 200)} {
		for _, bad := range []string{"seed", "secret", "priv", "session"} {
			if hasKeyLike(raw, bad) {
				t.Fatalf("an answer carries %q: %v", bad, raw)
			}
		}
	}
	// B is not a server administrator: no request, cannot approve.
	if mb := e.mustCode("B", "GET", "/e2ee/server-join", nil, 200); mb["request"] != nil || mb["can_approve"] != false {
		t.Fatalf("member view after reset: %v", mb)
	}
	e.mustCode("B", "POST", "/e2ee/server-join/approve", map[string]any{"actor_device_id": b2.id, "log_signature": b64s(make([]byte, e2ee.SigLen))}, 403)
	// The OLD phone's signature no longer counts: it was revoked by the reset.
	approve("A", e.a, 400)
	if dev.Info().Registered {
		t.Fatal("a revoked phone approved the server")
	}
	// The new phone signs: the server is A's again, cross-signed by the reset key.
	second := approve("A", a2, 200)
	var kind, by string
	if err := e.pool.QueryRow(ctx, `SELECT kind, registered_by_device_id::text FROM device_keys WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
		second, e.ids["A"]).Scan(&kind, &by); err != nil || kind != "server" || by != a2.id {
		t.Fatalf("new server key: %v kind=%q by=%q", err, kind, by)
	}
	waitPinned(second)
}

// hasKeyLike reports whether any map key (at any depth) contains s.
func hasKeyLike(v any, s string) bool {
	switch x := v.(type) {
	case map[string]any:
		for k, vv := range x {
			if strings.Contains(strings.ToLower(k), s) || hasKeyLike(vv, s) {
				return true
			}
		}
	case []any:
		for _, vv := range x {
			if hasKeyLike(vv, s) {
				return true
			}
		}
	}
	return false
}
