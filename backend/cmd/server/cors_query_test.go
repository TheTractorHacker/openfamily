package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A browser (the admin panel on another origin) sends a preflight before the
// HTTP QUERY method because it is not CORS-safelisted. The server must allow
// it, and If-None-Match for conditional requests.
func TestCORSPreflightAllowsQueryAndConditionalHeaders(t *testing.T) {
	h := cors("https://admin.example")(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Fatal("preflight must not reach the handler")
	}))
	req := httptest.NewRequest(http.MethodOptions, "/family/history/query", nil)
	req.Header.Set("Origin", "https://admin.example")
	req.Header.Set("Access-Control-Request-Method", "QUERY")
	req.Header.Set("Access-Control-Request-Headers", "authorization, content-type, if-none-match")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight status %d", rec.Code)
	}
	if !strings.Contains(rec.Header().Get("Access-Control-Allow-Methods"), "QUERY") {
		t.Fatalf("QUERY not allowed: %v", rec.Header())
	}
	if !strings.Contains(rec.Header().Get("Access-Control-Allow-Headers"), "If-None-Match") {
		t.Fatalf("If-None-Match not allowed: %v", rec.Header())
	}
	if !strings.Contains(rec.Header().Get("Access-Control-Expose-Headers"), "ETag") {
		t.Fatal("ETag not exposed")
	}
}
