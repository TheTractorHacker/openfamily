package middleware

import (
	"net"
	"net/http"
	"strings"
)

// DefaultProxyNets are trusted when TLS_BEHIND_PROXY=true and TRUSTED_PROXIES
// is unset: loopback and the private ranges Docker/Compose networks are carved
// from. In the shipped compose file the API port is only exposed to the Caddy
// container on that network, so every peer in these ranges is the proxy. If
// you publish the API port directly, set TRUSTED_PROXIES explicitly.
var DefaultProxyNets = mustParseCIDRs("127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")

func mustParseCIDRs(cidrs ...string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			panic(err)
		}
		out = append(out, n)
	}
	return out
}

// ParseTrustedProxies parses a comma-separated list of CIDRs and bare IPs.
// Empty or "none" yields no trusted proxies.
func ParseTrustedProxies(s string) ([]*net.IPNet, error) {
	s = strings.TrimSpace(s)
	if s == "" || strings.EqualFold(s, "none") {
		return nil, nil
	}
	var out []*net.IPNet
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.Contains(part, "/") {
			ip := net.ParseIP(part)
			if ip == nil {
				return nil, &net.ParseError{Type: "IP address", Text: part}
			}
			bits := 128
			if ip.To4() != nil {
				bits = 32
			}
			out = append(out, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
			continue
		}
		_, n, err := net.ParseCIDR(part)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, nil
}

func ipTrusted(ip net.IP, trusted []*net.IPNet) bool {
	for _, n := range trusted {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// ResolveClientIP returns the client address for a request. Forwarding headers
// are honoured only when the TCP peer (remoteAddr) is a trusted proxy, and
// then only the X-Forwarded-For chain is used, read right to left: trusted
// proxies are skipped and the first untrusted address is the client. Anything
// further left is client-supplied and ignored. True-Client-IP and X-Real-IP
// are never trusted. With no trusted proxies this is just the peer address.
func ResolveClientIP(remoteAddr string, xffValues []string, trusted []*net.IPNet) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	peer := net.ParseIP(host)
	if peer == nil || len(trusted) == 0 || !ipTrusted(peer, trusted) {
		return host
	}
	var chain []string
	for _, v := range xffValues {
		for _, p := range strings.Split(v, ",") {
			if p = strings.TrimSpace(p); p != "" {
				chain = append(chain, p)
			}
		}
	}
	for i := len(chain) - 1; i >= 0; i-- {
		ip := net.ParseIP(chain[i])
		if ip == nil {
			// Garbage entry: stop; do not skip past something unparseable.
			return host
		}
		if !ipTrusted(ip, trusted) {
			return ip.String()
		}
	}
	return host
}

// ClientIP rewrites r.RemoteAddr to the resolved client address (see
// ResolveClientIP) so downstream code, audit logging and rate limiting all see
// one value. It replaces chi's RealIP, which trusted spoofable headers from
// any peer.
func ClientIP(trusted []*net.IPNet) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.RemoteAddr = ResolveClientIP(r.RemoteAddr, r.Header.Values("X-Forwarded-For"), trusted)
			next.ServeHTTP(w, r)
		})
	}
}
