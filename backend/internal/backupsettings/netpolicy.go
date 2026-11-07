package backupsettings

import (
	"errors"
	"net"
	"strings"
	"syscall"
)

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

var transitionNets = func() []*net.IPNet {
	var out []*net.IPNet
	for _, c := range []string{"64:ff9b::/96", "64:ff9b:1::/48", "2002::/16", "2001::/32", "::/96"} {
		_, n, _ := net.ParseCIDR(c)
		out = append(out, n)
	}
	return out
}()

// embeddedIPv4 extracts every IPv4 address an IPv6 transition address can
// carry: NAT64 (64:ff9b::/96 and 64:ff9b:1::/48),
// 6to4 (2002::/16), IPv4-compatible (::/96) and Teredo (2001::/32: server and
// de-obfuscated client). ip must be a 16-byte non-IPv4-mapped address.
func embeddedIPv4(ip net.IP) []net.IP {
	b := ip.To16()
	if b == nil {
		return nil
	}
	v4 := func(a, c, d, e byte) net.IP { return net.IPv4(a, c, d, e).To4() }
	var out []net.IP
	switch {
	case b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b: // NAT64 well-known / local-use prefixes
		zero8 := true
		for _, x := range b[4:12] {
			if x != 0 {
				zero8 = false
			}
		}
		if zero8 { // 64:ff9b::/96
			out = append(out, v4(b[12], b[13], b[14], b[15]))
		} else if b[4] == 0x00 && b[5] == 0x01 { // 64:ff9b:1::/48 (RFC 8215, RFC 6052 /48 layout)
			out = append(out, v4(b[6], b[7], b[9], b[10]))
		}
	case b[0] == 0x20 && b[1] == 0x02: // 6to4
		out = append(out, v4(b[2], b[3], b[4], b[5]))
	case b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0: // Teredo
		out = append(out, v4(b[4], b[5], b[6], b[7]))                         // server
		out = append(out, v4(b[12]^0xff, b[13]^0xff, b[14]^0xff, b[15]^0xff)) // client
	}
	allZero := true
	for _, x := range b[:12] {
		if x != 0 {
			allZero = false
		}
	}
	if allZero { // IPv4-compatible ::a.b.c.d
		out = append(out, v4(b[12], b[13], b[14], b[15]))
	}
	return out
}

// CheckIP applies the S3 endpoint address policy. Link-local addresses (cloud
// metadata services live there), multicast and unspecified addresses are
// always refused. Loopback, RFC 1918, CGNAT and unique-local addresses are
// refused unless allowPrivate (a MinIO on the LAN is a legitimate target).
// IPv6 transition addresses (NAT64, 6to4, Teredo, IPv4-compatible) are refused
// unless allowPrivate, and the IPv4 address they embed is checked with the
// same policy, so metadata/private targets cannot be smuggled through them.
func CheckIP(ip net.IP, allowPrivate bool) error {
	if ip == nil {
		return errors.New("invalid address")
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	} else {
		trans := false
		for _, n := range transitionNets {
			if n.Contains(ip) {
				trans = true
			}
		}
		if trans && !ip.IsUnspecified() && !ip.Equal(net.IPv6loopback) {
			for _, e := range embeddedIPv4(ip) {
				if err := CheckIP(e, allowPrivate); err != nil {
					return err
				}
			}
			if !allowPrivate {
				return errors.New("IPv6 transition addresses (NAT64, 6to4, Teredo, IPv4-compatible) are refused; enable \"Allow private network\" if you really need one")
			}
		}
	}
	switch {
	case ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast():
		return errors.New("link-local, multicast and unspecified addresses are not allowed (cloud metadata endpoints live there)")
	case ip.Equal(net.ParseIP("100.100.100.200")) || ip.Equal(net.ParseIP("fd00:ec2::254")):
		return errors.New("cloud metadata addresses are not allowed")
	}
	if !allowPrivate && (ip.IsLoopback() || ip.IsPrivate() || cgnat.Contains(ip)) {
		return errors.New("private, loopback and shared addresses are refused; enable \"Allow private network\" if your S3 server is on your own network")
	}
	return nil
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
