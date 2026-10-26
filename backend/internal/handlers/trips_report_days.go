package handlers

import (
	"context"
	"sort"
	"time"
)

// Additive parts of GET /trips/report: a zero-filled per-day breakdown of the
// selected period and the most recent drives, so the Driving tab needs one
// request. Both use the same visible-member ids as the rest of the report.

// reportDay is one local calendar day of the period.
type reportDay struct {
	Date        string  `json:"date"`
	Drives      int     `json:"drives"`
	DistanceM   float64 `json:"distance_m"`
	TopSpeedMps float64 `json:"top_speed_mps"`
}

// reportTrip is a drive in recent_trips.
type reportTrip struct {
	ID          string      `json:"id"`
	UserID      string      `json:"user_id"`
	Name        string      `json:"name"`
	StartedAt   time.Time   `json:"started_at"`
	EndedAt     time.Time   `json:"ended_at"`
	DistanceM   float64     `json:"distance_m"`
	DurationS   float64     `json:"duration_s"`
	MaxSpeedMps float64     `json:"max_speed_mps"`
	Mode        string      `json:"mode"`
	EventCounts eventCounts `json:"event_counts"`
}

const recentTripsLimit = 10

// reportDays loads the period's driving trips of ids and returns the per-day
// buckets (offsetMin applied, zero-filled) and up to recentTripsLimit trips,
// newest first. members supplies names and the phone sensor flag.
func (s *Server) reportDays(ctx context.Context, ids []string, per reportPeriod, offsetMin int, members map[string]*reportMember) ([]reportDay, []reportTrip, error) {
	loc := time.FixedZone("", offsetMin*60)
	const dayFmt = "2006-01-02"
	days := []reportDay{}
	idx := map[string]int{}
	for d := per.start.In(loc); d.Before(per.end); d = d.AddDate(0, 0, 1) {
		idx[d.Format(dayFmt)] = len(days)
		days = append(days, reportDay{Date: d.Format(dayFmt)})
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id::text, user_id::text, started_at, ended_at, COALESCE(distance_m, 0), COALESCE(max_speed_mps, 0), mode
		FROM trips
		WHERE user_id = ANY($1::uuid[]) AND mode = 'driving' AND started_at >= $2 AND started_at < $3
		ORDER BY started_at DESC, id DESC`, ids, per.start, per.end)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	recent := []reportTrip{}
	for rows.Next() {
		var t reportTrip
		if err := rows.Scan(&t.ID, &t.UserID, &t.StartedAt, &t.EndedAt, &t.DistanceM, &t.MaxSpeedMps, &t.Mode); err != nil {
			continue
		}
		m := members[t.UserID]
		if m == nil {
			continue
		}
		if i, ok := idx[t.StartedAt.In(loc).Format(dayFmt)]; ok {
			d := &days[i]
			d.Drives++
			d.DistanceM += t.DistanceM
			if t.MaxSpeedMps > d.TopSpeedMps {
				d.TopSpeedMps = t.MaxSpeedMps
			}
		}
		if len(recent) < recentTripsLimit {
			t.Name = m.Name
			t.DurationS = t.EndedAt.Sub(t.StartedAt).Seconds()
			recent = append(recent, t)
		}
	}
	rows.Close()
	if len(recent) == 0 {
		return days, recent, nil
	}
	tripIDs := make([]string, len(recent))
	pos := map[string]int{}
	for i, t := range recent {
		tripIDs[i] = t.ID
		pos[t.ID] = i
	}
	evRows, err := s.Pool.Query(ctx, `
		SELECT trip_id::text, kind, count(*) FROM trip_events_effective
		WHERE trip_id = ANY($1::uuid[]) GROUP BY 1, 2`, tripIDs)
	if err != nil {
		return nil, nil, err
	}
	defer evRows.Close()
	for evRows.Next() {
		var id, kind string
		var n int
		if err := evRows.Scan(&id, &kind, &n); err != nil {
			continue
		}
		if i, ok := pos[id]; ok {
			recent[i].EventCounts.add(kind, n)
		}
	}
	for i := range recent {
		recent[i].EventCounts.finalizePhoneUse(members[recent[i].UserID].sensor)
	}
	sort.SliceStable(recent, func(a, b int) bool { return recent[a].StartedAt.After(recent[b].StartedAt) })
	return days, recent, nil
}
