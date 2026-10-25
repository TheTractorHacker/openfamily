package middleware

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

type fakeIngestStore struct {
	versions map[string]int
	devices  map[string]deviceKeyRecord
	extended map[string]time.Time
}

func (f *fakeIngestStore) TokenVersion(_ context.Context, userID string) (int, error) {
	v, ok := f.versions[userID]
	if !ok {
		return 0, errors.New("no user")
	}
	return v, nil
}

func (f *fakeIngestStore) DeviceKey(_ context.Context, id string) (deviceKeyRecord, error) {
	r, ok := f.devices[id]
	if !ok {
		return deviceKeyRecord{}, errors.New("no device")
	}
	return r, nil
}

func (f *fakeIngestStore) ExtendDeviceKey(_ context.Context, id string, exp time.Time) error {
	if f.extended == nil {
		f.extended = map[string]time.Time{}
	}
	f.extended[id] = exp
	return nil
}

func ingestFixture(t *testing.T, expires *time.Time) (*fakeIngestStore, http.Handler, string) {
	t.Helper()
	key, _ := GenerateDeviceIngestKey()
	hash := EncodeIngestKeyHash(HashDeviceIngestKey(key))
	owner := "user-1"
	store := &fakeIngestStore{
		versions: map[string]int{"user-1": 0},
		devices: map[string]deviceKeyRecord{
			"dev-A": {OwnerID: &owner, Hash: &hash, ExpiresAt: expires},
			"dev-B": {OwnerID: &owner, Hash: &hash, ExpiresAt: expires},
		},
	}
	tm := auth.NewTokenManager("test-secret", time.Minute, time.Hour)
	h := requireAuthOrDeviceIngestKey(tm, store)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if c := ClaimsFromContext(r.Context()); c == nil || c.UserID != "user-1" {
			t.Errorf("claims missing/wrong: %+v", c)
		}
		if DeviceIDFromContext(r.Context()) == "" {
			t.Error("device id not in context")
		}
		_, _ = w.Write(b) // body must still be readable downstream
	}))
	return store, h, key
}

func post(h http.Handler, header, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/locations", strings.NewReader(body))
	req.Header.Set(DeviceKeyHeader, header)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestDeviceKeyBoundToDevice(t *testing.T) {
	future := time.Now().Add(80 * 24 * time.Hour)
	_, h, key := ingestFixture(t, &future)

	// Key for device A posting for device A: allowed, body preserved.
	rec := post(h, "dev-A."+key, `{"device_id":"dev-A","lat":1,"lon":2}`)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"dev-A"`) {
		t.Fatalf("own device: status=%d body=%q", rec.Code, rec.Body.String())
	}
	// Key for device A posting for device B (same owner): refused.
	rec = post(h, "dev-A."+key, `{"device_id":"dev-B","lat":1,"lon":2}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other device single: status=%d, want 403", rec.Code)
	}
	// Batch naming another device in any point: refused.
	rec = post(h, "dev-A."+key, `{"points":[{"device_id":"dev-A"},{"device_id":"dev-B"}]}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("other device batch: status=%d, want 403", rec.Code)
	}
	rec = post(h, "dev-A."+key, `{"points":[{"device_id":"dev-A"}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("own device batch: status=%d", rec.Code)
	}
}

func TestDeviceKeyExpiryAndSliding(t *testing.T) {
	past := time.Now().Add(-time.Minute)
	_, h, key := ingestFixture(t, &past)
	if rec := post(h, "dev-A."+key, `{"device_id":"dev-A"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired key: status=%d, want 401", rec.Code)
	}

	// Legacy key (no expiry) keeps working and is stamped on first use.
	store, h, key := ingestFixture(t, nil)
	if rec := post(h, "dev-A."+key, `{"device_id":"dev-A"}`); rec.Code != http.StatusOK {
		t.Fatalf("legacy key: status=%d", rec.Code)
	}
	if exp, ok := store.extended["dev-A"]; !ok || time.Until(exp) < IngestKeyTTL-time.Minute {
		t.Fatalf("legacy key was not stamped with an expiry: %v", store.extended)
	}

	// A key with plenty of life left is not rewritten on every request.
	fresh := time.Now().Add(IngestKeyTTL - time.Hour)
	store, h, key = ingestFixture(t, &fresh)
	post(h, "dev-A."+key, `{"device_id":"dev-A"}`)
	if len(store.extended) != 0 {
		t.Fatalf("fresh key was extended: %v", store.extended)
	}
	// One in its second half is pushed out.
	stale := time.Now().Add(IngestKeyTTL/2 - time.Hour)
	store, h, key = ingestFixture(t, &stale)
	post(h, "dev-A."+key, `{"device_id":"dev-A"}`)
	if len(store.extended) != 1 {
		t.Fatalf("aging key was not extended: %v", store.extended)
	}
}

// A revoked key (hash NULLed on logout / password change / device delete) and a
// removed device must be refused.
func TestDeviceKeyRevoked(t *testing.T) {
	store, h, key := ingestFixture(t, nil)
	owner := "user-1"
	store.devices["dev-A"] = deviceKeyRecord{OwnerID: &owner} // ingest_key_hash NULL
	if rec := post(h, "dev-A."+key, `{"device_id":"dev-A"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked key: status=%d, want 401", rec.Code)
	}
	delete(store.devices, "dev-A")
	if rec := post(h, "dev-A."+key, `{"device_id":"dev-A"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("deleted device: status=%d, want 401", rec.Code)
	}
	// Wrong key for an existing device.
	if rec := post(h, "dev-B.wrong", `{"device_id":"dev-B"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong key: status=%d, want 401", rec.Code)
	}
}

func TestCheckBodyDeviceIgnoresUnparseable(t *testing.T) {
	if err := checkBodyDevice([]byte("not json"), "x"); err != nil {
		t.Fatal("unparseable body should be left to the handler")
	}
	if err := checkBodyDevice([]byte(`{"lat":1}`), "x"); err != nil {
		t.Fatal("body without device_id should be left to the handler")
	}
}
