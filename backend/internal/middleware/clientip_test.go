package middleware

import (
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func mustTrusted(t *testing.T, s string) []*net.IPNet {
	t.Helper()
	n, err := ParseTrustedProxies(s)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestResolveClientIP(t *testing.T) {
	proxies := mustTrusted(t, "172.16.0.0/12, 10.1.2.3")
	cases := []struct {
		name    string
		remote  string
		xff     []string
		trusted []*net.IPNet
		want    string
	}{
		{"no trust: header ignored", "203.0.113.9:5555", []string{"1.2.3.4"}, nil, "203.0.113.9"},
		{"untrusted peer cannot spoof", "203.0.113.9:5555", []string{"1.2.3.4"}, proxies, "203.0.113.9"},
		{"trusted proxy: client from xff", "172.18.0.2:4000", []string{"198.51.100.7"}, proxies, "198.51.100.7"},
		{"client-forged left entry ignored", "172.18.0.2:4000", []string{"6.6.6.6, 198.51.100.7"}, proxies, "198.51.100.7"},
		{"chain through two trusted proxies", "172.18.0.2:4000", []string{"198.51.100.7, 10.1.2.3"}, proxies, "198.51.100.7"},
		{"multiple header lines", "172.18.0.2:4000", []string{"6.6.6.6", "198.51.100.7"}, proxies, "198.51.100.7"},
		{"trusted peer, no xff", "172.18.0.2:4000", nil, proxies, "172.18.0.2"},
		{"garbage rightmost entry", "172.18.0.2:4000", []string{"198.51.100.7, not-an-ip"}, proxies, "172.18.0.2"},
		{"ipv6 client", "172.18.0.2:4000", []string{"2001:db8::1"}, proxies, "2001:db8::1"},
	}
	for _, c := range cases {
		if got := ResolveClientIP(c.remote, c.xff, c.trusted); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestClientIPMiddlewareIgnoresSpoofedHeadersFromUntrustedPeer(t *testing.T) {
	var seen string
	h := ClientIP(nil)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { seen = r.RemoteAddr }))
	req := httptest.NewRequest(http.MethodPost, "/auth/register", nil)
	req.RemoteAddr = "203.0.113.9:1234"
	req.Header.Set("X-Real-IP", "9.9.9.9")
	req.Header.Set("True-Client-IP", "8.8.8.8")
	req.Header.Set("X-Forwarded-For", "7.7.7.7")
	h.ServeHTTP(httptest.NewRecorder(), req)
	if seen != "203.0.113.9" {
		t.Fatalf("RemoteAddr=%q, want the real peer", seen)
	}
}

func TestParseTrustedProxies(t *testing.T) {
	if n, err := ParseTrustedProxies(""); err != nil || n != nil {
		t.Fatal("empty should mean none")
	}
	if n, err := ParseTrustedProxies("none"); err != nil || n != nil {
		t.Fatal("'none' should mean none")
	}
	if _, err := ParseTrustedProxies("300.1.1.1"); err == nil {
		t.Fatal("bad IP accepted")
	}
	if _, err := ParseTrustedProxies("10.0.0.0/99"); err == nil {
		t.Fatal("bad CIDR accepted")
	}
	n, err := ParseTrustedProxies("10.0.0.0/8,::1")
	if err != nil || len(n) != 2 {
		t.Fatalf("got %v %v", n, err)
	}
}
