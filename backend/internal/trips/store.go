package trips

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

const (
	// maxPointsPerRun bounds the rows one incremental pass loads for a user.
	maxPointsPerRun = 20000
	// watermarkOverlap rewinds the watermark behind the safe point so the next
	// pass starts inside the preceding stop (needed to anchor a departure).
	watermarkOverlap = 10 * time.Minute
	// initialBackfill is how far back a user with no watermark is processed.
	initialBackfill = 7 * 24 * time.Hour
	// MaxComputeRange is the longest range ComputeRange accepts.
	MaxComputeRange  = 7 * 24 * time.Hour
	maxComputePoints = 150000
)

// Store reads locations and reads/writes trips.
type Store struct {
	Pool   *pgxpool.Pool
	Params Params
	// Events holds the driving event thresholds (env-configurable).
	EventParams EventParams
}

// NewStore returns a Store with default segmentation parameters.
func NewStore(pool *pgxpool.Pool) *Store { return &Store{Pool: pool, Params: DefaultParams(), EventParams: DefaultEventParams()} }

// Row is a stored trip as returned by the API. Speeds are GPS estimates in
// meters per second; convert to km/h or mph on the client.
type Row struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	DeviceID    string    `json:"device_id,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	EndedAt     time.Time `json:"ended_at"`
	DurationS   float64   `json:"duration_s"`
	DistanceM   float64   `json:"distance_m"`
	MaxSpeedMps float64   `json:"max_speed_mps"`
	AvgSpeedMps float64   `json:"avg_speed_mps"`
	Mode        string    `json:"mode"`
	SpeedSource string    `json:"speed_source"`
	StartLat    float64   `json:"start_lat"`
	StartLon    float64   `json:"start_lon"`
	EndLat      float64   `json:"end_lat"`
	EndLon      float64   `json:"end_lon"`
	PointCount  int       `json:"point_count"`
}

// RoutePoint is one downsampled fix of a trip's path.
type RoutePoint struct {
	TS       time.Time `json:"ts"`
	Lat      float64   `json:"lat"`
	Lon      float64   `json:"lon"`
	SpeedMps *float64  `json:"speed_mps,omitempty"`
}

func (s *Store) loadPoints(ctx context.Context, userID string, from, to time.Time, limit int) ([]Point, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT d.id::text, l.ts, ST_Y(l.geom), ST_X(l.geom), l.speed_mps, COALESCE(l.accuracy_meters, 0)
		FROM locations l
		JOIN devices d ON d.id = l.device_id
		WHERE d.user_id = $1 AND l.ts >= $2 AND l.ts <= $3
		ORDER BY l.ts
		LIMIT $4`, userID, from, to, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var pts []Point
	for rows.Next() {
		var p Point
		if err := rows.Scan(&p.DeviceID, &p.TS, &p.Lat, &p.Lon, &p.SpeedMps, &p.AccuracyM); err != nil {
			return nil, err
		}
		pts = append(pts, p)
	}
	return pts, rows.Err()
}

const upsertSQL = `
	INSERT INTO trips (user_id, device_id, family_id, started_at, ended_at, distance_m,
	                   max_speed_mps, avg_speed_mps, mode, speed_source,
	                   start_lat, start_lon, end_lat, end_lon, point_count, version)
	VALUES ($1, NULLIF($2,'')::uuid, NULLIF($3,'')::uuid, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
	ON CONFLICT (user_id, started_at) DO UPDATE SET
	    device_id = EXCLUDED.device_id, family_id = EXCLUDED.family_id,
	    ended_at = EXCLUDED.ended_at, distance_m = EXCLUDED.distance_m,
	    max_speed_mps = EXCLUDED.max_speed_mps, avg_speed_mps = EXCLUDED.avg_speed_mps,
	    mode = EXCLUDED.mode, speed_source = EXCLUDED.speed_source,
	    start_lat = EXCLUDED.start_lat, start_lon = EXCLUDED.start_lon,
	    end_lat = EXCLUDED.end_lat, end_lon = EXCLUDED.end_lon,
	    point_count = EXCLUDED.point_count, version = EXCLUDED.version, updated_at = now()
	RETURNING id::text`

// upsertTrips writes trips and REPLACES each trip's events in the same
// transaction, so recomputation is idempotent.
func upsertTrips(ctx context.Context, tx pgx.Tx, userID, familyID string, trips []Trip) error {
	for _, t := range trips {
		var id string
		if err := tx.QueryRow(ctx, upsertSQL, userID, t.DeviceID, familyID, t.StartedAt, t.EndedAt, t.DistanceM,
			t.MaxSpeedMps, t.AvgSpeedMps, t.Mode, t.SpeedSource,
			t.StartLat, t.StartLon, t.EndLat, t.EndLon, t.PointCount, AlgorithmVersion).Scan(&id); err != nil {
			return err
		}
		// Only GPS-derived events are replaced; sensor events survive recompute.
		if _, err := tx.Exec(ctx, `DELETE FROM trip_events WHERE trip_id = $1::uuid AND source = 'gps'`, id); err != nil {
			return err
		}
		for _, e := range t.Events {
			if _, err := tx.Exec(ctx, `INSERT INTO trip_events (trip_id, user_id, kind, started_at, ended_at, magnitude, lat, lon)
				VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8)`,
				id, userID, e.Kind, e.StartedAt, e.EndedAt, e.Magnitude, e.Lat, e.Lon); err != nil {
				return err
			}
		}
	}
	// Attach sensor events that arrived before (or independently of) the trips.
	return LinkSensorEvents(ctx, tx, userID)
}

// Execer is satisfied by pgx.Tx and *pgxpool.Pool.
type Execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// LinkSensorEvents attaches the user's unattached sensor events to the trip
// whose [started_at, ended_at] contains the event start. Idempotent.
func LinkSensorEvents(ctx context.Context, db Execer, userID string) error {
	_, err := db.Exec(ctx, `
		UPDATE trip_events e SET trip_id = t.id
		FROM (SELECT DISTINCT ON (e2.id) e2.id AS eid, t2.id
		      FROM trip_events e2 JOIN trips t2 ON t2.user_id = e2.user_id
		        AND e2.started_at >= t2.started_at AND e2.started_at <= t2.ended_at
		      WHERE e2.user_id = $1::uuid AND e2.source = 'sensor' AND e2.trip_id IS NULL
		      ORDER BY e2.id, t2.started_at) t
		WHERE e.id = t.eid`, userID)
	return err
}

// ProcessUser incrementally segments a user's new locations since their
// watermark and upserts completed trips. It returns the number of trips
// written. Safe to call repeatedly (idempotent through the unique key).
//
// Limitation: fixes that arrive later than the watermark (offline outbox
// replays older than the overlap) are not seen by the incremental pass; use
// ComputeRange to repair a day.
func (s *Store) ProcessUser(ctx context.Context, userID, familyID string) (int, error) {
	now := time.Now()
	floor := now.Add(-config.LocationRetention())
	if bf := now.Add(-initialBackfill); bf.After(floor) {
		floor = bf
	}
	from := floor
	var wm time.Time
	err := s.Pool.QueryRow(ctx, `SELECT processed_until FROM trip_watermarks WHERE user_id = $1`, userID).Scan(&wm)
	switch {
	case err == nil:
		if wm.After(from) {
			from = wm
		}
	case errors.Is(err, pgx.ErrNoRows):
	default:
		return 0, err
	}

	pts, err := s.loadPoints(ctx, userID, from, now, maxPointsPerRun)
	if err != nil {
		return 0, err
	}
	if len(pts) == 0 {
		return 0, nil
	}
	lastRaw := pts[len(pts)-1].TS
	capped := len(pts) >= maxPointsPerRun

	res := Segment(pts, s.Params)
	if capped && res.InProgress && !res.SafeUntil.After(from.Add(watermarkOverlap)) {
		// One enormous movement filled the page: close it rather than stall.
		p := s.Params
		p.FinalizeOpen = true
		res = Segment(pts, p)
	}

	attachEvents(res.Trips, pts, s.EventParams, s.Params)

	newWM := res.SafeUntil.Add(-watermarkOverlap)
	if n := len(res.Trips); n > 0 && res.Trips[n-1].EndedAt.After(newWM) {
		newWM = res.Trips[n-1].EndedAt
	}
	if newWM.Before(from) {
		newWM = from
	}

	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := upsertTrips(ctx, tx, userID, familyID, res.Trips); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO trip_watermarks (user_id, processed_until, last_point_at) VALUES ($1, $2, $3)
		ON CONFLICT (user_id) DO UPDATE SET processed_until = GREATEST(trip_watermarks.processed_until, EXCLUDED.processed_until),
		    last_point_at = EXCLUDED.last_point_at, updated_at = now()`, userID, newWM, lastRaw); err != nil {
		return 0, err
	}
	return len(res.Trips), tx.Commit(ctx)
}

// ComputeRange recomputes a user's trips whose start lies in [from, to):
// existing rows in that range are replaced. Ranges are limited to
// MaxComputeRange and to the retention window. A movement still in progress at
// `to` is only stored when `to` is more than an hour in the past.
func (s *Store) ComputeRange(ctx context.Context, userID, familyID string, from, to time.Time) (int, error) {
	if !to.After(from) {
		return 0, errors.New("to must be after from")
	}
	if to.Sub(from) > MaxComputeRange {
		return 0, fmt.Errorf("range must be at most %d days", int(MaxComputeRange.Hours()/24))
	}
	now := time.Now()
	if min := now.Add(-config.LocationRetention()); from.Before(min) {
		from = min
		if !to.After(from) {
			return 0, nil
		}
	}
	pts, err := s.loadPoints(ctx, userID, from, to, maxComputePoints)
	if err != nil {
		return 0, err
	}
	p := s.Params
	p.FinalizeOpen = to.Before(now.Add(-time.Hour))
	res := Segment(pts, p)
	keep := make([]Trip, 0, len(res.Trips))
	for _, t := range res.Trips {
		if !t.StartedAt.Before(from) && t.StartedAt.Before(to) {
			keep = append(keep, t)
		}
	}
	attachEvents(keep, pts, s.EventParams, s.Params)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Sensor events are not derived from the track: detach them so the trip
	// delete (which cascades to GPS events) does not take them along. They are
	// re-linked by upsertTrips.
	if _, err := tx.Exec(ctx, `UPDATE trip_events SET trip_id = NULL WHERE source = 'sensor' AND user_id = $1
		AND trip_id IN (SELECT id FROM trips WHERE user_id = $1 AND started_at >= $2 AND started_at < $3)`, userID, from, to); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM trips WHERE user_id = $1 AND started_at >= $2 AND started_at < $3`, userID, from, to); err != nil {
		return 0, err
	}
	if err := upsertTrips(ctx, tx, userID, familyID, keep); err != nil {
		return 0, err
	}
	return len(keep), tx.Commit(ctx)
}

const rowCols = `id::text, user_id::text, COALESCE(device_id::text, ''), started_at, ended_at,
	EXTRACT(EPOCH FROM (ended_at - started_at)), distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
	start_lat, start_lon, end_lat, end_lon, point_count`

func scanRow(r pgx.Row) (Row, error) {
	var t Row
	err := r.Scan(&t.ID, &t.UserID, &t.DeviceID, &t.StartedAt, &t.EndedAt, &t.DurationS, &t.DistanceM,
		&t.MaxSpeedMps, &t.AvgSpeedMps, &t.Mode, &t.SpeedSource, &t.StartLat, &t.StartLon, &t.EndLat, &t.EndLon, &t.PointCount)
	return t, err
}

// List returns trips that started in [from, to), newest first. Trips older
// than the retention window are never returned.
func (s *Store) List(ctx context.Context, userID string, from, to time.Time, limit int) ([]Row, error) {
	if min := time.Now().Add(-config.LocationRetention()); from.Before(min) {
		from = min
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+rowCols+` FROM trips
		WHERE user_id = $1 AND started_at >= $2 AND started_at < $3
		ORDER BY started_at DESC LIMIT $4`, userID, from, to, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Row{}
	for rows.Next() {
		t, err := scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ErrNotFound is returned when a trip does not exist or is past retention.
var ErrNotFound = errors.New("trip not found")

// Get returns one trip by id.
func (s *Store) Get(ctx context.Context, id string) (Row, error) {
	t, err := scanRow(s.Pool.QueryRow(ctx, `SELECT `+rowCols+` FROM trips WHERE id::text = $1 AND started_at >= $2`,
		id, time.Now().Add(-config.LocationRetention())))
	if errors.Is(err, pgx.ErrNoRows) {
		return t, ErrNotFound
	}
	return t, err
}

// Route returns the trip's fixes, cleaned and downsampled to at most max
// points (always including first and last).
func (s *Store) Route(ctx context.Context, t Row, max int) ([]RoutePoint, error) {
	pts, err := s.loadPoints(ctx, t.UserID, t.StartedAt, t.EndedAt, maxPointsPerRun)
	if err != nil {
		return nil, err
	}
	pts, _ = Clean(pts, s.Params)
	return Downsample(pts, max), nil
}

// EventRow is a stored driving event as returned by the API.
type EventRow struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
	Magnitude float64   `json:"magnitude"`
	// Lat/Lon are null for sensor events recorded without a location fix.
	Lat    *float64 `json:"lat"`
	Lon    *float64 `json:"lon"`
	Source string   `json:"source"`
}

// Events returns a trip's stored events, oldest first (never nil).
func (s *Store) Events(ctx context.Context, tripID string) ([]EventRow, error) {
	rows, err := s.Pool.Query(ctx, `SELECT id::text, kind, started_at, ended_at, magnitude, lat, lon, source
		FROM trip_events_effective WHERE trip_id = $1::uuid ORDER BY started_at, id`, tripID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EventRow{}
	for rows.Next() {
		var e EventRow
		if err := rows.Scan(&e.ID, &e.Kind, &e.StartedAt, &e.EndedAt, &e.Magnitude, &e.Lat, &e.Lon, &e.Source); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Downsample keeps at most max evenly spaced points, always the first and last.
func Downsample(pts []Point, max int) []RoutePoint {
	out := []RoutePoint{}
	n := len(pts)
	if n == 0 || max < 2 {
		return out
	}
	conv := func(p Point) RoutePoint {
		rp := RoutePoint{TS: p.TS, Lat: p.Lat, Lon: p.Lon}
		if p.SpeedMps != nil && *p.SpeedMps >= 0 {
			rp.SpeedMps = p.SpeedMps
		}
		return rp
	}
	if n <= max {
		for _, p := range pts {
			out = append(out, conv(p))
		}
		return out
	}
	for k := 0; k < max; k++ {
		out = append(out, conv(pts[k*(n-1)/(max-1)]))
	}
	return out
}

// StopRow is a dwell between two consecutive trips, derived from their gap.
type StopRow struct {
	ArrivedAt  time.Time `json:"arrived_at"`
	DepartedAt time.Time `json:"departed_at"`
	DurationS  float64   `json:"duration_s"`
	Lat        float64   `json:"lat"`
	Lon        float64   `json:"lon"`
}

// DrivingSummary aggregates driving legs only.
type DrivingSummary struct {
	TripCount   int     `json:"trip_count"`
	DistanceM   float64 `json:"distance_m"`
	DriveTimeS  float64 `json:"drive_time_s"`
	MaxSpeedMps float64 `json:"max_speed_mps"`
	AvgSpeedMps float64 `json:"avg_speed_mps"`
	// SpeedEvents counts episodes (2+ consecutive fixes) above the threshold.
	SpeedEvents          int  `json:"speed_events"`
	SpeedEventsTruncated bool `json:"speed_events_truncated,omitempty"`
}

// Summary is the driving report for a period.
type Summary struct {
	UserID            string         `json:"user_id"`
	From              time.Time      `json:"from"`
	To                time.Time      `json:"to"`
	TripCount         int            `json:"trip_count"`
	TripsByMode       map[string]int `json:"trips_by_mode"`
	TotalDistanceM    float64        `json:"total_distance_m"`
	Driving           DrivingSummary `json:"driving"`
	SpeedThresholdMps float64        `json:"speed_threshold_mps"`
	SpeedSource       string         `json:"speed_source_note"`
	StopCount         int            `json:"stop_count"`
	Stops             []StopRow      `json:"stops"`
}

const maxSpeedEventTrips = 200

// Summary builds the report from stored trips in [from, to). Speed events are
// computed on demand from the raw fixes of the period's driving trips.
func (s *Store) Summary(ctx context.Context, userID string, from, to time.Time, thresholdMps float64) (Summary, error) {
	if min := time.Now().Add(-config.LocationRetention()); from.Before(min) {
		from = min
	}
	rows, err := s.List(ctx, userID, from, to, 5000)
	if err != nil {
		return Summary{}, err
	}
	sum := Summary{
		UserID: userID, From: from, To: to, TripsByMode: map[string]int{},
		SpeedThresholdMps: thresholdMps, Stops: []StopRow{},
		SpeedSource: "speeds are GPS estimates (device-reported where available, else distance/time)",
	}
	// List is newest-first; walk oldest-first for stop derivation.
	var prev *Row
	eventTrips := 0
	for i := len(rows) - 1; i >= 0; i-- {
		t := rows[i]
		sum.TripCount++
		sum.TripsByMode[t.Mode]++
		sum.TotalDistanceM += t.DistanceM
		if t.Mode == ModeDriving {
			d := &sum.Driving
			d.TripCount++
			d.DistanceM += t.DistanceM
			d.DriveTimeS += t.DurationS
			if t.MaxSpeedMps > d.MaxSpeedMps {
				d.MaxSpeedMps = t.MaxSpeedMps
			}
			if eventTrips >= maxSpeedEventTrips {
				d.SpeedEventsTruncated = true
			} else if thresholdMps > 0 && t.MaxSpeedMps > thresholdMps {
				eventTrips++
				pts, err := s.loadPoints(ctx, userID, t.StartedAt, t.EndedAt, maxPointsPerRun)
				if err != nil {
					return sum, err
				}
				d.SpeedEvents += CountSpeedEvents(pts, thresholdMps, s.Params)
			}
		}
		if prev != nil {
			if gap := t.StartedAt.Sub(prev.EndedAt); gap >= s.Params.StopDuration {
				sum.Stops = append(sum.Stops, StopRow{ArrivedAt: prev.EndedAt, DepartedAt: t.StartedAt,
					DurationS: gap.Seconds(), Lat: prev.EndLat, Lon: prev.EndLon})
			}
		}
		r := t
		prev = &r
	}
	sum.StopCount = len(sum.Stops)
	if sum.Driving.DriveTimeS > 0 {
		sum.Driving.AvgSpeedMps = sum.Driving.DistanceM / sum.Driving.DriveTimeS
	}
	return sum, nil
}

// Worker runs ProcessUser for users with new locations on an interval.
type Worker struct {
	Store       *Store
	Interval    time.Duration
	Concurrency int // simultaneous users per pass (default 4)
	MaxUsers    int // users per pass (default 200)
}

// Run blocks until ctx is cancelled. Each pass is bounded (MaxUsers,
// Concurrency, a per-user timeout) so a backlog cannot starve the pool.
func (w *Worker) Run(ctx context.Context) {
	if w.Interval <= 0 {
		w.Interval = 5 * time.Minute
	}
	timer := time.NewTimer(30 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		w.Pass(ctx)
		timer.Reset(w.Interval)
	}
}

// Pass runs one bounded sweep and prunes trips past retention.
func (w *Worker) Pass(ctx context.Context) {
	conc, maxUsers := w.Concurrency, w.MaxUsers
	if conc < 1 {
		conc = 4
	}
	if maxUsers < 1 {
		maxUsers = 200
	}
	now := time.Now()
	retention := config.LocationRetention()
	backfill := initialBackfill
	if retention < backfill {
		backfill = retention
	}
	rows, err := w.Store.Pool.Query(ctx, `
		SELECT u.id::text, COALESCE(u.family_id::text, '')
		FROM users u
		LEFT JOIN trip_watermarks w ON w.user_id = u.id
		WHERE EXISTS (
			SELECT 1 FROM devices d JOIN locations l ON l.device_id = d.id
			WHERE d.user_id = u.id AND l.ts > COALESCE(w.last_point_at, $1::timestamptz))
		LIMIT $2`, now.Add(-backfill), maxUsers)
	if err != nil {
		slog.Warn("trips: list users failed", "err", err)
		return
	}
	type target struct{ id, fam string }
	var targets []target
	for rows.Next() {
		var t target
		if err := rows.Scan(&t.id, &t.fam); err == nil {
			targets = append(targets, t)
		}
	}
	rows.Close()

	sem := make(chan struct{}, conc)
	done := make(chan struct{}, len(targets))
	for _, t := range targets {
		select {
		case sem <- struct{}{}:
		case <-ctx.Done():
			return
		}
		go func(t target) {
			defer func() { <-sem; done <- struct{}{} }()
			uctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			if _, err := w.Store.ProcessUser(uctx, t.id, t.fam); err != nil && ctx.Err() == nil {
				slog.Warn("trips: process user failed", "user", t.id, "err", err)
			}
		}(t)
	}
	for range targets {
		<-done
	}
	if ctx.Err() == nil {
		if _, err := w.Store.Pool.Exec(ctx, `DELETE FROM trips WHERE started_at < $1`, now.Add(-retention)); err != nil {
			slog.Warn("trips: retention prune failed", "err", err)
		}
		// Also purges sensor events that never found a trip.
		if _, err := w.Store.Pool.Exec(ctx, `DELETE FROM trip_events WHERE started_at < $1`, now.Add(-retention)); err != nil {
			slog.Warn("trips: event retention prune failed", "err", err)
		}
	}
}
