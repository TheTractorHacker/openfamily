package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

// The Driving tab regression (owner report, v0.25): in a Private circle with
// processing lanes a member whose lane is "server" must get trips and the full
// driving metrics from the server, exactly like a member of a Normal circle,
// and a phone-only member must stay out of the server's figures. Needs
// TEST_DATABASE_URL.

// laneDrive ingests a drive for dev through the server-device ingest (the path
// the sidecar uses): 5 minutes parked, 12 minutes at 25 m/s with 120 s at
// 40 m/s (speeding), 5 minutes parked. Returns how many points were stored.
func laneDrive(e *srvEnv, dev *tdev, begin time.Time, lonOffset float64) int {
	e.t.Helper()
	var pts []map[string]any
	ts, lat := begin, 40.0
	add := func(sp float64) {
		p := e.point("history", dev, ts, lat, -75.0+lonOffset)
		p["spd"] = sp
		pts = append(pts, p)
	}
	for i := 0; i < 60; i++ {
		add(0)
		ts = ts.Add(5 * time.Second)
	}
	for i := 0; i < 144; i++ {
		sp := 25.0
		if i >= 40 && i < 64 {
			sp = 40
		}
		lat += sp * 5 / 111195
		add(sp)
		ts = ts.Add(5 * time.Second)
	}
	for i := 0; i < 60; i++ {
		add(0)
		ts = ts.Add(5 * time.Second)
	}
	stored := 0
	for i := 0; i < len(pts); i += 400 {
		j := i + 400
		if j > len(pts) {
			j = len(pts)
		}
		c, m, raw := e.ingest(pts[i:j]...)
		if c != 200 {
			e.t.Fatalf("ingest %d %s", c, raw)
		}
		stored += int(m["stored"].(float64))
	}
	return stored
}

func TestServerLaneMemberGetsTripsAndDrivingMetricsInAPrivateCircle(t *testing.T) {
	e := readyLanes(t) // A and B: server lane, C: no choice (phone)
	ctx := context.Background()
	begin := time.Now().Add(-90 * time.Minute).Truncate(time.Second)
	if n := laneDrive(e, e.a, begin, 0); n < 200 {
		t.Fatalf("server-lane member A: only %d fixes stored", n)
	}
	if n := laneDrive(e, e.b, begin, 0.3); n < 200 {
		t.Fatalf("server-lane member B: only %d fixes stored", n)
	}
	// The phone member's fixes are refused: nothing of C is on the server.
	if c, m, _ := e.ingest(e.point("history", e.c, begin, 40, -74)); c != 200 || m["stored"].(float64) != 0 {
		t.Fatalf("a phone-lane member was stored: %d %v", c, m)
	}

	// The trips pipeline (what the background worker runs) builds the drives.
	st := trips.NewStore(e.pool)
	for _, n := range []string{"A", "B", "C"} {
		if _, err := st.ProcessUser(ctx, e.ids[n], e.circle); err != nil {
			t.Fatalf("process %s: %v", n, err)
		}
	}
	if got := e.count(`SELECT count(*) FROM trips WHERE user_id = $1 AND mode = 'driving'`, e.ids["A"]); got != 1 {
		t.Fatalf("A has %d driving trips, want 1", got)
	}
	if got := e.count(`SELECT count(*) FROM trips WHERE user_id = $1`, e.ids["C"]); got != 0 {
		t.Fatalf("the phone-lane member has %d trips on the server", got)
	}
	if got := e.count(`SELECT count(*) FROM trip_events WHERE user_id = $1 AND kind = 'speeding'`, e.ids["A"]); got != 1 {
		t.Fatalf("A has %d speeding events, want 1", got)
	}

	repRaw := func(as, circle string) (reportResp, string) {
		w := httptest.NewRecorder()
		reportRouter(e.srv, e.ids[as]).ServeHTTP(w, httptest.NewRequest("GET",
			"/trips/report?period=week&start="+begin.Format("2006-01-02")+"&circle_id="+circle, nil))
		if w.Code != 200 {
			t.Fatalf("report as %s: %d %s", as, w.Code, w.Body.String())
		}
		var r reportResp
		if err := json.Unmarshal(w.Body.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		return r, w.Body.String()
	}
	rep := func(as, circle string) reportResp { r, _ := repRaw(as, circle); return r }
	byUser := func(r reportResp) map[string]int {
		m := map[string]int{}
		for _, x := range r.Members {
			m[x.UserID] = x.Drives
		}
		return m
	}

	// A (server lane) sees themself and B with drives, speeding, top speed.
	r := rep("A", e.circle)
	got := byUser(r)
	if got[e.ids["A"]] != 1 || got[e.ids["B"]] != 1 {
		t.Fatalf("server-lane members missing from the report: %v", got)
	}
	if _, ok := got[e.ids["C"]]; ok && got[e.ids["C"]] != 0 {
		t.Fatalf("phone member has server figures: %v", got)
	}
	if r.Totals.Drives != 2 || r.Totals.Events.Speeding != 2 || r.Totals.DistanceM < 10000 || r.Totals.TopSpeedMps < 39 {
		t.Fatalf("totals %+v", r.Totals)
	}

	// C (phone lane) opens the same circle: sees the server-lane members' drives,
	// and none of their own on the server.
	rc := rep("C", e.circle)
	gc := byUser(rc)
	if gc[e.ids["A"]] != 1 || gc[e.ids["B"]] != 1 || gc[e.ids["C"]] != 0 {
		t.Fatalf("phone member's view: %v", gc)
	}
	// The default circle (what the app sends when none is picked) is the same.
	if byUser(rep("A", ""))[e.ids["B"]] != 1 {
		t.Fatal("report without circle_id lost the server-lane members")
	}

	// Recent drives carry the drive for the detail screen.
	_, raw := repRaw("A", e.circle)
	var extra struct {
		Recent []struct {
			ID string `json:"id"`
		} `json:"recent_trips"`
		Days []struct{} `json:"days"`
	}
	if err := json.Unmarshal([]byte(raw), &extra); err != nil || len(extra.Recent) != 2 || len(extra.Days) != 7 {
		t.Fatalf("recent drives / days missing: %v %s", err, raw)
	}
}

// The phone sensor path (Driving detection: hard braking, phone use) in a
// Private circle: a server-lane member's events are accepted and reach the
// report; a member who keeps data on their phone is refused (their phone works
// those figures out itself and shares only the result).
func TestSensorEventsFeedTheReportForServerLaneMembersOnly(t *testing.T) {
	e := readyLanes(t)
	ctx := context.Background()
	begin := time.Now().Add(-90 * time.Minute).Truncate(time.Second)
	laneDrive(e, e.a, begin, 0)
	if _, err := trips.NewStore(e.pool).ProcessUser(ctx, e.ids["A"], e.circle); err != nil {
		t.Fatal(err)
	}

	post := func(user string, body map[string]any) (int, string) {
		r := chi.NewRouter()
		r.Use(func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: e.ids[user]}))
				next.ServeHTTP(w, req)
			})
		})
		r.Post("/trips/sensor-events", e.srv.IngestSensorEvents)
		raw, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", "/trips/sensor-events", bytes.NewReader(raw)))
		return w.Code, w.Body.String()
	}
	ev := func(kind string, at time.Time, secs int, mag float64) map[string]any {
		m := map[string]any{"kind": kind, "started_at": at.UTC().Format(time.RFC3339),
			"ended_at": at.Add(time.Duration(secs) * time.Second).UTC().Format(time.RFC3339), "magnitude": mag, "lat": 40.01, "lon": -75.0}
		if kind == "phone_use" {
			m["max_speed_mps"] = 18.0
			m["confidence"] = 0.9
			m["activity"] = "screen"
		}
		return m
	}
	code, body := post("A", map[string]any{"sensor_enabled": true, "phone_use_enabled": true, "events": []any{
		ev("hard_brake", begin.Add(8*time.Minute), 3, 5.2),
		ev("rapid_accel", begin.Add(9*time.Minute), 4, 4.1),
		ev("phone_use", begin.Add(10*time.Minute), 20, 20),
	}})
	if code != 200 {
		t.Fatalf("server-lane member's sensor events refused: %d %s", code, body)
	}
	// A phone-lane member (all circles private, the server may not read them) is refused.
	if code, body := post("C", map[string]any{"sensor_enabled": true, "events": []any{ev("hard_brake", begin.Add(8*time.Minute), 3, 5)}}); code != 409 {
		t.Fatalf("phone-lane member's plaintext events: %d %s", code, body)
	}

	w := httptest.NewRecorder()
	reportRouter(e.srv, e.ids["B"]).ServeHTTP(w, httptest.NewRequest("GET",
		"/trips/report?period=week&start="+begin.Format("2006-01-02")+"&circle_id="+e.circle, nil))
	var r struct {
		Totals struct {
			Events struct {
				HardBrake  int  `json:"hard_brake"`
				RapidAccel int  `json:"rapid_accel"`
				Speeding   int  `json:"speeding"`
				PhoneUse   *int `json:"phone_use"`
			} `json:"events"`
		} `json:"totals"`
		SensorMembers []string `json:"sensor_members"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &r); err != nil || w.Code != 200 {
		t.Fatalf("report %d %s", w.Code, w.Body.String())
	}
	if r.Totals.Events.HardBrake < 1 || r.Totals.Events.RapidAccel < 1 || r.Totals.Events.PhoneUse == nil || *r.Totals.Events.PhoneUse < 1 {
		t.Fatalf("the sensor events are missing from the dashboard figures: %s", w.Body.String())
	}
	if len(r.SensorMembers) != 1 || r.SensorMembers[0] != e.ids["A"] {
		t.Fatalf("sensor_members: %v", r.SensorMembers)
	}
}
