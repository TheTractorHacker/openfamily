package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Offline backfill: a device that spends hours without data (a hike, a road
// trip through dead zones) queues its fixes client-side and drains them here
// once connectivity returns, so the family's history shows the actual track
// instead of a hole. This is deliberate store-and-forward semantics — very
// different rules from the live single-point ingest:
//
//   - points older than maxTSAge are accepted (up to batchMaxAge); the fresh
//     "ts is too old" rule only guards the live feed;
//   - the strict monotonicity check against MAX(l.ts) is skipped: the first
//     live post-reconnect fix makes every queued point older than the head,
//     and requiring newness here would reject the entire queue forever;
//   - NO geofence evaluation: replaying historical points would fire hours-
//     late arrive/leave transitions;
//   - NO `location`/`presence` WebSocket fan-out: backfill is history repair,
//     never a liveness announcement;
//   - no stationary dedup: queued points are already sparse (up to one per
//     reporting interval) and they carry the track we are trying to restore.
//
// member_positions is still upserted per point, keeping the same
// "never regress" WHERE guard as the live path, so a stale backfilled point
// can never move the family map backwards; devices.last_seen is refreshed
// once (the device is demonstrably alive when it syncs).
const (
	// batchMaxPoints caps one request. The client drains in chunks of ≤100,
	// so the default is generous; anything larger smells like a bug or abuse
	// and is rejected in one round-trip.
	batchMaxPoints = 500

	// batchMaxAge is the oldest allowed point timestamp. Chosen far wider
	// than any expected offline window; the client caps its queue far
	// tighter (48 hours). Points older than this are dropped, not stored.
	batchMaxAge = 7 * 24 * time.Hour

	// batchMaxBytes caps the decoded body (~500 points x ~400 B of JSON).
	batchMaxBytes = 1 << 20

	// batchRateLimit / batchWindow bound backfill requests per user. A
	// well-behaved client needs a handful of batches per sync; each batch may
	// carry up to batchMaxPoints rows, far above the live ingest cap.
	batchRateLimit = 10
	batchWindow    = time.Minute
)

// batchPoint is one queued location report. Fields mirror the single-point
// POST /locations body so clients can enqueue the exact bodies they failed to
// send and replay them unchanged.
type batchPoint struct {
	DeviceID       string     `json:"device_id"`
	TS             *time.Time `json:"ts,omitempty"`
	Lat            float64    `json:"lat"`
	Lon            float64    `json:"lon"`
	AccuracyMeters *float64   `json:"accuracy_meters,omitempty"`
	AltitudeMeters *float64   `json:"altitude_meters,omitempty"`
	SpeedMPS       *float64   `json:"speed_mps,omitempty"`
	HeadingDeg     *float64   `json:"heading_deg,omitempty"`
	BatteryPct     *float64   `json:"battery_pct,omitempty"`
	MotionState    string     `json:"motion_state,omitempty"`
	Source         string     `json:"source,omitempty"`
}

// filterBatchPoints validates each point and drops the permanently invalid
// ones: lat/lon out of range, timestamps too far in the future (clock skew),
// or older than batchMaxAge (the replay-protection floor for history).
// Points with no timestamp resolve to `now`. Pure — no database — so it is
// unit-testable without a pool.
func filterBatchPoints(points []batchPoint, now time.Time) (kept []batchPoint, rejected int) {
	kept = points[:0:0]
	for _, p := range points {
		if p.Lat < -90 || p.Lat > 90 || p.Lon < -180 || p.Lon > 180 {
			rejected++
			continue
		}
		ts := p.TS
		if ts == nil {
			clone := now
			ts = &clone
		}
		if ts.After(now.Add(maxTSSkew)) || ts.Before(now.Add(-batchMaxAge)) {
			rejected++
			continue
		}
		p.TS = ts
		kept = append(kept, p)
	}
	return kept, rejected
}

// batchKept filters out points already stored (previous deliveries of the
// same timestamp) and duplicates within the batch itself. The locations table
// has a unique (device_id, ts) index (000025) and the INSERT uses ON CONFLICT
// DO NOTHING as the race-proof backstop; this pre-filter keeps the common retry
// path cheap and the stored/skipped counts exact.
// Pure — no database — so it is unit-testable without a pool.
func batchKept(points []batchPoint, existing map[string]struct{}) (kept []batchPoint, skipped int) {
	seen := make(map[string]struct{}, len(points))
	kept = points[:0:0]
	for _, p := range points {
		key := p.TS.UTC().Format(time.RFC3339Nano)
		if _, dup := seen[key]; dup {
			skipped++
			continue
		}
		if _, dup := existing[key]; dup {
			skipped++
			continue
		}
		seen[key] = struct{}{}
		kept = append(kept, p)
	}
	return kept, skipped
}

// batchTSKeys renders dedup keys for the point timestamps the device is about
// to send, so already-stored points can be skipped in one query.
func batchTSKeys(points []batchPoint) []time.Time {
	tsList := make([]time.Time, 0, len(points))
	for _, p := range points {
		tsList = append(tsList, *p.TS)
	}
	return tsList
}

// IngestLocationBatch stores a batch of queued location points for a single
// device owned by the authenticated caller (Bearer token or X-Device-Key,
// same middleware as POST /locations). The client orders its queue
// newest-first so the freshest position lands before history, bounding how
// long the map can stay stale.
//
// The order of stored writes is oldest → newest: the member_positions upsert
// runs per point under the `WHERE member_positions.ts < EXCLUDED.ts` guard,
// so the final stored position is always the newest in the batch (or the one
// already stored, whichever is newer).
func (s *Server) IngestLocationBatch(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.LocationLimit != nil && !s.LocationLimit.Allow("locbatch:"+claims.UserID, batchRateLimit, batchWindow) {
		writeError(w, http.StatusTooManyRequests, "too many location backfill requests")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, batchMaxBytes)
	var req struct {
		Points []batchPoint `json:"points"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.Points) == 0 {
		writeError(w, http.StatusBadRequest, "points is required")
		return
	}
	if len(req.Points) > batchMaxPoints {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("too many points (max %d)", batchMaxPoints))
		return
	}

	// One device per batch: the dedupe pre-query and last_seen update are per
	// device, and a mixed batch would blur device ownership checks.
	deviceID := req.Points[0].DeviceID
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}
	for _, p := range req.Points[1:] {
		if p.DeviceID != deviceID {
			writeError(w, http.StatusBadRequest, "all points must use the same device")
			return
		}
	}

	// Verify the device belongs to the caller (same rule as single ingest).
	var ownerID string
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT user_id FROM devices WHERE id = $1`, deviceID).Scan(&ownerID); err != nil {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	if ownerID != claims.UserID {
		writeError(w, http.StatusForbidden, "device does not belong to you")
		return
	}

	var familyID *string
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT family_id FROM users WHERE id = $1`, ownerID).Scan(&familyID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load user")
		return
	}

	kept, rejected := filterBatchPoints(req.Points, time.Now())
	stored, skipped := 0, 0
	if len(kept) > 0 {
		var err error
		stored, skipped, err = s.storeBackfill(r.Context(), deviceID, ownerID, kept)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to store batch")
			return
		}
		if stored+skipped > 0 {
			// The device is demonstrably alive when it syncs its backlog, so
			// refresh liveness once (server receipt time, matching the
			// presence rationale). Purely-invalid batches don't count.
			if _, err := s.Pool.Exec(r.Context(),
				`UPDATE devices SET last_seen = now() WHERE id = $1`, deviceID); err != nil {
				writeError(w, http.StatusInternalServerError, "failed to update device")
				return
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"stored":   stored,
		"skipped":  skipped,
		"rejected": rejected,
	})
}

// storeBackfill begins the write transaction, drops points already stored,
// inserts the rest, upserts member_positions (never regressing), and commits.
// It returns (stored, skipped, err): skipped counts duplicates against
// existing rows or within the batch itself.
func (s *Server) storeBackfill(ctx context.Context, deviceID, ownerID string, points []batchPoint) (stored, skipped int, err error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	existing := make(map[string]struct{})
	rows, err := tx.Query(ctx, `
		SELECT ts FROM locations
		WHERE device_id = $1 AND ts = ANY($2)`, deviceID, batchTSKeys(points))
	if err != nil {
		return 0, 0, fmt.Errorf("dedupe query: %w", err)
	}
	for rows.Next() {
		var ts time.Time
		if err := rows.Scan(&ts); err != nil {
			rows.Close()
			return 0, 0, fmt.Errorf("dedupe scan: %w", err)
		}
		existing[ts.UTC().Format(time.RFC3339Nano)] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, 0, fmt.Errorf("dedupe rows: %w", err)
	}
	rows.Close()

	storable, dupes := batchKept(points, existing)

	// Oldest first so the guarded member_positions upsert converges on the
	// newest point in the batch.
	sort.Slice(storable, func(i, j int) bool { return storable[i].TS.Before(*storable[j].TS) })

	if len(storable) > 0 {
		b := &pgx.Batch{}
		for _, p := range storable {
			b.Queue(`
				INSERT INTO locations (device_id, ts, geom, accuracy_meters, altitude_meters, speed_mps, heading_deg, battery_pct, motion_state, source)
				VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, $6, $7, $8, $9, $10, $11)
				ON CONFLICT (device_id, ts) DO NOTHING`,
				p.DeviceID, *p.TS, p.Lon, p.Lat, p.AccuracyMeters,
				p.AltitudeMeters, p.SpeedMPS, p.HeadingDeg, p.BatteryPct,
				nullIfEmpty(p.MotionState), nullIfEmpty(p.Source),
			)
			b.Queue(`
				INSERT INTO member_positions (user_id, lat, lon, ts, battery_pct, speed_mps, motion_state, accuracy_meters, device_id, updated_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
				ON CONFLICT (user_id) DO UPDATE SET
					lat = EXCLUDED.lat, lon = EXCLUDED.lon, ts = EXCLUDED.ts,
					battery_pct = EXCLUDED.battery_pct, speed_mps = EXCLUDED.speed_mps,
					motion_state = EXCLUDED.motion_state, accuracy_meters = EXCLUDED.accuracy_meters,
					device_id = EXCLUDED.device_id, updated_at = now()
				WHERE member_positions.ts < EXCLUDED.ts`,
				ownerID, p.Lat, p.Lon, *p.TS, p.BatteryPct, p.SpeedMPS,
				nullIfEmpty(p.MotionState), p.AccuracyMeters, p.DeviceID,
			)
		}
		br := tx.SendBatch(ctx, b)
		inserted := 0
		for i := 0; i < len(storable)*2; i++ {
			tag, err := br.Exec()
			if err != nil {
				br.Close()
				return 0, 0, fmt.Errorf("ingest exec: %w", err)
			}
			// Even statements are the locations INSERTs; zero rows means a
			// concurrent delivery stored that timestamp first (ON CONFLICT).
			if i%2 == 0 {
				inserted += int(tag.RowsAffected())
			}
		}
		dupes += len(storable) - inserted
		stored = inserted
		if err := br.Close(); err != nil {
			return 0, 0, fmt.Errorf("ingest batch: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("commit: %w", err)
	}
	return stored, dupes, nil
}