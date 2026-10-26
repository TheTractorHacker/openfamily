package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type daysResp struct {
	Days []struct {
		Date        string  `json:"date"`
		Drives      int     `json:"drives"`
		DistanceM   float64 `json:"distance_m"`
		TopSpeedMps float64 `json:"top_speed_mps"`
	} `json:"days"`
	Recent []struct {
		ID          string    `json:"id"`
		UserID      string    `json:"user_id"`
		Name        string    `json:"name"`
		StartedAt   time.Time `json:"started_at"`
		DistanceM   float64   `json:"distance_m"`
		DurationS   float64   `json:"duration_s"`
		MaxSpeedMps float64   `json:"max_speed_mps"`
		Mode        string    `json:"mode"`
		EventCounts struct {
			Speeding  int  `json:"speeding"`
			HardBrake int  `json:"hard_brake"`
			PhoneUse  *int `json:"phone_use"`
		} `json:"event_counts"`
	} `json:"recent_trips"`
}

func (e *tripEnv) days(as, query string) (daysResp, string) {
	w := httptest.NewRecorder()
	reportRouter(e.srv, as).ServeHTTP(w, httptest.NewRequest("GET", "/trips/report"+query, nil))
	var d daysResp
	_ = json.Unmarshal(w.Body.Bytes(), &d)
	return d, w.Body.String()
}

func (e *tripEnv) insertTrip(u, fam string, at time.Time, dist, top float64, mode string) string {
	var id string
	e.must(e.pool.QueryRow(context.Background(), `INSERT INTO trips (user_id, family_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
		start_lat,start_lon,end_lat,end_lon,point_count) VALUES ($1,$2,$3,$4,$5,$6,10,$7,'device_gps',40,-75,40.1,-75,10) RETURNING id::text`,
		u, fam, at, at.Add(10*time.Minute), dist, top, mode).Scan(&id))
	return id
}

func TestReportDaysAndRecentTrips(t *testing.T) {
	e := setupTripEnv(t)
	ctx := context.Background()
	u := e.user("daysu", e.famA)
	t.Cleanup(func() { e.pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, u) })
	now := time.Now().UTC()
	mon := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	mon = mon.AddDate(0, 0, -((int(mon.Weekday())+6)%7)-14) // Monday two weeks ago
	day := mon.Format("2006-01-02")

	t1 := e.insertTrip(u, e.famA, mon.Add(30*time.Minute), 1000, 20, "driving")
	e.insertTrip(u, e.famA, mon.Add(23*time.Hour+30*time.Minute), 2000, 30, "driving")
	e.insertTrip(u, e.famA, mon.Add(2*24*time.Hour+time.Hour), 500, 10, "walking") // not a drive
	for _, k := range []string{"speeding", "hard_brake", "hard_brake"} {
		_, err := e.pool.Exec(ctx, `INSERT INTO trip_events (trip_id,user_id,kind,started_at,ended_at,magnitude,lat,lon) VALUES ($1,$2,$3,$4,$4,4,40,-75)`,
			t1, u, k, mon.Add(31*time.Minute))
		e.must(err)
	}

	d, raw := e.days(e.a2, "?start="+day+"&circle_id="+e.famA)
	if len(d.Days) != 7 || d.Days[0].Date != day || d.Days[6].Date != mon.AddDate(0, 0, 6).Format("2006-01-02") {
		t.Fatalf("days %+v", d.Days)
	}
	if d.Days[0].Drives != 2 || d.Days[0].DistanceM != 3000 || d.Days[0].TopSpeedMps != 30 || d.Days[1].Drives != 0 || d.Days[2].Drives != 0 {
		t.Errorf("day buckets %+v", d.Days)
	}
	if len(d.Recent) != 2 || d.Recent[0].DistanceM != 2000 || d.Recent[1].ID != t1 || d.Recent[1].Name != "daysu" ||
		d.Recent[1].DurationS != 600 || d.Recent[1].Mode != "driving" || d.Recent[1].MaxSpeedMps != 20 {
		t.Fatalf("recent %+v", d.Recent)
	}
	if ec := d.Recent[1].EventCounts; ec.Speeding != 1 || ec.HardBrake != 2 || ec.PhoneUse != nil {
		t.Errorf("event counts %+v", ec)
	}
	if !strings.Contains(raw, `"phone_use":null`) {
		t.Errorf("phone_use not null: %s", raw)
	}

	// UTC+1: the 00:30 UTC drive is 01:30 Monday, the 23:30 UTC drive is Tuesday.
	d, _ = e.days(e.a2, "?utc_offset_minutes=60&start="+day+"&circle_id="+e.famA)
	if d.Days[0].Drives != 1 || d.Days[1].Drives != 1 || d.Days[1].DistanceM != 2000 {
		t.Errorf("+60 buckets %+v", d.Days[:3])
	}
	// UTC-1: the 00:30 UTC drive is Sunday 23:30 of the previous week, so it
	// leaves this week; the 23:30 UTC drive is 22:30 Monday.
	d, _ = e.days(e.a2, "?utc_offset_minutes=-60&start="+day+"&circle_id="+e.famA)
	if d.Days[0].Drives != 1 || d.Days[0].DistanceM != 2000 || len(d.Recent) != 1 {
		t.Errorf("-60 buckets %+v recent %d", d.Days[:2], len(d.Recent))
	}

	// Phone sensor members get a number.
	_, err := e.pool.Exec(ctx, `UPDATE users SET driving_sensor_enabled=true, driving_phone_use_enabled=true WHERE id=$1`, u)
	e.must(err)
	d, _ = e.days(e.a2, "?start="+day+"&circle_id="+e.famA)
	if d.Recent[1].EventCounts.PhoneUse == nil || *d.Recent[1].EventCounts.PhoneUse != 0 {
		t.Errorf("sensor phone_use %+v", d.Recent[1].EventCounts)
	}

	// Month: one bucket per local day, zero-filled.
	d, _ = e.days(e.a2, "?period=month&start="+day+"&circle_id="+e.famA)
	first := time.Date(mon.Year(), mon.Month(), 1, 0, 0, 0, 0, time.UTC)
	if want := first.AddDate(0, 1, 0).Sub(first) / (24 * time.Hour); len(d.Days) != int(want) || d.Days[0].Date != first.Format("2006-01-02") {
		t.Errorf("month days %d", len(d.Days))
	}

	// More than ten drives: only the ten newest, newest first.
	for i := 0; i < 12; i++ {
		e.insertTrip(u, e.famA, mon.Add(3*24*time.Hour+time.Duration(i)*time.Hour), float64(100+i), 5, "driving")
	}
	d, _ = e.days(e.a2, "?start="+day+"&circle_id="+e.famA)
	if len(d.Recent) != 10 || d.Days[3].Drives != 12 {
		t.Fatalf("limit: recent=%d day3=%d", len(d.Recent), d.Days[3].Drives)
	}
	for i := 1; i < len(d.Recent); i++ {
		if d.Recent[i].StartedAt.After(d.Recent[i-1].StartedAt) {
			t.Errorf("not newest first at %d", i)
		}
	}
	if d.Recent[0].DistanceM != 111 {
		t.Errorf("newest %v", d.Recent[0].DistanceM)
	}

	// Outsiders get 404; sharing off hides the member from days and recent.
	w := httptest.NewRecorder()
	reportRouter(e.srv, e.b1).ServeHTTP(w, httptest.NewRequest("GET", "/trips/report?circle_id="+e.famA, nil))
	if w.Code != 404 {
		t.Errorf("outsider %d", w.Code)
	}
	_, err = e.pool.Exec(ctx, `UPDATE circle_members SET sharing_enabled=false WHERE circle_id=$1 AND user_id=$2`, e.famA, u)
	e.must(err)
	d, raw = e.days(e.a2, "?start="+day+"&circle_id="+e.famA)
	if len(d.Recent) != 0 || len(d.Days) != 7 || d.Days[0].Drives != 0 || d.Days[3].Drives != 0 || !strings.Contains(raw, `"recent_trips":[]`) {
		t.Errorf("sharing off leaks: %s", raw)
	}
	// ...but they still see their own drives.
	d, _ = e.days(u, "?start="+day)
	if len(d.Recent) != 10 || d.Days[0].Drives != 2 {
		t.Errorf("own view %d %+v", len(d.Recent), d.Days[0])
	}
	_ = fmt.Sprint
}
