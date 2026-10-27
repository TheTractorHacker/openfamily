package geocode

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// recorder serves canned bodies and records every request URL.
type recorder struct {
	mu   sync.Mutex
	urls []*url.URL
	h    func(r *http.Request) (int, []byte)
}

func (rc *recorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rc.mu.Lock()
	rc.urls = append(rc.urls, r.URL)
	rc.mu.Unlock()
	code, body := rc.h(r)
	w.WriteHeader(code)
	w.Write(body)
}

func (rc *recorder) count() int { rc.mu.Lock(); defer rc.mu.Unlock(); return len(rc.urls) }
func (rc *recorder) last() *url.URL {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return rc.urls[len(rc.urls)-1]
}

func serve(t *testing.T, h func(r *http.Request) (int, []byte)) (*recorder, string) {
	t.Helper()
	rc := &recorder{h: h}
	ts := httptest.NewServer(rc)
	t.Cleanup(ts.Close)
	return rc, ts.URL
}

// photonLadder answers like the live Photon did: nothing for the house-number
// forms, a street hit when the number is dropped, a city for the locality.
func photonLadder(t *testing.T) func(r *http.Request) (int, []byte) {
	return func(r *http.Request) (int, []byte) {
		switch r.URL.Query().Get("q") {
		case "Old 88 Road, Chester, Arkansas":
			return 200, fixture(t, "photon_live_old88_street.json")
		case "Chester, Arkansas":
			return 200, fixture(t, "photon_live_chester_ar.json")
		}
		return 200, fixture(t, "photon_empty.json")
	}
}

const owner = "14322 Old 88rd, Chester Ar"

func newSvc(t *testing.T, s Settings) *Service {
	t.Helper()
	s.AllowPrivate = true
	s.Version = "9.9.9"
	svc, err := New(s)
	if err != nil {
		t.Fatal(err)
	}
	return svc
}

func TestLadderRelaxesAndMarksApproximate(t *testing.T) {
	ph, u := serve(t, photonLadder(t))
	svc := newSvc(t, Settings{URL: u})
	resp, err := svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Limit: 5})
	if err != nil {
		t.Fatal(err)
	}
	if ph.count() != 2 || resp.Attempts != 2 {
		t.Fatalf("calls=%d attempts=%d", ph.count(), resp.Attempts)
	}
	if len(resp.Results) == 0 || !resp.Approximate {
		t.Fatalf("%+v", resp)
	}
	for _, r := range resp.Results {
		if !r.Approximate || r.Matched != "street" {
			t.Fatalf("result not marked: %+v", r)
		}
	}
	if q := ph.last().Query().Get("q"); q != "Old 88 Road, Chester, Arkansas" {
		t.Fatalf("last q %q", q)
	}
}

func TestLadderLocalityAndCap(t *testing.T) {
	ph, u := serve(t, func(r *http.Request) (int, []byte) {
		if r.URL.Query().Get("q") == "Chester, Arkansas" {
			return 200, fixture(t, "photon_live_chester_ar.json")
		}
		return 200, fixture(t, "photon_empty.json")
	})
	svc := newSvc(t, Settings{URL: u})
	resp, err := svc.SearchWith(context.Background(), "u1", owner, SearchOptions{})
	if err != nil || ph.count() != 3 {
		t.Fatalf("calls=%d err=%v", ph.count(), err)
	}
	if resp.Results[0].Matched != "locality" || !resp.Results[0].Approximate {
		t.Fatalf("%+v", resp.Results[0])
	}
	// Nothing anywhere: still capped at MaxAttempts and no error.
	ph2, u2 := serve(t, func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_empty.json") })
	svc2 := newSvc(t, Settings{URL: u2})
	resp, err = svc2.SearchWith(context.Background(), "u1", owner, SearchOptions{})
	if err != nil || len(resp.Results) != 0 || ph2.count() != MaxAttempts {
		t.Fatalf("calls=%d res=%d err=%v", ph2.count(), len(resp.Results), err)
	}
}

func TestExactResultStopsLadderAndIsNotApproximate(t *testing.T) {
	ph, u := serve(t, func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_house.json") })
	svc := newSvc(t, Settings{URL: u})
	resp, _ := svc.SearchWith(context.Background(), "u1", "123 Main Street, Springfield, Illinois", SearchOptions{})
	if ph.count() != 1 || resp.Approximate || resp.Results[0].Approximate || resp.Results[0].Matched != "" {
		t.Fatalf("calls=%d %+v", ph.count(), resp)
	}
}

func TestLadderCachedPerAttemptAndPerUser(t *testing.T) {
	ph, u := serve(t, photonLadder(t))
	svc := newSvc(t, Settings{URL: u})
	ctx := context.Background()
	r1, _ := svc.SearchWith(ctx, "u1", owner, SearchOptions{})
	n := ph.count()
	r2, _ := svc.SearchWith(ctx, "u1", owner, SearchOptions{})
	if ph.count() != n || !r2.Cached || r1.Cached {
		t.Fatalf("calls %d->%d cached=%v/%v", n, ph.count(), r1.Cached, r2.Cached)
	}
	if !r2.Results[0].Approximate {
		t.Fatal("cached relaxed results lost their marking")
	}
	// The cached slice itself must not have been mutated into "approximate".
	if v, ok := svc.cache.get("u1", "s:5:old 88 road, chester, arkansas"); !ok || v.([]Result)[0].Approximate {
		t.Fatal("cache holds marked copy")
	}
	svc.SearchWith(ctx, "u2", owner, SearchOptions{})
	if ph.count() != 2*n {
		t.Fatalf("u2 must hit upstream itself: %d", ph.count())
	}
}

func TestBiasParameters(t *testing.T) {
	ph, u := serve(t, func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_house.json") })
	svc := newSvc(t, Settings{URL: u, Lang: "en"})
	svc.SearchWith(context.Background(), "u1", "14322 Old Highway 88", SearchOptions{Bias: &Point{35.31049, -94.39051}})
	q := ph.last().Query()
	if q.Get("lat") != "35.310" || q.Get("lon") != "-94.391" || q.Get("location_bias_scale") != "0.6" {
		t.Fatalf("bias: %s", ph.last())
	}
	svc.SearchWith(context.Background(), "u1", "other query", SearchOptions{})
	q = ph.last().Query()
	if q.Has("lat") || q.Has("location_bias_scale") {
		t.Fatalf("bias sent without a bias point: %s", ph.last())
	}
}

type fallbackEnv struct {
	photon, nom, cen *recorder
	svc              *Service
}

func setupFallback(t *testing.T, nomH, cenH func(r *http.Request) (int, []byte)) *fallbackEnv {
	t.Helper()
	e := &fallbackEnv{}
	var pu, nu, cu string
	e.photon, pu = serve(t, photonLadder(t))
	e.nom, nu = serve(t, nomH)
	e.cen, cu = serve(t, cenH)
	e.svc = newSvc(t, Settings{URL: pu, FallbackURL: nu, CensusEnabled: true, CensusURL: cu})
	if err := e.svc.FallbackError(); err != nil {
		t.Fatal(err)
	}
	// Deterministic gates: no real waiting.
	for _, g := range []*gate{e.svc.fb.nomGate, e.svc.fb.censusGate} {
		g.sleep = func(context.Context, time.Duration) error { return nil }
	}
	return e
}

func emptyNom(t *testing.T) func(*http.Request) (int, []byte) {
	return func(*http.Request) (int, []byte) { return 200, fixture(t, "nominatim_empty.json") }
}
func censusOwner(t *testing.T) func(*http.Request) (int, []byte) {
	return func(*http.Request) (int, []byte) { return 200, fixture(t, "census_live_owner_match.json") }
}

func TestFallbackOnlyForExplicitSearches(t *testing.T) {
	e := setupFallback(t, emptyNom(t), censusOwner(t))
	ctx := context.Background()
	resp, err := e.svc.SearchWith(ctx, "u1", owner, SearchOptions{Bias: &Point{35.31, -94.39}})
	// Typing may reach Census (a free US geocoder) but never Nominatim.
	if err != nil || e.nom.count() != 0 || e.cen.count() != 1 || resp.Results[0].Source != "census" {
		t.Fatalf("typing path: nom=%d cen=%d %v", e.nom.count(), e.cen.count(), err)
	}
	resp, err = e.svc.SearchWith(ctx, "u1", owner, SearchOptions{Bias: &Point{35.31, -94.39}, Explicit: true})
	if err != nil || e.nom.count() != 1 || e.cen.count() != 1 || !resp.Fallback {
		t.Fatalf("nom=%d cen=%d err=%v", e.nom.count(), e.cen.count(), err)
	}
	first := resp.Results[0]
	if first.Approximate || first.Type != "house" || first.Source != "census" ||
		first.Label != "14322 Old 88 Rd, Chester, AR" || first.Lat < 35.65 || first.Lon > -94.25 {
		t.Fatalf("%+v", first)
	}
	// The exact Census hit outranks the approximate street hits from the ladder.
	if !resp.Results[1].Approximate || resp.Approximate {
		t.Fatalf("%+v", resp.Results)
	}
	// Structured Nominatim parameters for "number street, city, state".
	nq := e.nom.last().Query()
	if nq.Get("street") != "14322 Old 88 Road" || nq.Get("city") != "Chester" || nq.Get("state") != "Arkansas" || nq.Get("countrycodes") != "us" || nq.Has("q") {
		t.Fatalf("nominatim: %s", e.nom.last())
	}
	cq := e.cen.last().Query()
	if e.cen.last().Path != "/geocoder/locations/onelineaddress" || cq.Get("address") != "14322 Old 88 Road, Chester, Arkansas" ||
		cq.Get("benchmark") != "Public_AR_Current" || cq.Get("format") != "json" {
		t.Fatalf("census: %s", e.cen.last())
	}
	// Repeating the explicit search is served from the per-user cache.
	e.svc.SearchWith(ctx, "u1", owner, SearchOptions{Bias: &Point{35.31, -94.39}, Explicit: true})
	if e.nom.count() != 1 || e.cen.count() != 1 {
		t.Fatal("fallback results not cached")
	}
}

func TestFallbackNotUsedWhenPhotonHasExactHouseOrNoNumber(t *testing.T) {
	e := setupFallback(t, emptyNom(t), censusOwner(t))
	e.photon.h = func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_house.json") }
	e.svc.SearchWith(context.Background(), "u1", "123 Main Street, Springfield, Illinois", SearchOptions{Explicit: true})
	if e.nom.count()+e.cen.count() != 0 {
		t.Fatal("fallback used despite an exact house match")
	}
	// A city search that Photon answers does not need a fallback either.
	e.photon.h = func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_live_chester_ar.json") }
	e.svc.SearchWith(context.Background(), "u1", "Chester, AR", SearchOptions{Explicit: true})
	if e.nom.count()+e.cen.count() != 0 {
		t.Fatal("fallback used for a locality search")
	}
}

func TestFallbackCensusSkippedWhenNominatimHasHouseAndWhenNotUS(t *testing.T) {
	e := setupFallback(t, func(*http.Request) (int, []byte) { return 200, fixture(t, "nominatim_search.json") }, censusOwner(t))
	resp, _ := e.svc.SearchWith(context.Background(), "u1", "123 Main Street, Springfield, Illinois", SearchOptions{Explicit: true})
	if e.cen.count() != 0 || resp.Results[0].Source != "nominatim" {
		t.Fatalf("cen=%d %+v", e.cen.count(), resp.Results)
	}
	// Not US-looking: no state and a viewer in Paris.
	e2 := setupFallback(t, emptyNom(t), censusOwner(t))
	e2.svc.SearchWith(context.Background(), "u1", "5 Rue de la Paix, Paris", SearchOptions{Explicit: true, Bias: &Point{48.86, 2.33}})
	if e2.cen.count() != 0 || e2.nom.count() != 1 {
		t.Fatalf("cen=%d nom=%d", e2.cen.count(), e2.nom.count())
	}
	// Unknown viewer location (the app sends no bias until the pin moves): a
	// US address without a state must still reach Census.
	e3 := setupFallback(t, emptyNom(t), censusOwner(t))
	resp3, _ := e3.svc.SearchWith(context.Background(), "u1", "14322 Old 88 Rd, Chester", SearchOptions{})
	if e3.cen.count() != 1 || len(resp3.Results) == 0 || resp3.Results[0].Source != "census" {
		t.Fatalf("cen=%d %+v", e3.cen.count(), resp3.Results)
	}
}

func TestFallbackApproximateNominatimStreetHit(t *testing.T) {
	e := setupFallback(t, func(*http.Request) (int, []byte) { return 200, fixture(t, "nominatim_search.json") }, censusOwner(t))
	// nominatim_search.json: house, street, poi; with a number the non-house hits are approximate.
	resp, _ := e.svc.SearchWith(context.Background(), "u1", "123 Main Street, Springfield, Illinois", SearchOptions{Explicit: true})
	_ = resp
	e.photon.h = func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_empty.json") }
	resp, _ = e.svc.SearchWith(context.Background(), "u2", "123 Main Street, Springfield, Illinois", SearchOptions{Explicit: true})
	var street *Result
	for i := range resp.Results {
		if resp.Results[i].Type == "street" {
			street = &resp.Results[i]
		}
	}
	if street == nil || !street.Approximate || street.Matched != "street" {
		t.Fatalf("%+v", resp.Results)
	}
	if resp.Results[0].Approximate {
		t.Fatal("exact house must sort first")
	}
}

func TestFallbackGateSpacingAndBusy(t *testing.T) {
	now := time.Unix(1000, 0)
	g := newGate(time.Second)
	g.now = func() time.Time { return now }
	var slept []time.Duration
	g.sleep = func(_ context.Context, d time.Duration) error { slept = append(slept, d); return nil }
	ctx := context.Background()
	for i := 0; i < 3; i++ { // 0s, 1s, 2s wait
		if err := g.wait(ctx, 2*time.Second); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if len(slept) != 2 || slept[0] != time.Second || slept[1] != 2*time.Second {
		t.Fatalf("slept %v", slept)
	}
	if err := g.wait(ctx, 2*time.Second); !errors.Is(err, ErrBusy) { // would wait 3s
		t.Fatalf("want busy, got %v", err)
	}
	now = now.Add(10 * time.Second)
	if err := g.wait(ctx, 2*time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestFallbackBusyReportsTryAgainOnlyWhenNothingFound(t *testing.T) {
	e := setupFallback(t, emptyNom(t), func(*http.Request) (int, []byte) { return 200, fixture(t, "census_live_nomatch.json") })
	e.photon.h = func(*http.Request) (int, []byte) { return 200, fixture(t, "photon_empty.json") }
	e.svc.fb.nomGate.next = time.Now().Add(time.Hour)
	e.svc.fb.censusGate.next = time.Now().Add(time.Hour)
	resp, err := e.svc.SearchWith(context.Background(), "u1", "14322 Old Highway 88, Chester, AR", SearchOptions{Explicit: true})
	if !errors.Is(err, ErrBusy) || e.nom.count() != 0 || e.cen.count() != 0 {
		t.Fatalf("err=%v %+v", err, resp)
	}
	// With ladder results in hand, a busy fallback is not an error.
	e.photon.h = photonLadder(t)
	resp, err = e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true})
	if err != nil || len(resp.Results) == 0 {
		t.Fatalf("err=%v %+v", err, resp)
	}
}

func TestFallbackSurvivesPhotonOutage(t *testing.T) {
	e := setupFallback(t, emptyNom(t), censusOwner(t))
	e.photon.h = func(*http.Request) (int, []byte) { return 500, nil }
	resp, err := e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true})
	if err != nil || len(resp.Results) != 1 || resp.Results[0].Source != "census" {
		t.Fatalf("%v %+v", err, resp)
	}
	// Autocomplete during an outage reports the error.
	if _, err = e.svc.SearchWith(context.Background(), "u1", "other 12 street", SearchOptions{}); err == nil {
		t.Fatal("expected error")
	}
}

func TestFallbackSSRFAndRedirects(t *testing.T) {
	_, pu := serve(t, photonLadder(t))
	// Private fallback target without opt-in is refused, fallback disabled, primary unaffected.
	bad := []string{"http://127.0.0.1:9", "https://localhost", "https://10.0.0.5", "https://169.254.169.254", "https://user:pw@nominatim.example.com", "ftp://x.example.com"}
	for _, f := range bad {
		svc, err := New(Settings{URL: "https://1.1.1.1", FallbackURL: f})
		if err != nil {
			t.Fatalf("%s: primary must stay valid: %v", f, err)
		}
		if svc.FallbackError() == nil || svc.fb != nil {
			t.Errorf("fallback %q accepted", f)
		}
	}
	svc := newSvc(t, Settings{URL: pu})
	if svc.fb != nil || svc.FallbackError() != nil {
		t.Fatal("no fallback configured must mean no fallback")
	}
	if _, err := New(Settings{URL: "https://1.1.1.1", FallbackURL: "https://8.8.8.8", CensusEnabled: true}); err != nil {
		t.Fatal(err)
	}
	// A redirect from a fallback is not followed.
	var hit int32
	trap := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { atomic.AddInt32(&hit, 1) }))
	defer trap.Close()
	var nomCalls int32
	redir := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&nomCalls, 1)
		http.Redirect(w, r, trap.URL, http.StatusFound)
	}))
	defer redir.Close()
	_, eu := serve(t, func(*http.Request) (int, []byte) { return 200, fixture(t, "photon_empty.json") })
	s2 := newSvc(t, Settings{URL: eu, FallbackURL: redir.URL})
	s2.fb.nomGate.sleep = func(context.Context, time.Duration) error { return nil }
	resp, err := s2.SearchWith(context.Background(), "u1", "14322 Old Highway 88, Chester, AR", SearchOptions{Explicit: true})
	if nomCalls != 1 || atomic.LoadInt32(&hit) != 0 || len(resp.Results) != 0 || err != nil {
		t.Fatalf("redirect: calls=%d trap=%d res=%d err=%v", nomCalls, hit, len(resp.Results), err)
	}
}

func TestFallbackUserAgentAndNoSecretHeaders(t *testing.T) {
	var gotUA, gotCookie string
	e := setupFallback(t, func(r *http.Request) (int, []byte) {
		gotUA = r.Header.Get("User-Agent")
		gotCookie = r.Header.Get("Cookie") + r.Header.Get("Authorization")
		return 200, fixture(t, "nominatim_empty.json")
	}, censusOwner(t))
	e.svc.SearchWith(context.Background(), "u1", owner, SearchOptions{Explicit: true})
	if gotUA != "OpenFamily/9.9.9 (self-hosted)" || gotCookie != "" {
		t.Fatalf("ua=%q hdr=%q", gotUA, gotCookie)
	}
}

func TestNoQueryOrCoordinatesInLogsOrErrors(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(old)
	e := setupFallback(t, func(*http.Request) (int, []byte) { return 500, nil }, func(*http.Request) (int, []byte) { return 500, nil })
	e.photon.h = func(*http.Request) (int, []byte) { return 500, nil }
	_, err := e.svc.SearchWith(context.Background(), "u1", "14322 Old 88rd, Chester Ar", SearchOptions{Bias: &Point{35.31049, -94.39051}, Explicit: true})
	if err == nil {
		t.Fatal("expected error")
	}
	for _, s := range []string{err.Error(), buf.String()} {
		for _, bad := range []string{"14322", "Chester", "35.31", "94.39", "88"} {
			if strings.Contains(s, bad) {
				t.Fatalf("leak of %q in %q", bad, s)
			}
		}
	}
}

func TestCensusParsing(t *testing.T) {
	rs, err := census{}.parse(fixture(t, "census_live_owner_match.json"))
	if err != nil || len(rs) != 1 || rs[0].Name != "14322 Old 88 Rd" || rs[0].Label != "14322 Old 88 Rd, Chester, AR" {
		t.Fatalf("%+v %v", rs, err)
	}
	if rs, err = (census{}).parse(fixture(t, "census_live_nomatch.json")); err != nil || len(rs) != 0 {
		t.Fatalf("%v %v", rs, err)
	}
	if _, err = (census{}).parse(fixture(t, "malformed.json")); err == nil {
		t.Fatal("malformed")
	}
}

func TestIsExactHouseRequiresTheTypedNumber(t *testing.T) {
	wrong := Result{Label: "88 Old Hall Road, Northwich, England", Type: "house"}
	right := Result{Label: "14322 OLD 88 RD, CHESTER, AR, 72934", Type: "house", Source: "census"}
	q := "14322 Old 88 Rd, Chester, AR 72934"
	if isExactHouse(q, wrong) {
		t.Fatal("a house with another number matched")
	}
	if !isExactHouse(q, right) {
		t.Fatal("the matching house did not match")
	}
	if isExactHouse(q, Result{Label: "14322 Old 88 Rd", Type: "street"}) || isExactHouse(q, Result{Label: right.Label, Type: "house", Approximate: true}) {
		t.Fatal("street or approximate hit counted as exact")
	}
	s := &Service{}
	if !s.needFallback(q, []Result{wrong}) || s.needFallback(q, []Result{wrong, right}) {
		t.Fatal("needFallback ignored the house number")
	}
}
