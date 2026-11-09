package handlers

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// stubLocal makes the local listener and built-in proxy checks answer as given
// (status 0 with err == nil means "absent proxy").
func stubLocal(t *testing.T, localStatus int, localErr error, proxyStatus int, proxyErr error) {
	t.Helper()
	localProbe = func(context.Context, string) (int, error) { return localStatus, localErr }
	proxyProbe = func(context.Context, string, string) (int, error) { return proxyStatus, proxyErr }
	t.Cleanup(func() {
		localProbe = defaultLocalProbe
		proxyProbe = defaultProxyProbe
	})
}

func getDomainStatus(t *testing.T, srv *Server) domainStatusResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "admin"}))
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var got domainStatusResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestAdminGetDomainStatusUnauthenticated(t *testing.T) {
	srv := &Server{}
	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestAdminGetDomainStatusLocalOnly(t *testing.T) {
	srv := &Server{SiteAddress: ":80"}
	stubLocal(t, http.StatusOK, nil, 0, errors.New("proxy must not be probed"))

	// The checks must be skipped, never executed: a local-only deployment has
	// no public name and the probes would only add latency.
	dnsLookupHost = func(context.Context, string) ([]string, error) {
		t.Error("DNS lookup ran for a local-only site address")
		return nil, errors.New("unexpected")
	}
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(context.Context, string) (int, error) {
		t.Error("HTTPS probe ran for a local-only site address")
		return 0, errors.New("unexpected")
	}
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })

	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "admin"}))
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}

	var got domainStatusResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.CustomDomain || got.Hostname != "" {
		t.Fatalf("expected no custom domain, got %+v", got)
	}
	if got.DNS == nil || got.DNS.Status != domainCheckSkipped || got.HTTPS == nil || got.HTTPS.Status != domainCheckSkipped {
		t.Fatalf("expected skipped checks, got dns=%v https=%v", got.DNS, got.HTTPS)
	}
	if got.Proxy == nil || got.Proxy.Status != domainCheckSkipped {
		t.Fatalf("proxy=%+v", got.Proxy)
	}
	// The server itself is always checked: it is the authoritative answer.
	if got.Local == nil || got.Local.Status != domainCheckOK {
		t.Fatalf("local=%+v", got.Local)
	}
}

func TestAdminGetDomainStatusCustomDomainOK(t *testing.T) {
	srv := &Server{
		SiteAddress:   "openfamily.example.com",
		PublicBaseURL: "https://openfamily.example.com",
	}
	stubLocal(t, http.StatusOK, nil, http.StatusOK, nil)
	dnsLookupHost = func(_ context.Context, host string) ([]string, error) {
		if host != "openfamily.example.com" {
			t.Errorf("host=%q", host)
		}
		return []string{"203.0.113.7"}, nil
	}
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(_ context.Context, rawURL string) (int, error) {
		if rawURL != "https://openfamily.example.com/healthz" {
			t.Errorf("url=%q", rawURL)
		}
		return http.StatusOK, nil
	}
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })

	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "admin"}))
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}

	var got domainStatusResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if !got.CustomDomain || got.Hostname != "openfamily.example.com" {
		t.Fatalf("expected custom domain, got %+v", got)
	}
	if got.DNS.Status != domainCheckOK || len(got.DNS.Addresses) != 1 {
		t.Fatalf("dns=%+v", got.DNS)
	}
	if got.HTTPS.Status != domainCheckOK || got.Proxy.Status != domainCheckOK || got.Local.Status != domainCheckOK {
		t.Fatalf("https=%+v proxy=%+v local=%+v", got.HTTPS, got.Proxy, got.Local)
	}
}

func TestAdminGetDomainStatusFallsBackToPublicBaseURL(t *testing.T) {
	srv := &Server{
		SiteAddress:   ":80",
		PublicBaseURL: "https://openfamily.example.com",
	}
	stubLocal(t, http.StatusOK, nil, 0, errProxyAbsent)
	dnsLookupHost = func(_ context.Context, host string) ([]string, error) {
		return []string{"203.0.113.7"}, nil
	}
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(context.Context, string) (int, error) {
		return http.StatusNotFound, errors.New("no listener")
	}
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })

	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "admin"}))
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}

	var got domainStatusResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if !got.CustomDomain || got.Hostname != "openfamily.example.com" {
		t.Fatalf("expected fallback hostname, got %+v", got)
	}
	// The public probe from the server is only a hint: unverified with an
	// explanation, never a failure.
	if got.HTTPS.Status != domainCheckUnverified || got.HTTPS.Detail == "" {
		t.Fatalf("https=%+v", got.HTTPS)
	}
	if got.Proxy.Status != domainCheckSkipped {
		t.Fatalf("absent proxy must be skipped, got %+v", got.Proxy)
	}
}

func TestAdminGetDomainStatusDNSTimeoutIsFail(t *testing.T) {
	srv := &Server{SiteAddress: "openfamily.example.com"}
	stubLocal(t, http.StatusOK, nil, 0, errProxyAbsent)
	dnsLookupHost = func(context.Context, string) ([]string, error) {
		return nil, errors.New("lookup openfamily.example.com: i/o timeout")
	}
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(context.Context, string) (int, error) {
		return 0, errors.New("dial tcp: connection refused")
	}
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })

	req := httptest.NewRequest(http.MethodGet, "/api/admin/domain/status", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "admin"}))
	w := httptest.NewRecorder()
	srv.AdminGetDomainStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("probe failures must not break the endpoint: status=%d body=%s", w.Code, w.Body.String())
	}

	var got domainStatusResponse
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.DNS.Status != domainCheckFail || got.HTTPS.Status != domainCheckUnverified {
		t.Fatalf("dns=%+v https=%+v", got.DNS, got.HTTPS)
	}
}

// The owner's case: the domain is DNS-only and points at a home connection
// whose router has no NAT loopback. The server and its certificate are fine
// (local + proxy), the public probe times out from inside. That must read as
// "unverified, here is why and what to do", not as a red failure.
func TestAdminGetDomainStatusHairpinTimeoutIsNotAFailure(t *testing.T) {
	srv := &Server{SiteAddress: "family.example.org"}
	stubLocal(t, http.StatusOK, nil, http.StatusOK, nil)
	dnsLookupHost = func(context.Context, string) ([]string, error) { return []string{"198.51.100.4"}, nil }
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(ctx context.Context, _ string) (int, error) {
		<-ctx.Done()
		return 0, ctx.Err()
	}
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })
	oldTimeout := domainProbeTimeout
	domainProbeTimeout = 50 * time.Millisecond
	t.Cleanup(func() { domainProbeTimeout = oldTimeout })

	got := getDomainStatus(t, srv)
	if got.Local.Status != domainCheckOK || got.Proxy.Status != domainCheckOK || got.DNS.Status != domainCheckOK {
		t.Fatalf("local=%+v proxy=%+v dns=%+v", got.Local, got.Proxy, got.DNS)
	}
	if got.HTTPS.Status != domainCheckUnverified {
		t.Fatalf("https status=%q, want unverified", got.HTTPS.Status)
	}
	for _, want := range []string{"fine", "NAT loopback", "mobile data", "split DNS", "no answer within"} {
		if !strings.Contains(got.HTTPS.Detail, want) {
			t.Errorf("detail lacks %q: %s", want, got.HTTPS.Detail)
		}
	}
	if strings.Contains(got.HTTPS.Detail, "deadline exceeded") {
		t.Errorf("raw Go error leaked into the hint: %s", got.HTTPS.Detail)
	}
}

func TestAdminGetDomainStatusLocalDownIsFail(t *testing.T) {
	srv := &Server{SiteAddress: ":80"}
	stubLocal(t, 0, errors.New("connection refused"), 0, errProxyAbsent)
	got := getDomainStatus(t, srv)
	if got.Local.Status != domainCheckFail || !strings.Contains(got.Local.Detail, "connection refused") {
		t.Fatalf("local=%+v", got.Local)
	}
}

func TestAdminGetDomainStatusBadCertThroughProxyIsFail(t *testing.T) {
	srv := &Server{SiteAddress: "family.example.org"}
	stubLocal(t, http.StatusOK, nil, 0, &tls.CertificateVerificationError{Err: errors.New("x509: certificate has expired")})
	dnsLookupHost = func(context.Context, string) ([]string, error) { return []string{"198.51.100.4"}, nil }
	t.Cleanup(func() { dnsLookupHost = defaultDNSLookupHost })
	httpsProbe = func(context.Context, string) (int, error) { return http.StatusOK, nil }
	t.Cleanup(func() { httpsProbe = defaultHTTPSProbe })
	got := getDomainStatus(t, srv)
	if got.Proxy.Status != domainCheckFail || !strings.Contains(got.Proxy.Detail, "certificate") {
		t.Fatalf("proxy=%+v", got.Proxy)
	}
}

func TestLocalProbeDefaults(t *testing.T) {
	var seen string
	localProbe = func(_ context.Context, u string) (int, error) { seen = u; return http.StatusOK, nil }
	t.Cleanup(func() { localProbe = defaultLocalProbe })
	(&Server{}).checkLocal(context.Background())
	if seen != "http://127.0.0.1:8080/healthz" {
		t.Fatalf("default local URL %q", seen)
	}
	(&Server{LocalBaseURL: "https://127.0.0.1:9443/"}).checkLocal(context.Background())
	if seen != "https://127.0.0.1:9443/healthz" {
		t.Fatalf("configured local URL %q", seen)
	}
	if got := (&Server{}).localProxyAddr(); got != "caddy:443" {
		t.Fatalf("default proxy %q", got)
	}
}

// The real local probe against a real listener (no stubs).
func TestDefaultLocalProbeAgainstListener(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer ts.Close()
	c := (&Server{LocalBaseURL: ts.URL}).checkLocal(context.Background())
	if c.Status != domainCheckOK {
		t.Fatalf("local=%+v", c)
	}
}

// The real proxy probe: an unresolvable proxy name is "absent", not a failure.
func TestDefaultProxyProbeAbsent(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err := defaultProxyProbe(ctx, "no-such-proxy.invalid:443", "family.example.org")
	if !errors.Is(err, errProxyAbsent) {
		t.Fatalf("err=%v", err)
	}
}

func TestDomainHostname(t *testing.T) {
	cases := map[string]string{
		"":                               "",
		":80":                            "",
		"localhost":                      "",
		"localhost:8080":                 "",
		"127.0.0.1":                      "",
		"openfamily.example.com":         "openfamily.example.com",
		"openfamily.example.com:443":     "openfamily.example.com",
		"https://openfamily.example.com": "openfamily.example.com",
		"OpenFamily.Example.COM.":     "openfamily.example.com",
	}
	for in, want := range cases {
		if got := domainHostname(in); got != want {
			t.Errorf("domainHostname(%q)=%q want %q", in, got, want)
		}
	}
}

func TestHostnameFromOrigin(t *testing.T) {
	if got := hostnameFromOrigin("https://openfamily.example.com"); got != "openfamily.example.com" {
		t.Errorf("got %q", got)
	}
	// Plain-http or garbage origins are not public domains.
	for _, in := range []string{"", "http://insecure.example", "not a url"} {
		if got := hostnameFromOrigin(in); got != "" {
			t.Errorf("hostnameFromOrigin(%q)=%q want empty", in, got)
		}
	}
}
