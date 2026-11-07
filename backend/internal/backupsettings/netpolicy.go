package backupsettings

import (
	"errors"
	"net"
	"strings"
	"syscall"
)

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// CheckIP applies the S3 endpoint address policy. Link-local addresses (cloud
// metadata services live there), multicast and unspecified addresses are
// always refused. Loopback, RFC 1918, CGNAT and unique-local addresses are
// refused unless allowPrivate (a MinIO on the LAN is a legitimate target).
func CheckIP(ip net.IP, allowPrivate bool) error {
	if ip == nil {
		return errors.New("invalid address")
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
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
