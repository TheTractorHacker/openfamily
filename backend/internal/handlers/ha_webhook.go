package handlers

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// Home Assistant webhook delivery: URL validation (SSRF), safe HTTP client and
// request signing. See docs/integrations/home-assistant.md ("Trust paths").

// haLoopbackForTests lets tests deliver to an httptest server on 127.0.0.1.
// Never set outside tests.
var haLoopbackForTests atomic.Bool

const (
	haWebhookTimeout   = 10 * time.Second
	haWebhookMaxURLLen = 512
	// HA rejects deliveries whose timestamp is older than this (replay window).
	HAWebhookMaxSkew = 5 * time.Minute
)

type haAddrClass int

const (
	haAddrPublic haAddrClass = iota
	haAddrPrivate
	haAddrBlocked
)

var haExtraBlocked = []netip.Prefix{
	netip.MustParsePrefix("100.100.100.200/32"), // Alibaba Cloud metadata (inside CGNAT)
	netip.MustParsePrefix("fd00:ec2::/32"),      // AWS IPv6 metadata (inside ULA)
	netip.MustParsePrefix("168.63.129.16/32"),   // Azure wire server
	netip.MustParsePrefix("192.0.0.0/24"),       // IETF protocol assignments
	netip.MustParsePrefix("198.18.0.0/15"),      // benchmarking
	netip.MustParsePrefix("240.0.0.0/4"),        // reserved
	netip.MustParsePrefix("fec0::/10"),          // deprecated site-local
	netip.MustParsePrefix("2002::/16"),          // 6to4 (embeds an arbitrary IPv4 address)
	netip.MustParsePrefix("2001::/32"),          // Teredo
}

var haNAT64 = netip.MustParsePrefix("64:ff9b::/96")
var haCGNAT = netip.MustParsePrefix("100.64.0.0/10")

// haClassifyAddr decides what a webhook may connect to:
//   - blocked: never (loopback, link-local incl. cloud metadata, unspecified,
//     multicast, broadcast, reserved, known metadata services);
//   - private: RFC 1918, ULA and CGNAT (Tailscale), only when the integration
//     explicitly allows the local network;
//   - public: any other unicast address.
func haClassifyAddr(a netip.Addr) haAddrClass {
	a = a.Unmap()
	if a.Is6() && haNAT64.Contains(a) { // NAT64 embeds an IPv4 address
		b := a.As16()
		a = netip.AddrFrom4([4]byte{b[12], b[13], b[14], b[15]})
	}
	if a.Is6() {
		a = a.WithZone("")
	}
	if a.IsLoopback() && haLoopbackForTests.Load() {
		return haAddrPrivate
	}
	if !a.IsValid() || a.IsUnspecified() || a.IsLoopback() || a.IsLinkLocalUnicast() ||
		a.IsLinkLocalMulticast() || a.IsInterfaceLocalMulticast() || a.IsMulticast() {
		return haAddrBlocked
	}
	if a.Is4() && a == netip.AddrFrom4([4]byte{255, 255, 255, 255}) {
		return haAddrBlocked
	}
	for _, p := range haExtraBlocked {
		if p.Contains(a) {
			return haAddrBlocked
		}
	}
	if a.IsPrivate() || haCGNAT.Contains(a) {
		return haAddrPrivate
	}
	return haAddrPublic
}

func haAddrAllowed(a netip.Addr, allowPrivate bool) bool {
	switch haClassifyAddr(a) {
	case haAddrPublic:
		return true
	case haAddrPrivate:
		return allowPrivate
	}
	return false
}

var errHAWebhookBlocked = errors.New("webhook address not allowed")

// haParseWebhookURL checks the static shape of a webhook URL (scheme, no
// credentials, host present, length). Address checks happen separately.
func haParseWebhookURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > haWebhookMaxURLLen {
		return nil, errors.New("webhook URL must be 1-512 characters")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.Hostname() == "" {
		return nil, errors.New("webhook URL is not valid")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, errors.New("webhook URL must start with http:// or https://")
	}
	if u.User != nil {
		return nil, errors.New("webhook URL must not contain credentials")
	}
	if u.Fragment != "" {
		return nil, errors.New("webhook URL must not contain a fragment")
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return nil, errors.New("webhook URL has an invalid port")
		}
	}
	return u, nil
}

// haCheckWebhookHost resolves the host and rejects it unless EVERY address it
// resolves to is allowed. It is a save-time convenience check; the dial-time
// guard in haWebhookClient is what actually enforces the policy (DNS can change).
func haCheckWebhookHost(ctx context.Context, u *url.URL, allowPrivate bool) error {
	host := u.Hostname()
	if ip, err := netip.ParseAddr(host); err == nil {
		if !haAddrAllowed(ip, allowPrivate) {
			return errHAWebhookBlocked
		}
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(addrs) == 0 {
		return errors.New("webhook host does not resolve")
	}
	for _, a := range addrs {
		if !haAddrAllowed(a, allowPrivate) {
			return errHAWebhookBlocked
		}
	}
	return nil
}

// haWebhookClient builds an HTTP client that connects only to allowed
// addresses, checked on the resolved IP at connect time (so a DNS rebind
// between save and send cannot reach a blocked address), uses no proxy, does
// not follow redirects and has a hard timeout.
func haWebhookClient(allowPrivate bool) *http.Client {
	dialer := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return errHAWebhookBlocked
			}
			ip, err := netip.ParseAddr(host)
			if err != nil || !haAddrAllowed(ip, allowPrivate) {
				return errHAWebhookBlocked
			}
			return nil
		},
	}
	return &http.Client{
		Timeout: haWebhookTimeout,
		Transport: &http.Transport{
			Proxy:                 nil,
			DialContext:           dialer.DialContext,
			DisableKeepAlives:     true,
			TLSHandshakeTimeout:   5 * time.Second,
			ResponseHeaderTimeout: haWebhookTimeout,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// HAWebhookSignature is the value of X-OpenFamily-Signature:
// "v1=" + hex(HMAC-SHA256(secret, "<timestamp>.<body>")). Receivers must compare
// in constant time and reject timestamps older than HAWebhookMaxSkew.
func HAWebhookSignature(secret string, ts int64, body []byte) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(strconv.FormatInt(ts, 10)))
	m.Write([]byte("."))
	m.Write(body)
	return "v1=" + hex.EncodeToString(m.Sum(nil))
}

// haSend posts one signed delivery. It returns the HTTP status (0 when none)
// and a short, non-sensitive error class ("" on success). Response bodies are
// never read beyond a small drain and never stored or returned.
func haSend(ctx context.Context, rawURL, secret string, allowPrivate bool, eventKind string, deliveryID int64, body []byte) (int, string) {
	u, err := haParseWebhookURL(rawURL)
	if err != nil {
		return 0, "invalid_url"
	}
	ts := time.Now().Unix()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), strings.NewReader(string(body)))
	if err != nil {
		return 0, "invalid_url"
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "OpenFamily-HA/1")
	req.Header.Set("X-OpenFamily-Event", eventKind)
	req.Header.Set("X-OpenFamily-Delivery", strconv.FormatInt(deliveryID, 10))
	req.Header.Set("X-OpenFamily-Timestamp", strconv.FormatInt(ts, 10))
	req.Header.Set("X-OpenFamily-Signature", HAWebhookSignature(secret, ts, body))
	resp, err := haWebhookClient(allowPrivate).Do(req)
	if err != nil {
		return 0, haErrClass(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.StatusCode, ""
	}
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return resp.StatusCode, "redirect_not_followed"
	}
	return resp.StatusCode, fmt.Sprintf("http_%d", resp.StatusCode)
}

func haErrClass(err error) string {
	switch {
	case errors.Is(err, errHAWebhookBlocked):
		return "blocked_address"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns_error"
	}
	if strings.Contains(err.Error(), errHAWebhookBlocked.Error()) {
		return "blocked_address"
	}
	if strings.Contains(err.Error(), "tls:") || strings.Contains(err.Error(), "x509:") {
		return "tls_error"
	}
	return "connection_failed"
}

// haMaskURL hides the secret-looking tail of a webhook URL (HA webhook ids are
// bearer secrets) for display and audit.
func haMaskURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	p := strings.TrimSuffix(u.Path, "/")
	if len(p) <= 1 {
		return u.Scheme + "://" + u.Host
	}
	tail := ""
	if len(p) > 6 {
		tail = p[len(p)-4:]
	}
	return u.Scheme + "://" + u.Host + "/…" + tail
}

func haLogErr(what string, err error) {
	slog.Warn("home assistant integration: "+what, "err", err)
}
