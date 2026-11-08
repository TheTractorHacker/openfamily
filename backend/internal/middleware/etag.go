package middleware

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strings"
)

// etagMaxBody caps how much of a response is buffered to compute an ETag.
// Larger responses stream through unchanged.
const etagMaxBody = 1 << 20

// ETag adds a weak validator to successful JSON GET responses and answers
// 304 Not Modified when the client's If-None-Match matches. The hash is of
// the final body, so it is exact for any handler without per-endpoint code;
// the saving is the response bytes on the (mobile) network, not the query.
//
// Safe for per-user data: a validator only ever matches a body the same
// caller just received for the same URL, and requests carry their own
// Authorization, so a 304 reveals nothing the 200 would not.
// Responses that already set an ETag, non-JSON bodies (photos, files),
// errors and bodies over etagMaxBody are not touched.
func ETag(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			next.ServeHTTP(w, r)
			return
		}
		ew := &etagWriter{ResponseWriter: w}
		next.ServeHTTP(ew, r)
		ew.finish(r)
	})
}

type etagWriter struct {
	http.ResponseWriter
	status      int
	buf         []byte
	passthrough bool
	committed   bool
}

func (e *etagWriter) Unwrap() http.ResponseWriter { return e.ResponseWriter }

func (e *etagWriter) WriteHeader(code int) {
	if e.status == 0 {
		e.status = code
	}
	if code != http.StatusOK {
		e.startPassthrough()
	}
}

func (e *etagWriter) startPassthrough() {
	if e.committed {
		return
	}
	e.passthrough, e.committed = true, true
	if e.status == 0 {
		e.status = http.StatusOK
	}
	e.ResponseWriter.WriteHeader(e.status)
	if len(e.buf) > 0 {
		_, _ = e.ResponseWriter.Write(e.buf)
		e.buf = nil
	}
}

func (e *etagWriter) Write(p []byte) (int, error) {
	if e.status == 0 {
		e.status = http.StatusOK
	}
	if e.passthrough {
		return e.ResponseWriter.Write(p)
	}
	h := e.Header()
	if !strings.HasPrefix(h.Get("Content-Type"), "application/json") || h.Get("ETag") != "" ||
		h.Get("Content-Encoding") != "" || len(e.buf)+len(p) > etagMaxBody {
		e.startPassthrough()
		return e.ResponseWriter.Write(p)
	}
	e.buf = append(e.buf, p...)
	return len(p), nil
}

// Flush forces streaming from here on.
func (e *etagWriter) Flush() {
	e.startPassthrough()
	if f, ok := e.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (e *etagWriter) finish(r *http.Request) {
	if e.committed {
		return
	}
	if e.status == 0 {
		e.status = http.StatusOK
	}
	if e.status == http.StatusOK && len(e.buf) > 0 {
		sum := sha256.Sum256(e.buf)
		tag := `W/"` + base64.RawURLEncoding.EncodeToString(sum[:12]) + `"`
		h := e.Header()
		h.Set("ETag", tag)
		h.Add("Vary", "Authorization")
		if etagMatches(r.Header.Get("If-None-Match"), tag) {
			h.Del("Content-Type")
			h.Del("Content-Length")
			e.ResponseWriter.WriteHeader(http.StatusNotModified)
			return
		}
	}
	e.ResponseWriter.WriteHeader(e.status)
	if len(e.buf) > 0 {
		_, _ = e.ResponseWriter.Write(e.buf)
	}
}

// etagMatches implements weak comparison of an If-None-Match list.
func etagMatches(header, tag string) bool {
	header = strings.TrimSpace(header)
	if header == "" {
		return false
	}
	if header == "*" {
		return true
	}
	want := strings.TrimPrefix(tag, "W/")
	for _, part := range strings.Split(header, ",") {
		if strings.TrimPrefix(strings.TrimSpace(part), "W/") == want {
			return true
		}
	}
	return false
}
