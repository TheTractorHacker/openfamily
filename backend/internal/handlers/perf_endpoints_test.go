package handlers

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPerfEndpoints times the endpoints the mobile app hits most against a
// realistically sized database. It is opt-in (OF_PERF=1) because it seeds a
// lot of rows into the database named by TEST_DATABASE_URL and deletes them
// afterwards. Run on a throwaway database:
//
//	OF_PERF=1 TEST_DATABASE_URL=postgres://... go test ./internal/handlers -run TestPerfEndpoints -v
func TestPerfEndpoints(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" || os.Getenv("OF_PERF") != "1" {
		t.Skip("set OF_PERF=1 and TEST_DATABASE_URL to run")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	srv := &Server{Pool: pool, hub: newHub()}

	var fam string
	must(t, pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('Perf') RETURNING id`).Scan(&fam))
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE family_id = $1`, fam)
		_, _ = pool.Exec(context.Background(), `DELETE FROM families WHERE id = $1`, fam)
	})
	users := make([]string, 3)
	devices := make([]string, 3)
	roles := []string{"admin", "member", "child"}
	for i := range users {
		must(t, pool.QueryRow(ctx, `INSERT INTO users (family_id,email,name,role,password_hash) VALUES ($1,$2,$3,$4,'x') RETURNING id`,
			fam, fmt.Sprintf("perf%d-%d@example.com", i, time.Now().UnixNano()), fmt.Sprintf("User %d", i), roles[i]).Scan(&users[i]))
		must(t, pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1,'android','p') RETURNING id`, users[i]).Scan(&devices[i]))
		_, err := pool.Exec(ctx, `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 51.5, -0.1, now())
			ON CONFLICT (user_id) DO UPDATE SET ts = now()`, users[i])
		must(t, err)
		// ~6,700 locations per device over 30 days (20,000 total).
		_, err = pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom, speed_mps, battery_pct, motion_state, source)
			SELECT $1, now() - (g * interval '388 seconds'),
			       ST_SetSRID(ST_MakePoint(-0.1 + g*0.00001, 51.5 + g*0.00001), 4326), 5, 80, 'moving', 'gps'
			FROM generate_series(0, 6666) g`, devices[i])
		must(t, err)
		// 100 trips per user in the last 30 days, 3 events on every third trip.
		_, err = pool.Exec(ctx, `INSERT INTO trips (user_id, device_id, family_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps,
				mode, speed_source, start_lat, start_lon, end_lat, end_lon, point_count)
			SELECT $1, $2, $3, now() - (g * interval '7 hours'), now() - (g * interval '7 hours') + interval '20 minutes',
				8000, 30, 12, 'driving', 'device_gps', 51.5, -0.1, 51.6, -0.2, 60
			FROM generate_series(1, 100) g`, users[i], devices[i], fam)
		must(t, err)
	}
	_, err = pool.Exec(ctx, `INSERT INTO trip_events (trip_id, user_id, kind, started_at, ended_at, magnitude, lat, lon)
		SELECT t.id, t.user_id, k, t.started_at + interval '5 minutes', t.started_at + interval '5 minutes 10 seconds', 4.5, 51.55, -0.15
		FROM (SELECT *, row_number() OVER () rn FROM trips WHERE family_id = $1) t,
		     unnest(ARRAY['hard_brake','speeding','rapid_accel']) k WHERE t.rn % 1 = 0 AND t.rn <= 340`, fam)
	must(t, err)
	for i := 0; i < 5; i++ {
		_, err = pool.Exec(ctx, `INSERT INTO places (family_id, name, type, geom, radius_meters) VALUES ($1,$2,'custom', ST_SetSRID(ST_MakePoint(-0.1,51.5),4326), 150)`,
			fam, fmt.Sprintf("Place %d", i))
		must(t, err)
	}
	_, _ = pool.Exec(ctx, `ANALYZE`)

	var firstTrip string
	must(t, pool.QueryRow(ctx, `SELECT id FROM trips WHERE user_id=$1 ORDER BY started_at DESC LIMIT 1`, users[0]).Scan(&firstTrip))

	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: users[0]}))
			next.ServeHTTP(w, req)
		})
	})
	r.Get("/config", srv.GetConfig)
	r.Get("/family/members", srv.ListMembers)
	r.Get("/family/places", srv.ListPlaces)
	r.Get("/trips", srv.ListTrips)
	r.Get("/trips/report", srv.TripsReport)
	r.Get("/trips/{id}", srv.GetTrip)
	r.Post("/locations", srv.IngestLocation)

	now := time.Now().UTC()
	from := now.Add(-30 * 24 * time.Hour).Format(time.RFC3339)
	to := now.Format(time.RFC3339)
	body := fmt.Sprintf(`{"device_id":%q,"lat":51.5,"lon":-0.1,"accuracy_meters":10,"battery_pct":80}`, devices[0])
	cases := []struct{ name, method, path, body string }{
		{"GET /config", "GET", "/config", ""},
		{"GET /family/members", "GET", "/family/members", ""},
		{"GET /family/places", "GET", "/family/places", ""},
		{"GET /trips (30d, 200)", "GET", "/trips?user_id=" + users[0] + "&from=" + from + "&to=" + to + "&limit=200", ""},
		{"GET /trips/report (week)", "GET", "/trips/report?period=week&start=" + now.AddDate(0, 0, -6).Format("2006-01-02") + "&utc_offset_minutes=0", ""},
		{"GET /trips/report (month)", "GET", "/trips/report?period=month&start=" + now.Format("2006-01") + "-01&utc_offset_minutes=0", ""},
		{"GET /trips/{id}", "GET", "/trips/" + firstTrip + "?max_points=400", ""},
		{"POST /locations", "POST", "/locations", body},
	}
	for _, c := range cases {
		var ds []time.Duration
		code := 0
		for i := 0; i < 40; i++ {
			req := httptest.NewRequest(c.method, c.path, bytes.NewReader([]byte(c.body)))
			rec := httptest.NewRecorder()
			st := time.Now()
			r.ServeHTTP(rec, req)
			ds = append(ds, time.Since(st))
			code = rec.Code
		}
		sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
		t.Logf("PERFMETRIC %-28s status=%d p50=%6.2fms p95=%6.2fms max=%6.2fms", c.name, code,
			ms(ds[len(ds)/2]), ms(ds[len(ds)*95/100]), ms(ds[len(ds)-1]))
	}
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
