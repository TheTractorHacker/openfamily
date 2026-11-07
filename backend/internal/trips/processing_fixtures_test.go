package trips

// Shared fixtures for the on-device processors (docs/design/PROCESSING_ON_DEVICE.md).
//
// This test runs the REAL Go algorithm (Segment + DetectEvents) over synthetic
// tracks and writes input+expected output to testdata/processing/segmentation.json
// at the repository root. The Dart tests (app/test/processing/) replay the same
// inputs and compare. Without UPDATE_PROCESSING_FIXTURES=1 this test only checks
// that the committed file still equals what the algorithm produces now, so an
// algorithm change cannot silently drift from the Dart port.

import (
	"bytes"
	"encoding/json"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type fxFix struct {
	TS       string   `json:"ts"`
	Lat      float64  `json:"lat"`
	Lon      float64  `json:"lon"`
	SpeedMps *float64 `json:"speed_mps"`
	Accuracy float64  `json:"accuracy_m"`
	Device   string   `json:"device_id"`
}

type fxTrip struct {
	Trip
	EventsOut []Event `json:"events"`
}

type fxCase struct {
	Name         string   `json:"name"`
	FinalizeOpen bool     `json:"finalize_open"`
	Fixes        []fxFix  `json:"fixes"`
	Trips        []fxTrip `json:"trips"`
	Stops        []Stop   `json:"stops"`
	Stats        struct {
		Input, Used, OutOfOrder, Duplicate, LowAccuracy, Teleport, InvalidPosition int
	} `json:"stats"`
	InProgress bool   `json:"in_progress"`
	SafeUntil  string `json:"safe_until"`
	// Standalone event detection over the whole input (a single "leg").
	DirectEvents []Event `json:"direct_events"`
}

type fxFile struct {
	Comment string `json:"comment"`
	Params  struct {
		Segment Params `json:"segment"`
		Events  struct {
			SpeedingMps, SpeedingSeconds, HardBrakeMps2, RapidAccelMps2 float64
		} `json:"events"`
	} `json:"-"`
	Cases []fxCase `json:"cases"`
}

// sb is a scenario builder: heading north (plus optional east drift), piecewise
// speed profiles, configurable sampling and speed reporting.
type sb struct {
	t        time.Time
	x, y     float64
	interval time.Duration
	reported bool
	acc      float64
	rng      *rand.Rand
	pts      []Point
	v        float64
}

func newSB(start time.Time, seed int64, reported bool, interval time.Duration) *sb {
	return &sb{t: start, interval: interval, reported: reported, acc: 8, rng: rand.New(rand.NewSource(seed))}
}

func (k *sb) emit(speed float64) {
	lat := 40.0 + k.y/111195
	lon := -75.0 + k.x/(111195*math.Cos(40.0*math.Pi/180))
	p := Point{TS: k.t, Lat: lat, Lon: lon, AccuracyM: k.acc, DeviceID: "dev1"}
	if k.reported {
		s := speed
		p.SpeedMps = &s
	}
	k.pts = append(k.pts, p)
}

// profile drives for dur with speed f(tSinceStart).
func (k *sb) profile(dur time.Duration, f func(t float64) float64) *sb {
	if len(k.pts) == 0 {
		k.emit(f(0))
	}
	for el := k.interval; el <= dur; el += k.interval {
		dt := k.interval.Seconds()
		v := f(el.Seconds())
		k.t = k.t.Add(k.interval)
		k.y += (v + k.v) / 2 * dt
		k.v = v
		k.emit(v)
	}
	return k
}

func (k *sb) cruise(dur time.Duration, v float64) *sb {
	return k.profile(dur, func(float64) float64 { return v })
}

func (k *sb) still(dur time.Duration, jitter float64) *sb {
	bx, by := k.x, k.y
	if len(k.pts) == 0 {
		k.emit(0)
	}
	for el := k.interval; el <= dur; el += k.interval {
		k.t = k.t.Add(k.interval)
		k.x = bx + (k.rng.Float64()*2-1)*jitter
		k.y = by + (k.rng.Float64()*2-1)*jitter
		k.emit(0)
	}
	k.x, k.y, k.v = bx, by, 0
	return k
}

func (k *sb) skip(d time.Duration) *sb { k.t = k.t.Add(d); return k }

func toFx(pts []Point) []fxFix {
	out := make([]fxFix, len(pts))
	for i, p := range pts {
		out[i] = fxFix{TS: p.TS.UTC().Format(time.RFC3339Nano), Lat: p.Lat, Lon: p.Lon, SpeedMps: p.SpeedMps, Accuracy: p.AccuracyM, Device: p.DeviceID}
	}
	return out
}

func fixtureEP() EventParams {
	ep := DefaultEventParams()
	ep.SpeedingMps, ep.SpeedingSeconds, ep.HardBrakeMps2, ep.RapidAccelMps2 = 35.76, 30, 3.5, 3.5
	return ep
}

func runCase(name string, pts []Point, finalize bool) fxCase {
	p := DefaultParams()
	p.FinalizeOpen = finalize
	ep := fixtureEP()
	r := Segment(pts, p)
	attachEvents(r.Trips, pts, ep, p)
	c := fxCase{Name: name, FinalizeOpen: finalize, Fixes: toFx(pts), Stops: r.Stops, InProgress: r.InProgress}
	c.Trips = []fxTrip{}
	for _, t := range r.Trips {
		ev := t.Events
		if ev == nil {
			ev = []Event{}
		}
		c.Trips = append(c.Trips, fxTrip{Trip: t, EventsOut: ev})
	}
	if c.Stops == nil {
		c.Stops = []Stop{}
	}
	c.Stats.Input, c.Stats.Used, c.Stats.OutOfOrder = r.Stats.Input, r.Stats.Used, r.Stats.OutOfOrder
	c.Stats.Duplicate, c.Stats.LowAccuracy, c.Stats.Teleport = r.Stats.Duplicate, r.Stats.LowAccuracy, r.Stats.Teleport
	c.Stats.InvalidPosition = r.Stats.InvalidPosition
	if !r.SafeUntil.IsZero() {
		c.SafeUntil = r.SafeUntil.UTC().Format(time.RFC3339Nano)
	}
	c.DirectEvents = DetectEvents(pts, ep, p)
	if c.DirectEvents == nil {
		c.DirectEvents = []Event{}
	}
	return c
}

func fixtureCases() []fxCase {
	d0 := time.Date(2026, 10, 19, 7, 30, 0, 0, time.UTC) // a Monday
	var cs []fxCase

	// A: commute with a hard brake, a rapid acceleration and a speeding episode.
	{
		k := newSB(d0, 1, true, time.Second).still(6*time.Minute, 6)
		k.profile(5*time.Minute, func(t float64) float64 { return math.Min(t/6*1.0, 1) * 20 })
		k.profile(40*time.Second, func(t float64) float64 { return 38 })           // speeding
		k.profile(10*time.Second, func(t float64) float64 { return 38 - t/10*18 }) // decel 2 m/s^2
		k.profile(2*time.Minute, func(t float64) float64 { return 20 })
		k.profile(4*time.Second, func(t float64) float64 { return 20 - t/4*13 }) // hard brake 3.25? make harder below
		k.profile(2*time.Minute, func(t float64) float64 { return 7 })
		k.profile(3*time.Second, func(t float64) float64 { return 7 + t/3*12 }) // rapid accel 4 m/s^2
		k.profile(2*time.Minute, func(t float64) float64 { return 19 })
		k.profile(5*time.Second, func(t float64) float64 { return 19 - t/5*19 }) // hard brake to stop
		k.still(8*time.Minute, 7)
		cs = append(cs, runCase("commute_events_reported_1hz", k.pts, false))
	}
	// B: derived speed (no device speed), 5 s sampling.
	{
		k := newSB(d0, 2, false, 5*time.Second).still(4*time.Minute, 5).cruise(8*time.Minute, 20).still(5*time.Minute, 5)
		cs = append(cs, runCase("drive_derived_5s", k.pts, false))
	}
	// C: walk with reported speed.
	{
		k := newSB(d0, 3, true, 5*time.Second).still(5*time.Minute, 5).cruise(10*time.Minute, 1.4).still(5*time.Minute, 5)
		cs = append(cs, runCase("walk_reported", k.pts, false))
	}
	// D: walk, drive, walk (leg split + other mode).
	{
		k := newSB(d0, 4, true, 3*time.Second).still(5*time.Minute, 4).cruise(6*time.Minute, 1.3).cruise(10*time.Minute, 16).cruise(6*time.Minute, 1.3).still(5*time.Minute, 4)
		cs = append(cs, runCase("walk_drive_walk", k.pts, false))
	}
	// E: noisy input: teleports, duplicates, out of order, low accuracy, zero position.
	{
		k := newSB(d0, 5, true, 2*time.Second).still(5*time.Minute, 5).cruise(8*time.Minute, 18).still(6*time.Minute, 5)
		pts := append([]Point(nil), k.pts...)
		var noisy []Point
		for i, p := range pts {
			noisy = append(noisy, p)
			switch {
			case i%97 == 50:
				q := p
				q.TS = p.TS.Add(time.Second)
				q.Lat += 0.5 // teleport
				noisy = append(noisy, q)
			case i%131 == 60:
				noisy = append(noisy, p) // duplicate timestamp
			case i%151 == 70:
				q := p
				q.TS = p.TS.Add(-30 * time.Second) // out of order
				noisy = append(noisy, q)
			case i%173 == 80:
				q := p
				q.TS = p.TS.Add(time.Second)
				q.AccuracyM = 250
				noisy = append(noisy, q)
			case i%211 == 90:
				q := p
				q.TS = p.TS.Add(time.Second)
				q.Lat, q.Lon = 0, 0
				noisy = append(noisy, q)
			}
		}
		cs = append(cs, runCase("noisy_input", noisy, false))
	}
	// F: gap in the middle of a drive.
	{
		k := newSB(d0, 6, true, 5*time.Second).still(5*time.Minute, 5).cruise(5*time.Minute, 15).skip(15 * time.Minute).cruise(5*time.Minute, 15).still(5*time.Minute, 5)
		cs = append(cs, runCase("gap_mid_drive", k.pts, false))
	}
	// G: input ends mid-trip, both finalize modes.
	{
		k := newSB(d0, 7, true, 5*time.Second).still(5*time.Minute, 5).cruise(6*time.Minute, 15)
		cs = append(cs, runCase("in_progress", k.pts, false))
		cs = append(cs, runCase("in_progress_finalize", k.pts, true))
	}
	// H: two drives in a day, plus a short pause inside the second.
	{
		k := newSB(d0, 8, true, 4*time.Second).still(10*time.Minute, 5).cruise(9*time.Minute, 14).still(15*time.Minute, 5).
			cruise(4*time.Minute, 22).still(90*time.Second, 3).cruise(5*time.Minute, 22).still(10*time.Minute, 5)
		cs = append(cs, runCase("two_drives_pause", k.pts, false))
	}
	// I: stop and go traffic with a hard brake.
	{
		k := newSB(d0, 9, true, time.Second).still(5*time.Minute, 4)
		for i := 0; i < 6; i++ {
			k.profile(20*time.Second, func(t float64) float64 { return math.Min(t/8*12, 12) })
			k.profile(2*time.Second, func(t float64) float64 { return 12 - t/2*12 })
			k.still(25*time.Second, 1)
		}
		k.cruise(2*time.Minute, 15).still(6*time.Minute, 4)
		cs = append(cs, runCase("stop_and_go", k.pts, false))
	}
	// J: long stationary night with jitter (only a stop).
	{
		k := newSB(d0, 10, false, 30*time.Second).still(12*time.Hour, 15)
		cs = append(cs, runCase("long_stop_12h", k.pts, false))
	}
	// K: slow drift while stationary (must not start a trip) then a real drive.
	{
		k := newSB(d0, 11, false, 10*time.Second).still(20*time.Minute, 20).cruise(8*time.Minute, 12).still(6*time.Minute, 6)
		cs = append(cs, runCase("jitter_then_drive_derived", k.pts, false))
	}
	// L: sparse GPS (30 s) drive.
	{
		k := newSB(d0, 12, true, 30*time.Second).still(10*time.Minute, 6).cruise(20*time.Minute, 25).still(10*time.Minute, 6)
		cs = append(cs, runCase("sparse_30s", k.pts, false))
	}
	return cs
}

func fixturePath() string {
	return filepath.Join("..", "..", "..", "testdata", "processing", "segmentation.json")
}

func TestProcessingFixtures(t *testing.T) {
	f := fxFile{Comment: "Generated by backend/internal/trips/processing_fixtures_test.go (UPDATE_PROCESSING_FIXTURES=1). Do not edit by hand.", Cases: fixtureCases()}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", " ")
	if err := enc.Encode(f); err != nil {
		t.Fatal(err)
	}
	// Sanity: the scenarios must exercise what they claim.
	var anyEv bool
	for _, c := range f.Cases {
		for _, tr := range c.Trips {
			if len(tr.EventsOut) > 0 {
				anyEv = true
			}
		}
	}
	if !anyEv {
		t.Fatal("no scenario produced driving events")
	}
	if os.Getenv("UPDATE_PROCESSING_FIXTURES") == "1" {
		if err := os.WriteFile(fixturePath(), buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	old, err := os.ReadFile(fixturePath())
	if err != nil {
		t.Fatalf("fixture missing: %v (run with UPDATE_PROCESSING_FIXTURES=1)", err)
	}
	if !bytes.Equal(old, buf.Bytes()) {
		t.Fatal("testdata/processing/segmentation.json is stale: the Go algorithm output changed. Regenerate with UPDATE_PROCESSING_FIXTURES=1 and update the Dart port")
	}
}
