package trips

import (
	"testing"
	"time"
)

var evBase = time.Date(2026, 10, 20, 8, 0, 0, 0, time.UTC)

func testEP() EventParams {
	ep := DefaultEventParams()
	ep.SpeedingMps, ep.SpeedingSeconds, ep.HardBrakeMps2, ep.RapidAccelMps2 = 35.76, 30, 3.5, 3.5
	return ep
}

// track builds fixes every dt seconds driving north with the speed from f(t).
// Speed is reported (device GPS).
func evTrack(durS, dtS float64, f func(t float64) float64) []Point {
	var pts []Point
	lat := 40.0
	prev := 0.0
	for t := 0.0; t <= durS; t += dtS {
		v := f(t)
		if t > 0 {
			lat += (v + prev) / 2 * dtS / 111195
		}
		prev = v
		sp := v
		pts = append(pts, Point{TS: evBase.Add(time.Duration(t * float64(time.Second))), Lat: lat, Lon: -75, SpeedMps: &sp, AccuracyM: 5})
	}
	return pts
}

func kinds(ev []Event) map[string]int {
	m := map[string]int{}
	for _, e := range ev {
		m[e.Kind]++
	}
	return m
}

func TestCleanDriveHasNoEvents(t *testing.T) {
	pts := evTrack(300, 1, func(t float64) float64 { return 20 + 0.5*float64(int(t)%3) })
	if ev := DetectEvents(pts, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("events %+v", ev)
	}
}

func TestSpeedingEpisodes(t *testing.T) {
	// 40 s at 38 m/s counts; 20 s at 38 m/s does not.
	long := evTrack(120, 1, func(t float64) float64 {
		if t >= 30 && t <= 70 {
			return 38
		}
		return 25
	})
	ev := DetectEvents(long, testEP(), DefaultParams())
	if k := kinds(ev); k[EventSpeeding] != 1 {
		t.Fatalf("40 s: %+v", ev)
	}
	e := ev[0]
	if e.Magnitude != 38 || e.EndedAt.Sub(e.StartedAt) != 40*time.Second {
		t.Errorf("event %+v", e)
	}
	short := evTrack(120, 1, func(t float64) float64 {
		if t >= 30 && t <= 50 {
			return 38
		}
		return 25
	})
	if ev := DetectEvents(short, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("20 s counted: %+v", ev)
	}
}

func TestSpeedingTwoEpisodesAndMax(t *testing.T) {
	pts := evTrack(300, 2, func(t float64) float64 {
		switch {
		case t >= 20 && t <= 70:
			return 37 + (t-20)/50 // peaks at 38
		case t >= 150 && t <= 200:
			return 36.5
		}
		return 25
	})
	ev := DetectEvents(pts, testEP(), DefaultParams())
	if kinds(ev)[EventSpeeding] != 2 {
		t.Fatalf("%+v", ev)
	}
	for _, e := range ev {
		if e.Kind == EventSpeeding && e.StartedAt.Before(evBase.Add(100*time.Second)) && e.Magnitude < 37.9 {
			t.Errorf("max %v", e.Magnitude)
		}
	}
}

func TestSpeedingConfigurable(t *testing.T) {
	pts := evTrack(120, 1, func(t float64) float64 { return 30 })
	ep := testEP()
	ep.SpeedingMps, ep.SpeedingSeconds = 29, 60
	if ev := DetectEvents(pts, ep, DefaultParams()); len(ev) != 1 {
		t.Fatalf("%+v", ev)
	}
}

func TestSpeedingGapNotBridged(t *testing.T) {
	// Fast, then a 60 s hole, then fast: no single 30 s+ episode is fabricated
	// across the hole.
	a := evTrack(20, 1, func(float64) float64 { return 38 })
	b := evTrack(20, 1, func(float64) float64 { return 38 })
	for i := range b {
		b[i].TS = b[i].TS.Add(80 * time.Second)
		b[i].Lat += 0.01
	}
	if ev := DetectEvents(append(a, b...), testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestHardBrake(t *testing.T) {
	// 20 m/s to 0 at -6 m/s^2 starting at t=30.
	pts := evTrack(80, 1, func(t float64) float64 {
		switch {
		case t < 30:
			return 20
		case t < 30+20.0/6:
			return 20 - 6*(t-30)
		}
		return 0
	})
	ev := DetectEvents(pts, testEP(), DefaultParams())
	if k := kinds(ev); k[EventHardBrake] != 1 || len(ev) != 1 {
		t.Fatalf("%+v", ev)
	}
	if ev[0].Magnitude < 5 || ev[0].Magnitude > 7 {
		t.Errorf("magnitude %v", ev[0].Magnitude)
	}
}

func TestRapidAccel(t *testing.T) {
	// 0 to 20 m/s at +4 m/s^2 from t=10.
	pts := evTrack(60, 1, func(t float64) float64 {
		switch {
		case t < 10:
			return 0
		case t < 15:
			return 4 * (t - 10)
		}
		return 20
	})
	ev := DetectEvents(pts, testEP(), DefaultParams())
	if k := kinds(ev); k[EventRapidAccel] != 1 || len(ev) != 1 {
		t.Fatalf("%+v", ev)
	}
	// Starting-from-rest samples below 5 m/s are not counted but the episode
	// includes the later ones.
	if ev[0].Magnitude < 3.9 {
		t.Errorf("magnitude %v", ev[0].Magnitude)
	}
}

func TestGentleStopAndGoNoEvents(t *testing.T) {
	// Speed oscillates 0..10 m/s at 1 m/s^2.
	pts := evTrack(200, 1, func(t float64) float64 {
		ph := int(t) % 20
		if ph < 10 {
			return float64(ph)
		}
		return float64(20 - ph)
	})
	if ev := DetectEvents(pts, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestStopAndGoWithHardBrakeCounts(t *testing.T) {
	// cruising 12 m/s, brake hard to 0 (4 m/s^2), wait, gentle restart.
	pts := evTrack(60, 1, func(t float64) float64 {
		switch {
		case t < 10:
			return 12
		case t < 13:
			return 12 - 4*(t-10)
		case t < 25:
			return 0
		}
		return minf(12, (t-25)*1.0)
	})
	ev := DetectEvents(pts, testEP(), DefaultParams())
	if k := kinds(ev); k[EventHardBrake] != 1 || len(ev) != 1 {
		t.Fatalf("%+v", ev)
	}
}

func minf(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func TestGPSJitterSpikeIgnored(t *testing.T) {
	// Steady 15 m/s with one reported-speed spike to 40 and one dip to 0: those
	// deltas exceed the plausibility cap and must not become events.
	pts := evTrack(100, 1, func(float64) float64 { return 15 })
	spike, dip := 30, 60
	s, d := 40.0, 0.0
	pts[spike].SpeedMps, pts[dip].SpeedMps = &s, &d
	if ev := DetectEvents(pts, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestTenSecondGapFabricatesNothing(t *testing.T) {
	// 25 m/s then, after a 10 s hole, 5 m/s: an apparent -2 m/s^2 over 10 s is
	// not measurable (and even -4 over a gap must not count).
	a := evTrack(20, 1, func(float64) float64 { return 25 })
	b := evTrack(20, 1, func(float64) float64 { return 2 })
	for i := range b {
		b[i].TS = b[i].TS.Add(30 * time.Second) // 10 s after a's last fix
		b[i].Lat = a[len(a)-1].Lat + 0.0001 + float64(i)*0.00002
	}
	ev := DetectEvents(append(a, b...), testEP(), DefaultParams())
	for _, e := range ev {
		t.Errorf("fabricated %+v", e)
	}
}

func TestOutOfOrderAndDuplicatesIgnored(t *testing.T) {
	pts := evTrack(60, 1, func(float64) float64 { return 15 })
	// Insert an out-of-order stopped fix and a duplicate timestamp.
	z := 0.0
	bad := Point{TS: pts[20].TS.Add(-5 * time.Second), Lat: pts[20].Lat, Lon: -75, SpeedMps: &z, AccuracyM: 5}
	dup := pts[30]
	dup.SpeedMps = &z
	in := append([]Point{}, pts[:21]...)
	in = append(in, bad)
	in = append(in, pts[21:31]...)
	in = append(in, dup)
	in = append(in, pts[31:]...)
	if ev := DetectEvents(in, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestLowAccuracyFixesNotUsedForAccel(t *testing.T) {
	pts := evTrack(60, 1, func(t float64) float64 {
		if t < 30 {
			return 20
		}
		return 5
	})
	for i := range pts {
		pts[i].AccuracyM = 50 // above the 30 m accel limit, below the 100 m cleaning limit
	}
	if ev := DetectEvents(pts, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestDerivedSpeedFallback(t *testing.T) {
	pts := evTrack(80, 1, func(t float64) float64 {
		switch {
		case t < 30:
			return 20
		case t < 30+20.0/6:
			return 20 - 6*(t-30)
		}
		return 0
	})
	for i := range pts {
		pts[i].SpeedMps = nil
	}
	ev := DetectEvents(pts, testEP(), DefaultParams())
	if kinds(ev)[EventHardBrake] < 1 {
		t.Fatalf("derived speed missed the brake: %+v", ev)
	}
}

func TestSparseGPSUndercounts(t *testing.T) {
	// The same hard brake sampled every 10 s is invisible by design.
	pts := evTrack(100, 10, func(t float64) float64 {
		if t < 30 {
			return 20
		}
		return 0
	})
	if ev := DetectEvents(pts, testEP(), DefaultParams()); len(ev) != 0 {
		t.Fatalf("%+v", ev)
	}
}

func TestAttachEventsOnlyDriving(t *testing.T) {
	pts := evTrack(100, 1, func(t float64) float64 {
		switch {
		case t < 50:
			return 20
		case t < 53:
			return 20 - 6*(t-50)
		}
		return 2
	})
	trips := []Trip{
		{Mode: ModeDriving, StartedAt: pts[0].TS, EndedAt: pts[53].TS},
		{Mode: ModeWalking, StartedAt: pts[0].TS, EndedAt: pts[100].TS},
	}
	attachEvents(trips, pts, testEP(), DefaultParams())
	if len(trips[0].Events) != 1 || trips[0].Events[0].Kind != EventHardBrake {
		t.Errorf("driving: %+v", trips[0].Events)
	}
	if len(trips[1].Events) != 0 {
		t.Errorf("walking got events: %+v", trips[1].Events)
	}
}
