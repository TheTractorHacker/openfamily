package middleware

import (
	"bufio"
	"compress/gzip"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
)

// compressMinSize is the smallest body worth compressing: below it the gzip
// header and the CPU cost outweigh the saving.
const compressMinSize = 512

var gzipPool = sync.Pool{New: func() any {
	w, _ := gzip.NewWriterLevel(nil, gzip.BestSpeed)
	return w
}}

// Compress gzips JSON and text responses when the client sent
// Accept-Encoding: gzip. It is deliberately conservative:
//
//   - only application/json, text/* and application/problem+json bodies
//   - never WebSocket upgrades, server-sent events, Range requests, HEAD,
//     responses that already carry a Content-Encoding, or tiny bodies
//   - 304/204 responses pass through untouched
//
// Behind Caddy (`encode gzip`) the proxy leaves an already-encoded response
// alone, so this only changes anything for direct or Cloudflare-tunnel
// deployments that do not compress. Vary: Accept-Encoding is always added.
func Compress(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !acceptsGzip(r) || r.Method == http.MethodHead || r.Header.Get("Range") != "" ||
			r.Header.Get("Upgrade") != "" || strings.HasPrefix(r.URL.Path, "/ws/") || strings.HasPrefix(r.URL.Path, "/push/") ||
			r.URL.Path == "/api/admin/ws" {
			next.ServeHTTP(w, r)
			return
		}
		cw := &compressWriter{ResponseWriter: w}
		defer cw.finish()
		next.ServeHTTP(cw, r)
	})
}

func acceptsGzip(r *http.Request) bool {
	for _, part := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		name, q, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
			continue
		}
		q = strings.ReplaceAll(strings.TrimSpace(q), " ", "")
		return q != "q=0" && q != "q=0.0"
	}
	return false
}

func compressibleType(ct string) bool {
	ct = strings.ToLower(ct)
	return strings.HasPrefix(ct, "application/json") || strings.HasPrefix(ct, "application/problem+json") ||
		strings.HasPrefix(ct, "text/")
}

type compressWriter struct {
	http.ResponseWriter
	status   int
	buf      []byte // held until we know whether the body is big enough
	decided  bool
	gz       *gzip.Writer
	wroteHdr bool
}

func (c *compressWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

func (c *compressWriter) WriteHeader(code int) {
	if c.status == 0 {
		c.status = code
	}
	// Informational and bodyless statuses go straight through.
	if code < 200 || code == http.StatusNoContent || code == http.StatusNotModified {
		c.decided = true
		c.writeHeaderOnce(code)
	}
}

func (c *compressWriter) writeHeaderOnce(code int) {
	if c.wroteHdr {
		return
	}
	c.wroteHdr = true
	c.Header().Add("Vary", "Accept-Encoding")
	c.ResponseWriter.WriteHeader(code)
}

func (c *compressWriter) Write(p []byte) (int, error) {
	if c.status == 0 {
		c.status = http.StatusOK
	}
	if c.decided {
		if c.gz != nil {
			return c.gz.Write(p)
		}
		return c.ResponseWriter.Write(p)
	}
	h := c.Header()
	if h.Get("Content-Encoding") != "" || !compressibleType(h.Get("Content-Type")) && h.Get("Content-Type") != "" {
		c.decided = true
		c.writeHeaderOnce(c.status)
		return c.ResponseWriter.Write(p)
	}
	c.buf = append(c.buf, p...)
	if len(c.buf) >= compressMinSize {
		c.startGzip()
	}
	return len(p), nil
}

func (c *compressWriter) startGzip() {
	c.decided = true
	h := c.Header()
	if h.Get("Content-Type") == "" {
		h.Set("Content-Type", http.DetectContentType(c.buf))
	}
	if !compressibleType(h.Get("Content-Type")) {
		c.writeHeaderOnce(c.status)
		_, _ = c.ResponseWriter.Write(c.buf)
		c.buf = nil
		return
	}
	h.Set("Content-Encoding", "gzip")
	h.Del("Content-Length")
	c.writeHeaderOnce(c.status)
	gz := gzipPool.Get().(*gzip.Writer)
	gz.Reset(c.ResponseWriter)
	c.gz = gz
	_, _ = gz.Write(c.buf)
	c.buf = nil
}

// finish flushes whatever is pending: a small body goes out as-is, a gzip
// stream is closed.
func (c *compressWriter) finish() {
	if c.gz != nil {
		_ = c.gz.Close()
		gzipPool.Put(c.gz)
		c.gz = nil
		return
	}
	if !c.decided {
		if c.status == 0 {
			c.status = http.StatusOK
		}
		c.writeHeaderOnce(c.status)
		if len(c.buf) > 0 {
			_, _ = c.ResponseWriter.Write(c.buf)
		}
	}
}

// Flush is for streaming handlers; it commits the decision first.
func (c *compressWriter) Flush() {
	if !c.decided {
		if len(c.buf) >= compressMinSize {
			c.startGzip()
		} else {
			c.decided = true
			if c.status == 0 {
				c.status = http.StatusOK
			}
			c.writeHeaderOnce(c.status)
			if len(c.buf) > 0 {
				_, _ = c.ResponseWriter.Write(c.buf)
				c.buf = nil
			}
		}
	}
	if c.gz != nil {
		_ = c.gz.Flush()
	}
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (c *compressWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := c.ResponseWriter.(http.Hijacker); ok {
		c.decided = true
		return h.Hijack()
	}
	return nil, nil, errors.New("hijack not supported")
}
