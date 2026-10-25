package handlers

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Domain status is a read-only mirror of how the server is addressed plus two
// live checks (DNS resolution and an end-to-end HTTPS health probe). The API
// never changes SITE_ADDRESS or DNS records: the operator edits .env, Caddy
// provisions certificates, and this endpoint only reports what it observes.

const (
	domainCheckOK      = "ok"
	domainCheckFail    = "fail"
	domainCheckSkipped = "skipped"

	domainProbeTimeout = 5 * time.Second
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
	PublicBaseURL string       `json:"public_base_url"`
	DNS           *domainCheck `json:"dns,omitempty"`
	HTTPS         *domainCheck `json:"https,omitempty"`
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

	dnsLookupHost = defaultDNSLookupHost
	httpsProbe    = defaultHTTPSProbe
)

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

	if host != "" {
		resp.DNS = s.checkDNS(r.Context(), host)
		resp.HTTPS = s.checkHTTPS(r.Context(), host)
	} else {
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

func (s *Server) checkHTTPS(ctx context.Context, host string) *domainCheck {
	cctx, cancel := context.WithTimeout(ctx, domainProbeTimeout)
	defer cancel()
	status, err := httpsProbe(cctx, "https://"+host+"/healthz")
	if err != nil {
		return &domainCheck{
			Status: domainCheckFail,
			Detail: "Could not reach https://" + host + "/healthz from the server: " + err.Error() +
				". If this is a home network, a NAT loopback limitation can cause false failures here while the domain works from phones.",
		}
	}
	if status != http.StatusOK {
		return &domainCheck{
			Status: domainCheckFail,
			Detail: fmt.Sprintf("https://%s/healthz answered %d instead of 200 — is another service on that address?", host, status),
		}
	}
	return &domainCheck{
		Status: domainCheckOK,
		Detail: fmt.Sprintf("https://%s/healthz answered 200 with a valid certificate.", host),
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
