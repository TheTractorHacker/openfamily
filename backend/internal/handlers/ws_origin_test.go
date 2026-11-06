package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// SEC-009: cross-site WebSocket hijacking. The stream authenticates with a
// Bearer header or the Sec-WebSocket-Protocol token (never a cookie), and the
// handshake additionally enforces an Origin policy built from ALLOWED_ORIGIN:
//
//   - ALLOWED_ORIGIN empty: same-origin only (Origin host must equal the
//     request Host); every foreign browser origin is rejected.
//   - ALLOWED_ORIGIN set: that origin (scheme://host) is also accepted.
//   - No Origin header (native/mobile clients, which are not browsers and send
//     none): accepted, because auth does not rely on ambient credentials.
//
// The test drives the same AcceptOptions the real handlers use.

func originHandler(s *Server) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: s.wsOriginPatterns()})
		if err != nil {
			return
		}
		_ = c.Close(websocket.StatusNormalClosure, "")
	})
}

func dialWithOrigin(t *testing.T, srv *httptest.Server, origin string) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	h := http.Header{}
	if origin != "" {
		h.Set("Origin", origin)
	}
	c, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), &websocket.DialOptions{HTTPHeader: h})
	if err == nil {
		_ = c.CloseNow()
		return nil
	}
	if resp != nil && resp.StatusCode != http.StatusForbidden {
		t.Fatalf("origin %q: rejected with %d, want 403", origin, resp.StatusCode)
	}
	return err
}

func TestWSOriginEmptyAllowedOriginIsSameOriginOnly(t *testing.T) {
	s := &Server{}
	if got := s.wsOriginPatterns(); got != nil {
		t.Fatalf("patterns=%v, want nil (library default: same origin only)", got)
	}
	srv := httptest.NewServer(originHandler(s))
	defer srv.Close()

	if err := dialWithOrigin(t, srv, ""); err != nil {
		t.Fatalf("native client without Origin must connect: %v", err)
	}
	if err := dialWithOrigin(t, srv, srv.URL); err != nil {
		t.Fatalf("same-origin browser must connect: %v", err)
	}
	for _, foreign := range []string{"https://evil.example", "http://evil.example:8080", "null", "https://127.0.0.1.evil.example"} {
		if err := dialWithOrigin(t, srv, foreign); err == nil {
			t.Fatalf("foreign origin %q must be rejected when ALLOWED_ORIGIN is empty", foreign)
		}
	}
}

func TestWSOriginConfiguredAllowsOnlyThatOrigin(t *testing.T) {
	s := &Server{AllowedOrigin: "https://app.example.com"}
	srv := httptest.NewServer(originHandler(s))
	defer srv.Close()

	if err := dialWithOrigin(t, srv, "https://app.example.com"); err != nil {
		t.Fatalf("configured origin must connect: %v", err)
	}
	for _, foreign := range []string{"https://evil.example", "http://app.example.com", "https://app.example.com.evil.example", "https://sub.app.example.com"} {
		if err := dialWithOrigin(t, srv, foreign); err == nil {
			t.Fatalf("origin %q must be rejected (allowed: https://app.example.com)", foreign)
		}
	}
	if err := dialWithOrigin(t, srv, ""); err != nil {
		t.Fatalf("native client without Origin must connect: %v", err)
	}
}

// The token is only accepted from the Authorization header or the
// Sec-WebSocket-Protocol subprotocol; cookies and the query string are never
// read, so a cross-site page cannot ride ambient credentials.
func TestWSTokenNeverFromCookieOrQuery(t *testing.T) {
	r := httptest.NewRequest("GET", "/ws/stream?token=abc&access_token=abc", nil)
	r.AddCookie(&http.Cookie{Name: "token", Value: "abc"})
	r.AddCookie(&http.Cookie{Name: "access_token", Value: "abc"})
	if bearerToken(r) != "" {
		t.Fatal("bearerToken read a non-header credential")
	}
	if tok, sp := websocketSubprotocolToken(r); tok != "" || sp != "" {
		t.Fatalf("subprotocol token from cookie/query: %q %q", tok, sp)
	}
}
