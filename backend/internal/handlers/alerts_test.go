package handlers

import (
	"math"
	"net/http"
	"net/http/httptest"
	"regexp"
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

func TestShareState(t *testing.T) {
	created := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	a := alertRow{CreatedAt: created}
	if shareState(a, created.Add(23*time.Hour)) != shareOK || shareState(a, created.Add(25*time.Hour)) != shareExpiredState {
		t.Fatal("legacy rows keep the 24h lifetime")
	}
	exp := created.Add(time.Hour)
	a.ShareExpiresAt = &exp
	if shareState(a, created.Add(30*time.Minute)) != shareOK || shareState(a, created.Add(2*time.Hour)) != shareExpiredState {
		t.Fatal("explicit expiry must win")
	}
	rev := created.Add(time.Minute)
	a.ShareRevokedAt = &rev
	if shareState(a, created.Add(2*time.Minute)) != shareRevoked {
		t.Fatal("revoked link must not be served")
	}
}

func TestShareTokenIs128BitAndUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		tok, err := newShareToken()
		if err != nil || len(tok) != shareTokenLen {
			t.Fatalf("token %q err=%v", tok, err)
		}
		if seen[tok] {
			t.Fatal("duplicate token")
		}
		seen[tok] = true
	}
	if shareTokenLen*4 < 128 {
		t.Fatal("token below 128 bits")
	}
}

func TestAlertSMSBodyNeverHasCoordinatesOrEmergencyClaims(t *testing.T) {
	got := alertSMSBody("Frank", alertSOS, "https://example.com/alerts/share/abc")
	if !strings.Contains(got, "https://example.com/alerts/share/abc") || !strings.Contains(got, "NOT been contacted") {
		t.Fatalf("got %q", got)
	}
	noLink := alertSMSBody("Frank", alertSOS, "")
	for _, b := range []string{got, noLink} {
		if regexp.MustCompile(`-?\d{1,3}\.\d{3,}`).MatchString(b) {
			t.Fatalf("coordinates in SMS: %q", b)
		}
	}
	if strings.Contains(noLink, "http") {
		t.Fatalf("no link expected: %q", noLink)
	}
}

func TestAlertPushPayloadHidesSenderAndCoordinates(t *testing.T) {
	note := "at 51.50735, -0.12776 help"
	off := &Server{}
	title, body := off.alertPushCopy(alertSOS, "Sam Doe", note)
	for _, v := range []string{title, body} {
		if strings.Contains(v, "Sam") || strings.Contains(v, "51.5") || strings.Contains(v, "help") {
			t.Fatalf("non-verbose push leaks: %q", v)
		}
	}
	on := &Server{VerbosePush: true}
	title, _ = on.alertPushCopy(alertSOS, "Sam Doe", "")
	if title != "Sam sent SOS" {
		t.Fatalf("verbose title %q", title)
	}
	// Whatever the mode, the generated push never carries lat/lon-looking text
	// unless the sender typed it into the note (verbose only).
	for _, s := range []*Server{off, on} {
		for _, typ := range []string{alertCheckIn, alertHelp, alertSOS} {
			ti, bo := s.alertPushCopy(typ, "Sam Doe", "")
			if regexp.MustCompile(`\d+\.\d{3,}`).MatchString(ti + bo) {
				t.Fatalf("coords in push: %q %q", ti, bo)
			}
		}
	}
}

func TestAlertLimitsDefaultsAndEnv(t *testing.T) {
	d := (AlertLimits{}).withDefaults()
	if d.SMSMaxRecipients != 5 || d.ShareTTL != 4*time.Hour || d.SOSCooldown != 2*time.Minute || d.SenderSMSPerDay != 10 || d.SMSOnCheckIn {
		t.Fatalf("defaults %+v", d)
	}
	t.Setenv("ALERT_SMS_MAX_RECIPIENTS", "2")
	t.Setenv("ALERT_SHARE_TTL", "30m")
	t.Setenv("ALERT_SMS_SENDER_PER_DAY", "bogus")
	t.Setenv("ALERT_SMS_ON_CHECKIN", "true")
	e := AlertLimitsFromEnv()
	if e.SMSMaxRecipients != 2 || e.ShareTTL != 30*time.Minute || e.SenderSMSPerDay != 10 || !e.SMSOnCheckIn {
		t.Fatalf("env %+v", e)
	}
	t.Setenv("ALERT_SHARE_TTL", "9999h")
	if AlertLimitsFromEnv().ShareTTL != 7*24*time.Hour {
		t.Fatal("share TTL must be capped")
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
