package handlers

import (
	"math"
	"net/http"
	"strconv"
)

// Server-side trail simplification so a map view never downloads more points
// than it can draw. Opt-in via ?simplify=<metres> and/or ?max_points=<n> on
// GET /family/members/{id}/history; without them the response is unchanged.
const (
	maxSimplifyMeters = 500.0
	minTrailMaxPoints = 10
)

// simplifyTrail returns a Douglas-Peucker simplification of trail with the
// given tolerance in metres. The first and last point are always kept and
// the order is preserved; every dropped point lies within epsilon of the
// simplified line (flat-earth approximation, fine at city scale).
func simplifyTrail(trail []trailPoint, epsilon float64) []trailPoint {
	n := len(trail)
	if n <= 2 || epsilon <= 0 {
		return trail
	}
	// Project to local metres around the first point.
	lat0 := trail[0].Lat * math.Pi / 180
	kx := earthRadiusMeters * math.Cos(lat0) * math.Pi / 180
	ky := earthRadiusMeters * math.Pi / 180
	xs := make([]float64, n)
	ys := make([]float64, n)
	for i, p := range trail {
		xs[i] = (p.Lon - trail[0].Lon) * kx
		ys[i] = (p.Lat - trail[0].Lat) * ky
	}
	keep := make([]bool, n)
	keep[0], keep[n-1] = true, true
	// Iterative DP with an explicit stack (a 1500 point trail is fine either
	// way, this keeps the worst case off the call stack).
	type seg struct{ a, b int }
	stack := []seg{{0, n - 1}}
	for len(stack) > 0 {
		s := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if s.b <= s.a+1 {
			continue
		}
		maxD, idx := 0.0, -1
		for i := s.a + 1; i < s.b; i++ {
			if d := pointSegDist(xs[i], ys[i], xs[s.a], ys[s.a], xs[s.b], ys[s.b]); d > maxD {
				maxD, idx = d, i
			}
		}
		if idx >= 0 && maxD > epsilon {
			keep[idx] = true
			stack = append(stack, seg{s.a, idx}, seg{idx, s.b})
		}
	}
	out := make([]trailPoint, 0, n)
	for i, k := range keep {
		if k {
			out = append(out, trail[i])
		}
	}
	return out
}

func pointSegDist(px, py, ax, ay, bx, by float64) float64 {
	dx, dy := bx-ax, by-ay
	l2 := dx*dx + dy*dy
	if l2 == 0 {
		return math.Hypot(px-ax, py-ay)
	}
	t := ((px-ax)*dx + (py-ay)*dy) / l2
	t = math.Max(0, math.Min(1, t))
	return math.Hypot(px-(ax+t*dx), py-(ay+t*dy))
}

// thinTrail bounds the trail to at most max points: it raises the
// Douglas-Peucker tolerance until the result fits, and as a last resort
// samples evenly. First and last points are always kept.
func thinTrail(trail []trailPoint, max int, epsilon float64) []trailPoint {
	out := simplifyTrail(trail, epsilon)
	if max <= 0 || len(out) <= max {
		return out
	}
	eps := math.Max(epsilon, 1)
	for i := 0; i < 20 && len(out) > max; i++ {
		eps *= 1.6
		out = simplifyTrail(trail, eps)
	}
	if len(out) <= max {
		return out
	}
	step := float64(len(out)-1) / float64(max-1)
	res := make([]trailPoint, 0, max)
	for i := 0; i < max-1; i++ {
		res = append(res, out[int(math.Round(float64(i)*step))])
	}
	return append(res, out[len(out)-1])
}

// applyTrailParams reads ?simplify= and ?max_points= and shapes the trail.
// ok=false means a malformed parameter (400).
func applyTrailParams(r *http.Request, trail []trailPoint) ([]trailPoint, bool) {
	q := r.URL.Query()
	eps, maxN := 0.0, 0
	if v := q.Get("simplify"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || math.IsNaN(f) || f < 0 || f > maxSimplifyMeters {
			return nil, false
		}
		eps = f
	}
	if v := q.Get("max_points"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < minTrailMaxPoints || n > trailPointCap {
			return nil, false
		}
		maxN = n
	}
	if eps == 0 && maxN == 0 {
		return trail, true
	}
	return thinTrail(trail, maxN, eps), true
}
