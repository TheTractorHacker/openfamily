package handlers

import (
	"context"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Phase 3: the web viewer and the Dawarich bridge are device members. These
// tests pin the server-side guarantees they rely on. Needs TEST_DATABASE_URL.

// The server-side Dawarich sync reads only the plaintext `locations` table, and a
// Private circle never writes there, so it can never forward a private position.
func TestE2EEDawarichServerSyncSkipsPrivateCircles(t *testing.T) {
	e := newChanEnv(t)
	ctx := context.Background()
	var before int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM locations`).Scan(&before)

	// A sealed fix is stored as ciphertext only.
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte(`{"lat":52.5,"lon":13.4}`)))
	// Plaintext from the same private-only person is refused.
	e.mustCode("B", "POST", "/locations", map[string]any{"device_id": e.b.id, "lat": 52.1, "lon": 13.1}, 409)

	var after int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM locations`).Scan(&after)
	if after != before {
		t.Fatalf("a private circle wrote %d plaintext location rows", after-before)
	}
	// Both targets (main account for "everyone else" and a per-person mapping) get nothing.
	since := time.Now().Add(-48 * time.Hour)
	for _, tgt := range []dawarichTarget{{Key: "k", Since: since}, {UserID: e.ids["B"], Key: "k", Since: since}} {
		pts, err := e.srv.nextDawarichBatch(ctx, tgt)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range pts {
			var uid string
			_ = e.pool.QueryRow(ctx, `SELECT user_id::text FROM devices WHERE id = $1`, p.deviceID).Scan(&uid)
			if uid == e.ids["B"] || uid == e.ids["A"] || uid == e.ids["C"] {
				t.Fatalf("private-circle member %s reached the Dawarich batch", uid)
			}
		}
	}
}

// A viewer or bridge key can revoke itself (that is how `e2ee-bridge revoke` and the
// web "Revoke this viewer" button work); afterwards it can no longer pull.
func TestE2EEViewerRevokesItself(t *testing.T) {
	e := newChanEnv(t)
	web := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, web, "web", e.a, e2ee.ActRegister, false), 201)
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x")))
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+web.id, nil, 200)

	e.mustCode("A", "DELETE", "/e2ee/devices/"+web.id, simpleAction(t, e2ee.ActRevoke, web, "", 0, web.id, web.fp), 200)
	code, m, raw := e.do("A", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+web.id, nil)
	if code != 403 || m["code"] != "no_approved_device" {
		t.Fatalf("revoked viewer still pulls: %d %s", code, raw)
	}
	// The revoke flagged the circle for a new epoch.
	var rekey bool
	_ = e.pool.QueryRow(context.Background(), `SELECT e2ee_rekey_required FROM circles WHERE id = $1`, e.circle).Scan(&rekey)
	if !rekey {
		t.Fatal("revoking a viewer did not flag the circle for a new key epoch")
	}
}

// A viewer key of a user whose own chain is NOT approved gets no key: a replacement
// (reset) root of another user, and its viewer, wait for a circle admin.
func TestE2EEViewerOfUnapprovedRootIsNotApproved(t *testing.T) {
	e := newChanEnv(t)
	reset := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, reset, "device", nil, e2ee.ActReset, true), 201)
	view := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, view, "web", reset, e2ee.ActRegister, false), 201)
	e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+view.id, nil, 403)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"epoch": 1,
		"wraps": []any{mkWrap(t, e.circle, 1, e.a, view, e.key)}}, 400)
}
