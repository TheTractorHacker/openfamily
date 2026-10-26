package geocode

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"syscall"
	"time"
)

var specialNets = mustCIDRs(
	"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24",
	"198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4",
	"64:ff9b::/96", "100::/64", "2001:db8::/32",
)

func mustCIDRs(s ...string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(s))
	for _, c := range s {
		out = append(out, netip.MustParsePrefix(c))
	}
	return out
}

// isInternal reports whether ip is loopback, private, link-local, multicast,
// unspecified, or otherwise not a normal public unicast address.
func isInternal(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true
	}
	addr = addr.Unmap()
	if addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast() ||
		addr.IsLinkLocalMulticast() || addr.IsMulticast() || addr.IsUnspecified() {
		return true
	}
	for _, p := range specialNets {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// dialControl runs after DNS resolution with the concrete IP about to be
// dialed, so DNS rebinding cannot slip a private address past the startup
// check. https targets must be public unless allowPrivate; cleartext http
// targets must be internal (never send addresses over the open internet).
func dialControl(allowPrivate, cleartext bool) func(network, address string, c syscall.RawConn) error {
	return func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return errRefusedTarget
		}
		ip := net.ParseIP(host)
		if ip == nil {
			return errRefusedTarget
		}
		internal := isInternal(ip)
		if internal && !allowPrivate {
			return errRefusedTarget
		}
		if cleartext && !internal {
			return errRefusedTarget
		}
		return nil
	}
}

var errRefusedTarget = errors.New("geocoder target address refused")

// parseBaseURL validates GEOCODER_URL.
func parseBaseURL(raw string, allowPrivate bool) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return nil, errors.New("GEOCODER_URL is not a valid absolute URL")
	}
	if u.User != nil {
		return nil, errors.New("GEOCODER_URL must not contain credentials")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("GEOCODER_URL must not contain a query or fragment")
	}
	host := u.Hostname()
	switch u.Scheme {
	case "https":
	case "http":
		if !allowPrivate {
			return nil, errors.New("GEOCODER_URL must use https (http is only allowed for a private host with GEOCODER_ALLOW_PRIVATE=true)")
		}
	default:
		return nil, errors.New("GEOCODER_URL must use https")
	}
	if strings.EqualFold(host, "localhost") || strings.HasSuffix(strings.ToLower(host), ".localhost") {
		if !allowPrivate {
			return nil, errors.New("GEOCODER_URL points at a private/loopback host; set GEOCODER_ALLOW_PRIVATE=true for a self-hosted instance")
		}
	}
	if ip := net.ParseIP(host); ip != nil {
		internal := isInternal(ip)
		if internal && !allowPrivate {
			return nil, errors.New("GEOCODER_URL points at a private/loopback address; set GEOCODER_ALLOW_PRIVATE=true for a self-hosted instance")
		}
		if u.Scheme == "http" && !internal {
			return nil, errors.New("GEOCODER_URL must use https for public hosts")
		}
	} else if !allowPrivate {
		// Best-effort early check; the dial-time guard is authoritative.
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host); err == nil {
			for _, a := range addrs {
				if isInternal(a.IP) {
					return nil, fmt.Errorf("GEOCODER_URL host resolves to a private address; set GEOCODER_ALLOW_PRIVATE=true for a self-hosted instance")
				}
			}
		}
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u, nil
}
