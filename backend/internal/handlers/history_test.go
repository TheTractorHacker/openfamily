package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func TestFamilyHistoryAccess(t *testing.T) {
	status, _, ok := familyHistoryAccess("fam-a", "fam-a", true)
	if !ok || status != 0 {
		t.Fatalf("same family should be allowed, status=%d ok=%v", status, ok)
	}

	status, msg, ok := familyHistoryAccess("fam-a", "fam-b", true)
	if ok || status != http.StatusForbidden {
		t.Fatalf("other family: status=%d ok=%v msg=%s", status, ok, msg)
	}

	status, _, ok = familyHistoryAccess("fam-a", "", false)
	if ok || status != http.StatusNotFound {
		t.Fatalf("missing member: status=%d ok=%v", status, ok)
	}

	status, _, ok = familyHistoryAccess("", "fam-a", true)
	if ok || status != http.StatusNotFound {
		t.Fatalf("caller with no family: status=%d ok=%v", status, ok)
	}

	status, _, ok = familyHistoryAccess("fam-a", "", true)
	if ok || status != http.StatusForbidden {
		t.Fatalf("target with no family: status=%d ok=%v", status, ok)
	}
}

func TestParseHistoryRange(t *testing.T) {
	now := time.Date(2026, 8, 22, 18, 0, 0, 0, time.UTC)
	from := now.Add(-2 * time.Hour).Format(time.RFC3339)
	to := now.Format(time.RFC3339)

	req := httptest.NewRequest(http.MethodGet, "/history?from="+from+"&to="+to, nil)
	gotFrom, gotTo, _, ok := parseHistoryRange(req, now)
	if !ok {
		t.Fatal("valid range rejected")
	}
	if !gotFrom.Equal(now.Add(-2*time.Hour)) || !gotTo.Equal(now) {
		t.Fatalf("parsed %v %v", gotFrom, gotTo)
	}

	cases := []string{
		"/history",
		"/history?from=" + from,
		"/history?from=not-a-date&to=" + to,
		"/history?from=" + to + "&to=" + from,
		"/history?from=" + now.Add(-26*time.Hour).Format(time.RFC3339) + "&to=" + now.Format(time.RFC3339),
		"/history?from=" + now.Add(-91*24*time.Hour).Format(time.RFC3339) + "&to=" + now.Add(-91*24*time.Hour).Add(time.Hour).Format(time.RFC3339),
	}
	for _, url := range cases {
		req := httptest.NewRequest(http.MethodGet, url, nil)
		if _, _, _, ok := parseHistoryRange(req, now); ok {
			t.Errorf("accepted invalid range %s", url)
		}
	}
}

func TestGetMemberHistoryUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Get("/family/members/{id}/history", srv.GetMemberHistory)
	req := httptest.NewRequest(http.MethodGet, "/family/members/u1/history?from=2026-08-22T00:00:00Z&to=2026-08-23T00:00:00Z", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestAdminGetMemberHistoryUnauthenticated(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Get("/api/admin/members/{id}/history", srv.AdminGetMemberHistory)
	req := httptest.NewRequest(http.MethodGet, "/api/admin/members/u1/history?from=2026-08-22T00:00:00Z&to=2026-08-23T00:00:00Z", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestGetMemberHistoryRejectsBadRange(t *testing.T) {
	srv := &Server{}
	r := chi.NewRouter()
	r.Get("/family/members/{id}/history", srv.GetMemberHistory)

	req := httptest.NewRequest(http.MethodGet, "/family/members/u1/history", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "caller"}))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestGetMemberHistoryMissingMemberID(t *testing.T) {
	srv := &Server{}
	req := httptest.NewRequest(http.MethodGet, "/history?from=2026-08-22T00:00:00Z&to=2026-08-23T00:00:00Z", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "caller"}))
	w := httptest.NewRecorder()
	srv.GetMemberHistory(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestBuildVisitsEmptyDay(t *testing.T) {
	visits := buildVisits(nil, nil)
	if len(visits) != 0 {
		t.Fatalf("empty day produced %d visits", len(visits))
	}
}

func TestBuildVisitsNamedPlace(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	home := historyPlace{ID: "home-1", Name: "Home", Type: "home", Lat: 37.77, Lon: -122.42, RadiusMeters: 150}
	points := stayPoints(start, 37.7701, -122.4201, 10, time.Minute)
	visits := buildVisits(points, []historyPlace{home})
	if len(visits) != 1 {
		t.Fatalf("got %d visits: %+v", len(visits), visits)
	}
	if visits[0].Kind != "place" || visits[0].PlaceName != "Home" || visits[0].PlaceID == nil || *visits[0].PlaceID != "home-1" {
		t.Fatalf("named visit mismatch: %+v", visits[0])
	}
}

func TestBuildVisitsDriveByIgnored(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	home := historyPlace{ID: "home-1", Name: "Home", Type: "home", Lat: 37.77, Lon: -122.42, RadiusMeters: 150}
	points := []historyPoint{
		{Lat: 37.77, Lon: -122.42, TS: start, MotionState: "driving"},
		{Lat: 37.7701, Lon: -122.42, TS: start.Add(time.Minute), MotionState: "driving"},
		{Lat: 37.80, Lon: -122.40, TS: start.Add(10 * time.Minute), MotionState: "driving"},
	}
	visits := buildVisits(points, []historyPlace{home})
	for _, v := range visits {
		if v.Kind == "place" {
			t.Fatalf("drive-by became a place visit: %+v", v)
		}
	}
	if len(visits) == 0 || visits[0].Kind != "transit" {
		t.Fatalf("expected transit, got %+v", visits)
	}
}

func TestBuildVisitsUnnamedDwell(t *testing.T) {
	start := time.Date(2026, 8, 22, 9, 0, 0, 0, time.UTC)
	points := stayPoints(start, 40.0, -74.0, 8, time.Minute)
	visits := buildVisits(points, nil)
	stops := 0
	for _, v := range visits {
		if v.Kind == "stop" {
			stops++
			if v.PlaceName != "Stopped" || v.PlaceID != nil {
				t.Fatalf("unnamed stop mismatch: %+v", v)
			}
		}
	}
	if stops != 1 {
		t.Fatalf("expected one unnamed stop, got %+v", visits)
	}
}

func TestBuildVisitsPlaceThenTransitThenStop(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	home := historyPlace{ID: "home-1", Name: "Home", Type: "home", Lat: 37.77, Lon: -122.42, RadiusMeters: 200}
	var points []historyPoint
	points = append(points, stayPoints(start, 37.77, -122.42, 6, time.Minute)...)
	driveStart := start.Add(10 * time.Minute)
	for i := 1; i <= 5; i++ {
		points = append(points, historyPoint{
			Lat: 37.77 + float64(i)*0.02, Lon: -122.42, TS: driveStart.Add(time.Duration(i) * time.Minute), MotionState: "driving",
		})
	}
	stopStart := driveStart.Add(8 * time.Minute)
	points = append(points, stayPoints(stopStart, 37.90, -122.42, 8, time.Minute)...)

	visits := buildVisits(points, []historyPlace{home})
	if len(visits) < 3 {
		t.Fatalf("expected place/transit/stop, got %d visits %+v", len(visits), visits)
	}
	if visits[0].Kind != "place" || visits[0].PlaceName != "Home" {
		t.Fatalf("first visit: %+v", visits[0])
	}
	foundStop := false
	foundTransit := false
	for _, v := range visits {
		if v.Kind == "stop" {
			foundStop = true
		}
		if v.Kind == "transit" {
			foundTransit = true
		}
	}
	if !foundStop || !foundTransit {
		kinds := make([]string, len(visits))
		for i, v := range visits {
			kinds[i] = v.Kind
		}
		t.Fatalf("missing stop or transit: %v", kinds)
	}
}

func TestDownsampleTrailCaps(t *testing.T) {
	start := time.Date(2026, 8, 22, 0, 0, 0, 0, time.UTC)
	points := make([]historyPoint, 0, 200)
	for i := 0; i < 200; i++ {
		points = append(points, historyPoint{Lat: 1, Lon: 2, TS: start.Add(time.Duration(i) * time.Second)})
	}
	trail := downsampleTrail(points, time.Second, 20)
	if len(trail) != 20 {
		t.Fatalf("cap: got %d want 20", len(trail))
	}
	empty := downsampleTrail(nil, time.Second, 20)
	if empty == nil || len(empty) != 0 {
		t.Fatalf("empty trail should be empty slice, got %#v", empty)
	}
}

func TestHaversineMeters(t *testing.T) {
	d := haversineMeters(0, 0, 1, 0)
	if d < 110000 || d > 112000 {
		t.Fatalf("1 degree latitude = %f m", d)
	}
	if haversineMeters(37.77, -122.42, 37.77, -122.42) != 0 {
		t.Fatal("same point should be 0")
	}
}

func TestFilterUsablePoints(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	points := []historyPoint{
		{Lat: 1, Lon: 2, TS: start, Accuracy: 10},
		{Lat: 1, Lon: 2, TS: start.Add(time.Minute), Accuracy: 0},       // unknown kept
		{Lat: 1, Lon: 2, TS: start.Add(2 * time.Minute), Accuracy: 100}, // exactly at the gate kept
		{Lat: 1, Lon: 2, TS: start.Add(3 * time.Minute), Accuracy: 250}, // too weak, dropped
	}
	usable := filterUsablePoints(points)
	if len(usable) != 3 {
		t.Fatalf("got %d usable points, want 3: %+v", len(usable), usable)
	}
	if usable[2].TS != start.Add(2*time.Minute) {
		t.Fatalf("weak fix should be the one dropped: %+v", usable[2])
	}

	// A day where every fix is too weak falls back to the raw points rather
	// than presenting an empty history.
	allWeak := []historyPoint{
		{Lat: 1, Lon: 2, TS: start, Accuracy: 500},
		{Lat: 1, Lon: 2, TS: start.Add(time.Minute), Accuracy: 900},
	}
	if got := filterUsablePoints(allWeak); len(got) != 2 {
		t.Fatalf("all-weak day should fall back to raw points, got %d", len(got))
	}
	if got := filterUsablePoints(nil); len(got) != 0 {
		t.Fatalf("empty day should stay empty, got %d", len(got))
	}
}

// TestBuildVisitsJitterDoesNotBreakPlaceStay reproduces the "home all day but
// history shows transit" bug: a fix every minute alternating just inside and
// just outside the place radius. Per-fix run matching used to split this into
// one-minute runs, all below placeMinDuration, so no Home visit survived and
// the whole day became "In transit".
func TestBuildVisitsJitterDoesNotBreakPlaceStay(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	home := historyPlace{ID: "home-1", Name: "Home", Type: "home", Lat: 37.77, Lon: -122.42, RadiusMeters: 150}
	var points []historyPoint
	for i := 0; i < 20; i++ {
		lat := 37.77 + 0.00001 // ~1m inside the radius
		if i%2 == 1 {
			lat = 37.77 + 0.002 // ~220m outside the radius
		}
		points = append(points, historyPoint{Lat: lat, Lon: -122.42, TS: start.Add(time.Duration(i) * time.Minute)})
	}
	visits := buildVisits(points, []historyPlace{home})
	if len(visits) != 1 {
		t.Fatalf("jitter should collapse into one Home visit, got %d: %+v", len(visits), visits)
	}
	if visits[0].Kind != "place" || visits[0].PlaceName != "Home" {
		t.Fatalf("expected a Home place visit, got %+v", visits[0])
	}
	if !visits[0].ArrivedAt.Equal(start) || !visits[0].DepartedAt.Equal(start.Add(19*time.Minute)) {
		t.Fatalf("visit should span the jitter, got %v..%v", visits[0].ArrivedAt, visits[0].DepartedAt)
	}
}

func TestBuildVisitsJitterDoesNotBreakUnnamedDwell(t *testing.T) {
	start := time.Date(2026, 8, 22, 9, 0, 0, 0, time.UTC)
	var points []historyPoint
	for i := 0; i < 16; i++ {
		lat := 40.0
		if i%3 == 2 {
			lat = 40.002 // ~220m away: a jittering fix
		}
		points = append(points, historyPoint{Lat: lat, Lon: -74.0, TS: start.Add(time.Duration(i) * time.Minute)})
	}
	visits := buildVisits(points, nil)
	stops := 0
	for _, v := range visits {
		if v.Kind == "stop" {
			stops++
		}
	}
	if stops != 1 {
		t.Fatalf("jitter should not split the dwell, got %d stops: %+v", stops, visits)
	}
}

// TestBuildVisitsRealDepartureStillSplits guards the hysteresis: an excursion
// that outlasts stayBreakTolerance is a real departure and must still produce
// stay → transit → stay.
func TestBuildVisitsRealDepartureStillSplits(t *testing.T) {
	start := time.Date(2026, 8, 22, 8, 0, 0, 0, time.UTC)
	home := historyPlace{ID: "home-1", Name: "Home", Type: "home", Lat: 37.77, Lon: -122.42, RadiusMeters: 150}
	var points []historyPoint
	points = append(points, stayPoints(start, 37.77, -122.42, 5, time.Minute)...)
	// Leave for 7 minutes (longer than the tolerance), moving so the away
	// stretch can't cluster into a stop.
	for i := 0; i < 7; i++ {
		points = append(points, historyPoint{
			Lat: 37.90 + float64(i)*0.01, Lon: -122.42, TS: start.Add(time.Duration(5+i) * time.Minute),
		})
	}
	points = append(points, stayPoints(start.Add(12*time.Minute), 37.77, -122.42, 5, time.Minute)...)

	visits := buildVisits(points, []historyPlace{home})
	if len(visits) != 3 {
		t.Fatalf("want home/transit/home, got %d visits: %+v", len(visits), visits)
	}
	if visits[0].Kind != "place" || visits[0].PlaceName != "Home" {
		t.Fatalf("first visit should be Home: %+v", visits[0])
	}
	if visits[1].Kind != "transit" {
		t.Fatalf("middle visit should be transit: %+v", visits[1])
	}
	if visits[2].Kind != "place" || visits[2].PlaceName != "Home" {
		t.Fatalf("last visit should be Home: %+v", visits[2])
	}
}

func stayPoints(start time.Time, lat, lon float64, n int, step time.Duration) []historyPoint {
	out := make([]historyPoint, n)
	for i := 0; i < n; i++ {
		out[i] = historyPoint{
			Lat: lat + float64(i)*0.00001,
			Lon: lon,
			TS:  start.Add(time.Duration(i) * step),
		}
	}
	return out
}

func TestParseHistoryRangeHonorsConfiguredRetention(t *testing.T) {
	now := time.Date(2026, 8, 22, 18, 0, 0, 0, time.UTC)
	mk := func(daysAgo int) *http.Request {
		f := now.Add(-time.Duration(daysAgo) * 24 * time.Hour)
		return httptest.NewRequest(http.MethodGet, "/history?from="+f.Format(time.RFC3339)+"&to="+f.Add(time.Hour).Format(time.RFC3339), nil)
	}

	t.Setenv("LOCATION_RETENTION_DAYS", "")
	if _, _, _, ok := parseHistoryRange(mk(89), now); !ok {
		t.Error("89 days should be within the default 90-day window")
	}
	if _, _, msg, ok := parseHistoryRange(mk(91), now); ok || msg != "from is older than the 90-day retention window" {
		t.Errorf("default window: ok=%v msg=%q", ok, msg)
	}

	t.Setenv("LOCATION_RETENTION_DAYS", "30")
	if _, _, _, ok := parseHistoryRange(mk(29), now); !ok {
		t.Error("29 days should be within a 30-day window")
	}
	if _, _, msg, ok := parseHistoryRange(mk(45), now); ok || msg != "from is older than the 30-day retention window" {
		t.Errorf("30-day window: ok=%v msg=%q", ok, msg)
	}

	t.Setenv("LOCATION_RETENTION_DAYS", "365")
	if _, _, _, ok := parseHistoryRange(mk(200), now); !ok {
		t.Error("200 days should be within a 365-day window")
	}
}
