package trips

import (
	"math"
	"math/rand"
	"testing"
	"time"
)

var t0 = time.Date(2026, 6, 1, 8, 0, 0, 0, time.UTC)

const baseLat, baseLon = 40.0, -75.0

// track builds synthetic fixes at a fixed sampling interval.
type track struct {
	t        time.Time
	x, y     float64 // meters east / north of base
	interval time.Duration
	reported bool // attach device speed
	acc      float64
	rng      *rand.Rand
	pts      []Point
}

func newTrack(reported bool) *track {
	return &track{t: t0, interval: 5 * time.Second, reported: reported, acc: 8, rng: rand.New(rand.NewSource(1))}
}

func (k *track) emit(speed float64) {
	lat := baseLat + k.y/111195
	lon := baseLon + k.x/(111195*math.Cos(baseLat*math.Pi/180))
	p := Point{TS: k.t, Lat: lat, Lon: lon, AccuracyM: k.acc, DeviceID: "dev1"}
	if k.reported {
		s := speed
		p.SpeedMps = &s
	}
	k.pts = append(k.pts, p)
}

// move heads north at speed m/s for d (first fix is emitted at the start).
func (k *track) move(d time.Duration, speed float64) *track {
	if len(k.pts) == 0 {
		k.emit(speed)
	}
	for el := time.Duration(0); el < d; el += k.interval {
		k.t = k.t.Add(k.interval)
		k.y += speed * k.interval.Seconds()
		k.emit(speed)
	}
	return k
}

// still stays in place with +-jitter meters of noise.
func (k *track) still(d time.Duration, jitter float64) *track {
	bx, by := k.x, k.y
	if len(k.pts) == 0 {
		k.emit(0)
	}
	for el := time.Duration(0); el < d; el += k.interval {
		k.t = k.t.Add(k.interval)
		k.x = bx + (k.rng.Float64()*2-1)*jitter
		k.y = by + (k.rng.Float64()*2-1)*jitter
		k.emit(0)
	}
	k.x, k.y = bx, by
	return k
}

func (k *track) skip(d time.Duration) *track { k.t = k.t.Add(d); return k }

func near(t *testing.T, name string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol {
		t.Errorf("%s = %.2f, want %.2f +- %.2f", name, got, want, tol)
	}
}

func TestHaversine(t *testing.T) {
	near(t, "1 deg lat", Haversine(0, 10, 1, 10), 111195, 100)
	if Haversine(40, -75, 40, -75) != 0 {
		t.Error("identical points must be 0")
	}
}

func TestDriveDeviceSpeed(t *testing.T) {
	k := newTrack(true).still(5*time.Minute, 6).move(10*time.Minute, 15).still(10*time.Minute, 6)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 {
		t.Fatalf("trips=%d %+v", len(r.Trips), r.Trips)
	}
	tr := r.Trips[0]
	if tr.Mode != ModeDriving || tr.SpeedSource != SourceDevice {
		t.Errorf("mode=%s source=%s", tr.Mode, tr.SpeedSource)
	}
	near(t, "distance", tr.DistanceM, 9000, 150)
	near(t, "max", tr.MaxSpeedMps, 15, 0.01)
	near(t, "avg", tr.AvgSpeedMps, 15, 0.5)
	near(t, "duration", tr.DurationS(), 600, 10)
	if tr.EndLat <= tr.StartLat || tr.PointCount < 100 {
		t.Errorf("start/end/points wrong: %+v", tr)
	}
	if len(r.Stops) != 2 {
		t.Fatalf("stops=%d %+v", len(r.Stops), r.Stops)
	}
	if r.Stops[0].Open || !r.Stops[1].Open {
		t.Errorf("open flags: %+v", r.Stops)
	}
	if !r.Stops[0].EndedAt.Equal(tr.StartedAt) || !r.Stops[1].StartedAt.Equal(tr.EndedAt) {
		t.Errorf("stops must bracket the trip")
	}
	if r.InProgress {
		t.Error("not in progress")
	}
}

func TestDriveDerivedSpeedFallback(t *testing.T) {
	k := newTrack(false).still(4*time.Minute, 5).move(8*time.Minute, 20).still(5*time.Minute, 5)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 {
		t.Fatalf("trips=%d", len(r.Trips))
	}
	tr := r.Trips[0]
	if tr.SpeedSource != SourceDerived || tr.Mode != ModeDriving {
		t.Errorf("source=%s mode=%s", tr.SpeedSource, tr.Mode)
	}
	near(t, "max (derived, includes jitter)", tr.MaxSpeedMps, 20, 1.5)
}

func TestWalk(t *testing.T) {
	k := newTrack(true).still(5*time.Minute, 5).move(10*time.Minute, 1.4).still(5*time.Minute, 5)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 || r.Trips[0].Mode != ModeWalking {
		t.Fatalf("%+v", r.Trips)
	}
	near(t, "distance", r.Trips[0].DistanceM, 840, 30)
}

func TestCyclingIsOther(t *testing.T) {
	k := newTrack(true).still(4*time.Minute, 4).move(10*time.Minute, 4.0).still(4*time.Minute, 4)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 || r.Trips[0].Mode != ModeOther {
		t.Fatalf("%+v", r.Trips)
	}
}

func TestStopAndGoTrafficIsOneTrip(t *testing.T) {
	k := newTrack(true).still(5*time.Minute, 5)
	for i := 0; i < 4; i++ {
		k.move(2*time.Minute, 11)
		k.still(100*time.Second, 5) // red light / queue, shorter than StopDuration
	}
	k.move(2*time.Minute, 11).still(6*time.Minute, 5)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 {
		t.Fatalf("trips=%d: %+v", len(r.Trips), r.Trips)
	}
	if r.Trips[0].Mode != ModeDriving {
		t.Errorf("mode=%s", r.Trips[0].Mode)
	}
	near(t, "distance", r.Trips[0].DistanceM, 5*120*11, 200)
	if len(r.Stops) != 2 {
		t.Errorf("only the start and end dwell are stops, got %d", len(r.Stops))
	}
}

func TestLongStopSplitsTrips(t *testing.T) {
	k := newTrack(true).still(4*time.Minute, 5).move(5*time.Minute, 14).still(10*time.Minute, 5).move(5*time.Minute, 14).still(4*time.Minute, 5)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 2 || len(r.Stops) != 3 {
		t.Fatalf("trips=%d stops=%d", len(r.Trips), len(r.Stops))
	}
	mid := r.Stops[1]
	near(t, "mid stop", mid.EndedAt.Sub(mid.StartedAt).Seconds(), 600, 15)
}

func TestJitterWhileStationaryMakesNoTrip(t *testing.T) {
	// An hour of 30 m scatter with 25 m reported accuracy, no device speed.
	k := newTrack(false)
	k.acc = 25
	k.still(60*time.Minute, 30)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 0 {
		t.Fatalf("jitter produced trips: %+v", r.Trips)
	}
	if len(r.Stops) != 1 || r.Stops[0].PointCount < 600 {
		t.Fatalf("expected one long stop, got %+v", r.Stops)
	}
}

func TestSinglePositionSpikeIsIgnored(t *testing.T) {
	k := newTrack(false).still(10*time.Minute, 4)
	i := len(k.pts) / 2
	k.pts[i].Lat += 0.0015 // ~167 m away for one fix only (still plausible speed)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 0 || len(r.Stops) != 1 {
		t.Fatalf("trips=%d stops=%d", len(r.Trips), len(r.Stops))
	}
}

func TestTeleportRejected(t *testing.T) {
	k := newTrack(false).still(2*time.Minute, 3).move(6*time.Minute, 15).still(4*time.Minute, 3)
	i := 40
	k.pts[i].Lat += 1.0 // 111 km in 5 s
	r := Segment(k.pts, DefaultParams())
	if r.Stats.Teleport != 1 {
		t.Errorf("teleport=%d", r.Stats.Teleport)
	}
	if len(r.Trips) != 1 {
		t.Fatalf("trips=%d", len(r.Trips))
	}
	if r.Trips[0].MaxSpeedMps > 20 {
		t.Errorf("teleport leaked into max speed: %v", r.Trips[0].MaxSpeedMps)
	}
}

func TestLowAccuracyFixesDropped(t *testing.T) {
	k := newTrack(false).still(10*time.Minute, 3)
	for i := 10; i < 30; i++ {
		k.pts[i].AccuracyM = 500
		k.pts[i].Lat += 0.01
	}
	r := Segment(k.pts, DefaultParams())
	if r.Stats.LowAccuracy != 20 || len(r.Trips) != 0 {
		t.Fatalf("lowacc=%d trips=%d", r.Stats.LowAccuracy, len(r.Trips))
	}
}

func TestGapSplitsTripAndIsNotBridged(t *testing.T) {
	k := newTrack(true).still(4*time.Minute, 4).move(5*time.Minute, 15).skip(15*time.Minute).move(5*time.Minute, 15).still(5*time.Minute, 4)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 2 {
		t.Fatalf("trips=%d %+v", len(r.Trips), r.Trips)
	}
	if r.Trips[1].StartedAt.Sub(r.Trips[0].EndedAt) < 15*time.Minute {
		t.Error("gap must not be bridged")
	}
	// the first trip carries no distance across the gap
	near(t, "trip1", r.Trips[0].DistanceM, 4500, 100)
}

func TestOutOfOrderAndDuplicatesRejected(t *testing.T) {
	k := newTrack(true).still(2*time.Minute, 3).move(5*time.Minute, 15).still(4*time.Minute, 3)
	pts := append([]Point{}, k.pts[:50]...)
	pts = append(pts, k.pts[49]) // duplicate ts
	pts = append(pts, k.pts[30]) // out of order
	pts = append(pts, k.pts[50:]...)
	r := Segment(pts, DefaultParams())
	if r.Stats.Duplicate != 1 || r.Stats.OutOfOrder != 1 {
		t.Errorf("dup=%d ooo=%d", r.Stats.Duplicate, r.Stats.OutOfOrder)
	}
	clean := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 || math.Abs(r.Trips[0].DistanceM-clean.Trips[0].DistanceM) > 1e-6 {
		t.Errorf("rejected points changed the result: %+v vs %+v", r.Trips, clean.Trips)
	}
}

func TestMixedModeSplitsLegs(t *testing.T) {
	k := newTrack(true).still(4*time.Minute, 3).move(6*time.Minute, 1.4).move(8*time.Minute, 14).still(5*time.Minute, 3)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 2 {
		t.Fatalf("legs=%d %+v", len(r.Trips), r.Trips)
	}
	if r.Trips[0].Mode != ModeWalking || r.Trips[1].Mode != ModeDriving {
		t.Errorf("modes %s,%s", r.Trips[0].Mode, r.Trips[1].Mode)
	}
	if !r.Trips[0].EndedAt.Equal(r.Trips[1].StartedAt) {
		t.Error("legs must be contiguous")
	}
}

func TestShortMovementDiscarded(t *testing.T) {
	// 60 m shuffle around the house: below min distance, stop continues.
	k := newTrack(true).still(5*time.Minute, 3).move(45*time.Second, 1.4).still(5*time.Minute, 3)
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 0 {
		t.Fatalf("trips=%+v", r.Trips)
	}
	if len(r.Stops) != 1 {
		t.Fatalf("stops=%d, want the dwell kept as one", len(r.Stops))
	}
}

func TestInProgressTripAndFinalize(t *testing.T) {
	k := newTrack(true).still(4*time.Minute, 3).move(5*time.Minute, 15)
	r := Segment(k.pts, DefaultParams())
	if !r.InProgress || len(r.Trips) != 0 {
		t.Fatalf("inprogress=%v trips=%d", r.InProgress, len(r.Trips))
	}
	if !r.SafeUntil.Equal(t0.Add(4*time.Minute+5*time.Second).Add(-5*time.Second)) && r.SafeUntil.After(t0.Add(5*time.Minute)) {
		t.Errorf("SafeUntil=%v should be the trip start", r.SafeUntil)
	}
	p := DefaultParams()
	p.FinalizeOpen = true
	r = Segment(k.pts, p)
	if r.InProgress || len(r.Trips) != 1 {
		t.Fatalf("finalize: %+v", r)
	}
}

func TestEmptyAndTiny(t *testing.T) {
	if r := Segment(nil, DefaultParams()); len(r.Trips) != 0 || len(r.Stops) != 0 {
		t.Error("nil input")
	}
	if r := Segment([]Point{{TS: t0, Lat: 40, Lon: -75}}, DefaultParams()); len(r.Trips) != 0 {
		t.Error("single point")
	}
}

func TestInvalidCoordinatesRejected(t *testing.T) {
	pts := []Point{{TS: t0, Lat: 0, Lon: 0}, {TS: t0.Add(time.Second), Lat: 95, Lon: 1}, {TS: t0.Add(2 * time.Second), Lat: 40, Lon: -75}}
	_, st := Clean(pts, DefaultParams())
	if st.InvalidPosition != 2 || st.Used != 1 {
		t.Errorf("%+v", st)
	}
}

func TestNegativeSpeedTreatedAsMissing(t *testing.T) {
	k := newTrack(false).still(4*time.Minute, 3).move(6*time.Minute, 15).still(4*time.Minute, 3)
	for i := range k.pts {
		neg := -1.0
		k.pts[i].SpeedMps = &neg
	}
	r := Segment(k.pts, DefaultParams())
	if len(r.Trips) != 1 || r.Trips[0].SpeedSource != SourceDerived {
		t.Fatalf("%+v", r.Trips)
	}
}

func TestCountSpeedEvents(t *testing.T) {
	// 120 s at 30 m/s, 60 s at 10, 120 s at 30 again => 2 events at 25 m/s.
	k := newTrack(true).move(120*time.Second, 30).move(60*time.Second, 10).move(120*time.Second, 30)
	if got := CountSpeedEvents(k.pts, 25, DefaultParams()); got != 2 {
		t.Errorf("events=%d, want 2", got)
	}
	// A brief dip (10 s) merges the two bursts into one event.
	k = newTrack(true).move(120*time.Second, 30).move(10*time.Second, 10).move(120*time.Second, 30)
	if got := CountSpeedEvents(k.pts, 25, DefaultParams()); got != 1 {
		t.Errorf("merged events=%d, want 1", got)
	}
	// One spiky fix is noise.
	k = newTrack(true).move(60*time.Second, 10)
	k.pts[6].SpeedMps = ptr(40)
	if got := CountSpeedEvents(k.pts, 25, DefaultParams()); got != 0 {
		t.Errorf("single spike counted: %d", got)
	}
}

func ptr(f float64) *float64 { return &f }
