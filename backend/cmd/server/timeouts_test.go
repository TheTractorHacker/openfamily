package main

import (
	"context"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	mid "github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func startTestServer(t *testing.T, h http.Handler, to serverTimeouts) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := newHTTPServer("", h, to)
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return ln.Addr().String()
}

func TestDefaultServerTimeoutsAreSet(t *testing.T) {
	s := newHTTPServer(":0", http.NotFoundHandler(), defaultServerTimeouts)
	if s.ReadHeaderTimeout == 0 || s.ReadTimeout == 0 || s.WriteTimeout == 0 || s.IdleTimeout == 0 {
		t.Fatalf("a server timeout is unset: %+v", s)
	}
}

// A WebSocket must keep working long after the server's Read/Write timeouts
// would have fired on an ordinary request.
func TestServerTimeoutsDoNotBreakWebSockets(t *testing.T) {
	to := serverTimeouts{ReadHeader: 200 * time.Millisecond, Read: 200 * time.Millisecond, Write: 200 * time.Millisecond, Idle: 200 * time.Millisecond}
	addr := startTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		for {
			typ, b, err := c.Read(r.Context())
			if err != nil {
				return
			}
			if err := c.Write(r.Context(), typ, b); err != nil {
				return
			}
		}
	}), to)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws://"+addr, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	for i := 0; i < 4; i++ {
		time.Sleep(250 * time.Millisecond) // longer than every timeout
		if err := c.Write(ctx, websocket.MessageText, []byte("ping")); err != nil {
			t.Fatalf("write after %d idle periods: %v", i+1, err)
		}
		if _, b, err := c.Read(ctx); err != nil || string(b) != "ping" {
			t.Fatalf("read after %d idle periods: %q %v", i+1, b, err)
		}
	}
}

// A client that dribbles a request header is dropped at ReadHeaderTimeout.
func TestSlowHeaderClientIsDropped(t *testing.T) {
	to := serverTimeouts{ReadHeader: 150 * time.Millisecond, Read: time.Second, Write: time.Second, Idle: time.Second}
	addr := startTestServer(t, http.NotFoundHandler(), to)
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = conn.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\nX-Slow: "))
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 512)
	start := time.Now()
	n, _ := conn.Read(buf) // server answers 408 (or just closes) once the header deadline passes
	if time.Since(start) > time.Second {
		t.Fatalf("slow client held the connection for %v", time.Since(start))
	}
	if n > 0 && !strings.Contains(string(buf[:n]), "408") && !strings.Contains(string(buf[:n]), "400") {
		t.Fatalf("unexpected response: %q", buf[:n])
	}
}

func TestResolveTrustedProxies(t *testing.T) {
	cases := []struct {
		name       string
		cfg        config.Config
		wantTrust  bool // is 172.18.0.2 trusted?
		wantPublic bool // is 203.0.113.9 trusted?
	}{
		{"default: nobody", config.Config{}, false, false},
		{"behind proxy: private ranges", config.Config{TLSBehindProxy: true}, true, false},
		{"explicit list wins", config.Config{TLSBehindProxy: true, TrustedProxies: "203.0.113.0/24"}, false, true},
		{"none forces nobody", config.Config{TLSBehindProxy: true, TrustedProxies: "none"}, false, false},
	}
	for _, c := range cases {
		nets, err := resolveTrustedProxies(c.cfg)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		got := func(ip string) bool {
			return mid.ResolveClientIP("172.18.0.2:1", nil, nets) == "172.18.0.2" && func() bool {
				return mid.ResolveClientIP(ip+":1", []string{"198.51.100.7"}, nets) == "198.51.100.7"
			}()
		}
		if got("172.18.0.2") != c.wantTrust {
			t.Errorf("%s: private-peer trust=%v want %v", c.name, got("172.18.0.2"), c.wantTrust)
		}
		if got("203.0.113.9") != c.wantPublic {
			t.Errorf("%s: public-peer trust=%v want %v", c.name, got("203.0.113.9"), c.wantPublic)
		}
	}
	if _, err := resolveTrustedProxies(config.Config{TrustedProxies: "bogus"}); err == nil {
		t.Fatal("invalid TRUSTED_PROXIES accepted")
	}
}
