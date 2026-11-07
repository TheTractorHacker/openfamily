package backupsettings

import (
	"errors"
	"net"
	"strings"
	"syscall"
)

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

func mustCIDR(c string) *net.IPNet { _, n, _ := net.ParseCIDR(c); return n }

var (
	// Understood IPv6 transition forms whose embedded IPv4 address is decoded.
	// ::ffff:0:0/96 (IPv4-mapped) is listed for completeness: CheckIP converts
	// such addresses with To4() first, so every path sees the same IPv4 address.
	transitionNets = []*net.IPNet{
		mustCIDR("::ffff:0:0/96"), mustCIDR("64:ff9b::/96"), mustCIDR("2002::/16"), mustCIDR("2001::/32"), mustCIDR("::/96"),
	}
	// RFC 8215 local-use NAT64: the embedded-address layout is ambiguous, so it
	// is refused always, even with allowPrivate.
	localNAT64 = mustCIDR("64:ff9b:1::/48")
	globalV6   = mustCIDR("2000::/3")
	docV6      = mustCIDR("2001:db8::/32")
	ulaV6      = mustCIDR("fc00::/7")
)

// embeddedIPv4 extracts the IPv4 address of an understood transition address:
// IPv4-mapped (::ffff:a.b.c.d), NAT64 64:ff9b::/96, 6to4 (2002::/16), Teredo
// (2001::/32: server and de-obfuscated client) and IPv4-compatible (::/96).
func embeddedIPv4(ip net.IP) []net.IP {
	b := ip.To16()
	if b == nil {
		return nil
	}
	v4 := func(a, c, d, e byte) net.IP { return net.IPv4(a, c, d, e).To4() }
	last4 := v4(b[12], b[13], b[14], b[15])
	switch {
	case transitionNets[0].Contains(ip), transitionNets[1].Contains(ip), transitionNets[4].Contains(ip):
		return []net.IP{last4}
	case transitionNets[2].Contains(ip):
		return []net.IP{v4(b[2], b[3], b[4], b[5])}
	case transitionNets[3].Contains(ip):
		return []net.IP{v4(b[4], b[5], b[6], b[7]), v4(b[12]^0xff, b[13]^0xff, b[14]^0xff, b[15]^0xff)}
	}
	return nil
}

func checkV4(ip net.IP, allowPrivate bool) error {
	switch {
	case ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast():
		return errors.New("link-local, multicast and unspecified addresses are not allowed (cloud metadata endpoints live there)")
	case ip.Equal(net.ParseIP("100.100.100.200")):
		return errors.New("cloud metadata addresses are not allowed")
	}
	if !allowPrivate && (ip.IsLoopback() || ip.IsPrivate() || cgnat.Contains(ip)) {
		return errors.New("private, loopback and shared addresses are refused; enable \"Allow private network\" if your S3 server is on your own network")
	}
	return nil
}

// CheckIP applies the S3 endpoint address policy (used at save time, after DNS
// resolution and at dial time, so all paths see the same decision).
//
// IPv4 (including IPv4-mapped IPv6, normalised with To4 first): link-local
// (cloud metadata), multicast and unspecified are always refused; loopback,
// RFC 1918 and CGNAT only with allowPrivate.
//
// IPv6 is an allowlist. Understood transition forms (NAT64 64:ff9b::/96, 6to4,
// Teredo, IPv4-compatible) are refused unless allowPrivate, and their embedded
// IPv4 address is checked with the IPv4 rules. 64:ff9b:1::/48 is always
// refused. Otherwise only global unicast 2000::/3 (minus documentation
// 2001:db8::/32) is accepted; with allowPrivate also ULA fc00::/7 and ::1.
// Everything else (link-local, multicast, unspecified, any range not listed)
// is refused.
func CheckIP(ip net.IP, allowPrivate bool) error {
	if ip == nil {
		return errors.New("invalid address")
	}
	if v4 := ip.To4(); v4 != nil {
		return checkV4(v4, allowPrivate)
	}
	ip = ip.To16()
	if ip == nil {
		return errors.New("invalid address")
	}
	if ip.Equal(net.ParseIP("fd00:ec2::254")) {
		return errors.New("cloud metadata addresses are not allowed")
	}
	if localNAT64.Contains(ip) {
		return errors.New("local-use NAT64 addresses (64:ff9b:1::/48) are not allowed")
	}
	if ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
		return errors.New("link-local, multicast and unspecified addresses are not allowed (cloud metadata endpoints live there)")
	}
	for _, n := range transitionNets {
		if n.Contains(ip) {
			for _, e := range embeddedIPv4(ip) {
				if err := checkV4(e, allowPrivate); err != nil {
					return err
				}
			}
			if !allowPrivate {
				return errors.New("IPv6 transition addresses (NAT64, 6to4, Teredo, IPv4-compatible) are refused; enable \"Allow private network\" if you really need one")
			}
			return nil
		}
	}
	switch {
	case ip.Equal(net.IPv6loopback):
		if allowPrivate {
			return nil
		}
		return errors.New("loopback is refused; enable \"Allow private network\" if your S3 server is on this machine")
	case globalV6.Contains(ip) && !docV6.Contains(ip):
		return nil
	case ulaV6.Contains(ip):
		if allowPrivate {
			return nil
		}
		return errors.New("private IPv6 addresses are refused; enable \"Allow private network\" if your S3 server is on your own network")
	}
	return errors.New("this IPv6 address range is not allowed")
}

// CheckHost checks a host name or literal IP (no DNS lookup).
func CheckHost(host string, allowPrivate bool) error {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	if h == "metadata.google.internal" || h == "metadata" || h == "instance-data" {
		return errors.New("cloud metadata host names are not allowed")
	}
	if ip := net.ParseIP(h); ip != nil {
		return CheckIP(ip, allowPrivate)
	}
	if !allowPrivate && (h == "localhost" || strings.HasSuffix(h, ".localhost")) {
		return errors.New("localhost is refused; enable \"Allow private network\" if your S3 server is on this machine")
	}
	return nil
}

// GuardedDialControl is a net.Dialer.Control hook that re-checks the ADDRESS
// ACTUALLY DIALED (after DNS resolution), defeating DNS rebinding and names
// that resolve to metadata or, when not allowed, private addresses.
func GuardedDialControl(allowPrivate bool) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		return CheckIP(net.ParseIP(host), allowPrivate)
	}
}
