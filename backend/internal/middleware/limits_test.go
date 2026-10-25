package middleware

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func limitedHandler() http.Handler {
	return LimitBody(BodyLimitFor)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.ReadAll(r.Body); err != nil {
			http.Error(w, "read failed", http.StatusRequestEntityTooLarge)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
}

func TestBodyLimitDefaultRoute(t *testing.T) {
	h := limitedHandler()
	// 1 MiB to /auth/login: 413 from the declared length, handler never runs.
	req := httptest.NewRequest(http.MethodPost, "/auth/login", bytes.NewReader(make([]byte, 1<<20)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized login: status=%d, want 413", rec.Code)
	}
	// Small body passes.
	req = httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(`{"email":"a"}`))
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("small login: status=%d", rec.Code)
	}
}

// A client that does not declare a length (chunked) is still cut off.
func TestBodyLimitChunkedBody(t *testing.T) {
	h := limitedHandler()
	req := httptest.NewRequest(http.MethodPost, "/auth/register", io.NopCloser(bytes.NewReader(make([]byte, 1<<20))))
	req.ContentLength = -1
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("chunked oversized: status=%d, want 413", rec.Code)
	}
}

func TestBodyLimitRouteOverrides(t *testing.T) {
	cases := []struct {
		method, path string
		want         int64
	}{
		{"POST", "/auth/login", DefaultBodyLimit},
		{"PUT", "/api/profile/avatar", AvatarBodyLimit},
		{"POST", "/locations/batch", BatchBodyLimit},
		{"POST", "/locations", DefaultBodyLimit},
	}
	for _, c := range cases {
		r := httptest.NewRequest(c.method, c.path, nil)
		if got := BodyLimitFor(r); got != c.want {
			t.Errorf("%s %s: limit=%d want %d", c.method, c.path, got, c.want)
		}
	}
	// A near-limit avatar and batch are accepted.
	h := limitedHandler()
	for _, p := range []struct {
		m, path string
		n       int
	}{{"PUT", "/api/profile/avatar", 5 << 20}, {"POST", "/locations/batch", 900 << 10}} {
		req := httptest.NewRequest(p.m, p.path, bytes.NewReader(make([]byte, p.n)))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("%s %s (%d bytes): status=%d", p.m, p.path, p.n, rec.Code)
		}
	}
}
