package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

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
}

func TestAdminGetDomainStatusCustomDomainOK(t *testing.T) {
	srv := &Server{
		SiteAddress:   "openfamily.example.com",
		PublicBaseURL: "https://openfamily.example.com",
	}
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
	if got.HTTPS.Status != domainCheckOK {
		t.Fatalf("https=%+v", got.HTTPS)
	}
}

func TestAdminGetDomainStatusFallsBackToPublicBaseURL(t *testing.T) {
	srv := &Server{
		SiteAddress:   ":80",
		PublicBaseURL: "https://openfamily.example.com",
	}
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
	// A non-200 answer is a fail with detail, not an error swallow.
	if got.HTTPS.Status != domainCheckFail || got.HTTPS.Detail == "" {
		t.Fatalf("https=%+v", got.HTTPS)
	}
}

func TestAdminGetDomainStatusDNSTimeoutIsFail(t *testing.T) {
	srv := &Server{SiteAddress: "openfamily.example.com"}
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
	if got.DNS.Status != domainCheckFail || got.HTTPS.Status != domainCheckFail {
		t.Fatalf("dns=%+v https=%+v", got.DNS, got.HTTPS)
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
		"OpenFamily.Example.COM.":        "openfamily.example.com",
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
