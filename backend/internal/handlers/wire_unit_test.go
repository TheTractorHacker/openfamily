package handlers

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
)

func line(n int) []trailPoint {
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	out := make([]trailPoint, n)
	for i := range out {
		// A gentle zig-zag along a road with ~3 m of noise.
		out[i] = trailPoint{Lat: 51.5 + float64(i)*0.0001, Lon: -0.1 + float64(i)*0.0001 + 0.00003*float64(i%2), TS: t0.Add(time.Duration(i) * 30 * time.Second)}
	}
	return out
}

func TestSimplifyKeepsEndpointsAndOrder(t *testing.T) {
	tr := line(1500)
	got := simplifyTrail(tr, 20)
	if len(got) >= len(tr)/10 {
		t.Fatalf("expected strong simplification of a straight-ish line, got %d", len(got))
	}
	if got[0] != tr[0] || got[len(got)-1] != tr[len(tr)-1] {
		t.Fatal("endpoints must be preserved")
	}
	for i := 1; i < len(got); i++ {
		if !got[i].TS.After(got[i-1].TS) {
			t.Fatal("order not preserved")
		}
	}
}

func TestSimplifyKeepsCorners(t *testing.T) {
	// An L shape: the corner is far from the chord and must survive.
	var tr []trailPoint
	t0 := time.Now()
	for i := 0; i <= 50; i++ {
		tr = append(tr, trailPoint{Lat: 51.5, Lon: -0.1 + float64(i)*0.0002, TS: t0.Add(time.Duration(i) * time.Second)})
	}
	for i := 1; i <= 50; i++ {
		tr = append(tr, trailPoint{Lat: 51.5 + float64(i)*0.0002, Lon: -0.1 + 50*0.0002, TS: t0.Add(time.Duration(50+i) * time.Second)})
	}
	got := simplifyTrail(tr, 10)
	if len(got) != 3 {
		t.Fatalf("L shape should reduce to 3 points, got %d", len(got))
	}
	if got[1].Lat != 51.5 || math.Abs(got[1].Lon-(-0.1+50*0.0002)) > 1e-9 {
		t.Fatalf("corner lost: %+v", got[1])
	}
}

func TestThinTrailBound(t *testing.T) {
	// A jagged trail DP cannot shrink much at low epsilon still obeys max.
	tr := make([]trailPoint, 1500)
	for i := range tr {
		tr[i] = trailPoint{Lat: 51.5 + 0.001*math.Sin(float64(i)/3), Lon: -0.1 + 0.001*math.Cos(float64(i)/2), TS: time.Unix(int64(i), 0)}
	}
	for _, max := range []int{10, 50, 200} {
		got := thinTrail(tr, max, 0)
		if len(got) > max || len(got) < 2 {
			t.Fatalf("max %d got %d", max, len(got))
		}
		if got[0] != tr[0] || got[len(got)-1] != tr[len(tr)-1] {
			t.Fatalf("endpoints lost at max %d", max)
		}
	}
	if got := thinTrail(tr, 0, 0); len(got) != len(tr) {
		t.Fatal("no params must not change the trail")
	}
}

func TestApplyTrailParamsBounds(t *testing.T) {
	tr := line(100)
	bad := []string{"simplify=-1", "simplify=501", "simplify=abc", "max_points=9", "max_points=1501", "max_points=x", "simplify=NaN"}
	for _, q := range bad {
		if _, ok := applyTrailParams(httptest.NewRequest("GET", "/h?"+q, nil), tr); ok {
			t.Errorf("%s should be rejected", q)
		}
	}
	if out, ok := applyTrailParams(httptest.NewRequest("GET", "/h", nil), tr); !ok || len(out) != 100 {
		t.Fatal("default must pass through")
	}
	if out, ok := applyTrailParams(httptest.NewRequest("GET", "/h?max_points=20", nil), tr); !ok || len(out) > 20 {
		t.Fatalf("max_points ignored: %d", len(out))
	}
}

func TestDeltaCursor(t *testing.T) {
	now := time.Now()
	c := makeDeltaCursor(now, "abcd")
	if _, lay, ok := parseDeltaCursor(c, now); !ok || lay != "abcd" {
		t.Fatal("fresh cursor must parse")
	}
	for _, bad := range []string{"", "bootstrap", "123", "abc-def", "-x", "0-x"} {
		if _, _, ok := parseDeltaCursor(bad, now); ok {
			t.Errorf("%q should be rejected", bad)
		}
	}
	old := makeDeltaCursor(now.Add(-time.Hour), "abcd")
	if _, _, ok := parseDeltaCursor(old, now); ok {
		t.Fatal("stale cursor must force a full list")
	}
	future := makeDeltaCursor(now.Add(time.Hour), "abcd")
	if _, _, ok := parseDeltaCursor(future, now); ok {
		t.Fatal("future cursor must be rejected")
	}
}

type fakeItem struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

func TestWriteDeltaList(t *testing.T) {
	now := time.Now()
	rows := []deltaRow{
		{ID: "a", Layout: "x", Changed: now.Add(-time.Hour), V: fakeItem{"a", "A", "a@x"}},
		{ID: "b", Layout: "x", Changed: now, V: fakeItem{"b", "B", "b@x"}},
	}
	legacy := []fakeItem{{"a", "A", "a@x"}, {"b", "B", "b@x"}}
	get := func(q string) (*httptest.ResponseRecorder, map[string]any) {
		rec := httptest.NewRecorder()
		writeDeltaList(rec, httptest.NewRequest("GET", "/l?"+q, nil), rows, legacy, []string{"name"})
		var m map[string]any
		_ = jsonUnmarshal(rec.Body.Bytes(), &m)
		return rec, m
	}
	// legacy: untouched array
	rec, _ := get("")
	if !strings.HasPrefix(rec.Body.String(), `[{"id":"a","name":"A","email":"a@x"}`) {
		t.Fatalf("legacy shape changed: %s", rec.Body.String())
	}
	// compact view keeps the array shape but drops fields
	rec, _ = get("view=compact")
	if strings.Contains(rec.Body.String(), "email") || !strings.Contains(rec.Body.String(), `"name":"A"`) {
		t.Fatalf("compact: %s", rec.Body.String())
	}
	// first sync: full
	_, m := get("since=none")
	if m["full"] != true || len(m["items"].([]any)) != 2 || m["cursor"] == "" {
		t.Fatalf("first sync: %v", m)
	}
	cursor := m["cursor"].(string)
	// same layout, only b changed after the cursor? cursor = now-2s so b (now) qualifies, a does not
	_, m = get("since=" + cursor)
	items := m["items"].([]any)
	if m["full"] != false || len(items) != 1 || items[0].(map[string]any)["id"] != "b" || len(m["ids"].([]any)) != 2 {
		t.Fatalf("delta: %v", m)
	}
	// layout change (a removed) -> full again, ids shrink
	rec = httptest.NewRecorder()
	writeDeltaList(rec, httptest.NewRequest("GET", "/l?since="+cursor, nil), rows[1:], legacy[1:], nil)
	var m2 map[string]any
	_ = jsonUnmarshal(rec.Body.Bytes(), &m2)
	if m2["full"] != true || len(m2["ids"].([]any)) != 1 {
		t.Fatalf("layout change must force full: %v", m2)
	}
	// fields= overrides, id always kept
	rec, _ = get("fields=email")
	if !strings.Contains(rec.Body.String(), `"id":"a"`) || strings.Contains(rec.Body.String(), `"name"`) {
		t.Fatalf("fields: %s", rec.Body.String())
	}
}

func TestQueryMethodRouting(t *testing.T) {
	chi.RegisterMethod(QueryMethod)
	build := func(enabled bool) http.Handler {
		s := &Server{QueryMethod: enabled}
		r := chi.NewRouter()
		r.Use(func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				next.ServeHTTP(w, req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "u"})))
			})
		})
		r.Post("/family/history/query", s.HistoryQuery)
		r.MethodFunc(QueryMethod, "/family/history/query", s.HistoryQuery)
		return r
	}
	do := func(h http.Handler, method, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/family/history/query", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	off := build(false)
	rec := do(off, "QUERY", `{}`)
	if rec.Code != 405 || rec.Header().Get("Allow") != "POST, OPTIONS" || rec.Header().Get("Accept-Query") == "" {
		t.Fatalf("flag off: %d %v", rec.Code, rec.Header())
	}
	// POST still reaches the handler (400: empty body is invalid), never 405.
	if rec := do(off, "POST", `{}`); rec.Code != 400 {
		t.Fatalf("POST with flag off: %d", rec.Code)
	}
	on := build(true)
	if rec := do(on, "QUERY", `{}`); rec.Code != 400 {
		t.Fatalf("QUERY with flag on should reach handler (400 invalid body), got %d", rec.Code)
	}
	if rec := do(on, "GET", ``); rec.Code != 405 {
		t.Fatalf("GET on a body endpoint: %d", rec.Code)
	}
	bad := `{"member_id":"m","windows":[{"from":"x","to":"y"}],"simplify":900}`
	if rec := do(on, "POST", bad); rec.Code != 400 {
		t.Fatalf("simplify bound: %d", rec.Code)
	}
	nine := `{"member_id":"m","windows":[` + strings.Repeat(`{"from":"a","to":"b"},`, 8) + `{"from":"a","to":"b"}]}`
	if rec := do(on, "POST", nine); rec.Code != 400 {
		t.Fatalf("window bound: %d", rec.Code)
	}
}

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }
