// Package push delivers push notifications to family members' devices.
//
// Android devices are reached through UnifiedPush (typically an ntfy topic):
// the server POSTs the message to the device's unifiedpush_endpoint. iOS
// devices are reached through APNs over HTTP/2 using a provider JWT signed
// with the team's .p8 key.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Notification describes a single push message and its destination.
type Notification struct {
	Title string
	Body  string

	// Silent marks a machine-to-machine message (e.g. a location-refresh
	// request): instead of an alert, iOS devices receive a content-available
	// payload that wakes the app in the background to execute the command
	// silently. The command JSON travels in Body. Android keeps the exact
	// same wire shape as before — UnifiedPush delivers Body as the message
	// text either way.
	Silent bool

	// Platform is "ios" or "android".
	Platform string

	// PushToken is the APNs device token (iOS only).
	PushToken string

	// UnifiedPushEndpoint is the ntfy/UnifiedPush endpoint (Android only).
	UnifiedPushEndpoint string

	// Direct routes the message through the built-in direct channel (see
	// direct.go) instead of UnifiedPush/APNs. DeviceID and UserID identify the
	// outbox the event is queued in; AlertID (optional) links it to the
	// alert_deliveries rows; DedupeID (optional, generated when empty) is the id
	// the app dedupes on.
	Direct   bool
	DeviceID string
	UserID   string
	AlertID  string
	DedupeID string
}

// Dispatcher delivers push notifications. It is an interface so tests can
// substitute a stub.
type Dispatcher interface {
	Dispatch(ctx context.Context, n Notification) error
}

// PermanentError wraps an error that should not be retried (e.g. a 4xx
// response indicating the device token is invalid or the request is malformed).
// Transient failures (5xx, network errors) are retried; permanent ones are not.
type PermanentError struct {
	Err error
}

func (e *PermanentError) Error() string { return e.Err.Error() }
func (e *PermanentError) Unwrap() error { return e.Err }

// IsPermanent reports whether err is a permanent (non-retryable) error.
func IsPermanent(err error) bool {
	var pe *PermanentError
	return errors.As(err, &pe)
}

// ValidateUnifiedPushEndpoint checks that a UnifiedPush/ntfy endpoint is a
// safe https URL that does not resolve to a private, loopback, link-local,
// unspecified, or multicast address. This prevents SSRF via a maliciously
// registered endpoint (e.g. pointing at the cloud metadata service or an
// internal host) and avoids leaking location hints over cleartext http.
func ValidateUnifiedPushEndpoint(raw string) error {
	_, err := resolveEndpoint(raw)
	return err
}

// resolveEndpoint parses and validates an endpoint URL and returns the
// resolved (and validated) IP addresses of its host.
func resolveEndpoint(raw string) ([]net.IP, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("push: invalid endpoint: %w", err)
	}
	if u.Scheme != "https" {
		return nil, errors.New("push: endpoint scheme must be https")
	}
	host := u.Hostname()
	if host == "" {
		return nil, errors.New("push: endpoint host is required")
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return nil, fmt.Errorf("push: resolve endpoint host: %w", err)
	}
	if len(ips) == 0 {
		return nil, errors.New("push: endpoint host did not resolve")
	}
	for _, ip := range ips {
		if isDisallowedIP(ip) {
			return nil, fmt.Errorf("push: endpoint resolves to disallowed address %s", ip)
		}
	}
	return ips, nil
}

// Non-public IPv4 ranges that net.IP.IsPrivate does not cover but a push
// endpoint must not target either:
//
//   - 100.64.0.0/10 — carrier-grade NAT / shared address space (RFC 6598).
//     Also the range used by tailnets (e.g. Tailscale), so a server attached
//     to one could otherwise be pointed at internal hosts by an insider.
//   - 198.18.0.0/15 — benchmarking address space (RFC 2544).
var (
	cgnatRange     = netip.MustParsePrefix("100.64.0.0/10")
	benchmarkRange = netip.MustParsePrefix("198.18.0.0/15")
)

// isDisallowedIP reports whether ip is a non-public address that a push
// endpoint must not target.
func isDisallowedIP(ip net.IP) bool {
	if ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() ||
		ip.IsMulticast() {
		return true
	}
	// The Is* checks above ignore IPv4-mapped IPv6 forms, so normalize before
	// the range checks.
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true // unparseable addresses are never allowed
	}
	addr = addr.Unmap()
	return cgnatRange.Contains(addr) || benchmarkRange.Contains(addr)
}

// safeClient builds an http.Client for a validated endpoint that (a) pins the
// resolved IPs via a custom DialContext so http.Do cannot re-resolve to a
// different (rebound) address, and (b) re-validates every redirect hop.
func safeClient(rawURL string) (*http.Client, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("push: invalid endpoint: %w", err)
	}
	ips, err := resolveEndpoint(rawURL)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()

	port := u.Port()
	if port == "" {
		port = "443"
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			// Use the port from addr (so a redirect to the same host on a
			// different port dials the correct port), but pin the host to the
			// resolved IPs. Try each resolved IP in order with fallback.
			_, addrPort, err := net.SplitHostPort(addr)
			if err != nil {
				addrPort = port
			}
			var lastErr error
			for _, ip := range ips {
				conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), addrPort))
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			return nil, lastErr
		},
	}

	return &http.Client{
		Transport: transport,
		Timeout:   10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("push: too many redirects")
			}
			// Re-validate the redirect target and reject cross-host redirects
			// (the pinned IPs only apply to the original host).
			if err := ValidateUnifiedPushEndpoint(req.URL.String()); err != nil {
				return err
			}
			if req.URL.Hostname() != host {
				return errors.New("push: cross-host redirect not allowed")
			}
			return nil
		},
	}, nil
}

// APNsConfig holds the credentials needed to talk to Apple Push Notification
// service. KeyFile must point to the .p8 private key downloaded from the
// Apple Developer portal.
type APNsConfig struct {
	KeyFile    string
	KeyID      string
	TeamID     string
	Topic      string // app bundle ID
	Production bool   // false = sandbox (api.sandbox.push.apple.com)
}

// DispatcherImpl is the production Dispatcher. It delivers Android messages
// via UnifiedPush and iOS messages via APNs.
type DispatcherImpl struct {
	apns   *apnsClient // nil when APNs is not configured
	direct *DirectBroker
}

// SetDirect enables the built-in direct channel. Without it, direct
// notifications fail permanently (the caller then falls back to UnifiedPush).
func (d *DispatcherImpl) SetDirect(b *DirectBroker) { d.direct = b }

// NewDispatcher builds a Dispatcher. When cfg has no key file, APNs delivery
// is disabled and iOS notifications are logged and skipped.
func NewDispatcher(cfg APNsConfig) *DispatcherImpl {
	d := &DispatcherImpl{}
	if cfg.KeyFile == "" {
		slog.Warn("push: apns not configured; iOS notifications will be dropped")
	} else {
		c, err := newAPNsClient(cfg)
		if err != nil {
			slog.Error("push: apns disabled, failed to load key", "err", err)
		} else {
			d.apns = c
		}
	}
	return d
}

// Dispatch routes a notification to the correct transport based on platform.
func (d *DispatcherImpl) Dispatch(ctx context.Context, n Notification) error {
	if n.Direct {
		if d.direct == nil {
			return &PermanentError{Err: errors.New("push: direct channel disabled")}
		}
		return d.direct.Enqueue(ctx, n)
	}
	switch n.Platform {
	case "android":
		return d.dispatchUnifiedPush(ctx, n)
	case "ios":
		return d.dispatchAPNs(ctx, n)
	default:
		return fmt.Errorf("push: unsupported platform %q", n.Platform)
	}
}

// dispatchUnifiedPush POSTs the message to a UnifiedPush/ntfy endpoint. The
// endpoint is the full URL the device registered (e.g. https://ntfy.sh/<topic>).
func (d *DispatcherImpl) dispatchUnifiedPush(ctx context.Context, n Notification) error {
	if n.UnifiedPushEndpoint == "" {
		return errors.New("push: empty unifiedpush endpoint")
	}
	client, err := safeClient(n.UnifiedPushEndpoint)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.UnifiedPushEndpoint, bytes.NewBufferString(n.Body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("Title", n.Title)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		err := fmt.Errorf("push: unifiedpush returned %d: %s", resp.StatusCode, string(b))
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			return &PermanentError{Err: err}
		}
		return err
	}
	return nil
}

func (d *DispatcherImpl) dispatchAPNs(ctx context.Context, n Notification) error {
	if d.apns == nil {
		// Permanent: retrying (or re-dispatching) will never succeed while APNs
		// is unconfigured, so fail fast instead of burning retry attempts.
		return &PermanentError{Err: errors.New("push: apns not configured")}
	}
	if n.PushToken == "" {
		return errors.New("push: empty apns device token")
	}
	if n.Silent {
		return d.apns.sendSilent(ctx, n.PushToken, n.Body)
	}
	return d.apns.send(ctx, n.PushToken, n.Title, n.Body)
}

// apnsClient signs provider tokens and sends APNs requests over HTTP/2.
type apnsClient struct {
	cfg  APNsConfig
	key  *ecdsa.PrivateKey
	http *http.Client

	// Cached provider token, reused until shortly before its 1h expiry so we
	// do not regenerate (and re-sign) a token on every send.
	mu        sync.Mutex
	cachedTok string
	tokExpiry time.Time
}

func newAPNsClient(cfg APNsConfig) (*apnsClient, error) {
	key, err := loadECDSAPrivateKey(cfg.KeyFile)
	if err != nil {
		return nil, err
	}
	return &apnsClient{
		cfg:  cfg,
		key:  key,
		http: &http.Client{Timeout: 10 * time.Second},
	}, nil
}

// loadECDSAPrivateKey reads an Apple .p8 key file (PKCS#8 EC private key).
func loadECDSAPrivateKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("push: read apns key: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("push: apns key: no PEM block found")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("push: parse apns key: %w", err)
	}
	ec, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("push: apns key: not an ECDSA private key")
	}
	return ec, nil
}

// token returns a short-lived APNs provider token (ES256 JWT), caching it and
// reusing it until shortly before its 1h expiry. Apple requires an exp claim;
// a 1h lifetime is well within Apple's accepted range.
func (c *apnsClient) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.cachedTok != "" && time.Now().Before(c.tokExpiry) {
		return c.cachedTok, nil
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss": c.cfg.TeamID,
		"iat": now.Unix(),
		"exp": now.Add(time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = c.cfg.KeyID
	signed, err := token.SignedString(c.key)
	if err != nil {
		return "", err
	}
	c.cachedTok = signed
	// Refresh 5 minutes before the token actually expires to avoid using an
	// expired token on a slow send.
	c.tokExpiry = now.Add(time.Hour - 5*time.Minute)
	return signed, nil
}

// send delivers an alert notification to a single device token.
func (c *apnsClient) send(ctx context.Context, deviceToken, title, body string) error {
	host := "https://api.push.apple.com"
	if !c.cfg.Production {
		host = "https://api.sandbox.push.apple.com"
	}
	url := host + "/3/device/" + deviceToken

	payload := map[string]any{
		"aps": map[string]any{
			"alert": map[string]any{
				"title": title,
				"body":  body,
			},
			"sound": "default",
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	tok, err := c.token()
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+tok)
	req.Header.Set("apns-topic", c.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10))
	req.Header.Set("content-type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		err := fmt.Errorf("push: apns status %d: %s", resp.StatusCode, string(b))
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			return &PermanentError{Err: err}
		}
		return err
	}
	return nil
}

// sendSilent delivers a background (machine-to-machine) message: no alert is
// shown, iOS wakes the app in the background and hands it the payload. The
// command JSON travels under the custom "of" key (the client's
// AppDelegate forwards it over the app.openfamily/apns channel).
//
// Per Apple's APNs contract, content-available pushes use the "background"
// push type and priority 5 (background requests should not starve user alerts,
// and sending them at priority 10 is an error). Expiration is short on purpose:
// a location-refresh command that is minutes old is worthless, and the client
// ignores stale requests on execution anyway.
func (c *apnsClient) sendSilent(ctx context.Context, deviceToken, command string) error {
	host := "https://api.push.apple.com"
	if !c.cfg.Production {
		host = "https://api.sandbox.push.apple.com"
	}
	url := host + "/3/device/" + deviceToken

	payload := map[string]any{
		"aps": map[string]any{
			"content-available": 1,
		},
		"of": command,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	tok, err := c.token()
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+tok)
	req.Header.Set("apns-topic", c.cfg.Topic)
	req.Header.Set("apns-push-type", "background")
	req.Header.Set("apns-priority", "5")
	req.Header.Set("apns-expiration", strconv.FormatInt(time.Now().Add(5*time.Minute).Unix(), 10))
	req.Header.Set("content-type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		err := fmt.Errorf("push: apns status %d: %s", resp.StatusCode, string(b))
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			return &PermanentError{Err: err}
		}
		return err
	}
	return nil
}
