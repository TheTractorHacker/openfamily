package geocode

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

const googleHouseJSON = `{"status":"OK","results":[{"formatted_address":"14322 Old 88 Rd, Chester, AR 72934, USA",
"types":["street_address"],"address_components":[{"long_name":"14322","types":["street_number"]},{"long_name":"Old 88 Road","types":["route"]}],
"geometry":{"location":{"lat":35.6511,"lng":-94.2549},"location_type":"RANGE_INTERPOLATED"}}]}`

const googleCityJSON = `{"status":"OK","results":[{"formatted_address":"Chester, AR 72934, USA",
"types":["locality","political"],"geometry":{"location":{"lat":35.69,"lng":-94.17},"location_type":"APPROXIMATE"}}]}`

func googleOK(body string) func(*http.Request) (int, []byte) {
	return func(*http.Request) (int, []byte) { return 200, []byte(body) }
}

type googleEnv struct {
	*fallbackEnv
	goog *recorder
}

// setupGoogle wires Photon (street-only for the owner), Census (no match
// unless censusH says otherwise) and a fake Google, all on httptest servers.
func setupGoogle(t *testing.T, censusH, googleH func(*http.Request) (int, []byte), mod func(*Settings)) *googleEnv {
	t.Helper()
	e := &googleEnv{fallbackEnv: &fallbackEnv{}}
	var pu, nu, cu, gu string
	e.photon, pu = serve(t, photonLadder(t))
	e.nom, nu = serve(t, emptyNom(t))
	e.cen, cu = serve(t, censusH)
	e.goog, gu = serve(t, googleH)
	s := Settings{URL: pu, FallbackURL: nu, CensusEnabled: true, CensusURL: cu,
		GoogleAPIKey: "test-key-not-real", GoogleURL: gu}
	if mod != nil {
		mod(&s)
	}
	e.svc = newSvc(t, s)
	for _, g := range []*gate{e.svc.fb.nomGate, e.svc.fb.censusGate} {
		g.sleep = func(context.Context, time.Duration) error { return nil }
	}
	return e
}

func censusNoMatch(t *testing.T) func(*http.Request) (int, []byte) {
	return func(*http.Request) (int, []byte) { return 200, fixture(t, "census_live_nomatch.json") }
}

func TestGoogleParse(t *testing.T) {
	rs, err := parseGoogle([]byte(googleHouseJSON), true)
	if err != nil || len(rs) != 1 {
		t.Fatalf("%v %v", rs, err)
	}
	r := rs[0]
	if r.Type != "house" || r.Approximate || r.Source != "google" || r.Name != "14322 Old 88 Road" ||
		r.Label != "14322 Old 88 Rd, Chester, AR 72934, USA" || r.Lat != 35.6511 {
		t.Fatalf("%+v", r)
	}
	rs, _ = parseGoogle([]byte(googleCityJSON), true)
	if len(rs) != 1 || rs[0].Type != "city" || !rs[0].Approximate || rs[0].Matched != "locality" || rs[0].Name != "Chester" {
		t.Fatalf("%+v", rs)
	}
	if rs, _ = parseGoogle([]byte(`{"status":"ZERO_RESULTS","results":[]}`), true); len(rs) != 0 {
		t.Fatal("zero results")
	}
	if _, err = parseGoogle([]byte(`{"status":"REQUEST_DENIED"}`), true); err == nil {
		t.Fatal("denied must be an error")
	}
	if _, err = parseGoogle(fixture(t, "malformed.json"), true); err == nil {
		t.Fatal("malformed must be an error")
	}
}

func TestGoogleUsedWhenFreeProvidersMissHouse(t *testing.T) {
	e := setupGoogle(t, censusNoMatch(t), googleOK(googleHouseJSON), nil)
	resp, err := e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true, Bias: &Point{35.31, -94.39}})
	if err != nil || e.goog.count() != 1 || !resp.Google || resp.Results[0].Source != "google" || resp.Results[0].Approximate {
		t.Fatalf("goog=%d err=%v %+v", e.goog.count(), err, resp)
	}
	q := e.goog.last().Query()
	if e.goog.last().Path != "/maps/api/geocode/json" || q.Get("key") != "test-key-not-real" ||
		q.Get("address") != "14322 Old 88 Road, Chester, Arkansas" || q.Get("region") != "us" ||
		q.Get("bounds") != "34.810,-94.890|35.810,-93.890" {
		t.Fatalf("google request: %s", e.goog.last())
	}
	// Cache hit: same query again costs nothing.
	resp, _ = e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true, Bias: &Point{35.31, -94.39}})
	if e.goog.count() != 1 || !resp.Google || !resp.Cached {
		t.Fatalf("not cached: %d %+v", e.goog.count(), resp)
	}
	if e.svc.goog.used != 1 {
		t.Fatalf("used=%d", e.svc.goog.used)
	}
}

func TestGoogleSkippedWhenCensusHasExactHouse(t *testing.T) {
	e := setupGoogle(t, censusOwner(t), googleOK(googleHouseJSON), nil)
	resp, _ := e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true, Bias: &Point{35.31, -94.39}})
	if e.goog.count() != 0 || resp.Google || resp.Results[0].Source != "census" {
		t.Fatalf("google used despite a free exact match: %d", e.goog.count())
	}
}

func TestGoogleSkippedByCostRules(t *testing.T) {
	ctx := context.Background()
	e := setupGoogle(t, censusNoMatch(t), googleOK(googleHouseJSON), nil)
	// Too short, even explicit and empty.
	e.svc.SearchWith(ctx, "u1", "12 Elm", SearchOptions{Explicit: true})
	// No house number, results exist (Photon answers Chester).
	e.photon.h = func(*http.Request) (int, []byte) { return 200, fixture(t, "photon_live_chester_ar.json") }
	e.svc.SearchWith(ctx, "u1", "Chester, Arkansas", SearchOptions{Explicit: true})
	// Typing with a single part.
	e.photon.h = func(*http.Request) (int, []byte) { return 200, fixture(t, "photon_empty.json") }
	e.svc.SearchWith(ctx, "u1", "14322 Old 88 Road", SearchOptions{})
	// Typing without a house number, nothing found.
	e.svc.SearchWith(ctx, "u1", "Somewhere Nowhere, Zzyzx", SearchOptions{})
	if e.goog.count() != 0 {
		t.Fatalf("google called %d times", e.goog.count())
	}
	// Explicit and empty without a house number is allowed.
	e.svc.SearchWith(ctx, "u1", "Zzyzx Hot Springs, California", SearchOptions{Explicit: true})
	if e.goog.count() != 1 {
		t.Fatalf("explicit+empty should reach google: %d", e.goog.count())
	}
	// Typing with a house number and two parts is allowed.
	e.svc.SearchWith(ctx, "u1", "14322 Old 88 Road, Chester", SearchOptions{})
	if e.goog.count() != 2 {
		t.Fatalf("typing with 2 parts: %d", e.goog.count())
	}
}

func TestGoogleMonthlyCap(t *testing.T) {
	e := setupGoogle(t, censusNoMatch(t), googleOK(googleCityJSON), func(s *Settings) { s.GoogleMonthlyCap = 2 })
	now := time.Date(2026, 3, 31, 23, 0, 0, 0, time.UTC)
	e.svc.goog.now = func() time.Time { return now }
	ctx := context.Background()
	for _, q := range []string{"1 First Street, Chester, AR", "2 Second Street, Chester, AR", "3 Third Street, Chester, AR"} {
		e.svc.SearchWith(ctx, "u1", q, SearchOptions{Explicit: true})
	}
	if e.goog.count() != 2 {
		t.Fatalf("cap not enforced: %d", e.goog.count())
	}
	// Month rollover resets the counter.
	now = now.Add(2 * time.Hour)
	e.svc.SearchWith(ctx, "u1", "3 Third Street, Chester, AR", SearchOptions{Explicit: true})
	if e.goog.count() != 3 {
		t.Fatalf("no reset at month rollover: %d", e.goog.count())
	}
}

func TestGoogleDisabledWithoutKey(t *testing.T) {
	e := setupGoogle(t, censusNoMatch(t), googleOK(googleHouseJSON), func(s *Settings) { s.GoogleAPIKey = "  " })
	if e.svc.GoogleEnabled() {
		t.Fatal("enabled without key")
	}
	resp, err := e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true})
	if err != nil || e.goog.count() != 0 || resp.Google {
		t.Fatalf("google used without a key: %d %v", e.goog.count(), err)
	}
}

func TestGoogleFailureDoesNotBreakSearch(t *testing.T) {
	e := setupGoogle(t, censusNoMatch(t), func(*http.Request) (int, []byte) { return 500, []byte("boom") }, nil)
	resp, err := e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true})
	if err != nil || len(resp.Results) == 0 || resp.Google {
		t.Fatalf("%v %+v", err, resp)
	}
}

func TestGoogleBaseURLRules(t *testing.T) {
	// Without the test override the host is the fixed constant.
	s, err := New(Settings{URL: "https://1.1.1.1", GoogleAPIKey: "k"})
	if err != nil || s.goog == nil || s.goog.base.Host != "maps.googleapis.com" {
		t.Fatalf("%v", err)
	}
	// An override obeys the SSRF rules: private hosts need AllowPrivate.
	s, _ = New(Settings{URL: "https://1.1.1.1", GoogleAPIKey: "k", GoogleURL: "http://127.0.0.1:1"})
	if s.goog != nil || s.GoogleError() == nil {
		t.Fatal("private google url accepted")
	}
}

func TestCensusPartialStateRetry(t *testing.T) {
	cases := map[string]string{
		"14322 Old 88 Rd, Chester A":    "14322 Old 88 Road, Chester, AR",
		"14322 Old 88 Rd, Chester, A":   "14322 Old 88 Road, Chester, AR",
		"14322 Old 88 Rd, Chester, Ark": "14322 Old 88 Road, Chester, AR",
	}
	for in, want := range cases {
		var addr string
		e := setupFallback(t, emptyNom(t), func(r *http.Request) (int, []byte) {
			if strings.Contains(r.URL.Path, "geographies") {
				return 200, []byte(`{"result":{"geographies":{"States":[{"STUSAB":"AR"}]}}}`)
			}
			addr = r.URL.Query().Get("address")
			return 200, fixture(t, "census_live_owner_match.json")
		})
		resp, err := e.svc.SearchWith(context.Background(), "u1", in, SearchOptions{Explicit: true, Bias: &Point{35.31, -94.39}})
		if err != nil || addr != want || resp.Results[0].Source != "census" {
			t.Fatalf("%q: census address %q err=%v", in, addr, err)
		}
	}
}

func TestPartialStateToken(t *testing.T) {
	for tok, want := range map[string]bool{"A": true, "Ar": false, "Zz": true, "Ark": true, "Arkansas": false,
		"New": true, "Chester": false, "12": false, "72934": false} {
		if got := partialStateToken(tok); got != want {
			t.Errorf("%q: got %v want %v", tok, got, want)
		}
	}
}
