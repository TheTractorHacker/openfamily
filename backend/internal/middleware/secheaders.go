package middleware

import (
	"net/http"
	"strings"
)

// SecurityHeaders sets baseline hardening headers on every response (BSEC-014).
// Handlers and the admin SPA / public share page override individual headers
// (they call Header().Set after this runs). It never wraps the ResponseWriter,
// so WebSocket upgrades and http.ResponseController are unaffected.
//
//   - nosniff: a JSON/avatar response is never reinterpreted as HTML or script
//   - CSP default-src 'none'; frame-ancestors 'none': API responses are data,
//     never documents, and cannot be framed
//   - X-Frame-Options / Referrer-Policy: legacy framing guard, no URL leakage
//   - HSTS, only when the request arrived over TLS (directly or via a proxy
//     that says so)
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Permissions-Policy", "geolocation=(), camera=(), microphone=()")
		if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		next.ServeHTTP(w, r)
	})
}

// NoStore marks authenticated responses uncacheable by browsers and shared
// caches. Handlers that deliberately allow private caching (avatars) set their
// own Cache-Control afterwards.
func NoStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
