package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// Event outbox, scanner and webhook delivery for the Home Assistant
// integration. The outbox (ha_events) holds facts without coordinates; every
// integration's visibility rules are applied again when an event is rendered
// for it, so a token never receives more than the API would show it.

const (
	haScanEvery      = 5 * time.Second
	haScanOverlap    = 2 * time.Minute // tolerate commit lag; the unique source_key dedupes
	haTripSettle     = 5 * time.Minute // a trip is announced once it has been over this long
	haTripLookback   = 3 * time.Hour
	haOutboxKeep     = 7 * 24 * time.Hour
	haBatchPerTarget = 25
	haMaxAttempts    = 6
	haParallel       = 8
)

type haEvent struct {
	ID         int64
	Kind       string
	UserID     string
	RefID      string
	PlaceID    string
	PlaceName  string
	OccurredAt time.Time
	Data       map[string]any
}

func (s *Server) haLoadEvents(ctx context.Context, after int64, limit int) ([]haEvent, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT id, kind, user_id::text, COALESCE(ref_id::text, ''), COALESCE(place_id::text, ''), place_name, occurred_at, data
		FROM ha_events WHERE id > $1 ORDER BY id LIMIT $2`, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []haEvent
	for rows.Next() {
		var e haEvent
		var raw []byte
		if err := rows.Scan(&e.ID, &e.Kind, &e.UserID, &e.RefID, &e.PlaceID, &e.PlaceName, &e.OccurredAt, &raw); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(raw, &e.Data)
		out = append(out, e)
	}
	return out, rows.Err()
}

// haEventPayload renders ev for integ, or reports it invisible.
func (s *Server) haEventPayload(ctx context.Context, integ *haIntegration, ev haEvent) (map[string]any, bool, error) {
	if !integ.has(haScopeEvents) || !haKnownKind(ev.Kind) {
		return nil, false, nil
	}
	if (ev.Kind == "trip_start" || ev.Kind == "trip_end") && !integ.has(haScopeDriving) {
		return nil, false, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT m.circle_id::text, (m.sharing_enabled AND NOT `+pausedExprSQL("m.user_id")+`),
		       NOT e2ee_plaintext_blocked(m.circle_id), u.name
		FROM live_circle_members m
		JOIN live_circle_members v ON v.circle_id = m.circle_id AND v.user_id = $1
		JOIN users u ON u.id = m.user_id
		WHERE m.user_id = $2 AND m.circle_id = ANY($3::uuid[])`, integ.UserID, ev.UserID, integ.CircleIDs)
	if err != nil {
		return nil, false, err
	}
	var name string
	visible, coords := false, false
	shareCircles := map[string]bool{}
	readableIn := map[string]bool{}
	for rows.Next() {
		var cid string
		var sharing, readable bool
		if err := rows.Scan(&cid, &sharing, &readable, &name); err != nil {
			rows.Close()
			return nil, false, err
		}
		alarm := ev.Kind == "sos" || ev.Kind == "crash"
		readableIn[cid] = readable
		if readable && sharing {
			shareCircles[cid] = true
		}
		if (alarm) || (readable && sharing) {
			visible = true
		}
		if readable && (alarm || sharing) {
			coords = true
		}
	}
	rows.Close()
	if rows.Err() != nil {
		return nil, false, rows.Err()
	}
	if !visible {
		return nil, false, nil
	}
	out := map[string]any{
		"id": ev.ID, "type": ev.Kind, "occurred_at": ev.OccurredAt.UTC().Format(time.RFC3339),
		"member": map[string]any{"id": ev.UserID, "name": name},
	}
	switch ev.Kind {
	case "arrival", "departure":
		var typ, cid string
		err := s.Pool.QueryRow(ctx, `SELECT p.type, COALESCE(p.circle_id, p.family_id)::text FROM places p WHERE p.id::text = $1`, ev.PlaceID).Scan(&typ, &cid)
		if errors.Is(err, pgx.ErrNoRows) {
			// The place was deleted since: the name in the outbox is all there is, and
			// it is only shown when the event is visible through some shared circle.
			typ = ""
		} else if err != nil {
			return nil, false, err
		} else if !shareCircles[cid] {
			return nil, false, nil // a place of a circle this token cannot read through
		}
		out["place"] = haPlaceRef{ID: ev.PlaceID, Name: ev.PlaceName, IsHome: typ == "home"}
	case "low_battery", "trip_end", "trip_start":
		if ev.Data != nil {
			out["data"] = ev.Data
		}
	case "sos", "crash":
		if ev.Kind == "sos" {
			// An SOS belongs to the circle it was raised in; it must be one this token reads.
			var fam *string
			if err := s.Pool.QueryRow(ctx, `SELECT family_id::text FROM alerts WHERE id::text = $1`, ev.RefID).Scan(&fam); err != nil || fam == nil {
				return nil, false, nil
			}
			rd, ok := readableIn[*fam]
			if !ok {
				return nil, false, nil
			}
			coords = rd
		}
		loc := map[string]any{"available": false}
		switch {
		case !coords:
			loc["reason"] = haStateUnavailablePrivate
		case !integ.has(haScopeLocation):
			loc["reason"] = "scope"
		default:
			lat, lon := s.haAlarmPosition(ctx, ev)
			if lat != nil && lon != nil {
				loc = map[string]any{"available": true, "lat": *lat, "lon": *lon}
			} else {
				loc["reason"] = "no_fix"
			}
		}
		out["location"] = loc
		if ev.Data != nil {
			out["data"] = ev.Data
		}
	}
	return out, true, nil
}

func (s *Server) haAlarmPosition(ctx context.Context, ev haEvent) (*float64, *float64) {
	if ev.RefID == "" {
		return nil, nil
	}
	var lat, lon *float64
	q := `SELECT lat, lon FROM alerts WHERE id::text = $1`
	if ev.Kind == "crash" {
		q = `SELECT lat, lon FROM crash_events WHERE id::text = $1`
	}
	if err := s.Pool.QueryRow(ctx, q, ev.RefID).Scan(&lat, &lon); err != nil {
		return nil, nil
	}
	return lat, lon
}

// ---- outbox ---------------------------------------------------------------

// haEnqueue adds an event fact once per sourceKey. It is a no-op while no
// integration listens, so servers that do not use Home Assistant store nothing.
func (s *Server) haEnqueue(ctx context.Context, kind, userID, sourceKey, refID, placeID, placeName string, at time.Time, data map[string]any) {
	var listening bool
	if err := s.Pool.QueryRow(ctx, haListeningSQL).Scan(&listening); err != nil || !listening {
		return
	}
	s.haInsertEvent(ctx, kind, userID, sourceKey, refID, placeID, placeName, at, data)
}

const haListeningSQL = `SELECT EXISTS (SELECT 1 FROM ha_integrations WHERE revoked_at IS NULL AND 'events' = ANY(scopes))`

func pgSeconds(d time.Duration) string { return fmt.Sprintf("%d seconds", int(d.Seconds())) }

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Server) haInsertEvent(ctx context.Context, kind, userID, sourceKey, refID, placeID, placeName string, at time.Time, data map[string]any) {
	if data == nil {
		data = map[string]any{}
	}
	raw, _ := json.Marshal(data)
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO ha_events (kind, user_id, source_key, ref_id, place_id, place_name, occurred_at, data)
		VALUES ($1, $2, $3, $4::uuid, $5::uuid, $6, $7, $8)
		ON CONFLICT (source_key) DO NOTHING`,
		kind, userID, sourceKey, nullStr(refID), nullStr(placeID), placeName, at, raw); err != nil {
		haLogErr("enqueue "+kind, err)
	}
}

func (s *Server) haCursor(ctx context.Context, source string) (time.Time, error) {
	var ts time.Time
	err := s.Pool.QueryRow(ctx, `
		INSERT INTO ha_event_cursors (source, cursor_ts) VALUES ($1, now() + $2::interval)
		ON CONFLICT (source) DO UPDATE SET source = EXCLUDED.source RETURNING cursor_ts`, source, pgSeconds(haScanOverlap)).Scan(&ts)
	return ts, err
}

func (s *Server) haSetCursor(ctx context.Context, source string, ts time.Time) {
	if _, err := s.Pool.Exec(ctx, `UPDATE ha_event_cursors SET cursor_ts = $2 WHERE source = $1 AND cursor_ts < $2`, source, ts); err != nil {
		haLogErr("cursor", err)
	}
}

// haScan copies new geofence transitions, SOS alerts, crash reports and ended
// drives into the outbox. When nobody listens it only moves the cursors to
// "now", so enabling the integration later never replays old history.
func (s *Server) haScan(ctx context.Context) {
	var listening bool
	if err := s.Pool.QueryRow(ctx, haListeningSQL).Scan(&listening); err != nil {
		return
	}
	if !listening {
		// Idle: park every cursor at "now" (plus the overlap the queries subtract again).
		_, _ = s.Pool.Exec(ctx, `UPDATE ha_event_cursors SET cursor_ts = now() + $1::interval`, pgSeconds(haScanOverlap))
		return
	}
	s.haScanGeofence(ctx)
	s.haScanAlerts(ctx)
	s.haScanCrashes(ctx)
	s.haScanTrips(ctx)
}

func (s *Server) haScanGeofence(ctx context.Context) {
	cur, err := s.haCursor(ctx, "geofence")
	if err != nil {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT ge.id::text, ge.user_id::text, ge.event_type, ge.ts, ge.place_id::text, COALESCE(p.name, '')
		FROM geofence_events ge JOIN places p ON p.id = ge.place_id
		WHERE ge.ts > $1 AND ge.place_id IS NOT NULL ORDER BY ge.ts LIMIT 500`, cur.Add(-haScanOverlap))
	if err != nil {
		haLogErr("scan geofence", err)
		return
	}
	type row struct {
		id, user, typ, place, name string
		ts                         time.Time
	}
	var rs []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.id, &r.user, &r.typ, &r.ts, &r.place, &r.name) == nil {
			rs = append(rs, r)
		}
	}
	rows.Close()
	var max time.Time
	for _, r := range rs {
		kind := "arrival"
		if r.typ == "exit" {
			kind = "departure"
		}
		s.haInsertEvent(ctx, kind, r.user, "geo:"+r.id, r.id, r.place, r.name, r.ts, nil)
		if r.ts.After(max) {
			max = r.ts
		}
	}
	if !max.IsZero() {
		s.haSetCursor(ctx, "geofence", max)
	}
}

func (s *Server) haScanAlerts(ctx context.Context) {
	cur, err := s.haCursor(ctx, "alerts")
	if err != nil {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id::text, user_id::text, created_at FROM alerts
		WHERE type = 'sos' AND created_at > $1 ORDER BY created_at LIMIT 200`, cur.Add(-haScanOverlap))
	if err != nil {
		haLogErr("scan alerts", err)
		return
	}
	type row struct {
		id, user string
		ts       time.Time
	}
	var rs []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.id, &r.user, &r.ts) == nil {
			rs = append(rs, r)
		}
	}
	rows.Close()
	var max time.Time
	for _, r := range rs {
		s.haInsertEvent(ctx, "sos", r.user, "sos:"+r.id, r.id, "", "", r.ts, nil)
		if r.ts.After(max) {
			max = r.ts
		}
	}
	if !max.IsZero() {
		s.haSetCursor(ctx, "alerts", max)
	}
}

func (s *Server) haScanCrashes(ctx context.Context) {
	var have bool
	if err := s.Pool.QueryRow(ctx, `SELECT to_regclass('crash_events') IS NOT NULL`).Scan(&have); err != nil || !have {
		return
	}
	cur, err := s.haCursor(ctx, "crash")
	if err != nil {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id::text, user_id::text, created_at, occurred_at, source FROM crash_events
		WHERE created_at > $1 ORDER BY created_at LIMIT 200`, cur.Add(-haScanOverlap))
	if err != nil {
		haLogErr("scan crashes", err)
		return
	}
	type row struct {
		id, user, src string
		created, at   time.Time
	}
	var rs []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.id, &r.user, &r.created, &r.at, &r.src) == nil {
			rs = append(rs, r)
		}
	}
	rows.Close()
	var max time.Time
	for _, r := range rs {
		s.haInsertEvent(ctx, "crash", r.user, "crash:"+r.id, r.id, "", "", r.at, map[string]any{"source": r.src})
		if r.created.After(max) {
			max = r.created
		}
	}
	if !max.IsZero() {
		s.haSetCursor(ctx, "crash", max)
	}
}

// haScanTrips announces drives some minutes after they ended. The trip worker
// segments history after the fact, so trip_start is delivered together with
// trip_end (occurred_at carries the real start time); it is not a live signal.
func (s *Server) haScanTrips(ctx context.Context) {
	// The "trips" cursor is only the moment listening began: drives that ended
	// before it are never announced.
	since, err := s.haCursor(ctx, "trips")
	if err != nil {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT t.id::text, t.user_id::text, t.started_at, t.ended_at, t.distance_m, t.max_speed_mps
		FROM trips t
		WHERE t.mode = 'driving' AND t.distance_m >= $1
		  AND t.ended_at > GREATEST($4::timestamptz, now() - $2::interval) AND t.ended_at <= now() - $3::interval
		  AND NOT EXISTS (SELECT 1 FROM ha_events e WHERE e.source_key = 'trip_end:' || t.id::text)
		ORDER BY t.ended_at LIMIT 100`,
		driveMinMeters, pgSeconds(haTripLookback), pgSeconds(haTripSettle), since.Add(-haScanOverlap))
	if err != nil {
		haLogErr("scan trips", err)
		return
	}
	type row struct {
		id, user   string
		start, end time.Time
		dist, maxv float64
	}
	var rs []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.id, &r.user, &r.start, &r.end, &r.dist, &r.maxv) == nil {
			rs = append(rs, r)
		}
	}
	rows.Close()
	for _, r := range rs {
		s.haInsertEvent(ctx, "trip_start", r.user, "trip_start:"+r.id, r.id, "", "", r.start, nil)
		s.haInsertEvent(ctx, "trip_end", r.user, "trip_end:"+r.id, r.id, "", "", r.end, map[string]any{
			"distance_m": r.dist, "duration_s": r.end.Sub(r.start).Seconds(), "max_speed_mps": r.maxv,
		})
	}
}

// ---- delivery -------------------------------------------------------------

func haBackoff(failures int) time.Duration {
	d := 30 * time.Second
	for i := 1; i < failures && d < 15*time.Minute; i++ {
		d *= 2
	}
	if d > 15*time.Minute {
		d = 15 * time.Minute
	}
	return d
}

// haDeliverAll pushes pending events to every configured webhook.
func (s *Server) haDeliverAll(ctx context.Context) {
	rows, err := s.Pool.Query(ctx, `SELECT `+haCols+` FROM ha_integrations
		WHERE revoked_at IS NULL AND webhook_url <> '' AND 'events' = ANY(scopes)
		  AND (webhook_next_attempt IS NULL OR webhook_next_attempt <= now())
		  AND webhook_cursor < COALESCE((SELECT max(id) FROM ha_events), 0)`)
	if err != nil {
		haLogErr("list targets", err)
		return
	}
	var targets []*haIntegration
	for rows.Next() {
		if i, err := scanHA(rows); err == nil {
			targets = append(targets, i)
		}
	}
	rows.Close()
	sem := make(chan struct{}, haParallel)
	var wg sync.WaitGroup
	for _, t := range targets {
		sem <- struct{}{}
		wg.Add(1)
		go func(t *haIntegration) {
			defer func() { <-sem; wg.Done() }()
			s.haDeliverPending(ctx, t)
		}(t)
	}
	wg.Wait()
}

func (s *Server) haWantsKind(i *haIntegration, kind string) bool {
	if len(i.WebhookEvents) == 0 {
		return true
	}
	for _, k := range i.WebhookEvents {
		if k == kind {
			return true
		}
	}
	return false
}

// haDeliverPending delivers in order. A failure keeps the cursor on the failed
// event and schedules a retry with exponential backoff (30 s .. 15 min); after
// haMaxAttempts consecutive failures that one event is dropped and recorded.
func (s *Server) haDeliverPending(ctx context.Context, integ *haIntegration) {
	evs, err := s.haLoadEvents(ctx, integ.WebhookCursor, haBatchPerTarget)
	if err != nil {
		haLogErr("load events", err)
		return
	}
	failures := integ.WebhookFailures
	allowPrivate := s.haEffectiveAllowPrivate(ctx, integ)
	for _, ev := range evs {
		if ctx.Err() != nil {
			return
		}
		advance := func() {
			_, _ = s.Pool.Exec(ctx, `UPDATE ha_integrations SET webhook_cursor = $2, webhook_failures = $3, webhook_next_attempt = NULL
				WHERE id = $1 AND revoked_at IS NULL AND webhook_cursor < $2`, integ.ID, ev.ID, failures)
		}
		if !s.haWantsKind(integ, ev.Kind) {
			advance()
			continue
		}
		payload, vis, err := s.haEventPayload(ctx, integ, ev)
		if err != nil {
			haLogErr("render event", err)
			return
		}
		if !vis {
			advance()
			continue
		}
		body, _ := json.Marshal(payload)
		sctx, cancel := context.WithTimeout(ctx, haWebhookTimeout+2*time.Second)
		code, class := haSend(sctx, integ.WebhookURL, integ.WebhookSecret, allowPrivate, ev.Kind, ev.ID, body)
		cancel()
		s.haRecordDelivery(ctx, integ.ID, ev.Kind, code, class)
		if class == "" {
			failures = 0
			advance()
			continue
		}
		failures++
		if failures >= haMaxAttempts {
			failures = 0 // give up on this event, keep the target alive
			advance()
			continue
		}
		_, _ = s.Pool.Exec(ctx, `UPDATE ha_integrations SET webhook_failures = $2, webhook_next_attempt = now() + $3::interval
			WHERE id = $1 AND revoked_at IS NULL`, integ.ID, failures, pgSeconds(haBackoff(failures)))
		return
	}
}

// RunHAIntegrations is the background loop: scan sources, deliver webhooks,
// prune the outbox. It stops with ctx.
func (s *Server) RunHAIntegrations(ctx context.Context) {
	t := time.NewTicker(haScanEvery)
	defer t.Stop()
	lastPrune := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		s.haScan(ctx)
		s.haDeliverAll(ctx)
		if time.Since(lastPrune) > time.Hour {
			lastPrune = time.Now()
			_, _ = s.Pool.Exec(ctx, `DELETE FROM ha_events WHERE created_at < now() - $1::interval`, pgSeconds(haOutboxKeep))
		}
	}
}
