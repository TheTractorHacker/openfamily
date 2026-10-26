package trips

import (
	"math"
	"sort"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

// Event kinds. phone_use is reserved: the server cannot detect it from GPS, so
// it is never produced and reports show it as null (an on-device sensor is a
// later phase).
const (
	EventSpeeding   = "speeding"
	EventHardBrake  = "hard_brake"
	EventRapidAccel = "rapid_accel"
	EventPhoneUse   = "phone_use"
)

// Event is one driving risk event inside a driving trip.
//
// ACCURACY: events are ESTIMATES derived from GPS fixes. Acceleration is only
// computed between fixes at most MaxAccelGap apart, so sparse GPS (the app
// often reports every 10-60 s to save battery) UNDER-COUNTS braking and
// acceleration events, and a brief spike between fixes is invisible. GPS speed
// noise can also produce occasional false events. Do not use for enforcement.
// A motion sensor (accelerometer/gyroscope on the phone) is a later phase.
type Event struct {
	Kind      string    `json:"kind"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
	// Magnitude is the maximum speed in m/s for speeding and the peak
	// acceleration magnitude in m/s^2 for hard_brake / rapid_accel.
	Magnitude float64 `json:"magnitude"`
	Lat       float64 `json:"lat"`
	Lon       float64 `json:"lon"`
}

// EventParams holds the event thresholds. Brake and accel thresholds are
// positive magnitudes.
type EventParams struct {
	SpeedingMps     float64
	SpeedingSeconds float64
	HardBrakeMps2   float64
	RapidAccelMps2  float64
	// MaxAccelGap: acceleration is only computed between consecutive fixes at
	// most this far apart.
	MaxAccelGap time.Duration
	// MinAccelDt ignores intervals shorter than this (noise amplification).
	MinAccelDt time.Duration
	// MaxAccelAccuracyM: both fixes of an interval need accuracy at least this
	// good (unknown accuracy, 0, is accepted).
	MaxAccelAccuracyM float64
	// MinMovingMps: the vehicle must be above this speed before braking / after
	// accelerating, so a stop-and-go creep does not count.
	MinMovingMps float64
	// MaxPlausibleAccel: larger magnitudes are treated as a GPS jump and ignored.
	MaxPlausibleAccel float64
	// MaxSpeedingGap: over-limit fixes further apart than this are not one episode.
	MaxSpeedingGap time.Duration
}

// DefaultEventParams returns the defaults, with the four public thresholds
// taken from the environment (DRIVING_SPEEDING_MPS, DRIVING_SPEEDING_SECONDS,
// DRIVING_HARD_BRAKE_MPS2, DRIVING_RAPID_ACCEL_MPS2).
func DefaultEventParams() EventParams {
	return EventParams{
		SpeedingMps:       config.DrivingSpeedingMps(),
		SpeedingSeconds:   config.DrivingSpeedingSeconds(),
		HardBrakeMps2:     config.DrivingHardBrakeMps2(),
		RapidAccelMps2:    config.DrivingRapidAccelMps2(),
		MaxAccelGap:       4 * time.Second,
		MinAccelDt:        500 * time.Millisecond,
		MaxAccelAccuracyM: 30,
		MinMovingMps:      5,
		MaxPlausibleAccel: 12,
		MaxSpeedingGap:    15 * time.Second,
	}
}

// fixSpeed is the speed at fix i: device-reported if present, else distance /
// time from fix i-1 when they are within maxGap. ok is false when unknown.
func fixSpeed(c []Point, i int, ep EventParams, p Params) (float64, bool) {
	if v := c[i].SpeedMps; v != nil && *v >= 0 && !math.IsNaN(*v) {
		return math.Min(*v, p.MaxPlausibleSpeedMps), true
	}
	if i == 0 {
		return 0, false
	}
	dt := c[i].TS.Sub(c[i-1].TS)
	if dt <= 0 || dt > ep.MaxSpeedingGap {
		return 0, false
	}
	return Haversine(c[i-1].Lat, c[i-1].Lon, c[i].Lat, c[i].Lon) / dt.Seconds(), true
}

// DetectEvents finds speeding, hard braking and rapid acceleration in the
// fixes of ONE driving leg. in need not be clean (Clean drops out-of-order,
// duplicate, low-accuracy and teleporting fixes). Callers must only pass legs
// classified as driving. Results are ordered by start time.
func DetectEvents(in []Point, ep EventParams, p Params) []Event {
	c, _ := Clean(in, p)
	if len(c) < 2 {
		return nil
	}
	v := make([]float64, len(c))
	okv := make([]bool, len(c))
	for i := range c {
		v[i], okv[i] = fixSpeed(c, i, ep, p)
	}
	out := detectSpeeding(c, v, okv, ep)
	out = append(out, detectAccel(c, v, okv, ep)...)
	sort.SliceStable(out, func(a, b int) bool { return out[a].StartedAt.Before(out[b].StartedAt) })
	return out
}

// detectSpeeding emits one event per sustained episode of fixes above the
// limit lasting at least SpeedingSeconds (first to last over-limit fix).
func detectSpeeding(c []Point, v []float64, okv []bool, ep EventParams) []Event {
	if ep.SpeedingMps <= 0 {
		return nil
	}
	var out []Event
	first, last := -1, -1
	peak := 0
	flush := func() {
		if first < 0 {
			return
		}
		if c[last].TS.Sub(c[first].TS).Seconds() >= ep.SpeedingSeconds {
			out = append(out, Event{Kind: EventSpeeding, StartedAt: c[first].TS, EndedAt: c[last].TS,
				Magnitude: v[peak], Lat: c[peak].Lat, Lon: c[peak].Lon})
		}
		first, last = -1, -1
	}
	for i := range c {
		over := okv[i] && v[i] > ep.SpeedingMps
		if !over {
			flush()
			continue
		}
		if first >= 0 && c[i].TS.Sub(c[last].TS) > ep.MaxSpeedingGap {
			flush()
		}
		if first < 0 {
			first, peak = i, i
		}
		last = i
		if v[i] > v[peak] {
			peak = i
		}
	}
	flush()
	return out
}

// detectAccel emits hard_brake / rapid_accel episodes. An interval counts only
// when its two fixes are within MaxAccelGap, both accurate, both have a speed,
// and the implied acceleration is below MaxPlausibleAccel (else it is a GPS
// jump). Adjacent qualifying intervals of the same kind merge into one event.
func detectAccel(c []Point, v []float64, okv []bool, ep EventParams) []Event {
	var out []Event
	var cur *Event
	var curEnd int // index of the last fix of cur
	flush := func() {
		if cur != nil {
			out = append(out, *cur)
			cur = nil
		}
	}
	for i := 1; i < len(c); i++ {
		dt := c[i].TS.Sub(c[i-1].TS)
		valid := okv[i] && okv[i-1] && dt >= ep.MinAccelDt && dt <= ep.MaxAccelGap &&
			(ep.MaxAccelAccuracyM <= 0 || (c[i].AccuracyM <= ep.MaxAccelAccuracyM && c[i-1].AccuracyM <= ep.MaxAccelAccuracyM))
		kind := ""
		var mag float64
		if valid {
			a := (v[i] - v[i-1]) / dt.Seconds()
			switch {
			case math.Abs(a) > ep.MaxPlausibleAccel:
				// GPS jump: breaks any running episode.
			case a <= -ep.HardBrakeMps2 && v[i-1] >= ep.MinMovingMps:
				kind, mag = EventHardBrake, -a
			case a >= ep.RapidAccelMps2 && v[i] >= ep.MinMovingMps:
				kind, mag = EventRapidAccel, a
			}
		}
		if kind == "" {
			flush()
			continue
		}
		if cur != nil && (cur.Kind != kind || curEnd != i-1) {
			flush()
		}
		if cur == nil {
			cur = &Event{Kind: kind, StartedAt: c[i-1].TS, Magnitude: mag, Lat: c[i].Lat, Lon: c[i].Lon}
		} else if mag > cur.Magnitude {
			cur.Magnitude, cur.Lat, cur.Lon = mag, c[i].Lat, c[i].Lon
		}
		cur.EndedAt = c[i].TS
		curEnd = i
	}
	flush()
	return out
}

// attachEvents sets Events on every driving trip from the fixes in pts
// (ordered by time, may contain several devices).
func attachEvents(trips []Trip, pts []Point, ep EventParams, p Params) {
	if len(trips) == 0 {
		return
	}
	c, _ := Clean(pts, p)
	for k := range trips {
		t := &trips[k]
		t.Events = nil
		if t.Mode != ModeDriving {
			continue
		}
		lo := sort.Search(len(c), func(i int) bool { return !c[i].TS.Before(t.StartedAt) })
		hi := sort.Search(len(c), func(i int) bool { return c[i].TS.After(t.EndedAt) })
		t.Events = DetectEvents(c[lo:hi], ep, p)
	}
}
