package handlers

import (
	"errors"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func stubCertVia(t *testing.T, fn func(host, addr string) tlsResult) {
	t.Helper()
	old := certVia
	certVia = fn
	tlsCacheMu.Lock()
	tlsCache = map[string]tlsResult{}
	tlsCacheMu.Unlock()
	t.Cleanup(func() {
		certVia = old
		tlsCacheMu.Lock()
		tlsCache = map[string]tlsResult{}
		tlsCacheMu.Unlock()
	})
}

// The built-in proxy is asked first, so a router without NAT loopback does not
// hide a valid certificate.
func TestLookupCertPrefersLocalProxy(t *testing.T) {
	var tried []string
	stubCertVia(t, func(host, addr string) tlsResult {
		tried = append(tried, addr)
		if addr == "caddy:443" {
			return tlsResult{at: time.Now(), expiry: time.Now().Add(60 * 24 * time.Hour)}
		}
		t.Errorf("public address must not be dialled when the proxy answered: %s", addr)
		return tlsResult{}
	})
	srv := &Server{SiteAddress: "family.example.org"}
	r := httptest.NewRequest("GET", "https://family.example.org/api/admin/system/checks", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	c := srv.checkTLS(r)
	if c.Status != checkOK || len(tried) != 1 {
		t.Fatalf("check=%+v tried=%v", c, tried)
	}
}

// Without a built-in proxy it falls back to the public address.
func TestLookupCertFallsBackToPublicAddress(t *testing.T) {
	var tried []string
	stubCertVia(t, func(host, addr string) tlsResult {
		tried = append(tried, addr)
		if addr == "caddy:443" {
			return tlsResult{at: time.Now(), err: &net.DNSError{Err: "no such host", Name: "caddy", IsNotFound: true}, dialErr: true}
		}
		return tlsResult{at: time.Now(), expiry: time.Now().Add(30 * 24 * time.Hour)}
	})
	res := lookupCert("family.example.org", "caddy:443", "family.example.org:443")
	if res.err != nil || len(tried) != 2 || tried[1] != "family.example.org:443" {
		t.Fatalf("res=%+v tried=%v", res, tried)
	}
}

// Nothing answers from inside (own reverse proxy + hairpin-less router): that
// is information with a plain explanation, not a warning or failure.
func TestCheckTLSUnreachableFromInsideIsInfo(t *testing.T) {
	stubCertVia(t, func(host, addr string) tlsResult {
		return tlsResult{at: time.Now(), err: errors.New("dial tcp: i/o timeout"), dialErr: true}
	})
	srv := &Server{SiteAddress: "family.example.org"}
	r := httptest.NewRequest("GET", "https://family.example.org/", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	c := srv.checkTLS(r)
	if c.Status != checkInfo || !strings.Contains(c.Hint, "NAT loopback") || !strings.Contains(c.Hint, "mobile data") {
		t.Fatalf("check=%+v", c)
	}
}

// A certificate that answers but is not trusted is still a warning.
func TestCheckTLSUntrustedIsWarn(t *testing.T) {
	stubCertVia(t, func(host, addr string) tlsResult {
		return tlsResult{at: time.Now(), expiry: time.Now().Add(24 * time.Hour * 40), err: errors.New("x509: certificate signed by unknown authority")}
	})
	srv := &Server{SiteAddress: "family.example.org"}
	c := srv.checkTLS(httptest.NewRequest("GET", "https://family.example.org/", nil))
	if c.Status != checkWarn || c.Hint == "" {
		t.Fatalf("check=%+v", c)
	}
}
