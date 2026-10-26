package handlers

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/geocode"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

const geoUser = "11111111-1111-1111-1111-111111111111"

func geoFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("../geocode/testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func geoServer(t *testing.T, typ string, h http.HandlerFunc) *Server {
	t.Helper()
	ts := httptest.NewServer(h)
	t.Cleanup(ts.Close)
	svc, err := geocode.New(geocode.Settings{URL: ts.URL, Type: typ, AllowPrivate: true})
	if err != nil {
		t.Fatal(err)
	}
	return &Server{Geocoder: svc, AuthLimit: sms.NewLimiter()}
}

func geoCall(h http.HandlerFunc, target, user string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, target, nil)
	if user != "" {
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), testClaims(user)))
	}
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestGeocodeDisabledContract(t *testing.T) {
	s := &Server{}
	for _, h := range []http.HandlerFunc{s.GeocodeSearch, s.GeocodeReverse} {
		rec := geoCall(h, "/geocode/x?q=abc&lat=1&lon=2", geoUser)
		if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "geocoding is not configured") {
			t.Fatalf("%d %s", rec.Code, rec.Body)
		}
	}
	w := httptest.NewRecorder()
	s.GetConfig(w, httptest.NewRequest(http.MethodGet, "/config", nil))
	var body map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	g, _ := body["geocoder"].(map[string]any)
	if g["enabled"] != false || g["autocomplete"] != false {
		t.Fatalf("geocoder=%v", body["geocoder"])
	}
}

func TestGeocodeConfigAdvertisesWithoutURL(t *testing.T) {
	s := geoServer(t, "photon", func(http.ResponseWriter, *http.Request) {})
	w := httptest.NewRecorder()
	s.GetConfig(w, httptest.NewRequest(http.MethodGet, "/config", nil))
	var body map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	g, _ := body["geocoder"].(map[string]any)
	if g["enabled"] != true || g["autocomplete"] != true || len(g) != 2 {
		t.Fatalf("geocoder=%v", body["geocoder"])
	}
	if strings.Contains(w.Body.String(), "127.0.0.1") {
		t.Fatal("provider URL leaked")
	}
}

func TestGeocodeAuthRequired(t *testing.T) {
	s := geoServer(t, "photon", func(http.ResponseWriter, *http.Request) {
		t.Error("provider reached without auth")
	})
	if rec := geoCall(s.GeocodeSearch, "/geocode/search?q=abcd", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("search %d", rec.Code)
	}
	if rec := geoCall(s.GeocodeReverse, "/geocode/reverse?lat=1&lon=2", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("reverse %d", rec.Code)
	}
}

func TestGeocodeSearchOK(t *testing.T) {
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		w.Write(geoFixture(t, "photon_poi.json"))
	})
	rec := geoCall(s.GeocodeSearch, "/geocode/search?q=lincoln&lat=39.8&lon=-89.6&limit=3", geoUser)
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var out struct {
		Results []geocode.Result `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || len(out.Results) != 2 || out.Results[0].Type != "poi" {
		t.Fatalf("%v %s", err, rec.Body)
	}
}

func TestGeocodeSearchEmptyIsArray(t *testing.T) {
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) { w.Write(geoFixture(t, "photon_empty.json")) })
	rec := geoCall(s.GeocodeSearch, "/geocode/search?q=zzzz", geoUser)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"results":[]`) {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

func TestGeocodeValidation(t *testing.T) {
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		t.Error("invalid request reached provider")
	})
	for _, u := range []string{
		"/geocode/search", "/geocode/search?q=ab", "/geocode/search?q=" + strings.Repeat("a", 121),
		"/geocode/search?q=abc&lat=91&lon=0", "/geocode/search?q=abc&lat=1", "/geocode/search?q=abc&lat=NaN&lon=0",
		"/geocode/search?q=abc&limit=0",
	} {
		if rec := geoCall(s.GeocodeSearch, u, geoUser); rec.Code != 400 {
			t.Errorf("%s -> %d", u, rec.Code)
		}
	}
	for _, u := range []string{"/geocode/reverse", "/geocode/reverse?lat=1", "/geocode/reverse?lat=1&lon=181", "/geocode/reverse?lat=Inf&lon=1"} {
		if rec := geoCall(s.GeocodeReverse, u, geoUser); rec.Code != 400 {
			t.Errorf("%s -> %d", u, rec.Code)
		}
	}
}

func TestGeocodeReverseFoundAndNotFound(t *testing.T) {
	s := geoServer(t, "nominatim", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("lat") == "10.00000" {
			w.Write(geoFixture(t, "nominatim_reverse_none.json"))
			return
		}
		w.Write(geoFixture(t, "nominatim_reverse.json"))
	})
	rec := geoCall(s.GeocodeReverse, "/geocode/reverse?lat=39.799&lon=-89.65", geoUser)
	var a geocode.Address
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &a) != nil || a.Address != "123 Main Street, Springfield, Illinois" {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	rec = geoCall(s.GeocodeReverse, "/geocode/reverse?lat=10&lon=10", geoUser)
	if rec.Code != 404 || !strings.Contains(rec.Body.String(), "no address found") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

func TestGeocodeProviderFailureIs502(t *testing.T) {
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) })
	rec := geoCall(s.GeocodeSearch, "/geocode/search?q=abcd", geoUser)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("%d", rec.Code)
	}
}

func TestGeocodeRateLimits(t *testing.T) {
	var hits int32
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(geoFixture(t, "photon_house.json"))
	})
	var last int
	for i := 0; i <= geocodeSearchPerMin; i++ {
		last = geoCall(s.GeocodeSearch, "/geocode/search?q=abcd", geoUser).Code // cache hits still count
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("search last=%d", last)
	}
	if hits != 1 {
		t.Fatalf("provider hits=%d, cache should absorb repeats", hits)
	}
	if geoCall(s.GeocodeSearch, "/geocode/search?q=abcd", "22222222-2222-2222-2222-222222222222").Code != 200 {
		t.Fatal("other user throttled")
	}
	for i := 0; i <= geocodeReversePerMin; i++ {
		last = geoCall(s.GeocodeReverse, "/geocode/reverse?lat=1&lon=2", geoUser).Code
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("reverse last=%d", last)
	}
}

func TestGeocodeLogsNeverContainQueryOrCoordinates(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(old) })

	fail := false
	s := geoServer(t, "photon", func(w http.ResponseWriter, r *http.Request) {
		if fail {
			w.WriteHeader(500)
			return
		}
		w.Write(geoFixture(t, "photon_house.json"))
	})
	const secret = "Zxqv Lane 777"
	geoCall(s.GeocodeSearch, "/geocode/search?q=Zxqv+Lane+777&lat=48.8584&lon=2.2945", geoUser)
	geoCall(s.GeocodeReverse, "/geocode/reverse?lat=48.85841&lon=2.29451", geoUser)
	fail = true
	geoCall(s.GeocodeSearch, "/geocode/search?q=Zxqv+Lane+778", geoUser)
	geoCall(s.GeocodeReverse, "/geocode/reverse?lat=51.5007&lon=-0.1246", geoUser)
	out := buf.String()
	if out == "" {
		t.Fatal("expected some logs")
	}
	for _, bad := range []string{secret, "Zxqv", "Lane", "48.85", "2.29", "51.50", "0.124", "q="} {
		if strings.Contains(out, bad) {
			t.Errorf("log contains %q:\n%s", bad, out)
		}
	}
}

func TestGeocodeAutocompleteRefusedOnPublicNominatimPolicy(t *testing.T) {
	// Simulate the autocomplete-disabled mode via a public-host service.
	svc, err := geocode.New(geocode.Settings{URL: "https://nominatim.openstreetmap.org", Type: "nominatim"})
	if err != nil {
		t.Skipf("offline: %v", err)
	}
	s := &Server{Geocoder: svc}
	rec := geoCall(s.GeocodeSearch, "/geocode/search?q=abcd", geoUser)
	if rec.Code != 400 || !strings.Contains(rec.Body.String(), "autocomplete is disabled") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}
