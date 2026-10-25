package trips

import (
	"math"
	"sort"
	"time"
)

// stationaryJitterM bounds how large a step can be and still be discounted as
// jitter when the device reports a speed below MovingSpeedMps.
const stationaryJitterM = 20.0

type step struct {
	dist     float64 // meters credited to the trip (0 for stationary noise)
	dt       time.Duration
	speed    float64
	reported bool
	label    byte // 'D' fast, 'S' slow, '-' still
}

type run struct {
	a, b  int // step range [a,b)
	label byte
}

// buildLegs converts the points of one movement (first point = departure
// anchor, last = arrival anchor) into one or more trips, split where the speed
// profile changes between fast (driving-like) and slow (walking-like) for a
// sustained time. It returns nil when the movement is below the minimum trip
// distance/duration.
func buildLegs(pts []Point, p Params) []Trip {
	if len(pts) < 2 {
		return nil
	}
	steps := make([]step, len(pts)-1)
	var total float64
	for k := 1; k < len(pts); k++ {
		a, b := pts[k-1], pts[k]
		d := Haversine(a.Lat, a.Lon, b.Lat, b.Lon)
		sp, rep := stepSpeed(a, b, p)
		st := step{dist: d, dt: b.TS.Sub(a.TS), speed: sp, reported: rep, label: '-'}
		// Stationary noise adds no distance: tiny steps, and jitter-sized
		// steps while the device itself reports it is not moving.
		if d < p.NoiseStepM || (rep && sp < p.MovingSpeedMps && d < stationaryJitterM) {
			st.dist = 0
		}
		switch {
		case sp >= p.DriveSpeedMps:
			st.label = 'D'
		case sp >= p.MovingSpeedMps:
			st.label = 'S'
		}
		total += st.dist
		steps[k-1] = st
	}
	dur := pts[len(pts)-1].TS.Sub(pts[0].TS)
	if total < p.MinTripDistanceM || dur < p.MinTripDuration {
		return nil
	}

	// Runs of equal label; still steps inherit the running label.
	var runs []run
	cur := byte(0)
	for i, s := range steps {
		l := s.label
		if l == '-' {
			if cur == 0 {
				continue // leading still steps are attached below
			}
			l = cur
		}
		if l != cur {
			if len(runs) > 0 {
				runs[len(runs)-1].b = i
			}
			runs = append(runs, run{a: i, label: l})
			cur = l
		}
	}
	if len(runs) == 0 {
		runs = []run{{a: 0, b: len(steps), label: 'S'}}
	}
	runs[0].a = 0
	runs[len(runs)-1].b = len(steps)

	measure := func(r run) (time.Duration, float64) {
		var d time.Duration
		var m float64
		for _, s := range steps[r.a:r.b] {
			d += s.dt
			m += s.dist
		}
		return d, m
	}
	// Absorb legs that are too short into their neighbour, then coalesce.
	for changed := true; changed && len(runs) > 1; {
		changed = false
		for i, r := range runs {
			d, m := measure(r)
			if d >= p.MinLegDuration && m >= p.MinLegDistanceM {
				continue
			}
			if i == 0 {
				runs[1].a = r.a
				runs = runs[1:]
			} else {
				runs[i-1].b = r.b
				runs = append(runs[:i], runs[i+1:]...)
			}
			changed = true
			break
		}
		for i := 1; i < len(runs); {
			if runs[i].label == runs[i-1].label {
				runs[i-1].b = runs[i].b
				runs = append(runs[:i], runs[i+1:]...)
			} else {
				i++
			}
		}
	}

	out := make([]Trip, 0, len(runs))
	for _, r := range runs {
		out = append(out, makeTrip(pts[r.a:r.b+1], steps[r.a:r.b]))
	}
	return out
}

func makeTrip(pts []Point, steps []step) Trip {
	first, last := pts[0], pts[len(pts)-1]
	t := Trip{
		DeviceID: first.DeviceID, StartedAt: first.TS, EndedAt: last.TS,
		StartLat: first.Lat, StartLon: first.Lon, EndLat: last.Lat, EndLon: last.Lon,
		PointCount: len(pts),
	}
	var moving []float64
	rep, der := 0, 0
	for _, s := range steps {
		t.DistanceM += s.dist
		if s.speed > t.MaxSpeedMps {
			t.MaxSpeedMps = s.speed
		}
		if s.speed >= 0 && s.label != '-' {
			moving = append(moving, s.speed)
			if s.reported {
				rep++
			} else {
				der++
			}
		}
	}
	if d := t.DurationS(); d > 0 {
		t.AvgSpeedMps = t.DistanceM / d
	}
	switch {
	case rep > 0 && der > 0:
		t.SpeedSource = SourceMixed
	case rep > 0:
		t.SpeedSource = SourceDevice
	default:
		t.SpeedSource = SourceDerived
	}
	t.Mode = classify(moving)
	return t
}

func classify(moving []float64) string {
	if len(moving) == 0 {
		return ModeWalking
	}
	sort.Float64s(moving)
	p90 := moving[int(math.Ceil(0.9*float64(len(moving))))-1]
	switch {
	case p90 >= drivingP90Mps:
		return ModeDriving
	case p90 <= walkingP90Mps:
		return ModeWalking
	}
	return ModeOther
}

// CountSpeedEvents counts distinct episodes in which the estimated speed
// stayed above thresholdMps for at least two consecutive fixes (a lone
// over-threshold fix is treated as GPS noise). Episodes closer than
// minSeparation merge into one. Points are cleaned first.
func CountSpeedEvents(in []Point, thresholdMps float64, p Params) int {
	c, _ := Clean(in, p)
	const minSeparation = 30 * time.Second
	events := 0
	run := 0
	var runStart, prevEnd time.Time
	counted := false
	for k := 1; k < len(c); k++ {
		sp, _ := stepSpeed(c[k-1], c[k], p)
		if sp <= thresholdMps {
			if counted {
				prevEnd = c[k-1].TS
			}
			run, counted = 0, false
			continue
		}
		run++
		if run == 1 {
			runStart = c[k-1].TS
		}
		if run >= 2 && !counted {
			counted = true
			if events == 0 || runStart.Sub(prevEnd) >= minSeparation {
				events++
			}
		}
	}
	return events
}
