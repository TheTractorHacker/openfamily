package trips

import (
	"fmt"
	"math"
	"testing"
	"time"
)

// Synthetic days for the trips pipeline benchmarks. The shapes mirror what the
// phones send (see docs/live-tracking-client.md): 1 Hz fixes while driving,
// one fix per 5 s while walking, one jittery fix per minute while parked.
//
// Run:
//
//	go test ./internal/trips -run '^$' -bench . -benchmem -count 5
//
// Results are recorded in docs/design/OPTIMIZATION_ARCHITECTURE.md (section
// "Measured baselines"); re-run with -count 10 and benchstat before quoting a
// change.

func f64(v float64) *float64 { return &v }

// synthDay returns one device's fixes for a plausible day: parked overnight
// (60 s jitter fixes), a 30 min drive, 8 h parked at work, a 20 min walk, a
// 30 min drive home, parked again. 5,100 points.
func synthDay(start time.Time) []Point {
	var pts []Point
	t := start
	lat, lon := 52.5200, 13.4050
	parked := func(d time.Duration) {
		n := int(d / time.Minute)
		for i := 0; i < n; i++ {
			// 3-8 m of jitter, accuracy 10-30 m, speed reported as 0.
			j := float64(i%7) * 0.00001
			pts = append(pts, Point{TS: t, Lat: lat + j, Lon: lon - j, SpeedMps: f64(0), AccuracyM: 10 + float64(i%3)*10})
			t = t.Add(time.Minute)
		}
	}
	drive := func(d time.Duration, speed float64) {
		n := int(d / time.Second)
		for i := 0; i < n; i++ {
			// Speed varies with traffic lights: 0 for 20 s every 3 min.
			v := speed
			if i%180 < 20 {
				v = 0
			}
			lat += v / 111_000 // ~1 degree lat = 111 km
			pts = append(pts, Point{TS: t, Lat: lat, Lon: lon, SpeedMps: f64(v), AccuracyM: 5})
			t = t.Add(time.Second)
		}
	}
	walk := func(d time.Duration) {
		n := int(d / (5 * time.Second))
		for i := 0; i < n; i++ {
			lon += 1.4 * 5 / (111_000 * math.Cos(lat*math.Pi/180))
			pts = append(pts, Point{TS: t, Lat: lat, Lon: lon, SpeedMps: f64(1.4), AccuracyM: 8})
			t = t.Add(5 * time.Second)
		}
	}
	parked(7 * time.Hour)
	drive(30*time.Minute, 15)
	parked(8 * time.Hour)
	walk(20 * time.Minute)
	drive(30*time.Minute, 18)
	parked(6 * time.Hour)
	return pts
}

// synthDrive returns n points of continuous 1 Hz motorway driving: the
// worst case for a single ProcessUser pass (capped at 20,000 points).
func synthDrive(start time.Time, n int) []Point {
	pts := make([]Point, 0, n)
	lat, lon := 48.1351, 11.5820
	t := start
	for i := 0; i < n; i++ {
		v := 30.0 + 5*math.Sin(float64(i)/300)
		lat += v / 111_000
		pts = append(pts, Point{TS: t, Lat: lat, Lon: lon, SpeedMps: f64(v), AccuracyM: 4})
		t = t.Add(time.Second)
	}
	return pts
}

func BenchmarkSegmentDay(b *testing.B) {
	pts := synthDay(time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC))
	p := DefaultParams()
	p.FinalizeOpen = true
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := Segment(pts, p)
		if len(r.Trips) < 2 {
			b.Fatalf("expected at least 2 trips, got %d", len(r.Trips))
		}
	}
	b.ReportMetric(float64(len(pts)), "points")
}

func BenchmarkSegmentDrive20k(b *testing.B) {
	pts := synthDrive(time.Date(2026, 1, 5, 6, 0, 0, 0, time.UTC), 20_000)
	p := DefaultParams()
	p.FinalizeOpen = true
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = Segment(pts, p)
	}
	b.ReportMetric(float64(len(pts)), "points")
}

func BenchmarkDetectEventsDay(b *testing.B) {
	pts := synthDay(time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC))
	p := DefaultParams()
	ep := DefaultEventParams()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = DetectEvents(pts, ep, p)
	}
}

func BenchmarkCleanDay(b *testing.B) {
	pts := synthDay(time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC))
	p := DefaultParams()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = Clean(pts, p)
	}
}

// BenchmarkCountSpeedEventsPerTrip models the GET /trips/report N+1: the
// report re-reads and re-scans the raw points of every driving trip. One
// 30 min drive per iteration; multiply by trips in the period.
func BenchmarkCountSpeedEventsPerTrip(b *testing.B) {
	pts := synthDrive(time.Date(2026, 1, 5, 6, 0, 0, 0, time.UTC), 1_800)
	p := DefaultParams()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = CountSpeedEvents(pts, 25, p)
	}
}

// TestSynthDayShape pins the synthetic day so the benchmark input cannot
// silently drift (two drives, one walk, stops in between).
func TestSynthDayShape(t *testing.T) {
	pts := synthDay(time.Date(2026, 1, 5, 0, 0, 0, 0, time.UTC))
	p := DefaultParams()
	p.FinalizeOpen = true
	r := Segment(pts, p)
	var driving, walking int
	for _, tr := range r.Trips {
		switch tr.Mode {
		case "driving":
			driving++
		case "walking":
			walking++
		}
	}
	if driving != 2 || walking != 1 {
		var modes []string
		for _, tr := range r.Trips {
			modes = append(modes, fmt.Sprintf("%s %.0fm", tr.Mode, tr.DistanceM))
		}
		t.Fatalf("expected 2 driving + 1 walking trips, got %v", modes)
	}
}
