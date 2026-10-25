package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSecurityHeadersOnAPIResponses(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{}`)) })
	for _, path := range []string{"/healthz", "/me"} {
		h := SecurityHeaders(NoStore(ok))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		want := map[string]string{
			"X-Content-Type-Options":  "nosniff",
			"X-Frame-Options":         "DENY",
			"Referrer-Policy":         "no-referrer",
			"Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
			"Cache-Control":           "no-store",
		}
		for k, v := range want {
			if got := rec.Header().Get(k); got != v {
				t.Errorf("%s %s = %q, want %q", path, k, got, v)
			}
		}
		if rec.Header().Get("Strict-Transport-Security") != "" {
			t.Errorf("%s: HSTS set on plain HTTP", path)
		}
	}
}

func TestSecurityHeadersHSTSOverTLSAndOverride(t *testing.T) {
	h := SecurityHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'") // e.g. admin SPA
	}))
	req := httptest.NewRequest(http.MethodGet, "/admin", nil)
	req.Header.Set("X-Forwarded-Proto", "https")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Strict-Transport-Security") == "" {
		t.Error("HSTS missing for proxied HTTPS request")
	}
	if rec.Header().Get("Content-Security-Policy") != "default-src 'self'" {
		t.Error("handler could not override the default CSP")
	}
}
