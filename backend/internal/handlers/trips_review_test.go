package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

func TestValidateSensorEventPhoneDetail(t *testing.T) {
	now := time.Now()
	base := func() sensorEventIn {
		return sensorEventIn{Kind: "phone_use", StartedAt: now.Add(-time.Minute).UTC().Format(time.RFC3339),
			EndedAt: now.UTC().Format(time.RFC3339), Magnitude: f64(20)}
	}
	// Old clients: no detail fields at all.
	if ev, ok := validateSensorEvent(base(), now); !ok || ev.MaxSpeed != nil || ev.Confidence != nil || ev.Activity != nil {
		t.Fatalf("plain event %+v %v", ev, ok)
	}
	in := base()
	act := "call"
	in.MaxSpeedMps, in.Confidence, in.Activity = f64(22.5), f64(0.8), &act
	ev, ok := validateSensorEvent(in, now)
	if !ok || *ev.MaxSpeed != 22.5 || *ev.Confidence != 0.8 || *ev.Activity != "call" {
		t.Fatalf("detail event %+v %v", ev, ok)
	}
	// Unknown activity from a newer client is dropped, the event is kept.
	odd := "hologram"
	in.Activity = &odd
	if ev, ok := validateSensorEvent(in, now); !ok || ev.Activity != nil {
		t.Errorf("unknown activity %+v %v", ev, ok)
	}
	for name, mut := range map[string]func(*sensorEventIn){
		"neg speed":    func(i *sensorEventIn) { i.MaxSpeedMps = f64(-1) },
		"huge speed":   func(i *sensorEventIn) { i.MaxSpeedMps = f64(500) },
		"conf over 1":  func(i *sensorEventIn) { i.Confidence = f64(1.5) },
		"conf under 0": func(i *sensorEventIn) { i.Confidence = f64(-0.1) },
	} {
		bad := base()
		mut(&bad)
		if _, ok := validateSensorEvent(bad, now); ok {
			t.Errorf("%s accepted", name)
		}
	}
	// Detail fields are ignored on other kinds.
	b := sensorEventIn{Kind: "hard_brake", StartedAt: now.Add(-time.Minute).UTC().Format(time.RFC3339),
		EndedAt: now.Add(-time.Minute + time.Second).UTC().Format(time.RFC3339), Magnitude: f64(5), Confidence: f64(0.5)}
	if ev, ok := validateSensorEvent(b, now); !ok || ev.Confidence != nil {
		t.Errorf("brake detail %+v %v", ev, ok)
	}
}

func reviewRouter(srv *Server, userID string) http.Handler {
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if userID != "" {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: userID}))
			}
			next.ServeHTTP(w, req)
		})
	})
	r.Get("/trips/{id}", srv.GetTrip)
	r.Get("/trips/{id}/events", srv.TripEvents)
	r.Put("/trips/{id}/passenger", srv.SetTripPassenger)
	r.Patch("/trips/events/{eventId}", srv.SetEventDismissed)
	return r
}

func (e *sensorEnv) call(as, method, path, body string) (int, map[string]any) {
	w := httptest.NewRecorder()
	reviewRouter(e.srv, as).ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func eventsOf(out map[string]any) []map[string]any {
	var res []map[string]any
	for _, x := range out["events"].([]any) {
		res = append(res, x.(map[string]any))
	}
	return res
}

func TestUnauthenticatedReview(t *testing.T) {
	srv := &Server{}
	for _, c := range []struct{ method, path string }{
		{"PUT", "/trips/x/passenger"}, {"PATCH", "/trips/events/x"},
	} {
		w := httptest.NewRecorder()
		reviewRouter(srv, "").ServeHTTP(w, httptest.NewRequest(c.method, c.path, strings.NewReader(`{}`)))
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: %d", c.method, c.path, w.Code)
		}
	}
}

func TestPhoneUseDismissAndPassenger(t *testing.T) {
	e := setupSensorEnv(t)
	ctx := context.Background()
	st := trips.NewStore(e.pool)
	e.must2(st.ProcessUser(ctx, e.a1, e.famA))
	tid, ts, _ := e.tripOf(e.a1)
	e.post(e.bearer(e.a1), `{"sensor_enabled":true,"phone_use_enabled":true}`)

	at := ts.Add(40 * time.Second)
	phone := strings.Replace(evJSON("phone_use", at, 20*time.Second, 14),
		`"lon":-75.2}`, `"lon":-75.2,"max_speed_mps":21.5,"confidence":0.85,"activity":"screen"}`, 1)
	brake := evJSON("hard_brake", at.Add(2*time.Minute), time.Second, 6)
	code, out := e.post(e.bearer(e.a1), evBody("", phone, brake))
	if code != 200 || num(out, "accepted") != 2 {
		t.Fatalf("ingest %d %v", code, out)
	}
	var evID string
	e.must(e.pool.QueryRow(ctx, `SELECT id::text FROM trip_events WHERE user_id=$1 AND kind='phone_use'`, e.a1).Scan(&evID))
	var speed, conf float64
	var act string
	e.must(e.pool.QueryRow(ctx, `SELECT max_speed_mps, confidence, activity FROM trip_events WHERE id=$1`, evID).Scan(&speed, &conf, &act))
	if speed != 21.5 || conf < 0.84 || conf > 0.86 || act != "screen" {
		t.Fatalf("detail not stored %v %v %v", speed, conf, act)
	}
	counts := func(as string) (phone, brakes float64) {
		ev := memberEvents(e.reportJSON(as, e.famA), e.a1)
		phone, _ = ev["phone_use"].(float64)
		brakes, _ = ev["hard_brake"].(float64)
		return
	}
	if p, b := counts(e.a2); p != 1 || b < 1 {
		t.Fatalf("baseline phone=%v brake=%v", p, b)
	}

	// Another family member cannot dismiss it; unknown and malformed ids 404.
	for _, id := range []string{evID, "00000000-0000-0000-0000-000000000000", "not-a-uuid"} {
		who := e.a2
		if id != evID {
			who = e.a1
		}
		if code, _ := e.call(who, "PATCH", "/trips/events/"+id, `{"dismissed":true}`); code != 404 {
			t.Errorf("dismiss %s as %s: %d", id, who, code)
		}
	}
	if code, _ := e.call(e.b1, "PATCH", "/trips/events/"+evID, `{"dismissed":true}`); code != 404 {
		t.Errorf("cross-family dismiss: %d", code)
	}
	// A bad body is a 400, a GPS/brake event cannot be dismissed.
	if code, _ := e.call(e.a1, "PATCH", "/trips/events/"+evID, `{}`); code != 400 {
		t.Errorf("empty body %d", code)
	}
	var brakeID string
	e.must(e.pool.QueryRow(ctx, `SELECT id::text FROM trip_events WHERE user_id=$1 AND kind='hard_brake' AND source='sensor'`, e.a1).Scan(&brakeID))
	if code, _ := e.call(e.a1, "PATCH", "/trips/events/"+brakeID, `{"dismissed":true}`); code != 404 {
		t.Errorf("brake dismiss %d", code)
	}
	if p, _ := counts(e.a2); p != 1 {
		t.Fatalf("failed dismissals changed the report: %v", p)
	}

	// Owner dismisses: gone from the circle's report and from others' trip view,
	// still listed (flagged) for the owner so it can be restored.
	if code, out := e.call(e.a1, "PATCH", "/trips/events/"+evID, `{"dismissed":true}`); code != 200 || out["dismissed"] != true {
		t.Fatalf("dismiss %d %v", code, out)
	}
	if p, _ := counts(e.a2); p != 0 {
		t.Errorf("dismissed event still counted: %v", p)
	}
	_, other := e.call(e.a2, "GET", "/trips/"+tid, "")
	for _, ev := range eventsOf(other) {
		if ev["kind"] == "phone_use" {
			t.Error("a2 still sees the dismissed event")
		}
	}
	_, own := e.call(e.a1, "GET", "/trips/"+tid, "")
	var found bool
	for _, ev := range eventsOf(own) {
		if ev["kind"] == "phone_use" {
			found = ev["dismissed"] == true && ev["max_speed_mps"].(float64) == 21.5 && ev["activity"] == "screen"
		}
	}
	if !found {
		t.Errorf("owner view lacks the dismissed event: %v", own["events"])
	}
	// Restore.
	if code, _ := e.call(e.a1, "PATCH", "/trips/events/"+evID, `{"dismissed":false}`); code != 200 {
		t.Fatal("restore")
	}
	if p, _ := counts(e.a2); p != 1 {
		t.Errorf("restored event not counted: %v", p)
	}

	// Passenger: only the owner; all of the drive's events leave the report.
	if code, _ := e.call(e.a2, "PUT", "/trips/"+tid+"/passenger", `{"passenger":true}`); code != 404 {
		t.Errorf("a2 passenger %d", code)
	}
	if code, _ := e.call(e.a1, "PUT", "/trips/"+tid+"/passenger", `{}`); code != 400 {
		t.Errorf("passenger body %d", code)
	}
	if code, out := e.call(e.a1, "PUT", "/trips/"+tid+"/passenger", `{"passenger":true}`); code != 200 || out["passenger"] != true {
		t.Fatalf("passenger %d %v", code, out)
	}
	if p, b := counts(e.a2); p != 0 || b != 0 {
		t.Errorf("passenger drive still counted phone=%v brake=%v", p, b)
	}
	_, pv := e.call(e.a1, "GET", "/trips/"+tid+"/events", "")
	if pv["passenger"] != true || len(eventsOf(pv)) != 0 {
		t.Errorf("passenger view %v", pv)
	}
	// The mark survives a recompute (trips are deleted and re-inserted).
	_, err := st.ComputeRange(ctx, e.a1, e.famA, time.Now().Add(-6*time.Hour), time.Now())
	e.must(err)
	if p, b := counts(e.a2); p != 0 || b != 0 {
		t.Errorf("passenger mark lost on recompute phone=%v brake=%v", p, b)
	}
	// Undo.
	var tid2 string
	e.must(e.pool.QueryRow(ctx, `SELECT id::text FROM trips WHERE user_id=$1 ORDER BY started_at LIMIT 1`, e.a1).Scan(&tid2))
	if code, _ := e.call(e.a1, "PUT", "/trips/"+tid2+"/passenger", `{"passenger":false}`); code != 200 {
		t.Fatal("unmark")
	}
	if p, _ := counts(e.a2); p != 1 {
		t.Errorf("unmarked drive not counted: %v", p)
	}
}
