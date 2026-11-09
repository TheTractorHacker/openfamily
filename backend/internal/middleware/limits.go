package middleware

import (
	"net/http"
	"strings"
)

// Request body ceilings (BSEC-005). JSON API bodies are tiny; the exceptions
// are the avatar upload and the offline location backfill.
const (
	// DefaultBodyLimit applies to every route not listed in BodyLimitFor.
	DefaultBodyLimit int64 = 64 << 10
	// AvatarBodyLimit leaves headroom over the handler's own 5 MiB image cap
	// (which stays the authoritative check and returns its specific error).
	AvatarBodyLimit int64 = 6 << 20
	// BatchBodyLimit matches the batch ingest handler (500 points).
	BatchBodyLimit int64 = 1 << 20
	// E2EEBatchBodyLimit matches the Private-circle item batch and the server
	// device's ingest handlers (each enforces its own, equal cap). Without this the
	// 64 KiB default cut them off first: a busy drive made the server's batch too
	// big, every retry was the same batch, and nothing reached the map.
	E2EEBatchBodyLimit int64 = 2 << 20
	// E2EEBlobBodyLimit matches the sealed chat photo handler (5 MiB + overhead).
	E2EEBlobBodyLimit int64 = 6 << 20
)

// BodyLimitFor returns the maximum request body size for a request.
func BodyLimitFor(r *http.Request) int64 {
	p := r.URL.Path
	switch {
	case r.Method == http.MethodPut && p == "/api/profile/avatar":
		return AvatarBodyLimit
	case p == "/locations/batch":
		return BatchBodyLimit
	case r.Method == http.MethodPost && p == "/internal/e2ee/ingest":
		return E2EEBatchBodyLimit
	case r.Method == http.MethodPost && strings.HasPrefix(p, "/circles/") && strings.HasSuffix(p, "/e2ee/batch"):
		return E2EEBatchBodyLimit
	case r.Method == http.MethodPost && strings.HasPrefix(p, "/circles/") && strings.HasSuffix(p, "/e2ee/blobs"):
		return E2EEBlobBodyLimit
	}
	return DefaultBodyLimit
}

// LimitBody caps request bodies. A declared Content-Length over the limit is
// refused with 413 before the handler runs; chunked or lying clients are cut
// off by http.MaxBytesReader (the handler's body read then fails). The
// ResponseWriter is passed through unwrapped so WebSocket upgrades and
// http.ResponseController keep working.
func LimitBody(limit func(*http.Request) int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Body == nil || r.Body == http.NoBody {
				next.ServeHTTP(w, r)
				return
			}
			max := limit(r)
			if r.ContentLength > max {
				http.Error(w, `{"error":"request body too large"}`, http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, max)
			next.ServeHTTP(w, r)
		})
	}
}
