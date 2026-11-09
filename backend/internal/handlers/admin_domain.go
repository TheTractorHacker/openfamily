package handlers

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Domain status is a read-only mirror of how the server is addressed plus
// live checks, in order of authority:
//
//  1. local: the API's own listener (127.0.0.1) answers /healthz. This is the
//     real "is the server up" answer and never depends on the network.
//  2. proxy: the built-in HTTPS proxy (Caddy, reached on the compose network)
//     serves the domain with a valid certificate. Still inside this machine.
//  3. dns: the domain resolves.
//  4. https: the server opens its own PUBLIC address. Only a hint: many home
//     routers cannot loop a request from inside the network back to the
//     network's own public address (no "NAT loopback"/hairpin), and a domain
//     that is DNS-only (no CDN proxy) points straight at that address. So a
//     failure here is reported as "unverified", never as a failure.
//
// The API never changes SITE_ADDRESS or DNS records: the operator edits .env,
// Caddy provisions certificates, and this endpoint only reports what it sees.

const (
	domainCheckOK      = "ok"
	domainCheckFail    = "fail"
	domainCheckSkipped = "skipped"
	// domainCheckUnverified: the check could not confirm it, which does not
	// mean it is broken (used for the from-the-server public URL probe).
	domainCheckUnverified = "unverified"

	// defaultLocalProxyAddr is the Caddy service of the "proxy" compose profile.
	defaultLocalProxyAddr = "caddy:443"
	defaultLocalBaseURL   = "http://127.0.0.1:8080"
)

type domainCheck struct {
	Status    string   `json:"status"`
	Detail    string   `json:"detail,omitempty"`
	Addresses []string `json:"addresses,omitempty"`
}

type domainStatusResponse struct {
	// SiteAddress is the raw SITE_ADDRESS value ("openfamily.example.com",
	// ":80", "localhost", ...). Empty when not passed through to the api
	// service (e.g. deployments without Compose).
	SiteAddress string `json:"site_address"`
	// Hostname is the public domain derived from SITE_ADDRESS (falling back
	// to PUBLIC_BASE_URL). Empty for local-only setups.
	Hostname     string `json:"hostname,omitempty"`
	CustomDomain bool   `json:"custom_domain"`
	// PublicBaseURL mirrors the effective SMS share-link origin so the panel
	// can show whether it matches the domain.
	PublicBaseURL string `json:"public_base_url"`
	// Local: the server's own listener answers (authoritative "is it up").
	Local *domainCheck `json:"local,omitempty"`
	// Proxy: HTTPS for the domain through the built-in proxy on this machine.
	Proxy *domainCheck `json:"proxy,omitempty"`
	DNS   *domainCheck `json:"dns,omitempty"`
	// HTTPS: the public URL opened from the server itself. A hint only: see
	// the package comment; failures are "unverified".
	HTTPS *domainCheck `json:"https,omitempty"`
}

// Indirection points for tests; production uses the real resolver/client.
var (
	defaultDNSLookupHost = func(ctx context.Context, host string) ([]string, error) {
		return net.DefaultResolver.LookupHost(ctx, host)
	}
	defaultHTTPSProbe = func(ctx context.Context, rawURL string) (int, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return 0, err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		return resp.StatusCode, nil
	}

	// defaultLocalProbe GETs the API's own /healthz on the loopback address.
	// A loopback https listener uses the operator's certificate for the public
	// name, so the certificate is not checked here (that is the proxy check).
	defaultLocalProbe = func(ctx context.Context, rawURL string) (int, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return 0, err
		}
		client := &http.Client{Transport: &http.Transport{
			Proxy:           nil,
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}, //nolint:gosec // loopback only
		}}
		resp, err := client.Do(req)
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		return resp.StatusCode, nil
	}

	// defaultProxyProbe opens https://host/healthz but connects to the local
	// proxy address instead of the public IP, so it checks Caddy's routing and
	// certificate for host without leaving this machine. errProxyAbsent means
	// there is no such proxy (the name does not resolve).
	defaultProxyProbe = func(ctx context.Context, proxyAddr, host string) (int, error) {
		proxyHost, _, err := net.SplitHostPort(proxyAddr)
		if err != nil {
			return 0, err
		}
		if _, err := net.DefaultResolver.LookupHost(ctx, proxyHost); err != nil {
			return 0, errProxyAbsent
		}
		d := &net.Dialer{}
		client := &http.Client{Transport: &http.Transport{
			Proxy: nil,
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return d.DialContext(ctx, network, proxyAddr)
			},
			TLSClientConfig: &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12},
		}}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+"/healthz", nil)
		if err != nil {
			return 0, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		return resp.StatusCode, nil
	}

	dnsLookupHost = defaultDNSLookupHost
	httpsProbe    = defaultHTTPSProbe
	localProbe    = defaultLocalProbe
	proxyProbe    = defaultProxyProbe
)

var errProxyAbsent = errors.New("no built-in proxy")

// domainProbeTimeout bounds each live check (a var so tests can shorten it).
var domainProbeTimeout = 5 * time.Second

func (s *Server) localBaseURL() string {
	if v := strings.TrimRight(strings.TrimSpace(s.LocalBaseURL), "/"); v != "" {
		return v
	}
	return defaultLocalBaseURL
}

func (s *Server) localProxyAddr() string {
	if v := strings.TrimSpace(s.LocalProxyAddr); v != "" {
		return v
	}
	return defaultLocalProxyAddr
}

// AdminGetDomainStatus reports the configured site address and live DNS/TLS
// checks. Requires platform admin.
func (s *Server) AdminGetDomainStatus(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}

	host := domainHostname(s.SiteAddress)
	if host == "" {
		// Fall back to the effective PUBLIC_BASE_URL (env, or the value an
		// admin saved in the Twilio card) before concluding "no domain".
		host = hostnameFromOrigin(s.publicBaseURL())
	}

	resp := domainStatusResponse{
		SiteAddress:   s.SiteAddress,
		Hostname:      host,
		CustomDomain:  host != "",
		PublicBaseURL: s.publicBaseURL(),
	}

	resp.Local = s.checkLocal(r.Context())
	if host != "" {
		resp.Proxy = s.checkProxy(r.Context(), host)
		resp.DNS = s.checkDNS(r.Context(), host)
		resp.HTTPS = s.checkPublic(r.Context(), host, resp.Proxy)
	} else {
		resp.Proxy = &domainCheck{Status: domainCheckSkipped}
		resp.DNS = &domainCheck{Status: domainCheckSkipped}
		resp.HTTPS = &domainCheck{Status: domainCheckSkipped}
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) checkDNS(ctx context.Context, host string) *domainCheck {
	cctx, cancel := context.WithTimeout(ctx, domainProbeTimeout)
	defer cancel()
	addrs, err := dnsLookupHost(cctx, host)
	if err != nil {
		var dnsErr *net.DNSError
		detail := err.Error()
		if errors.As(err, &dnsErr) && dnsErr.IsNotFound {
			detail = fmt.Sprintf("%s does not resolve yet — add an A/AAAA record at your DNS provider.", host)
		}
		return &domainCheck{Status: domainCheckFail, Detail: detail}
	}
	return &domainCheck{
		Status:    domainCheckOK,
		Detail:    fmt.Sprintf("%s resolves to %s.", host, strings.Join(addrs, ", ")),
		Addresses: addrs,
	}
}

// checkLocal asks the API's own listener. This is the authoritative "the
// server is up" check: it does not depend on DNS, routers or certificates.
func (s *Server) checkLocal(ctx context.Context) *domainCheck {
	cctx, cancel := context.WithTimeout(ctx, domainProbeTimeout)
	defer cancel()
	status, err := localProbe(cctx, s.localBaseURL()+"/healthz")
	if err != nil {
		return &domainCheck{Status: domainCheckFail, Detail: "The server did not answer on its own address: " + err.Error() + "."}
	}
	if status != http.StatusOK {
		return &domainCheck{Status: domainCheckFail, Detail: fmt.Sprintf("The server answered %d on its own address instead of 200.", status)}
	}
	return &domainCheck{Status: domainCheckOK, Detail: "The server is up and answering."}
}

// checkProxy opens the domain through the built-in HTTPS proxy on this
// machine, which proves routing and the certificate without hairpin NAT.
func (s *Server) checkProxy(ctx context.Context, host string) *domainCheck {
	cctx, cancel := context.WithTimeout(ctx, domainProbeTimeout)
	defer cancel()
	status, err := proxyProbe(cctx, s.localProxyAddr(), host)
	if errors.Is(err, errProxyAbsent) {
		return &domainCheck{Status: domainCheckSkipped,
			Detail: "No built-in HTTPS proxy runs next to the server (you may use your own). Check the address in a browser instead."}
	}
	if err != nil {
		var cv *tls.CertificateVerificationError
		if errors.As(err, &cv) {
			return &domainCheck{Status: domainCheckFail,
				Detail: "The built-in proxy answers for " + host + " but its certificate is not valid: " + cv.Err.Error() +
					". Check docker compose logs caddy; ports 80 and 443 must be reachable from the internet for Let's Encrypt."}
		}
		return &domainCheck{Status: domainCheckFail,
			Detail: "The built-in proxy did not serve https://" + host + ": " + err.Error() + ". Check docker compose logs caddy."}
	}
	if status != http.StatusOK {
		return &domainCheck{Status: domainCheckFail,
			Detail: fmt.Sprintf("The built-in proxy answered %d for https://%s/healthz instead of 200. Is SITE_ADDRESS the same in Caddy and the server?", status, host)}
	}
	return &domainCheck{Status: domainCheckOK, Detail: fmt.Sprintf("https://%s is served by this machine with a valid certificate.", host)}
}

// hairpinAdvice explains, in plain words, why the server may not be able to
// open its own public address although everyone else can.
func hairpinAdvice(host string) string {
	return "This does not mean the address is broken: many home routers do not let a computer inside the network open " +
		"the network's own public address (\"NAT loopback\" or \"hairpin\" is missing), which is common when the domain " +
		"points straight at your home connection. Open https://" + host + " on a phone using mobile data, or from another " +
		"network: if it loads there, everything is fine. To make this check pass too, add split DNS: in your router or " +
		"local DNS, point " + host + " at the server's address inside your network."
}

// checkPublic opens the public URL from the server itself: a hint about
// "reachable from outside", never a failure (see the package comment).
func (s *Server) checkPublic(ctx context.Context, host string, proxy *domainCheck) *domainCheck {
	cctx, cancel := context.WithTimeout(ctx, domainProbeTimeout)
	defer cancel()
	status, err := httpsProbe(cctx, "https://"+host+"/healthz")
	lead := "The server could not open its own public address https://" + host + " "
	if proxy != nil && proxy.Status == domainCheckOK {
		lead = "The server and its certificate are fine (checked on this machine above), but it could not open its own public address https://" + host + " "
	}
	if err != nil {
		reason := err.Error()
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(cctx.Err(), context.DeadlineExceeded) {
			reason = "no answer within 5 seconds"
		}
		return &domainCheck{Status: domainCheckUnverified, Detail: lead + "(" + reason + "). " + hairpinAdvice(host)}
	}
	if status != http.StatusOK {
		return &domainCheck{Status: domainCheckUnverified,
			Detail: fmt.Sprintf("%s(it answered %d instead of 200, possibly your router's own page). %s", lead, status, hairpinAdvice(host))}
	}
	return &domainCheck{
		Status: domainCheckOK,
		Detail: fmt.Sprintf("https://%s/healthz answered 200 with a valid certificate when opened from the server.", host),
	}
}

// domainHostname extracts the public domain from a Caddy-style site address.
// Accepts "example.com", "example.com:8443", "https://example.com"; returns ""
// for local-only addresses (":80", "localhost", bare IP literals).
func domainHostname(siteAddress string) string {
	addr := strings.TrimSpace(siteAddress)
	if addr == "" || addr == ":" || strings.HasPrefix(addr, ":") {
		return ""
	}
	// Allow scheme-prefixed values even though Caddyfiles usually omit them.
	if i := strings.Index(addr, "://"); i >= 0 {
		addr = addr[i+3:]
	}
	if i := strings.IndexAny(addr, "/?#"); i >= 0 {
		addr = addr[:i]
	}
	if host, _, err := net.SplitHostPort(addr); err == nil {
		addr = host
	}
	if addr == "" || addr == "localhost" || addr == "0.0.0.0" || net.ParseIP(addr) != nil {
		return ""
	}
	return strings.TrimSuffix(strings.ToLower(addr), ".")
}

// hostnameFromOrigin returns the host of an https origin URL (""
// otherwise). Used as a fallback when SITE_ADDRESS is local or unset.
func hostnameFromOrigin(origin string) string {
	origin = strings.TrimSpace(origin)
	if origin == "" {
		return ""
	}
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "https" {
		return ""
	}
	return u.Hostname()
}
