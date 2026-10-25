package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/trips"
)

func tripsRouter(srv *Server, userID string) http.Handler {
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if userID != "" {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: userID}))
			}
			next.ServeHTTP(w, req)
		})
	})
	r.Get("/trips", srv.ListTrips)
	r.Get("/trips/summary", srv.TripsSummary)
	r.Post("/trips/compute", srv.ComputeTrips)
	r.Get("/trips/{id}", srv.GetTrip)
	return r
}

func TestTripsUnauthenticated(t *testing.T) {
	srv := &Server{}
	for _, c := range []struct{ method, path string }{
		{"GET", "/trips"}, {"GET", "/trips/summary"}, {"GET", "/trips/abc"}, {"POST", "/trips/compute"},
	} {
		w := httptest.NewRecorder()
		tripsRouter(srv, "").ServeHTTP(w, httptest.NewRequest(c.method, c.path, nil))
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: status %d", c.method, c.path, w.Code)
		}
	}
}

func TestPeriodBounds(t *testing.T) {
	loc, _ := time.LoadLocation("America/New_York")
	d := time.Date(2026, 6, 3, 15, 0, 0, 0, loc) // Wednesday
	from, to, ok := periodBounds("day", d, loc)
	if !ok || from.Day() != 3 || to.Day() != 4 {
		t.Errorf("day %v %v", from, to)
	}
	from, to, _ = periodBounds("week", d, loc)
	if from.Weekday() != time.Monday || from.Day() != 1 || to.Sub(from) != 7*24*time.Hour {
		t.Errorf("week %v %v", from, to)
	}
	from, to, _ = periodBounds("month", d, loc)
	if from.Day() != 1 || to.Month() != time.July {
		t.Errorf("month %v %v", from, to)
	}
	if _, _, ok := periodBounds("year", d, loc); ok {
		t.Error("year accepted")
	}
}

func TestParseOptionalRange(t *testing.T) {
	now := time.Date(2026, 6, 3, 12, 0, 0, 0, time.UTC)
	from, to, msg := parseOptionalRange(httptest.NewRequest("GET", "/trips", nil), now, 24*time.Hour)
	if msg != "" || !to.Equal(now) || !from.Equal(now.Add(-24*time.Hour)) {
		t.Errorf("defaults: %v %v %q", from, to, msg)
	}
	for _, q := range []string{"?from=x", "?to=x", "?from=2026-06-04T00:00:00Z&to=2026-06-03T00:00:00Z"} {
		if _, _, msg := parseOptionalRange(httptest.NewRequest("GET", "/trips"+q, nil), now, time.Hour); msg == "" {
			t.Errorf("accepted %s", q)
		}
	}
}

type tripEnv struct {
	pool                 *pgxpool.Pool
	srv                  *Server
	a1, a2, b1           string
	famA, famB           string
	t                    *testing.T
	driveStart, driveEnd time.Time
	base                 time.Time
}

func (e *tripEnv) must(err error) {
	e.t.Helper()
	if err != nil {
		e.t.Fatal(err)
	}
}

func (e *tripEnv) user(name string, fam string) string {
	var id string
	e.must(e.pool.QueryRow(context.Background(),
		`INSERT INTO users (email, name, password_hash, family_id) VALUES ($1,$2,'x',NULLIF($3,'')::uuid) RETURNING id::text`,
		fmt.Sprintf("%s-%d@trips.test", name, time.Now().UnixNano()), name, fam).Scan(&id))
	return id
}

// drive seeds a stationary -> drive -> stationary track ending ~1h before now.
func (e *tripEnv) drive(userID string, lonOffset float64) {
	ctx := context.Background()
	var dev string
	e.must(e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id::text`, userID).Scan(&dev))
	start := e.base
	e.driveStart = start.Add(5 * time.Minute)
	lat := 40.0
	ts := start
	batch := &pgx.Batch{}
	insert := func(speed float64) {
		batch.Queue(`INSERT INTO locations (device_id, ts, geom, accuracy_meters, speed_mps)
			VALUES ($1,$2,ST_SetSRID(ST_MakePoint($3,$4),4326),8,$5)`, dev, ts, -75.0+lonOffset, lat, speed)
	}
	for i := 0; i < 60; i++ { // 5 min still
		insert(0)
		ts = ts.Add(5 * time.Second)
	}
	for i := 0; i < 96; i++ { // 8 min at 25 m/s (above the 70 mph default? no: below) -> 33 m/s burst below
		sp := 25.0
		if i >= 40 && i < 60 {
			sp = 35 // 100 s above the 31.3 m/s default threshold
		}
		lat += sp * 5 / 111195
		insert(sp)
		ts = ts.Add(5 * time.Second)
	}
	e.driveEnd = ts
	for i := 0; i < 60; i++ {
		insert(0)
		ts = ts.Add(5 * time.Second)
	}
	br := e.pool.SendBatch(ctx, batch)
	defer br.Close()
	for i := 0; i < batch.Len(); i++ {
		_, err := br.Exec()
		e.must(err)
	}
}

func setupTripEnv(t *testing.T) *tripEnv {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	e := &tripEnv{pool: pool, srv: &Server{Pool: pool}, t: t, base: time.Now().Add(-2 * time.Hour).Truncate(time.Second)}
	ctx := context.Background()
	e.must(pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('A') RETURNING id::text`).Scan(&e.famA))
	e.must(pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('B') RETURNING id::text`).Scan(&e.famB))
	e.a1, e.a2, e.b1 = e.user("a1", e.famA), e.user("a2", e.famA), e.user("b1", e.famB)
	t.Cleanup(func() {
		for _, id := range []string{e.a1, e.a2, e.b1} {
			pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, id)
		}
		pool.Exec(ctx, `DELETE FROM families WHERE id IN ($1,$2)`, e.famA, e.famB)
	})
	e.drive(e.a1, 0)
	e.drive(e.b1, 0.5)
	return e
}

func (e *tripEnv) get(as, path string) (int, []byte) {
	w := httptest.NewRecorder()
	tripsRouter(e.srv, as).ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	return w.Code, w.Body.Bytes()
}

func TestTripsEndToEndAndCrossFamily(t *testing.T) {
	e := setupTripEnv(t)
	ctx := context.Background()
	st := trips.NewStore(e.pool)

	n, err := st.ProcessUser(ctx, e.a1, e.famA)
	e.must(err)
	if n != 1 {
		t.Fatalf("a1 trips written=%d", n)
	}
	_, err = st.ProcessUser(ctx, e.b1, e.famB)
	e.must(err)
	// Idempotent: re-running neither duplicates nor loses rows.
	if _, err := st.ProcessUser(ctx, e.a1, e.famA); err != nil {
		t.Fatal(err)
	}
	if n, err := st.ComputeRange(ctx, e.a1, e.famA, time.Now().Add(-6*time.Hour), time.Now()); err != nil || n != 1 {
		t.Fatalf("compute range n=%d err=%v", n, err)
	}
	var cnt int
	e.must(e.pool.QueryRow(ctx, `SELECT count(*) FROM trips WHERE user_id=$1`, e.a1).Scan(&cnt))
	if cnt != 1 {
		t.Fatalf("a1 rows=%d, want 1", cnt)
	}

	type listResp struct {
		Trips []trips.Row `json:"trips"`
	}
	code, body := e.get(e.a1, "/trips")
	var lr listResp
	_ = json.Unmarshal(body, &lr)
	if code != 200 || len(lr.Trips) != 1 {
		t.Fatalf("own list: %d %s", code, body)
	}
	tr := lr.Trips[0]
	if tr.UserID != e.a1 || tr.Mode != "driving" || tr.SpeedSource != "device_gps" {
		t.Errorf("trip %+v", tr)
	}
	if math.Abs(tr.StartedAt.Sub(e.driveStart).Seconds()) > 15 {
		t.Errorf("start %v want ~%v", tr.StartedAt, e.driveStart)
	}
	if math.Abs(tr.MaxSpeedMps-35) > 0.01 || tr.DistanceM < 11000 {
		t.Errorf("max=%v dist=%v", tr.MaxSpeedMps, tr.DistanceM)
	}

	// Same-family member may read it, including detail with a route.
	code, body = e.get(e.a2, "/trips?user_id="+e.a1)
	_ = json.Unmarshal(body, &lr)
	if code != 200 || len(lr.Trips) != 1 {
		t.Fatalf("family list: %d %s", code, body)
	}
	code, body = e.get(e.a2, "/trips/"+tr.ID+"?max_points=50")
	var dr struct {
		Route []trips.RoutePoint `json:"route"`
	}
	_ = json.Unmarshal(body, &dr)
	if code != 200 || len(dr.Route) != 50 {
		t.Fatalf("detail: %d route=%d %s", code, len(dr.Route), body)
	}

	// Other family: nothing leaks.
	if code, _ := e.get(e.b1, "/trips?user_id="+e.a1); code != http.StatusForbidden {
		t.Errorf("b1 list a1: %d", code)
	}
	if code, _ := e.get(e.b1, "/trips/summary?user_id="+e.a1); code != http.StatusForbidden {
		t.Errorf("b1 summary a1: %d", code)
	}
	if code, _ := e.get(e.b1, "/trips/"+tr.ID); code != http.StatusNotFound {
		t.Errorf("b1 detail a1 trip: %d", code)
	}
	code, body = e.get(e.b1, "/trips")
	_ = json.Unmarshal(body, &lr)
	if code != 200 || len(lr.Trips) != 1 || lr.Trips[0].UserID != e.b1 {
		t.Errorf("b1 own list leaked: %d %s", code, body)
	}
	if code, _ := e.get(e.a1, "/trips/not-a-uuid"); code != http.StatusNotFound {
		t.Errorf("bad id: %d", code)
	}

	// Driving report with default and low thresholds.
	var sr struct {
		Summary trips.Summary `json:"summary"`
	}
	code, body = e.get(e.a2, "/trips/summary?user_id="+e.a1+"&period=day")
	_ = json.Unmarshal(body, &sr)
	if code != 200 {
		t.Fatalf("summary: %d %s", code, body)
	}
	// The seeded drive may straddle UTC midnight; use the week for counts.
	code, body = e.get(e.a1, "/trips/summary?period=week&speed_threshold_mps=30")
	_ = json.Unmarshal(body, &sr)
	if code != 200 {
		t.Fatalf("week summary: %d %s", code, body)
	}
	s := sr.Summary
	if ws, we, _ := periodBounds("week", time.Now(), time.UTC); e.driveStart.Before(ws) || !e.driveStart.Before(we) {
		t.Log("seeded drive straddles a week boundary; skipping summary assertions")
	} else if s.Driving.TripCount != 1 || s.Driving.SpeedEvents != 1 || s.Driving.MaxSpeedMps != 35 || s.TripCount != 1 {
		t.Errorf("summary %+v", s)
	} else if s.Driving.DriveTimeS < 400 || s.Driving.AvgSpeedMps < 20 {
		t.Errorf("driving totals %+v", s.Driving)
	}
	if code, _ := e.get(e.a1, "/trips/summary?period=year"); code != 400 {
		t.Errorf("bad period: %d", code)
	}
}

func TestTripsWorkerPass(t *testing.T) {
	e := setupTripEnv(t)
	ctx := context.Background()
	w := &trips.Worker{Store: trips.NewStore(e.pool), MaxUsers: 1000}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	w.Pass(cancelled) // must return promptly without writing
	w.Pass(ctx)
	var n int
	e.must(e.pool.QueryRow(ctx, `SELECT count(*) FROM trips WHERE user_id = ANY($1::uuid[])`, []string{e.a1, e.b1}).Scan(&n))
	if n != 2 {
		t.Fatalf("worker wrote %d trips, want 2", n)
	}
	var wm, last time.Time
	e.must(e.pool.QueryRow(ctx, `SELECT processed_until, last_point_at FROM trip_watermarks WHERE user_id=$1`, e.a1).Scan(&wm, &last))
	if !wm.After(e.driveEnd.Add(-time.Minute)) || wm.After(last) {
		t.Errorf("watermark %v should sit just after the trip end %v (last point %v)", wm, e.driveEnd, last)
	}
	// Nothing new: a second pass does not reprocess or duplicate.
	w.Pass(ctx)
	e.must(e.pool.QueryRow(ctx, `SELECT count(*) FROM trips WHERE user_id = ANY($1::uuid[])`, []string{e.a1, e.b1}).Scan(&n))
	if n != 2 {
		t.Fatalf("after second pass %d trips", n)
	}
}
