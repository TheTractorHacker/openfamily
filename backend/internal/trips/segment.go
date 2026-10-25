// Package trips turns an ordered series of GPS fixes into trips (movement
// between stops) and stops (stationary dwells), and persists them.
//
// Speed is a GPS ESTIMATE. When a fix carries a device-reported speed
// (Doppler / fused provider value) it is used as given and labelled
// SourceDevice; otherwise speed is derived from distance over time between
// consecutive accepted fixes and labelled SourceDerived. Neither is a
// calibrated measurement; do not use for enforcement.
package trips

import (
	"math"
	"sort"
	"time"
)

// AlgorithmVersion is stored with each trip so a future change of the
// thresholds can be recognised and recomputed.
const AlgorithmVersion = 1

// Modes assigned to a trip leg.
const (
	ModeDriving = "driving"
	ModeWalking = "walking"
	ModeOther   = "other" // between walking and driving: cycling, running, slow transit
)

// Speed sources, describing where the numbers of a trip came from.
const (
	SourceDevice  = "device_gps" // speed reported by the device GPS (an estimate)
	SourceDerived = "derived"    // haversine distance / elapsed time
	SourceMixed   = "mixed"
)

// Point is one location fix. SpeedMps is nil when the device did not report
// speed; negative values (the "unknown" sentinel on some platforms) are
// treated as missing. AccuracyM of 0 means unknown.
type Point struct {
	TS        time.Time
	Lat, Lon  float64
	SpeedMps  *float64
	AccuracyM float64
	DeviceID  string
}

// Params holds every threshold. DefaultParams documents the chosen values.
type Params struct {
	// MaxAccuracyM drops fixes whose reported accuracy radius is worse than
	// this. Unknown accuracy (0) is kept.
	MaxAccuracyM float64
	// MaxPlausibleSpeedMps rejects a fix whose implied speed from the last
	// accepted fix exceeds it (GPS teleport / drift). Also caps reported speed.
	MaxPlausibleSpeedMps float64
	// MovingSpeedMps is the minimum step speed counted as movement when
	// classifying legs and computing average moving speed.
	MovingSpeedMps float64
	// DriveSpeedMps separates "fast" steps from "slow" steps when splitting a
	// trip into legs of different mode.
	DriveSpeedMps float64
	// StopRadiusM: fixes within max(StopRadiusM, accuracy) of an anchor are
	// "the same place". Movement must leave this radius for two consecutive
	// fixes to start a trip, which rejects stationary jitter and lone spikes.
	StopRadiusM float64
	// StopDuration is how long the device must stay inside the stop radius for
	// a trip to end and a stop to exist.
	StopDuration time.Duration
	// MaxGap: consecutive fixes further apart than this end the trip (or
	// stop) rather than being bridged.
	MaxGap time.Duration
	// MinTripDistanceM / MinTripDuration discard movement shorter than this.
	MinTripDistanceM float64
	MinTripDuration  time.Duration
	// MinLegDuration / MinLegDistanceM: a mode change shorter than this is
	// absorbed into the neighbouring leg (e.g. a 40 s crawl in traffic).
	MinLegDuration  time.Duration
	MinLegDistanceM float64
	// NoiseStepM: steps shorter than this add no distance (stationary noise).
	NoiseStepM float64
	// FinalizeOpen closes a trip still in progress at the end of the input
	// instead of leaving it out as incomplete.
	FinalizeOpen bool
}

// DefaultParams returns the documented defaults.
func DefaultParams() Params {
	return Params{
		MaxAccuracyM:         100,
		MaxPlausibleSpeedMps: 90, // ~324 km/h
		MovingSpeedMps:       1.0,
		DriveSpeedMps:        4.5, // ~16 km/h
		StopRadiusM:          50,
		StopDuration:         3 * time.Minute,
		MaxGap:               10 * time.Minute,
		MinTripDistanceM:     250,
		MinTripDuration:      2 * time.Minute,
		MinLegDuration:       2 * time.Minute,
		MinLegDistanceM:      150,
		NoiseStepM:           5,
	}
}

// Mode classification (on the 90th percentile of moving step speeds).
const (
	drivingP90Mps = 5.5 // ~20 km/h
	walkingP90Mps = 2.5 // ~9 km/h; faster is "other" (running, cycling)
)

// Trip is one leg of movement between two stops (or mode changes).
type Trip struct {
	DeviceID    string    `json:"device_id,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	EndedAt     time.Time `json:"ended_at"`
	DistanceM   float64   `json:"distance_m"`
	MaxSpeedMps float64   `json:"max_speed_mps"`
	// AvgSpeedMps is DistanceM / duration, including in-trip pauses.
	AvgSpeedMps float64 `json:"avg_speed_mps"`
	Mode        string  `json:"mode"`
	SpeedSource string  `json:"speed_source"`
	StartLat    float64 `json:"start_lat"`
	StartLon    float64 `json:"start_lon"`
	EndLat      float64 `json:"end_lat"`
	EndLon      float64 `json:"end_lon"`
	PointCount  int     `json:"point_count"`
}

// DurationS is the trip duration in seconds.
func (t Trip) DurationS() float64 { return t.EndedAt.Sub(t.StartedAt).Seconds() }

// Stop is a stationary dwell of at least Params.StopDuration.
type Stop struct {
	StartedAt  time.Time `json:"started_at"`
	EndedAt    time.Time `json:"ended_at"`
	Lat        float64   `json:"lat"`
	Lon        float64   `json:"lon"`
	PointCount int       `json:"point_count"`
	// Open is true when the stop runs to the end of the input, so its true
	// end is unknown.
	Open bool `json:"open,omitempty"`
}

// Stats counts what Clean did with the input.
type Stats struct {
	Input           int
	Used            int
	OutOfOrder      int // timestamp earlier than the last accepted fix
	Duplicate       int // same timestamp as the last accepted fix
	LowAccuracy     int
	Teleport        int
	InvalidPosition int
}

// Result is the output of Segment.
type Result struct {
	Trips []Trip
	Stops []Stop
	Stats Stats
	// SafeUntil is the instant up to which the output is final: the start of
	// an in-progress trip, else the last accepted fix. A caller processing
	// incrementally resumes from here.
	SafeUntil time.Time
	// InProgress is true when the input ends mid-trip (and FinalizeOpen is false).
	InProgress bool
}

// stepSpeed returns the speed to use for the step ending at b, and whether it
// is device-reported.
func stepSpeed(a, b Point, p Params) (speed float64, reported bool) {
	if b.SpeedMps != nil && *b.SpeedMps >= 0 && !math.IsNaN(*b.SpeedMps) {
		return math.Min(*b.SpeedMps, p.MaxPlausibleSpeedMps), true
	}
	dt := b.TS.Sub(a.TS).Seconds()
	if dt <= 0 {
		return 0, false
	}
	return Haversine(a.Lat, a.Lon, b.Lat, b.Lon) / dt, false
}

// Clean filters the input into a strictly increasing, plausible series.
// Out-of-order and duplicate timestamps are REJECTED (never re-sorted):
// accepting a late fix would rewrite already-segmented history.
func Clean(in []Point, p Params) ([]Point, Stats) {
	st := Stats{Input: len(in)}
	out := make([]Point, 0, len(in))
	tele := 0
	for _, pt := range in {
		if math.IsNaN(pt.Lat) || math.IsNaN(pt.Lon) || pt.Lat < -90 || pt.Lat > 90 || pt.Lon < -180 || pt.Lon > 180 ||
			(pt.Lat == 0 && pt.Lon == 0) {
			st.InvalidPosition++
			continue
		}
		if p.MaxAccuracyM > 0 && pt.AccuracyM > p.MaxAccuracyM {
			st.LowAccuracy++
			continue
		}
		if n := len(out); n > 0 {
			last := out[n-1]
			if pt.TS.Equal(last.TS) {
				st.Duplicate++
				continue
			}
			if pt.TS.Before(last.TS) {
				st.OutOfOrder++
				continue
			}
			dt := pt.TS.Sub(last.TS)
			if dt <= p.MaxGap && p.MaxPlausibleSpeedMps > 0 {
				d := Haversine(last.Lat, last.Lon, pt.Lat, pt.Lon)
				if d/dt.Seconds() > p.MaxPlausibleSpeedMps {
					// Three consecutive "teleports" mean the anchor, not the
					// new fixes, was the outlier: re-anchor.
					tele++
					if tele < 3 {
						st.Teleport++
						continue
					}
				}
			}
		}
		tele = 0
		out = append(out, pt)
	}
	st.Used = len(out)
	return out, st
}

func radius(a, b Point, p Params) float64 {
	return math.Max(p.StopRadiusM, math.Max(a.AccuracyM, b.AccuracyM))
}

// Segment splits fixes into trips and stops using p. in need not be clean;
// see Clean for what is rejected.
func Segment(in []Point, p Params) Result {
	c, stats := Clean(in, p)
	res := Result{Stats: stats}
	n := len(c)
	if n == 0 {
		return res
	}
	res.SafeUntil = c[n-1].TS

	within := func(a, b int) bool {
		return Haversine(c[a].Lat, c[a].Lon, c[b].Lat, c[b].Lon) <= radius(c[a], c[b], p)
	}
	gap := func(i int) bool { return c[i].TS.Sub(c[i-1].TS) > p.MaxGap }

	emitStop := func(from, to int, open bool) {
		if to <= from || c[to].TS.Sub(c[from].TS) < p.StopDuration {
			return
		}
		var sl, so float64
		k := 0
		for x := from; x <= to; x++ {
			if within(from, x) {
				sl += c[x].Lat
				so += c[x].Lon
				k++
			}
		}
		res.Stops = append(res.Stops, Stop{
			StartedAt: c[from].TS, EndedAt: c[to].TS,
			Lat: sl / float64(k), Lon: so / float64(k),
			PointCount: to - from + 1, Open: open,
		})
	}

	anchor, stopFrom := 0, 0
	i := 1
	for i < n {
		if gap(i) {
			emitStop(stopFrom, i-1, false)
			anchor, stopFrom = i, i
			i++
			continue
		}
		if within(anchor, i) {
			i++
			continue
		}
		// Leaving the stop radius. Require the next fix to be outside too and
		// the implied speed to look like movement, so a lone spike or slow
		// drift does not start a trip.
		s := i - 1
		if i+1 >= n || gap(i+1) || within(anchor, i+1) {
			i++
			continue
		}
		dt := c[i+1].TS.Sub(c[s].TS).Seconds()
		if Haversine(c[s].Lat, c[s].Lon, c[i+1].Lat, c[i+1].Lon)/dt < p.MovingSpeedMps {
			i++
			continue
		}

		// The true departure is the last fix that still looks stationary;
		// walk back from the first fix outside the radius (at most to the
		// anchor) so slow walkers do not lose up to StopRadiusM at the start.
		for s-1 >= anchor {
			if sp, _ := stepSpeed(c[s-1], c[s], p); sp < p.MovingSpeedMps {
				break
			}
			s--
		}

		// Moving phase: ca is the latest "possible stop" anchor.
		ca := s
		end, resume := -1, n
		complete, gapEnded := false, false
		for j := s + 1; j < n; j++ {
			if gap(j) {
				end, resume, complete, gapEnded = j-1, j, true, true
				break
			}
			if within(ca, j) {
				if c[j].TS.Sub(c[ca].TS) >= p.StopDuration {
					// Arrival is the last fix that still looked like movement.
					end = ca
					for end+1 <= j {
						if sp, _ := stepSpeed(c[end], c[end+1], p); sp < p.MovingSpeedMps {
							break
						}
						end++
					}
					resume, complete = j+1, true
					break
				}
			} else {
				ca = j
			}
		}
		if end < 0 { // input ended mid-trip
			if p.FinalizeOpen {
				end, complete = ca, true
			} else {
				end = n - 1
				res.InProgress = true
				res.SafeUntil = c[s].TS
			}
		}

		legs := buildLegs(c[s:end+1], p)
		switch {
		case !complete:
			// Input ended mid-trip: only the stop before it is final.
			emitStop(stopFrom, s, false)
			return finish(res)
		case gapEnded:
			if legs != nil {
				emitStop(stopFrom, s, false)
				res.Trips = append(res.Trips, legs...)
			} else {
				emitStop(stopFrom, end, false)
			}
			anchor, stopFrom = resume, resume
			i = resume + 1
		default:
			if legs != nil {
				emitStop(stopFrom, s, false)
				res.Trips = append(res.Trips, legs...)
				stopFrom = end
			} // else: the movement was too small; the stop continues across it
			anchor = end
			i = resume
		}
	}
	// Trailing stationary period.
	emitStop(stopFrom, n-1, true)
	return finish(res)
}

func finish(res Result) Result {
	sort.SliceStable(res.Trips, func(a, b int) bool { return res.Trips[a].StartedAt.Before(res.Trips[b].StartedAt) })
	return res
}
