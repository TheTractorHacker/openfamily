package handlers

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"crypto/ed25519"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

// The API's built-in server device (docs/design/PRIVACY_PROCESSING.md section 22):
// the server asks to join, an admin phone approves, the in-process loop pins the
// key. Needs TEST_DATABASE_URL.

func TestBuiltinServerDeviceJoinApprovePin(t *testing.T) {
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
	// A is the server administrator, B an ordinary member.
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = TRUE WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	// Loopback: the bearer "token" the device mints is the user id (the test router
	// authenticates with X-Test-User); the ingest token passes through untouched.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if b := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "); len(b) == 36 {
			r.Header.Set("X-Test-User", b)
		}
		e.rt.ServeHTTP(w, r)
	}))
	defer ts.Close()
	dir := filepath.Join(t.TempDir(), "server-device")
	opt := e2eebridge.EmbeddedOptions{Dir: dir, BaseURL: ts.URL, Token: testServerToken, Poll: 5 * time.Second,
		MintAccess: func(_ context.Context, uid string) (string, error) { return uid, nil }}
	dev, err := e2eebridge.OpenEmbedded(opt)
	if err != nil {
		t.Fatal(err)
	}
	e.srv.ServerDevice = dev

	// The key file is private, and a restart keeps the same key.
	if fi, err := os.Stat(filepath.Join(dir, "identity.json")); err == nil && fi.Mode().Perm()&0o077 != 0 {
		t.Fatalf("identity file is readable by others: %v", fi.Mode())
	}
	first := dev.Info().DeviceID
	if again, err := e2eebridge.OpenEmbedded(opt); err != nil || again.Info().DeviceID != first {
		t.Fatalf("restart must keep the key: %v", err)
	}

	// An ordinary member sees that the server wants to join, but gets no request and cannot approve.
	m := e.mustCode("B", "GET", "/e2ee/server-join", nil, 200)
	if m["waiting"] != true || m["can_approve"] != false || m["request"] != nil {
		t.Fatalf("member view: %v", m)
	}
	e.mustCode("B", "POST", "/e2ee/server-join/approve", map[string]any{"actor_device_id": e.b.id, "log_signature": "x"}, 403)

	// The admin gets the request with the code to compare.
	m = e.mustCode("A", "GET", "/e2ee/server-join", nil, 200)
	req, _ := m["request"].(map[string]any)
	if m["can_approve"] != true || req == nil || req["short"] == "" || req["device_id"] != first {
		t.Fatalf("admin view: %v", m)
	}
	// A wrong signature is refused and leaves the server waiting.
	e.mustCode("A", "POST", "/e2ee/server-join/approve", map[string]any{"actor_device_id": e.a.id, "log_signature": b64s(make([]byte, e2ee.SigLen))}, 400)
	if dev.Info().Registered {
		t.Fatal("registered with a bad signature")
	}
	// The phone signs the registration (the same action as for a sidecar).
	fp, _ := hex.DecodeString(req["fingerprint"].(string))
	lm, err := e2ee.LogActionMessage(e2ee.ActRegister, e.ids["A"], e.a.id, "", first, 0, fp)
	if err != nil {
		t.Fatal(err)
	}
	e.mustCode("A", "POST", "/e2ee/server-join/approve", map[string]any{"device_id": first, "actor_device_id": e.a.id,
		"log_signature": b64s(ed25519.Sign(e.a.priv, lm))}, 200)
	if !dev.Info().Registered {
		t.Fatal("not registered after approval")
	}
	var kind string
	if err := e.pool.QueryRow(ctx, `SELECT kind FROM device_keys WHERE device_id = $1 AND revoked_at IS NULL`, first).Scan(&kind); err != nil || kind != "server" {
		t.Fatalf("server key not registered as kind server: %v %q", err, kind)
	}

	// The in-process loop pins the key by itself.
	rctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		dev.Run(rctx)
	}()
	// Stop the loop and wait for it before the temporary directory is removed: it writes state files.
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
		}
	}()
	deadline := time.Now().Add(20 * time.Second)
	for {
		m := e.mustCode("B", "GET", "/e2ee/server-device", nil, 200)
		if d, _ := m["device"].(map[string]any); d != nil && d["device_id"] == first {
			if m["builtin"] != true {
				t.Fatalf("builtin flag missing: %v", m)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the built-in device never pinned its key: %v", m)
		}
		time.Sleep(300 * time.Millisecond)
	}
	// Once registered there is nothing left to approve.
	m = e.mustCode("A", "GET", "/e2ee/server-join", nil, 200)
	if m["waiting"] != false || m["request"] != nil {
		t.Fatalf("still waiting: %v", m)
	}
}

func TestRecommendedLaneRules(t *testing.T) {
	cases := []struct {
		eff         string
		pinned, adm bool
		want        string
	}{
		{ProfileHome, true, false, "server"},
		{ProfileHome, false, false, "phone"},
		{ProfileCloud, true, false, "phone"},
		{ProfileCloud, true, true, "server"},
		{ProfileCloud, false, true, "phone"},
	}
	for _, c := range cases {
		if got := recommendedLane(c.eff, c.pinned, c.adm); got != c.want {
			t.Errorf("%+v: got %s", c, got)
		}
	}
}
