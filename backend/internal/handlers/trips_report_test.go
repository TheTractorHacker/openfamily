package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

func reportRouter(srv *Server, userID string) http.Handler {
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if userID != "" {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: userID}))
			}
			next.ServeHTTP(w, req)
		})
	})
	r.Get("/trips/report", srv.TripsReport)
	r.Get("/trips/{id}", srv.GetTrip)
	r.Get("/trips/{id}/events", srv.TripEvents)
	return r
}

func TestComputeReportPeriod(t *testing.T) {
	// Wed 2026-10-21 12:00 UTC.
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	p, msg := computeReportPeriod("week", "", now, 0)
	if msg != "" || p.startDay != "2026-10-19" || p.endDay != "2026-10-25" || p.prevStartDay != "2026-10-12" || p.prevEndDay != "2026-10-18" {
		t.Fatalf("%+v %q", p, msg)
	}
	// Sunday 23:30 UTC is already Monday in UTC+1 (next week) and still the
	// same week in UTC-1.
	sun := time.Date(2026, 10, 25, 23, 30, 0, 0, time.UTC)
	if p, _ := computeReportPeriod("week", "", sun, 60); p.startDay != "2026-10-26" {
		t.Errorf("+60: %s", p.startDay)
	}
	if p, _ := computeReportPeriod("week", "", sun, -60); p.startDay != "2026-10-19" {
		t.Errorf("-60: %s", p.startDay)
	}
	// The instant bounds follow the offset: local Monday 00:00 at UTC-5 is 05:00 UTC.
	p, _ = computeReportPeriod("week", "2026-10-21", now, -300)
	if !p.start.Equal(time.Date(2026, 10, 19, 5, 0, 0, 0, time.UTC)) || p.end.Sub(p.start) != 7*24*time.Hour {
		t.Errorf("bounds %v %v", p.start, p.end)
	}
	// Arbitrary start snaps to its week; month works, prev month too.
	p, _ = computeReportPeriod("month", "2026-03-31", now, 0)
	if p.startDay != "2026-03-01" || p.endDay != "2026-03-31" || p.prevStartDay != "2026-02-01" || p.prevEndDay != "2026-02-28" {
		t.Errorf("month %+v", p)
	}
	if _, msg := computeReportPeriod("year", "", now, 0); msg == "" {
		t.Error("year accepted")
	}
	if _, msg := computeReportPeriod("week", "21-10-2026", now, 0); msg == "" {
		t.Error("bad date accepted")
	}
}

func TestReportUnauthenticatedAndValidation(t *testing.T) {
	srv := &Server{}
	for _, p := range []string{"/trips/report", "/trips/x/events"} {
		w := httptest.NewRecorder()
		reportRouter(srv, "").ServeHTTP(w, httptest.NewRequest("GET", p, nil))
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s: %d", p, w.Code)
		}
	}
	for _, q := range []string{"?period=year", "?start=nope", "?utc_offset_minutes=9999", "?utc_offset_minutes=x"} {
		w := httptest.NewRecorder()
		reportRouter(srv, "u").ServeHTTP(w, httptest.NewRequest("GET", "/trips/report"+q, nil))
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", q, w.Code)
		}
	}
}

// seedProfile inserts 1 Hz fixes for a drive whose speed follows f(t) for
// durS seconds, between 5 minutes of stillness before and after. Returns the
// instant the movement starts.
func (e *tripEnv) seedProfile(userID string, lonOffset float64, begin time.Time, durS int, f func(t float64) float64) {
	ctx := context.Background()
	var dev string
	e.must(e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, userID).Scan(&dev))
	batch := &pgx.Batch{}
	lat, ts := 40.0, begin
	ins := func(sp float64) {
		batch.Queue(`INSERT INTO locations (device_id, ts, geom, accuracy_meters, speed_mps)
			VALUES ($1,$2,ST_SetSRID(ST_MakePoint($3,$4),4326),6,$5)`, dev, ts, -75.0+lonOffset, lat, sp)
	}
	for i := 0; i < 60; i++ {
		ins(0)
		ts = ts.Add(5 * time.Second)
	}
	prev := 0.0
	for i := 0; i <= durS; i++ {
		v := f(float64(i))
		lat += (v + prev) / 2 / 111195
		prev = v
		ins(v)
		ts = ts.Add(time.Second)
	}
	for i := 0; i < 60; i++ {
		ins(0)
		ts = ts.Add(5 * time.Second)
	}
	br := e.pool.SendBatch(ctx, batch)
	defer br.Close()
	for i := 0; i < batch.Len(); i++ {
		_, err := br.Exec()
		e.must(err)
	}
}

// riskyProfile: gentle launch, cruise, 40 s at 38 m/s, then a 5 m/s^2 stop.
func riskyProfile(t float64) float64 {
	switch {
	case t < 10:
		return 2.5 * t
	case t < 60:
		return 25
	case t < 65:
		return 25 + 2.6*(t-60)
	case t < 105:
		return 38
	case t < 110:
		return 38 - 2.6*(t-105)
	case t < 160:
		return 25
	case t < 165:
		return 25 - 5*(t-160)
	}
	return 0
}

type reportResp struct {
	Period string `json:"period"`
	Start  string `json:"start"`
	End    string `json:"end"`
	Totals struct {
		Drives         int     `json:"drives"`
		DistanceM      float64 `json:"distance_m"`
		TopSpeedMps    float64 `json:"top_speed_mps"`
		TopSpeedUserID *string `json:"top_speed_user_id"`
		Events         struct {
			Speeding   int `json:"speeding"`
			HardBrake  int `json:"hard_brake"`
			RapidAccel int `json:"rapid_accel"`
		} `json:"events"`
	} `json:"totals"`
	Previous struct {
		Drives         int     `json:"drives"`
		TopSpeedUserID *string `json:"top_speed_user_id"`
		Events         struct {
			Speeding  int `json:"speeding"`
			HardBrake int `json:"hard_brake"`
		} `json:"events"`
	} `json:"previous_totals"`
	Members []struct {
		UserID string `json:"user_id"`
		Name   string `json:"name"`
		Drives int    `json:"drives"`
		Events struct {
			Speeding   int `json:"speeding"`
			HardBrake  int `json:"hard_brake"`
			RapidAccel int `json:"rapid_accel"`
		} `json:"events"`
		PrevEvents struct {
			Speeding  int `json:"speeding"`
			HardBrake int `json:"hard_brake"`
		} `json:"previous_events"`
	} `json:"members"`
	Thresholds map[string]float64 `json:"thresholds"`
	Estimated  bool               `json:"estimated"`
}

func (e *tripEnv) report(as, query string) (int, reportResp, string) {
	w := httptest.NewRecorder()
	reportRouter(e.srv, as).ServeHTTP(w, httptest.NewRequest("GET", "/trips/report"+query, nil))
	var rr reportResp
	_ = json.Unmarshal(w.Body.Bytes(), &rr)
	return w.Code, rr, w.Body.String()
}

func TestTripEventsReportEndToEnd(t *testing.T) {
	e := setupTripEnv(t) // also seeds plain drives for a1 and b1
	ctx := context.Background()
	// Fresh users so the plain seeded drives do not interfere.
	a3 := e.user("a3", e.famA)
	e.seedProfile(a3, 0.2, e.base.Add(-3*time.Hour), 165, riskyProfile)
	t.Cleanup(func() { e.pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, a3) })
	st := trips.NewStore(e.pool)
	if n, err := st.ProcessUser(ctx, a3, e.famA); err != nil || n != 1 {
		t.Fatalf("process n=%d err=%v", n, err)
	}
	var tripID string
	var started time.Time
	e.must(e.pool.QueryRow(ctx, `SELECT id::text, started_at FROM trips WHERE user_id=$1`, a3).Scan(&tripID, &started))

	countEvents := func() map[string]int {
		rows, err := e.pool.Query(ctx, `SELECT kind, count(*) FROM trip_events WHERE trip_id=$1 GROUP BY 1`, tripID)
		e.must(err)
		defer rows.Close()
		m := map[string]int{}
		for rows.Next() {
			var k string
			var n int
			e.must(rows.Scan(&k, &n))
			m[k] = n
		}
		return m
	}
	if m := countEvents(); m["speeding"] != 1 || m["hard_brake"] != 1 || len(m) != 2 {
		t.Fatalf("events %v", m)
	}
	// Idempotent: reprocess and recompute replace, never duplicate.
	if _, err := st.ProcessUser(ctx, a3, e.famA); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ComputeRange(ctx, a3, e.famA, started.Add(-time.Hour), started.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	// ComputeRange replaces the trip row, so it gets a new id.
	e.must(e.pool.QueryRow(ctx, `SELECT id::text FROM trips WHERE user_id=$1`, a3).Scan(&tripID))
	if m := countEvents(); m["speeding"] != 1 || m["hard_brake"] != 1 || len(m) != 2 {
		t.Fatalf("after recompute %v", m)
	}
	var orphans int
	e.must(e.pool.QueryRow(ctx, `SELECT count(*) FROM trip_events WHERE user_id=$1`, a3).Scan(&orphans))
	if orphans != 2 {
		t.Fatalf("user has %d events, want 2 (old ones cascaded)", orphans)
	}

	// Previous-week trip with events, inserted directly.
	prevStart := started.AddDate(0, 0, -7)
	var prevTrip string
	e.must(e.pool.QueryRow(ctx, `INSERT INTO trips (user_id, family_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
		start_lat,start_lon,end_lat,end_lon,point_count) VALUES ($1,$2,$3,$4,5000,30,15,'driving','device_gps',40,-75,40.1,-75,10) RETURNING id::text`,
		a3, e.famA, prevStart, prevStart.Add(10*time.Minute)).Scan(&prevTrip))
	for _, k := range []string{"hard_brake", "hard_brake", "speeding"} {
		_, err := e.pool.Exec(ctx, `INSERT INTO trip_events (trip_id,user_id,kind,started_at,ended_at,magnitude,lat,lon) VALUES ($1,$2,$3,$4,$4,4,40,-75)`,
			prevTrip, a3, k, prevStart.Add(time.Minute))
		e.must(err)
	}

	// The report for the week containing the trip, as another family member.
	day := started.UTC().Format("2006-01-02")
	code, rr, raw := e.report(e.a2, "?period=week&start="+day+"&circle_id="+e.famA)
	if code != 200 {
		t.Fatalf("report %d %s", code, raw)
	}
	if !rr.Estimated || rr.Thresholds["speeding_mps"] != 35.76 || rr.Thresholds["speeding_seconds"] != 30 || rr.Thresholds["hard_brake_mps2"] != 3.5 {
		t.Errorf("thresholds %+v", rr.Thresholds)
	}
	if !strings.Contains(raw, `"phone_use":null`) {
		t.Errorf("phone_use not null: %s", raw)
	}
	if rr.Totals.Drives != 1 || rr.Totals.Events.Speeding != 1 || rr.Totals.Events.HardBrake != 1 || rr.Totals.Events.RapidAccel != 0 {
		t.Errorf("totals %+v", rr.Totals)
	}
	if rr.Totals.TopSpeedUserID == nil || *rr.Totals.TopSpeedUserID != a3 || rr.Totals.TopSpeedMps < 37.9 || rr.Totals.TopSpeedMps > 38.1 {
		t.Errorf("top speed %+v", rr.Totals)
	}
	if rr.Previous.Drives != 1 || rr.Previous.Events.HardBrake != 2 || rr.Previous.Events.Speeding != 1 {
		t.Errorf("previous %+v", rr.Previous)
	}
	var found bool
	ids := map[string]bool{}
	for _, m := range rr.Members {
		ids[m.UserID] = true
		if m.UserID == a3 {
			found = true
			if m.Name != "a3" || m.Drives != 1 || m.Events.Speeding != 1 || m.PrevEvents.HardBrake != 2 {
				t.Errorf("member %+v", m)
			}
		}
	}
	if !found || !ids[e.a1] || !ids[e.a2] || ids[e.b1] {
		t.Errorf("members %v", ids) // zero-drive members included, other family excluded
	}
	// Default circle (primary) gives the same.
	if code, rr2, _ := e.report(e.a2, "?start="+day); code != 200 || rr2.Totals.Events.Speeding != 1 || rr2.Period != "week" {
		t.Errorf("default circle: %d %+v", code, rr2.Totals)
	}
	// An empty far-past week has no drives but still lists members.
	if code, rr3, _ := e.report(e.a2, "?start=2020-01-01"); code != 200 || rr3.Totals.Drives != 0 || len(rr3.Members) < 3 || rr3.Totals.TopSpeedUserID != nil {
		t.Errorf("empty week: %d %+v", code, rr3.Totals)
	}

	// Trip events + detail.
	get := func(as, path string) (int, string) {
		w := httptest.NewRecorder()
		reportRouter(e.srv, as).ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		return w.Code, w.Body.String()
	}
	code, body := get(e.a2, "/trips/"+tripID+"/events")
	var er struct {
		Events []trips.EventRow `json:"events"`
	}
	_ = json.Unmarshal([]byte(body), &er)
	if code != 200 || len(er.Events) != 2 {
		t.Fatalf("events %d %s", code, body)
	}
	byKind := map[string]trips.EventRow{}
	for _, ev := range er.Events {
		byKind[ev.Kind] = ev
	}
	if m := byKind["speeding"].Magnitude; m < 37.9 || m > 38.1 {
		t.Errorf("speeding magnitude %v", m)
	}
	if m := byKind["hard_brake"].Magnitude; m < 4.9 || m > 5.1 {
		t.Errorf("brake magnitude %v", m)
	}
	code, body = get(e.a2, "/trips/"+tripID+"?max_points=20")
	var dr struct {
		Events []trips.EventRow `json:"events"`
	}
	_ = json.Unmarshal([]byte(body), &dr)
	if code != 200 || len(dr.Events) != 2 {
		t.Errorf("detail events %d %s", code, body)
	}

	// Isolation: the other family gets 404 for the circle, for the trip events,
	// and its own default report excludes everyone in A.
	if code, _, _ := e.report(e.b1, "?circle_id="+e.famA); code != http.StatusNotFound {
		t.Errorf("outsider circle: %d", code)
	}
	if code, _ := get(e.b1, "/trips/"+tripID+"/events"); code != http.StatusNotFound {
		t.Errorf("outsider events: %d", code)
	}
	code, rrB, _ := e.report(e.b1, "?start="+day)
	if code != 200 || len(rrB.Members) != 1 || rrB.Members[0].UserID != e.b1 || rrB.Totals.Events.Speeding != 0 {
		t.Errorf("b1 report: %d %+v", code, rrB.Members)
	}
	if code, _, _ := e.report(e.a2, "?circle_id=not-a-uuid"); code != http.StatusNotFound {
		t.Errorf("bad circle id: %d", code)
	}
	if code, _ := get(e.a2, "/trips/not-a-uuid/events"); code != http.StatusNotFound {
		t.Errorf("bad trip id: %d", code)
	}

	// Sharing off hides the member everywhere; they still see themselves.
	_, err := e.pool.Exec(ctx, `UPDATE circle_members SET sharing_enabled=false WHERE circle_id=$1 AND user_id=$2`, e.famA, a3)
	e.must(err)
	code, rr, _ = e.report(e.a2, "?start="+day)
	if code != 200 || rr.Totals.Events.Speeding != 0 || rr.Totals.Drives != 0 {
		t.Errorf("sharing off totals: %+v", rr.Totals)
	}
	for _, m := range rr.Members {
		if m.UserID == a3 {
			t.Error("member with sharing off is listed")
		}
	}
	if code, _ := get(e.a2, "/trips/"+tripID+"/events"); code != http.StatusNotFound {
		t.Errorf("sharing off events: %d", code)
	}
	code, body = get(e.a2, "/trips/"+tripID)
	dr.Events = nil
	_ = json.Unmarshal([]byte(body), &dr)
	if len(dr.Events) != 0 || !strings.Contains(body, `"events":[]`) {
		t.Errorf("sharing off detail leaks events: %d %s", code, body)
	}
	if code, own, _ := e.report(a3, "?start="+day); code != 200 || own.Totals.Events.Speeding != 1 {
		t.Errorf("own report with sharing off: %d %+v", code, own.Totals)
	}
	if code, _ := get(a3, "/trips/"+tripID+"/events"); code != 200 {
		t.Errorf("own events: %d", code)
	}
}

func TestReportWeekBoundaryWithOffset(t *testing.T) {
	e := setupTripEnv(t)
	ctx := context.Background()
	u := e.user("bnd", e.famA)
	t.Cleanup(func() { e.pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, u) })
	// Monday 00:30 UTC of a recent week.
	now := time.Now().UTC()
	mon := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	mon = mon.AddDate(0, 0, -((int(mon.Weekday())+6)%7)-7) // Monday of last week
	at := mon.Add(30 * time.Minute)
	_, err := e.pool.Exec(ctx, `INSERT INTO trips (user_id, family_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
		start_lat,start_lon,end_lat,end_lon,point_count) VALUES ($1,$2,$3,$4,1000,20,10,'driving','device_gps',40,-75,40.1,-75,10)`,
		u, e.famA, at, at.Add(5*time.Minute))
	e.must(err)
	drives := func(q string) (int, string) {
		_, rr, _ := e.report(u, q)
		return rr.Totals.Drives, rr.Start
	}
	day := mon.Format("2006-01-02")
	if n, s := drives("?start=" + day); n != 1 || s != day {
		t.Errorf("UTC: n=%d start=%s", n, s)
	}
	// At UTC-1 the trip happened Sunday 23:30 local: it belongs to the week before.
	if n, _ := drives("?utc_offset_minutes=-60&start=" + day); n != 0 {
		t.Errorf("UTC-1 same week n=%d", n)
	}
	prev := mon.AddDate(0, 0, -7).Format("2006-01-02")
	if n, _ := drives("?utc_offset_minutes=-60&start=" + prev); n != 1 {
		t.Errorf("UTC-1 previous week n=%d", n)
	}
	// previous_totals picks it up from the following week.
	next := mon.AddDate(0, 0, 7).Format("2006-01-02")
	if _, rr, _ := e.report(u, "?start="+next); rr.Previous.Drives != 1 {
		t.Errorf("previous drives %d", rr.Previous.Drives)
	}
	_ = fmt.Sprint
}
