package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func ip(n int) *int { return &n }

func TestWeeklySafetyScore(t *testing.T) {
	if weeklySafetyScore(0, 0, eventCounts{}) != nil {
		t.Error("no drives must have no score")
	}
	if s := weeklySafetyScore(3, 200_000, eventCounts{}); *s != 100 {
		t.Errorf("clean = %d", *s)
	}
	// 4 events over 100 km: rate 4/100km -> 100 - 20.
	if s := weeklySafetyScore(3, 100_000, eventCounts{HardBrake: 2, RapidAccel: 1, Speeding: 1}); *s != 80 {
		t.Errorf("got %d", *s)
	}
	// Short distance is floored at 10 km; many events clamp at 0.
	if s := weeklySafetyScore(1, 500, eventCounts{HardBrake: 50}); *s != 0 {
		t.Errorf("clamp = %d", *s)
	}
	// Phone use counts even though it is hidden from the output.
	if s := weeklySafetyScore(1, 100_000, eventCounts{phone: 2}); *s != 90 {
		t.Errorf("phone = %d", *s)
	}
}

func TestWeeklyDue(t *testing.T) {
	// Sunday 2026-11-01 18:00 UTC is the due moment for the week of Mon 2026-10-26.
	mon := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		now  time.Time
		week time.Time
	}{
		{time.Date(2026, 11, 1, 18, 0, 0, 0, time.UTC), mon},
		{time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC), mon},
		{time.Date(2026, 11, 1, 17, 59, 0, 0, time.UTC), mon.AddDate(0, 0, -7)},
		{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC), mon.AddDate(0, 0, -7)},
	} {
		w, due := weeklyDue(c.now)
		if !w.Equal(c.week) || !due.Equal(w.Add(6*24*time.Hour+18*time.Hour)) {
			t.Errorf("%v: week %v due %v", c.now, w, due)
		}
	}
}

func TestWeeklyPushText(t *testing.T) {
	nm := func(n string) string { return n }
	ms := []weekMember{
		{Name: "Alex", Current: weekStat{Drives: 3, DistanceM: 200_000}},
		{Name: "Sam", Current: weekStat{Drives: 2, DistanceM: 141_000, Events: eventCounts{HardBrake: 3}}},
	}
	_, body, ok := weeklyPushText(ms, nm)
	if !ok || body != "Your family's week: 5 drives, 212 mi, Sam had 3 hard brakes" {
		t.Errorf("%q %v", body, ok)
	}
	ms[1].Current.Events.HardBrake = 1
	if _, body, _ = weeklyPushText(ms, nm); !strings.HasSuffix(body, "Sam had 1 hard brake") {
		t.Errorf("%q", body)
	}
	ms[1].Current.Events.HardBrake = 0
	if _, body, _ = weeklyPushText(ms, nm); strings.Contains(body, "had") {
		t.Errorf("no brakes: %q", body)
	}
	if _, _, ok := weeklyPushText([]weekMember{{Name: "Z"}}, nm); ok {
		t.Error("no drives should not push")
	}
	// Names go through the privacy mapper.
	ms[1].Current.Events.HardBrake = 2
	if _, body, _ = weeklyPushText(ms, func(string) string { return "A family member" }); !strings.Contains(body, "A family member had 2 hard brakes") {
		t.Errorf("%q", body)
	}
}

func TestWeeklySummaryUnauthenticatedAndValidation(t *testing.T) {
	r := chi.NewRouter()
	r.Get("/x", (&Server{}).WeeklySummary)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
	if w.Code != http.StatusUnauthorized {
		t.Errorf("%d", w.Code)
	}
	w = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/x?utc_offset_minutes=9999", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "u"}))
	r.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("%d", w.Code)
	}
}

// DB test: stats computation, idempotency and the endpoint.
func TestWeeklySummaryJobDB(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	srv := &Server{Pool: pool}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	tag := time.Now().Format("150405.000000")
	var fam string
	must(pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('wk-'||$1) RETURNING id::text`, tag).Scan(&fam))
	user := func(name string) string {
		var id string
		must(pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash, family_id) VALUES ($1,$2,'x',$3) RETURNING id::text`,
			"wk-"+name+tag+"@example.com", name, fam).Scan(&id))
		return id
	}
	sam, alex := user("Sam"), user("Alex")

	now := time.Date(2026, 11, 1, 18, 5, 0, 0, time.UTC) // just after Sunday 18:00
	week, _ := weeklyDue(now)
	trip := func(uid string, at time.Time, distM, topMps float64) string {
		var id string
		must(pool.QueryRow(ctx, `INSERT INTO trips (user_id, family_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
			start_lat,start_lon,end_lat,end_lon,point_count) VALUES ($1,$2,$3,$4,$5,$6,15,'driving','device_gps',40,-75,40.1,-75,10) RETURNING id::text`,
			uid, fam, at, at.Add(30*time.Minute), distM, topMps).Scan(&id))
		return id
	}
	ev := func(tripID, uid, kind string, at time.Time) {
		_, err := pool.Exec(ctx, `INSERT INTO trip_events (trip_id,user_id,kind,started_at,ended_at,magnitude,lat,lon) VALUES ($1,$2,$3,$4,$4,4,40,-75)`,
			tripID, uid, kind, at)
		must(err)
	}
	t1 := trip(sam, week.Add(10*time.Hour), 100_000, 30)
	trip(sam, week.Add(3*24*time.Hour), 40_000, 38)
	ev(t1, sam, "hard_brake", week.Add(10*time.Hour+time.Minute))
	ev(t1, sam, "hard_brake", week.Add(10*time.Hour+2*time.Minute))
	ev(t1, sam, "speeding", week.Add(10*time.Hour+3*time.Minute))
	trip(alex, week.Add(24*time.Hour), 60_000, 25)
	trip(alex, week.Add(-24*time.Hour), 9_000, 20) // previous week: not counted
	trip(alex, week.Add(6*24*time.Hour+19*time.Hour), 9_000, 20) // after Sunday 18:00: not counted

	ms, err := srv.familyWeekMembers(ctx, fam, week, week.Add(weeklyDueOffset))
	must(err)
	got := map[string]weekMember{}
	for _, m := range ms {
		got[m.Name] = m
	}
	s := got["Sam"].Current
	if s.Drives != 2 || s.DistanceM != 140_000 || s.TopSpeedMps != 38 || s.DurationS != 3600 ||
		s.Events.HardBrake != 2 || s.Events.Speeding != 1 || s.Events.PhoneUse != nil {
		t.Fatalf("sam %+v", s)
	}
	if s.Score == nil || *s.Score != 89 { // 3 events / 140 km = 2.14 per 100 km -> 100 - 10.7
		t.Errorf("score %v", s.Score)
	}
	if a := got["Alex"].Current; a.Drives != 1 || a.DistanceM != 60_000 {
		t.Fatalf("alex %+v", a)
	}

	// Idempotent: the first run stores one row, later runs none.
	// (Other families in the shared test DB may also be summarised.)
	if _, err := srv.RunWeeklySummaryOnce(ctx, now); err != nil {
		t.Fatal(err)
	}
	n, err := srv.RunWeeklySummaryOnce(ctx, now.Add(time.Hour))
	must(err)
	if n != 0 {
		t.Errorf("second run stored %d", n)
	}
	var rows int
	var data string
	must(pool.QueryRow(ctx, `SELECT count(*), COALESCE(max(data::text),'') FROM weekly_summaries WHERE family_id=$1 AND week_start=$2::date`, fam, week).Scan(&rows, &data))
	if rows != 1 {
		t.Fatalf("rows = %d", rows)
	}
	if !json.Valid([]byte(data)) || !strings.Contains(data, `"Sam"`) {
		t.Errorf("data %s", data)
	}
	// Two hours before the due time the job targets the previous week, so
	// this week's row is not touched.
	if _, err := srv.RunWeeklySummaryOnce(ctx, now.Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	must(pool.QueryRow(ctx, `SELECT count(*) FROM weekly_summaries WHERE family_id=$1`, fam).Scan(&rows))
	if rows != 2 { // this week (earlier run) + the previous week, one each
		t.Errorf("rows = %d", rows)
	}
}
