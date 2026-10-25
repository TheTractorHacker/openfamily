package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

func TestGenerateDeviceIngestKey(t *testing.T) {
	key, err := GenerateDeviceIngestKey()
	if err != nil {
		t.Fatalf("GenerateDeviceIngestKey: %v", err)
	}
	if len(key) < 40 {
		t.Fatalf("key too short: %d chars", len(key))
	}
	other, err := GenerateDeviceIngestKey()
	if err != nil {
		t.Fatalf("GenerateDeviceIngestKey: %v", err)
	}
	if key == other {
		t.Fatal("two generated keys are identical")
	}
}

func TestParseDeviceKeyHeader(t *testing.T) {
	cases := []struct {
		name   string
		header string
		devID  string
		key    string
		ok     bool
	}{
		{"valid", "d290f1ee-6c54-4b01-90e6-d701748f0851.abcDEF123-_x", "d290f1ee-6c54-4b01-90e6-d701748f0851", "abcDEF123-_x", true},
		{"no dot", "abc", "", "", false},
		{"leading dot", ".abc", "", "", false},
		{"trailing dot", "abc.", "", "", false},
		{"empty", "", "", "", false},
		{"spaces in key", "dev.key with space", "", "", false},
		{"key may contain further dots (not generated, but tolerated)", "dev.a.b", "dev", "a.b", true},
	}
	for _, c := range cases {
		devID, key, ok := ParseDeviceKeyHeader(c.header)
		if ok != c.ok || (ok && (devID != c.devID || key != c.key)) {
			t.Errorf("%s: got (%q,%q,%v), want (%q,%q,%v)", c.name, devID, key, ok, c.devID, c.key, c.ok)
		}
	}
}

func TestIngestKeysEqual(t *testing.T) {
	key, err := GenerateDeviceIngestKey()
	if err != nil {
		t.Fatalf("GenerateDeviceIngestKey: %v", err)
	}
	stored := EncodeIngestKeyHash(HashDeviceIngestKey(key))
	if !ingestKeysEqual(stored, key) {
		t.Fatal("stored hash does not match its own key")
	}
	other, _ := GenerateDeviceIngestKey()
	if ingestKeysEqual(stored, other) {
		t.Fatal("different key matches stored hash")
	}
	if ingestKeysEqual(stored, key+"x") {
		t.Fatal("mutated key matches stored hash")
	}
}

// TestRequireAuthOrDeviceIngestKeyNoCredentials covers the paths that must
// 401 before any database access (nil pool is therefore intentional).
func TestRequireAuthOrDeviceIngestKeyNoCredentials(t *testing.T) {
	tm := auth.NewTokenManager("test-secret", time.Minute, time.Hour)
	handler := RequireAuthOrDeviceIngestKey(tm, nil)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("unauthenticated request reached the handler")
	}))

	// No headers at all.
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/locations", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no headers: status=%d, want %d", rec.Code, http.StatusUnauthorized)
	}

	// Malformed device-key header.
	req := httptest.NewRequest(http.MethodPost, "/locations", nil)
	req.Header.Set(DeviceKeyHeader, "not-a-credential")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("malformed header: status=%d, want %d", rec.Code, http.StatusUnauthorized)
	}

	// Invalid Bearer token (fails JWT parse before any pool access).
	req = httptest.NewRequest(http.MethodPost, "/locations", nil)
	req.Header.Set("Authorization", "Bearer not-a-jwt")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("invalid bearer: status=%d, want %d", rec.Code, http.StatusUnauthorized)
	}
}
