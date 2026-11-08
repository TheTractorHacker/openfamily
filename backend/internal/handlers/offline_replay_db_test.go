package handlers

import (
	"strings"
	"testing"
)

// Offline-first replay: a phone queues an SOS or check-in while the server is
// unreachable and sends it again with the same client_id. If the first request
// actually arrived (only the answer was lost), the replay must not create a
// second alert or deliver a second time, and must not hit the cooldown.
// Needs TEST_DATABASE_URL (skipped otherwise).

func TestSOSReplayWithClientIDIsIdempotent(t *testing.T) {
	fx := newAlertFixture(t)
	h := newSharingRouter(fx)

	code, first := callJSON(t, h, "POST", "/alerts/sos", fx.a, map[string]any{"lat": 50.0, "lon": 8.0, "client_id": "sos-1"})
	if code != 201 {
		t.Fatalf("first SOS: %d %v", code, first)
	}
	code, again := callJSON(t, h, "POST", "/alerts/sos", fx.a, map[string]any{"lat": 50.0, "lon": 8.0, "client_id": "sos-1"})
	if code != 200 {
		t.Fatalf("replay must be a 200 with the stored alert (not 429, not 201): %d %v", code, again)
	}
	if again["id"] != first["id"] {
		t.Fatalf("replay returned another alert: %v vs %v", again["id"], first["id"])
	}
	var n int
	if err := fx.srv.Pool.QueryRow(t.Context(), `SELECT count(*) FROM alerts WHERE user_id = $1 AND type = 'sos'`, fx.a).Scan(&n); err != nil || n != 1 {
		t.Fatalf("alerts stored: %d err=%v", n, err)
	}
	// Without a client id nothing changes: the cooldown still applies.
	if fx.srv.AlertLimit != nil {
		if code, _ = callJSON(t, h, "POST", "/alerts/sos", fx.a, map[string]any{"lat": 50.0, "lon": 8.0}); code != 429 {
			t.Fatalf("cooldown without client id: %d", code)
		}
	}
	// The same client id from another user is a different alert.
	if code, _ = callJSON(t, h, "POST", "/alerts/sos", fx.b, map[string]any{"client_id": "sos-1"}); code != 201 {
		t.Fatalf("other sender: %d", code)
	}
	if code, _ = callJSON(t, h, "POST", "/alerts/sos", fx.b, map[string]any{"client_id": strings.Repeat("x", 65)}); code != 400 {
		t.Fatalf("long client id: %d", code)
	}
}

func TestCheckinReplayWithClientIDIsIdempotent(t *testing.T) {
	fx := newAlertFixture(t)
	h := newSharingRouter(fx)

	body := map[string]any{"recipient_ids": []string{fx.b}, "note": "home", "client_id": "ci-1"}
	code, first := callJSON(t, h, "POST", "/checkins", fx.a, body)
	if code != 201 {
		t.Fatalf("first: %d %v", code, first)
	}
	code, again := callJSON(t, h, "POST", "/checkins", fx.a, body)
	if code != 200 || again["id"] != first["id"] {
		t.Fatalf("replay: %d %v (first %v)", code, again, first)
	}
	var n int
	if err := fx.srv.Pool.QueryRow(t.Context(), `SELECT count(*) FROM checkins WHERE user_id = $1`, fx.a).Scan(&n); err != nil || n != 1 {
		t.Fatalf("check-ins stored: %d err=%v", n, err)
	}
}
