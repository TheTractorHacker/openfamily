package handlers

// Fixtures for the on-device report/weekly processors
// (docs/design/PROCESSING_ON_DEVICE.md). The pure Go functions
// (weeklySafetyScore, computeReportPeriod, weeklyDue) are called directly; the
// per-member aggregation lives in SQL on the server, so this file holds a
// straight Go transcription of those queries (weekStats, TripsReport,
// reportDays) to produce expected values for the shared JSON. Writes
// testdata/processing/weekly.json with UPDATE_PROCESSING_FIXTURES=1, otherwise
// verifies the committed file is current.

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

type pfScore struct {
	Drives    int     `json:"drives"`
	DistanceM float64 `json:"distance_m"`
	Hard      int     `json:"hard_brake"`
	Rapid     int     `json:"rapid_accel"`
	Speeding  int     `json:"speeding"`
	Phone     int     `json:"phone"`
	Score     *int    `json:"score"`
}

type pfPeriod struct {
	Period       string `json:"period"`
	Start        string `json:"start"`
	NowUS        int64  `json:"now_us"`
	OffsetMin    int    `json:"offset_min"`
	Error        string `json:"error,omitempty"`
	StartUS      int64  `json:"start_us"`
	EndUS        int64  `json:"end_us"`
	PrevStartUS  int64  `json:"prev_start_us"`
	PrevEndUS    int64  `json:"prev_end_us"`
	StartDay     string `json:"start_day"`
	EndDay       string `json:"end_day"`
	PrevStartDay string `json:"prev_start_day"`
	PrevEndDay   string `json:"prev_end_day"`
}

type pfDue struct {
	NowUS       int64 `json:"now_us"`
	WeekStartUS int64 `json:"week_start_us"`
	DueUS       int64 `json:"due_us"`
}

type pfTrip struct {
	ID          string  `json:"id"`
	StartedAt   string  `json:"started_at"`
	EndedAt     string  `json:"ended_at"`
	DistanceM   float64 `json:"distance_m"`
	MaxSpeedMps float64 `json:"max_speed_mps"`
	Mode        string  `json:"mode"`
}

type pfEvent struct {
	Kind      string `json:"kind"`
	StartedAt string `json:"started_at"`
}

type pfAgg struct {
	Name      string    `json:"name"`
	PhoneUse  bool      `json:"phone_use_enabled"`
	OffsetMin int       `json:"offset_min"`
	NowUS     int64     `json:"now_us"`
	Trips     []pfTrip  `json:"trips"`
	Events    []pfEvent `json:"events"`
	// expected
	Week struct {
		Current  weekStat `json:"current"`
		Previous weekStat `json:"previous"`
	} `json:"week"`
	Report struct {
		Drives         int         `json:"drives"`
		DistanceM      float64     `json:"distance_m"`
		TopSpeedMps    float64     `json:"top_speed_mps"`
		Events         eventCounts `json:"events"`
		PreviousEvents eventCounts `json:"previous_events"`
		PrevDrives     int         `json:"prev_drives"`
		PrevDistanceM  float64     `json:"prev_distance_m"`
		PrevTopSpeed   float64     `json:"prev_top_speed_mps"`
		Days           []reportDay `json:"days"`
		Recent         []struct {
			ID          string      `json:"id"`
			StartedAt   time.Time   `json:"started_at"`
			EndedAt     time.Time   `json:"ended_at"`
			DistanceM   float64     `json:"distance_m"`
			DurationS   float64     `json:"duration_s"`
			MaxSpeedMps float64     `json:"max_speed_mps"`
			Mode        string      `json:"mode"`
			EventCounts eventCounts `json:"event_counts"`
		} `json:"recent_trips"`
	} `json:"report"`
}

type pfFile struct {
	Comment string     `json:"comment"`
	Scores  []pfScore  `json:"scores"`
	Periods []pfPeriod `json:"periods"`
	Dues    []pfDue    `json:"dues"`
	Aggs    []pfAgg    `json:"aggregations"`
}

func inWin(t, from, to time.Time) bool { return !t.Before(from) && t.Before(to) }

func buildAgg(name string, seed int64, offset int, phone bool) pfAgg {
	rng := rand.New(rand.NewSource(seed))
	now := time.Date(2026, 11, 4, 15, 20, 0, 0, time.UTC) // Wednesday
	a := pfAgg{Name: name, PhoneUse: phone, OffsetMin: offset, NowUS: now.UnixMicro()}
	base := now.AddDate(0, 0, -16)
	kinds := []string{trips.EventSpeeding, trips.EventHardBrake, trips.EventRapidAccel, trips.EventPhoneUse}
	type tr struct {
		id         string
		s, e       time.Time
		dist, mx   float64
		mode       string
	}
	var all []tr
	for i := 0; i < 60; i++ {
		s := base.Add(time.Duration(rng.Int63n(int64(19 * 24 * time.Hour))))
		s = s.Truncate(time.Second)
		dur := time.Duration(120+rng.Intn(3000)) * time.Second
		mode := trips.ModeDriving
		switch rng.Intn(6) {
		case 0:
			mode = trips.ModeWalking
		case 1:
			mode = trips.ModeOther
		}
		all = append(all, tr{id: "t" + string(rune('A'+i/26)) + string(rune('a'+i%26)), s: s, e: s.Add(dur),
			dist: float64(int(rng.Float64() * 40000)), mx: float64(int(rng.Float64()*400)) / 10, mode: mode})
	}
	// Boundary cases: exactly at period starts (Monday 00:00 in the offset).
	per, _ := computeReportPeriod("week", "", now, offset)
	all = append(all,
		tr{"edge-start", per.start, per.start.Add(10 * time.Minute), 12000, 20, trips.ModeDriving},
		tr{"edge-end", per.end.Add(-time.Second), per.end.Add(20 * time.Minute), 5000, 30, trips.ModeDriving},
		tr{"edge-prev", per.prevStart, per.prevStart.Add(10 * time.Minute), 7000, 25, trips.ModeDriving})
	sort.Slice(all, func(i, j int) bool { return all[i].s.Before(all[j].s) })
	for _, t := range all {
		a.Trips = append(a.Trips, pfTrip{ID: t.id, StartedAt: t.s.UTC().Format(time.RFC3339Nano), EndedAt: t.e.UTC().Format(time.RFC3339Nano),
			DistanceM: t.dist, MaxSpeedMps: t.mx, Mode: t.mode})
		if t.mode == trips.ModeDriving {
			for k := rng.Intn(4); k > 0; k-- {
				ev := t.s.Add(time.Duration(rng.Int63n(int64(t.e.Sub(t.s)))))
				a.Events = append(a.Events, pfEvent{Kind: kinds[rng.Intn(len(kinds))], StartedAt: ev.Truncate(time.Second).Format(time.RFC3339Nano)})
			}
		}
	}

	parse := func(s string) time.Time { x, _ := time.Parse(time.RFC3339Nano, s); return x }
	stat := func(from, to time.Time) weekStat {
		var st weekStat
		for _, t := range a.Trips {
			s, e := parse(t.StartedAt), parse(t.EndedAt)
			if t.Mode == "driving" && inWin(s, from, to) {
				st.Drives++
				st.DistanceM += t.DistanceM
				st.DurationS += e.Sub(s).Seconds()
				if t.MaxSpeedMps > st.TopSpeedMps {
					st.TopSpeedMps = t.MaxSpeedMps
				}
			}
		}
		for _, ev := range a.Events {
			if inWin(parse(ev.StartedAt), from, to) {
				st.Events.add(ev.Kind, 1)
			}
		}
		st.finish(phone)
		return st
	}
	a.Week.Current = stat(per.start, per.end)
	a.Week.Previous = stat(per.prevStart, per.prevEnd)

	// TripsReport transcription.
	cur, prev := a.Week.Current, a.Week.Previous
	a.Report.Drives, a.Report.DistanceM, a.Report.TopSpeedMps = cur.Drives, cur.DistanceM, cur.TopSpeedMps
	a.Report.PrevDrives, a.Report.PrevDistanceM, a.Report.PrevTopSpeed = prev.Drives, prev.DistanceM, prev.TopSpeedMps
	a.Report.Events, a.Report.PreviousEvents = cur.Events, prev.Events
	loc := time.FixedZone("", offset*60)
	const dayFmt = "2006-01-02"
	a.Report.Days = []reportDay{}
	idx := map[string]int{}
	for d := per.start.In(loc); d.Before(per.end); d = d.AddDate(0, 0, 1) {
		idx[d.Format(dayFmt)] = len(a.Report.Days)
		a.Report.Days = append(a.Report.Days, reportDay{Date: d.Format(dayFmt)})
	}
	type rt = struct {
		ID          string      `json:"id"`
		StartedAt   time.Time   `json:"started_at"`
		EndedAt     time.Time   `json:"ended_at"`
		DistanceM   float64     `json:"distance_m"`
		DurationS   float64     `json:"duration_s"`
		MaxSpeedMps float64     `json:"max_speed_mps"`
		Mode        string      `json:"mode"`
		EventCounts eventCounts `json:"event_counts"`
	}
	var inPer []rt
	for _, t := range a.Trips {
		s, e := parse(t.StartedAt), parse(t.EndedAt)
		if t.Mode != "driving" || !inWin(s, per.start, per.end) {
			continue
		}
		if i, ok := idx[s.In(loc).Format(dayFmt)]; ok {
			d := &a.Report.Days[i]
			d.Drives++
			d.DistanceM += t.DistanceM
			if t.MaxSpeedMps > d.TopSpeedMps {
				d.TopSpeedMps = t.MaxSpeedMps
			}
		}
		inPer = append(inPer, rt{ID: t.ID, StartedAt: s, EndedAt: e, DistanceM: t.DistanceM, DurationS: e.Sub(s).Seconds(), MaxSpeedMps: t.MaxSpeedMps, Mode: t.Mode})
	}
	sort.SliceStable(inPer, func(i, j int) bool {
		if !inPer[i].StartedAt.Equal(inPer[j].StartedAt) {
			return inPer[i].StartedAt.After(inPer[j].StartedAt)
		}
		return inPer[i].ID > inPer[j].ID
	})
	if len(inPer) > recentTripsLimit {
		inPer = inPer[:recentTripsLimit]
	}
	for i := range inPer {
		for _, ev := range a.Events {
			es := parse(ev.StartedAt)
			if !es.Before(inPer[i].StartedAt) && !es.After(inPer[i].EndedAt) {
				inPer[i].EventCounts.add(ev.Kind, 1)
			}
		}
		inPer[i].EventCounts.finalizePhoneUse(phone)
	}
	a.Report.Recent = inPer
	a.Report.Events.finalizePhoneUse(phone)
	a.Report.PreviousEvents.finalizePhoneUse(phone)
	return a
}

func TestProcessingWeeklyFixtures(t *testing.T) {
	f := pfFile{Comment: "Generated by backend/internal/handlers/processing_fixtures_test.go (UPDATE_PROCESSING_FIXTURES=1). Do not edit by hand."}
	for _, c := range []pfScore{
		{Drives: 0}, {Drives: 3, DistanceM: 200000}, {Drives: 3, DistanceM: 100000, Hard: 2, Rapid: 1, Speeding: 1},
		{Drives: 1, DistanceM: 500, Hard: 50}, {Drives: 1, DistanceM: 100000, Phone: 2}, {Drives: 2, DistanceM: 1234, Hard: 1},
		{Drives: 5, DistanceM: 333333, Hard: 1, Rapid: 1, Speeding: 1}, {Drives: 4, DistanceM: 87000, Hard: 1},
		{Drives: 2, DistanceM: 30000, Speeding: 1}, {Drives: 2, DistanceM: 22500, Hard: 1},
	} {
		ev := eventCounts{HardBrake: c.Hard, RapidAccel: c.Rapid, Speeding: c.Speeding, phone: c.Phone}
		c.Score = weeklySafetyScore(c.Drives, c.DistanceM, ev)
		f.Scores = append(f.Scores, c)
	}
	now := time.Date(2026, 11, 4, 15, 20, 0, 0, time.UTC)
	for _, c := range []pfPeriod{
		{Period: "week", NowUS: now.UnixMicro()}, {Period: "week", NowUS: now.UnixMicro(), OffsetMin: 330},
		{Period: "week", NowUS: now.UnixMicro(), OffsetMin: -480}, {Period: "month", NowUS: now.UnixMicro()},
		{Period: "month", NowUS: now.UnixMicro(), OffsetMin: 840}, {Period: "week", Start: "2026-01-01", NowUS: now.UnixMicro()},
		{Period: "month", Start: "2026-03-31", NowUS: now.UnixMicro(), OffsetMin: -300}, {Period: "month", Start: "2026-01-15", NowUS: now.UnixMicro()},
		{Period: "week", Start: "2026-03-01", NowUS: now.UnixMicro()}, {Period: "week", NowUS: time.Date(2026, 11, 8, 23, 30, 0, 0, time.UTC).UnixMicro(), OffsetMin: 60},
		{Period: "week", NowUS: time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC).UnixMicro()}, {Period: "year", NowUS: now.UnixMicro()},
		{Period: "week", Start: "bad", NowUS: now.UnixMicro()},
	} {
		per, msg := computeReportPeriod(c.Period, c.Start, time.UnixMicro(c.NowUS).UTC(), c.OffsetMin)
		if msg != "" {
			c.Error = msg
		} else {
			c.StartUS, c.EndUS, c.PrevStartUS, c.PrevEndUS = per.start.UnixMicro(), per.end.UnixMicro(), per.prevStart.UnixMicro(), per.prevEnd.UnixMicro()
			c.StartDay, c.EndDay, c.PrevStartDay, c.PrevEndDay = per.startDay, per.endDay, per.prevStartDay, per.prevEndDay
		}
		f.Periods = append(f.Periods, c)
	}
	for _, n := range []time.Time{
		time.Date(2026, 11, 8, 17, 59, 59, 0, time.UTC), time.Date(2026, 11, 8, 18, 0, 0, 0, time.UTC),
		time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC),
		time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 3, 29, 3, 0, 0, 0, time.UTC),
	} {
		w, d := weeklyDue(n)
		f.Dues = append(f.Dues, pfDue{NowUS: n.UnixMicro(), WeekStartUS: w.UnixMicro(), DueUS: d.UnixMicro()})
	}
	f.Aggs = []pfAgg{buildAgg("utc_no_phone", 1, 0, false), buildAgg("ist_phone", 2, 330, true), buildAgg("pst_phone", 3, -480, true)}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", " ")
	if err := enc.Encode(f); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("..", "..", "..", "testdata", "processing", "weekly.json")
	if os.Getenv("UPDATE_PROCESSING_FIXTURES") == "1" {
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	old, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture missing: %v (UPDATE_PROCESSING_FIXTURES=1)", err)
	}
	if !bytes.Equal(old, buf.Bytes()) {
		t.Fatal("testdata/processing/weekly.json is stale; regenerate with UPDATE_PROCESSING_FIXTURES=1 and update the Dart port")
	}
}
