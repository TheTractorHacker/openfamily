package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

func joinReq(s *Server, path, host string) *httptest.ResponseRecorder {
	r := chi.NewRouter()
	r.Get("/join/{code}", s.JoinLanding)
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Host = host
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	return rec
}

func TestJoinLandingValidCode(t *testing.T) {
	s := &Server{PublicBaseURL: "https://fam.example.com/"}
	rec := joinReq(s, "/join/ab23-cdef", "ignored.example")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"AB23CDEF", "openfamily://join?code=AB23CDEF&amp;server=https%3A%2F%2Ffam.example.com"} {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q:\n%s", want, body)
		}
	}
	if rec.Header().Get("Cache-Control") != "no-store" || rec.Header().Get("Content-Security-Policy") == "" {
		t.Error("missing security headers")
	}
}

func TestJoinLandingFallsBackToRequestHost(t *testing.T) {
	rec := joinReq(&Server{}, "/join/AB23CDEF", "fam.example.com")
	if !strings.Contains(rec.Body.String(), "https%3A%2F%2Ffam.example.com") {
		t.Errorf("host fallback missing: %s", rec.Body.String())
	}
}

func TestJoinLandingRejectsBadInput(t *testing.T) {
	for _, path := range []string{"/join/short", "/join/%3Cscript%3Ealert1", "/join/AB23CDEF9"} {
		rec := joinReq(&Server{PublicBaseURL: "https://x.example"}, path, "x.example")
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: status %d", path, rec.Code)
		}
		if strings.Contains(rec.Body.String(), "<script") || strings.Contains(rec.Body.String(), "openfamily://") {
			t.Errorf("%s: leaked input or link", path)
		}
	}
	rec := joinReq(&Server{}, "/join/AB23CDEF", "bad host!")
	if rec.Code != http.StatusNotFound {
		t.Errorf("bad host accepted: %d", rec.Code)
	}
}

func TestJoinLandingHasInstallPathAndQR(t *testing.T) {
	rec := joinReq(&Server{PublicBaseURL: "https://fam.example.com"}, "/join/AB23CDEF", "x")
	body := rec.Body.String()
	for _, want := range []string{`href="/app.apk"`, "<svg", "QR code for this invite page", "Install anyway"} {
		if !strings.Contains(body, want) {
			t.Errorf("page missing %q", want)
		}
	}
	// The CSP forbids scripts, so the page must not rely on any.
	if strings.Contains(body, "<script") {
		t.Error("page must not contain scripts")
	}
	if got := rec.Header().Get("Content-Security-Policy"); !strings.Contains(got, "default-src 'none'") {
		t.Errorf("CSP loosened: %q", got)
	}
}

func TestQRSVGEncodesAndIsDeterministic(t *testing.T) {
	a := qrSVG("https://fam.example.com/join/AB23CDEF")
	if !strings.HasPrefix(string(a), "<svg") || !strings.Contains(string(a), "<path") {
		t.Fatalf("unexpected svg: %.80s", a)
	}
	if a != qrSVG("https://fam.example.com/join/AB23CDEF") {
		t.Error("QR output not deterministic")
	}
}

func TestPublicDownloadAPKWithoutConfigIs404(t *testing.T) {
	rec := httptest.NewRecorder()
	(&Server{}).PublicDownloadAPK(rec, httptest.NewRequest(http.MethodGet, "/app.apk", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d", rec.Code)
	}
}
