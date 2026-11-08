package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// Ingest benchmarks against a real (throwaway) TimescaleDB, companions of
// BenchmarkIngestMoving in live_test.go. They answer one question for the
// tracking architecture: what does a point cost the server when it arrives
// alone (POST /locations, the 1 Hz live path) versus inside a batch
// (POST /locations/batch, the store-and-forward path)? Both measure the
// handler plus Postgres, no HTTP stack, no auth middleware, and the async
// post-commit work (geofences, broadcast) is only submitted, not awaited.
//
// Run (needs TEST_DATABASE_URL pointing at a migrated throwaway database;
// scripts/perf/ingest-bench.sh does the whole thing in Docker):
//
//	go test ./internal/handlers -run '^$' -bench 'BenchmarkIngest' -benchmem -count 3 -benchtime 200x
//
// Results are recorded in docs/design/OPTIMIZATION_ARCHITECTURE.md.

func benchPoolAndDevice(b *testing.B) (*pgxpool.Pool, string, string, func()) {
	b.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		b.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		b.Fatal(err)
	}
	var uid, dev string
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'Bench','x') RETURNING id`,
		"bench-"+time.Now().Format("150405.000000")+"@example.com").Scan(&uid); err != nil {
		b.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, uid).Scan(&dev); err != nil {
		b.Fatal(err)
	}
	cleanup := func() {
		// Let the post-commit work (geofence pass, broadcast) submitted by the
		// last iterations finish before the pool goes away.
		time.Sleep(300 * time.Millisecond)
		pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)
		pool.Close()
	}
	return pool, uid, dev, cleanup
}

// BenchmarkIngestBatch100 posts 100 moving points per request (the outbox's
// drain chunk size, LocationOutbox.defaultMaxPerCall). Divide ns/op by 100
// for the per-point cost and compare with BenchmarkIngestMoving.
func BenchmarkIngestBatch100(b *testing.B) {
	benchIngestBatch(b, 100)
}

// BenchmarkIngestBatch500 posts the maximum batch (batchMaxPoints).
func BenchmarkIngestBatch500(b *testing.B) {
	benchIngestBatch(b, 500)
}

func benchIngestBatch(b *testing.B, n int) {
	pool, uid, dev, cleanup := benchPoolAndDevice(b)
	defer cleanup()
	srv := &Server{Pool: pool, hub: newHub(), LocationLimit: sms.NewLimiter()}
	srv.LocationLimit = nil
	claims := &auth.Claims{UserID: uid}
	// Timestamps must stay unique and ascending across iterations: the batch
	// endpoint dedupes on (device, ts) and the stored points keep accumulating.
	base := time.Now().Add(-72 * time.Hour)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		pts := make([]map[string]any, 0, n)
		for j := 0; j < n; j++ {
			k := i*n + j
			ts := base.Add(time.Duration(k) * time.Second)
			pts = append(pts, map[string]any{
				"device_id": dev, "ts": ts,
				"lat": 40.0 + float64(k%100000)*0.0001, "lon": -75.0,
				"speed_mps": 20.0, "heading_deg": 90.0, "accuracy_meters": 5.0,
				"source": "background",
			})
		}
		body, _ := json.Marshal(map[string]any{"points": pts})
		req := httptest.NewRequest(http.MethodPost, "/locations/batch", bytes.NewReader(body))
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), claims))
		rec := httptest.NewRecorder()
		srv.IngestLocationBatch(rec, req)
		if rec.Code/100 != 2 {
			b.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
	}
	b.ReportMetric(float64(n), "points/op")
}

// BenchmarkIngestStationary posts the same position again and again: the
// server's stationary-dedup path (200, no locations row, liveness only).
func BenchmarkIngestStationary(b *testing.B) {
	pool, uid, dev, cleanup := benchPoolAndDevice(b)
	defer cleanup()
	srv := &Server{Pool: pool, hub: newHub(), LocationLimit: sms.NewLimiter()}
	srv.LocationLimit = nil
	claims := &auth.Claims{UserID: uid}
	base := time.Now().Add(-10 * time.Minute)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		body, _ := json.Marshal(map[string]any{
			"device_id": dev, "ts": base.Add(time.Duration(i+1) * 10 * time.Millisecond),
			"lat": 41.0, "lon": -75.0, "speed_mps": 0.0, "accuracy_meters": 12.0,
		})
		req := httptest.NewRequest(http.MethodPost, "/locations", bytes.NewReader(body))
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), claims))
		rec := httptest.NewRecorder()
		srv.IngestLocation(rec, req)
		if rec.Code != 201 && rec.Code != 200 {
			b.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
	}
}
