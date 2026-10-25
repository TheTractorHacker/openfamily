package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// TestHeartbeatDeviceUnauthenticated verifies the heartbeat endpoint requires
// an authenticated caller (checked before any database access, so this needs
// no Postgres).
func TestHeartbeatDeviceUnauthenticated(t *testing.T) {
	s := &Server{}
	req := httptest.NewRequest(http.MethodPost, "/devices/heartbeat",
		strings.NewReader(`{"device_id":"abc"}`))
	rec := httptest.NewRecorder()
	s.HeartbeatDevice(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

// TestHeartbeatDeviceRequiresDeviceID verifies a missing device_id is rejected
// with 400 before any database access.
func TestHeartbeatDeviceRequiresDeviceID(t *testing.T) {
	s := &Server{}
	req := httptest.NewRequest(http.MethodPost, "/devices/heartbeat",
		strings.NewReader(`{}`))
	req = req.WithContext(middleware.ContextWithClaims(
		req.Context(), testClaims("44444444-4444-4444-4444-444444444444"),
	))
	rec := httptest.NewRecorder()
	s.HeartbeatDevice(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want %d", rec.Code, http.StatusBadRequest)
	}
}
