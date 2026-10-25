package handlers

import (
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

func TestFirstName(t *testing.T) {
	if got := firstName("Frank Johnette"); got != "Frank" {
		t.Fatalf("got %q", got)
	}
	if got := firstName(""); got != "A family member" {
		t.Fatalf("got %q", got)
	}
}

func TestShareExpired(t *testing.T) {
	created := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if shareExpired(created, created.Add(23*time.Hour)) {
		t.Fatal("23h should not expire")
	}
	if !shareExpired(created, created.Add(25*time.Hour)) {
		t.Fatal("25h should expire")
	}
}

func TestAlertSMSBody(t *testing.T) {
	got := alertSMSBody("Frank", alertCheckIn, "https://example.com/alerts/share/abc")
	if got != "Frank checked in. https://example.com/alerts/share/abc" {
		t.Fatalf("got %q", got)
	}
	sos := alertSMSBody("Frank", alertSOS, "https://example.com/x")
	if sos != "Frank sent SOS. https://example.com/x" {
		t.Fatalf("sos %q", sos)
	}
	lat, lon := 37.7, -122.4
	loc := alertLocationText("", &lat, &lon)
	if loc == "" {
		t.Fatal("expected lat/lon fallback")
	}
}

func TestPostCheckInUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Post("/alerts/check-in", srv.PostCheckIn)
	req := httptest.NewRequest(http.MethodPost, "/alerts/check-in", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestPostHelpUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Post("/alerts/help", srv.PostHelp)
	req := httptest.NewRequest(http.MethodPost, "/alerts/help", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestPostSOSUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Post("/alerts/sos", srv.PostSOS)
	req := httptest.NewRequest(http.MethodPost, "/alerts/sos", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestGetAlertUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Get("/alerts/{id}", srv.GetAlert)
	req := httptest.NewRequest(http.MethodGet, "/alerts/abc", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestResolveAlertUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Post("/alerts/{id}/resolve", srv.ResolveAlert)
	req := httptest.NewRequest(http.MethodPost, "/alerts/abc/resolve", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestShareURLRequiresHTTPS(t *testing.T) {
	srv := &Server{PublicBaseURL: "http://localhost"}
	if srv.shareURL("abc") != "" {
		t.Fatal("http origin must not produce a share URL")
	}
	srv.PublicBaseURL = "https://openfamily.example.com"
	if srv.shareURL("abc") != "https://openfamily.example.com/alerts/share/abc" {
		t.Fatalf("got %q", srv.shareURL("abc"))
	}
}

func TestSharePageHeadersNoScriptAndResolvedHidesLocation(t *testing.T) {
	lat, lon := 51.50735, -0.12776
	a := alertRow{Type: alertSOS, Status: alertStatusActive, Lat: &lat, Lon: &lon, SenderName: "Sam Doe", CreatedAt: time.Now()}

	page := sharePageHTML(a)
	if strings.Contains(page, "<script") || strings.Contains(page, "unpkg.com") {
		t.Fatalf("share page still loads script/third-party code:\n%s", page)
	}
	if !strings.Contains(page, "51.50735") {
		t.Fatal("active alert should show the location")
	}

	a.Status = "resolved"
	page = sharePageHTML(a)
	if strings.Contains(page, "51.50735") || strings.Contains(page, "openstreetmap") {
		t.Fatalf("resolved alert still reveals location:\n%s", page)
	}

	rec := httptest.NewRecorder()
	setShareHeaders(rec)
	for k, want := range map[string]string{
		"Referrer-Policy":         "no-referrer",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Content-Security-Policy": shareCSP,
		"Cache-Control":           "no-store",
	} {
		if got := rec.Header().Get(k); got != want {
			t.Errorf("%s=%q want %q", k, got, want)
		}
	}
	if !strings.Contains(shareCSP, "default-src 'none'") || strings.Contains(shareCSP, "script-src") {
		t.Fatalf("CSP should forbid scripts: %s", shareCSP)
	}
	if !strings.Contains(rec.Header().Get("X-Robots-Tag"), "noindex") {
		t.Error("missing noindex")
	}
}

func TestValidAlertCoord(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	nan, inf := math.NaN(), math.Inf(1)
	cases := []struct {
		v        *float64
		min, max float64
		ok       bool
	}{
		{nil, -90, 90, true},
		{f(0), -90, 90, true},
		{f(90), -90, 90, true},
		{f(-90.0001), -90, 90, false},
		{f(91), -90, 90, false},
		{f(180), -180, 180, true},
		{f(1e12), -180, 180, false},
		{&nan, -90, 90, false},
		{&inf, -180, 180, false},
	}
	for i, c := range cases {
		if got := validAlertCoord(c.v, c.min, c.max); got != c.ok {
			t.Errorf("case %d: got %v want %v", i, got, c.ok)
		}
	}
}

// Out-of-range client coordinates are refused before any database access.
func TestDecodeAlertRequestRejectsOutOfRangeCoordinates(t *testing.T) {
	for body, wantErr := range map[string]bool{
		`{"lat": 123.4, "lon": 10}`:   true,
		`{"lat": 10, "lon": -181}`:    true,
		`{"lat": 1e12, "lon": 1}`:     true,
		`{"lat": 51.5, "lon": -0.12}`: false,
		`{"note": "help"}`:            false,
		`{"lat": 90, "lon": 180}`:     false,
		`{"lat": "north", "lon": 1}`:  true,
	} {
		req := httptest.NewRequest(http.MethodPost, "/alerts/sos", strings.NewReader(body))
		_, _, msg := decodeAlertRequest(req)
		if (msg != "") != wantErr {
			t.Errorf("%s: msg=%q wantErr=%v", body, msg, wantErr)
		}
	}
}
