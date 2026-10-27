package handlers

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	maxHistoryRange    = 25 * time.Hour
	trailBucket        = 30 * time.Second
	trailPointCap      = 1500
	stayDistanceMeters = 100.0
	stayMinDuration    = 5 * time.Minute
	placeMinDuration   = 3 * time.Minute
	samePlaceMergeGap  = 5 * time.Minute
	earthRadiusMeters  = 6371000.0

	// Fixes reporting accuracy worse than this many meters (the device's
	// 68%-confidence radius) are dropped before the trail and visit
	// computation. Indoor WiFi/cell fixes routinely wander hundreds of
	// meters while the device is stationary, and drawing / clustering them
	// verbatim made a member at home all day look like they were moving.
	// 0 (unknown) is kept so devices that don't report accuracy still work.
	historyMaxAccuracyMeters = 100.0

	// A stay tolerates jitter: consecutive fixes outside a place radius (or
	// the stay-point distance) don't break the stay while the excursion
	// lasts at most this long, so one drifting fix can't split a visit into
	// place → transit → place. A real departure outlasts the window and
	// re-anchors at the first missed fix, so trips are not truncated.
	stayBreakTolerance = 3 * time.Minute
)

// trailPoint is one downsampled GPS sample on the day's path.
type trailPoint struct {
	Lat         float64   `json:"lat"`
	Lon         float64   `json:"lon"`
	TS          time.Time `json:"ts"`
	MotionState string    `json:"motion_state,omitempty"`
	// SpeedMPS and BatteryPct are the device-reported values of the last fix
	// in the bucket that carried them; omitted when unknown.
	SpeedMPS   *float64 `json:"speed_mps,omitempty"`
	BatteryPct *float64 `json:"battery_pct,omitempty"`
}

// historyVisit is a place stay, unnamed dwell, or in-transit segment.
type historyVisit struct {
	ArrivedAt  time.Time `json:"arrived_at"`
	DepartedAt time.Time `json:"departed_at"`
	Lat        float64   `json:"lat"`
	Lon        float64   `json:"lon"`
	PlaceID    *string   `json:"place_id,omitempty"`
	PlaceName  string    `json:"place_name"`
	PlaceType  string    `json:"place_type,omitempty"`
	Kind       string    `json:"kind"` // place | stop | transit
}

type historyOut struct {
	UserID string         `json:"user_id"`
	From   time.Time      `json:"from"`
	To     time.Time      `json:"to"`
	Trail  []trailPoint   `json:"trail"`
	Visits []historyVisit `json:"visits"`
}

type historyPoint struct {
	Lat         float64
	Lon         float64
	TS          time.Time
	MotionState string
	// Accuracy is the device-reported 68%-confidence radius in meters;
	// 0 means unknown.
	Accuracy float64
	// SpeedMPS and BatteryPct are nil when the device did not report them.
	SpeedMPS   *float64
	BatteryPct *float64
}

type historyPlace struct {
	ID           string
	Name         string
	Type         string
	Lat          float64
	Lon          float64
	RadiusMeters float64
}

// GetMemberHistory returns one family member's location trail and visits for
// a time range. The caller and target must share a family.
func (s *Server) GetMemberHistory(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	from, to, errMsg, ok := parseHistoryRange(r, time.Now())
	if !ok {
		writeError(w, http.StatusBadRequest, errMsg)
		return
	}
	memberID := chi.URLParam(r, "id")
	if memberID == "" {
		writeError(w, http.StatusBadRequest, "member id is required")
		return
	}

	callerFamily, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}
	targetFamily, found, err := s.userFamilyID(r.Context(), memberID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	status, msg, allowed := familyHistoryAccess(callerFamily, targetFamily, found)
	if !allowed {
		writeError(w, status, msg)
		return
	}

	out, err := s.buildMemberHistory(r.Context(), memberID, targetFamily, from, to)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load history")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminGetMemberHistory returns any member's location trail and visits.
// RequireAuth + RequirePlatformAdmin are enforced by the route group.
func (s *Server) AdminGetMemberHistory(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	from, to, errMsg, ok := parseHistoryRange(r, time.Now())
	if !ok {
		writeError(w, http.StatusBadRequest, errMsg)
		return
	}
	memberID := chi.URLParam(r, "id")
	if memberID == "" {
		writeError(w, http.StatusBadRequest, "member id is required")
		return
	}

	targetFamily, found, err := s.userFamilyID(r.Context(), memberID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}

	out, err := s.buildMemberHistory(r.Context(), memberID, targetFamily, from, to)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load history")
		return
	}
	s.auditAdminView(r.Context(), claims.UserID, targetFamily, "viewed location history of member "+memberID, clientIP(r))
	writeJSON(w, http.StatusOK, out)
}

// familyHistoryAccess classifies whether a family caller may read a target
// member's history. Other-family members return 403 so the UI can say "not
// in your family" rather than a generic not-found.
func familyHistoryAccess(callerFamily, targetFamily string, targetFound bool) (int, string, bool) {
	if callerFamily == "" {
		return http.StatusNotFound, "no family", false
	}
	if !targetFound {
		return http.StatusNotFound, "member not found", false
	}
	if targetFamily == "" || targetFamily != callerFamily {
		return http.StatusForbidden, "member is not in your family", false
	}
	return 0, "", true
}

func parseHistoryRange(r *http.Request, now time.Time) (time.Time, time.Time, string, bool) {
	fromStr := r.URL.Query().Get("from")
	toStr := r.URL.Query().Get("to")
	if fromStr == "" || toStr == "" {
		return time.Time{}, time.Time{}, "from and to are required", false
	}
	from, err := parseRFC3339(fromStr)
	if err != nil {
		return time.Time{}, time.Time{}, "from must be RFC3339", false
	}
	to, err := parseRFC3339(toStr)
	if err != nil {
		return time.Time{}, time.Time{}, "to must be RFC3339", false
	}
	if !to.After(from) {
		return time.Time{}, time.Time{}, "to must be after from", false
	}
	if to.Sub(from) > maxHistoryRange {
		return time.Time{}, time.Time{}, "range must be at most one day", false
	}
	if now.Sub(from) > config.LocationRetention() {
		return time.Time{}, time.Time{}, fmt.Sprintf("from is older than the %d-day retention window", config.LocationRetentionDays()), false
	}
	return from, to, "", true
}

func parseRFC3339(s string) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, s)
}

func (s *Server) userFamilyID(ctx context.Context, userID string) (string, bool, error) {
	var familyID *string
	err := s.Pool.QueryRow(ctx, `SELECT family_id FROM users WHERE id = $1`, userID).Scan(&familyID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if familyID == nil {
		return "", true, nil
	}
	return *familyID, true, nil
}

func (s *Server) buildMemberHistory(ctx context.Context, userID, familyID string, from, to time.Time) (historyOut, error) {
	out := historyOut{
		UserID: userID,
		From:   from,
		To:     to,
		Trail:  []trailPoint{},
		Visits: []historyVisit{},
	}

	points, err := s.loadHistoryPoints(ctx, userID, from, to)
	if err != nil {
		return out, err
	}
	places, err := s.loadFamilyPlaces(ctx, familyID)
	if err != nil {
		return out, err
	}

	usable := filterUsablePoints(points)
	out.Trail = downsampleTrail(usable, trailBucket, trailPointCap)
	out.Visits = buildVisits(usable, places)
	return out, nil
}

// filterUsablePoints drops fixes too inaccurate to trust for trail/visit
// reconstruction (see historyMaxAccuracyMeters). Accuracy unknown (0) is
// kept. If every fix on the day fails the gate, the raw points are returned
// so a weak-fix device still sees its day rather than an empty one.
func filterUsablePoints(points []historyPoint) []historyPoint {
	usable := make([]historyPoint, 0, len(points))
	for _, p := range points {
		if p.Accuracy > 0 && p.Accuracy > historyMaxAccuracyMeters {
			continue
		}
		usable = append(usable, p)
	}
	if len(usable) == 0 && len(points) > 0 {
		return points
	}
	return usable
}

func (s *Server) loadHistoryPoints(ctx context.Context, userID string, from, to time.Time) ([]historyPoint, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT ST_Y(l.geom), ST_X(l.geom), l.ts, COALESCE(l.motion_state, ''), COALESCE(l.accuracy_meters, 0), l.speed_mps, l.battery_pct
		FROM locations l
		JOIN devices d ON d.id = l.device_id
		WHERE d.user_id = $1 AND l.ts >= $2 AND l.ts < $3
		ORDER BY l.ts`, userID, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	points := []historyPoint{}
	for rows.Next() {
		var p historyPoint
		if err := rows.Scan(&p.Lat, &p.Lon, &p.TS, &p.MotionState, &p.Accuracy, &p.SpeedMPS, &p.BatteryPct); err != nil {
			return nil, err
		}
		points = append(points, p)
	}
	return points, rows.Err()
}

func (s *Server) loadFamilyPlaces(ctx context.Context, familyID string) ([]historyPlace, error) {
	if familyID == "" {
		return nil, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id, name, type, ST_Y(geom), ST_X(geom), radius_meters
		FROM places
		WHERE family_id = $1 AND geom IS NOT NULL AND radius_meters IS NOT NULL`, familyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	places := []historyPlace{}
	for rows.Next() {
		var p historyPlace
		if err := rows.Scan(&p.ID, &p.Name, &p.Type, &p.Lat, &p.Lon, &p.RadiusMeters); err != nil {
			return nil, err
		}
		places = append(places, p)
	}
	return places, rows.Err()
}

func downsampleTrail(points []historyPoint, bucket time.Duration, capN int) []trailPoint {
	if len(points) == 0 {
		return []trailPoint{}
	}
	trail := make([]trailPoint, 0, len(points))
	var bucketStart time.Time
	var latSum, lonSum float64
	var count int
	var motion string
	var ts time.Time
	var speed, battery *float64

	flush := func() {
		if count == 0 {
			return
		}
		trail = append(trail, trailPoint{
			Lat:         latSum / float64(count),
			Lon:         lonSum / float64(count),
			TS:          ts,
			MotionState: motion,
			SpeedMPS:    speed,
			BatteryPct:  battery,
		})
	}

	for _, p := range points {
		start := p.TS.Truncate(bucket)
		if count == 0 {
			bucketStart = start
		}
		if start != bucketStart {
			flush()
			bucketStart = start
			latSum, lonSum, count, motion = 0, 0, 0, ""
			speed, battery = nil, nil
		}
		latSum += p.Lat
		lonSum += p.Lon
		count++
		ts = p.TS
		if p.SpeedMPS != nil {
			speed = p.SpeedMPS
		}
		if p.BatteryPct != nil {
			battery = p.BatteryPct
		}
		if motion == "" {
			motion = p.MotionState
		}
	}
	flush()

	if capN > 0 && len(trail) > capN {
		step := float64(len(trail)-1) / float64(capN-1)
		capped := make([]trailPoint, 0, capN)
		for i := 0; i < capN; i++ {
			capped = append(capped, trail[int(math.Round(float64(i)*step))])
		}
		return capped
	}
	return trail
}

// buildVisits turns a day's GPS points into named place stays, unnamed dwells,
// and in-transit gaps. Named places win when a stay centroid is inside a
// family place radius; everything else uses stay-point clustering. Both paths
// tolerate brief GPS-jitter excursions (see stayBreakTolerance) so a
// stationary member isn't split into phantom transit segments.
func buildVisits(points []historyPoint, places []historyPlace) []historyVisit {
	if len(points) == 0 {
		return []historyVisit{}
	}

	stays := detectStays(points, places)
	stays = mergeSamePlaceStays(stays)
	return fillTransit(points, stays)
}

func detectStays(points []historyPoint, places []historyPlace) []historyVisit {
	stays := []historyVisit{}

	// Named-place runs: consecutive points inside the same place. Brief
	// excursions outside the radius don't end the run while they stay close
	// in time to the last in-place fix (GPS jitter); a real departure
	// outlasts stayBreakTolerance and re-anchors a fresh run at the first
	// missed point.
	type run struct {
		start, end int
		place      *historyPlace
		missStart  int           // first consecutive point outside the place, -1 if none
		missPlace  *historyPlace // place (if any) matched at missStart
	}
	runs := []run{}
	for i, p := range points {
		pl := matchPlace(p.Lat, p.Lon, places)
		for {
			n := len(runs)
			if n == 0 {
				runs = append(runs, run{start: i, end: i, place: pl, missStart: -1})
				break
			}
			last := &runs[n-1]
			if placeID(last.place) == placeID(pl) {
				// Still inside (or back inside): absorb tolerated misses.
				last.end = i
				last.missStart = -1
				break
			}
			if last.missStart < 0 {
				last.missStart = i
				last.missPlace = pl
			}
			// Measured from the last in-place fix, not from the first miss:
			// a lone out-of-radius fix after a long reporting gap is a gap,
			// not jitter.
			if points[i].TS.Sub(points[last.end].TS) <= stayBreakTolerance {
				break // excursion still short; the run may yet resume
			}
			// The excursion outlasted the tolerance: the run ended at its
			// last in-place point. Re-anchor a fresh run at the first missed
			// point (so a genuine trip isn't truncated by the window) and
			// re-match the current point against that new run.
			runs = append(runs, run{start: last.missStart, end: last.missStart, place: last.missPlace, missStart: -1})
		}
	}
	// A miss streak still open at the end of the day has no returning fix to
	// confirm it; every point in it passed the tolerance check, so absorb it
	// rather than leaking a phantom transit tail.
	if n := len(runs); n > 0 && runs[n-1].missStart >= 0 {
		runs[n-1].end = len(points) - 1
	}

	covered := make([]bool, len(points))
	for _, r := range runs {
		if r.place == nil {
			continue
		}
		dur := points[r.end].TS.Sub(points[r.start].TS)
		if dur < placeMinDuration {
			continue
		}
		lat, lon := centroid(points[r.start : r.end+1])
		id := r.place.ID
		stays = append(stays, historyVisit{
			ArrivedAt:  points[r.start].TS,
			DepartedAt: points[r.end].TS,
			Lat:        lat,
			Lon:        lon,
			PlaceID:    &id,
			PlaceName:  r.place.Name,
			PlaceType:  r.place.Type,
			Kind:       "place",
		})
		for i := r.start; i <= r.end; i++ {
			covered[i] = true
		}
	}

	// Unnamed dwells on the remaining points (classic stay-point scan,
	// tolerating brief jitter beyond the stay distance: an excursion that
	// stays close in time to the last in-range fix is absorbed into the
	// dwell, one that outlasts stayBreakTolerance ends the dwell there).
	i := 0
	for i < len(points) {
		if covered[i] {
			i++
			continue
		}
		end := i
		missAt := -1
		j := i + 1
		for j < len(points) && !covered[j] {
			if haversineMeters(points[i].Lat, points[i].Lon, points[j].Lat, points[j].Lon) <= stayDistanceMeters {
				end = j
				missAt = -1
				j++
				continue
			}
			if missAt < 0 {
				missAt = j
			}
			// Measured from the last in-range fix, not from the first miss:
			// a far fix after a long gap is a gap, not jitter.
			if points[j].TS.Sub(points[end].TS) > stayBreakTolerance {
				break
			}
			j++
		}
		// A miss streak still open at the end of the day is trailing jitter
		// (every point passed the tolerance check): absorb it so the day
		// doesn't end on a phantom transit tail.
		if missAt >= 0 && j >= len(points) {
			end = len(points) - 1
		}
		if end > i && points[end].TS.Sub(points[i].TS) >= stayMinDuration {
			lat, lon := centroid(points[i : end+1])
			stays = append(stays, historyVisit{
				ArrivedAt:  points[i].TS,
				DepartedAt: points[end].TS,
				Lat:        lat,
				Lon:        lon,
				PlaceName:  "Stopped",
				Kind:       "stop",
			})
			i = end + 1
			continue
		}
		i++
	}

	sort.Slice(stays, func(a, b int) bool {
		return stays[a].ArrivedAt.Before(stays[b].ArrivedAt)
	})
	return stays
}

func mergeSamePlaceStays(stays []historyVisit) []historyVisit {
	if len(stays) < 2 {
		return stays
	}
	out := []historyVisit{stays[0]}
	for _, next := range stays[1:] {
		prev := &out[len(out)-1]
		if prev.Kind == "place" && next.Kind == "place" &&
			placeIDPtr(prev.PlaceID) == placeIDPtr(next.PlaceID) &&
			next.ArrivedAt.Sub(prev.DepartedAt) <= samePlaceMergeGap {
			prev.DepartedAt = next.DepartedAt
			continue
		}
		out = append(out, next)
	}
	return out
}

func fillTransit(points []historyPoint, stays []historyVisit) []historyVisit {
	if len(stays) == 0 {
		if len(points) == 0 {
			return []historyVisit{}
		}
		lat, lon := centroid(points)
		return []historyVisit{transitVisit(points[0].TS, points[len(points)-1].TS, lat, lon, points)}
	}

	out := make([]historyVisit, 0, len(stays)*2+1)
	cursor := points[0].TS
	for _, stay := range stays {
		if stay.ArrivedAt.After(cursor) {
			seg := pointsInRange(points, cursor, stay.ArrivedAt)
			if len(seg) > 0 {
				lat, lon := centroid(seg)
				out = append(out, transitVisit(cursor, stay.ArrivedAt, lat, lon, seg))
			}
		}
		out = append(out, stay)
		cursor = stay.DepartedAt
	}
	lastTS := points[len(points)-1].TS
	if lastTS.After(cursor) {
		seg := pointsInRange(points, cursor, lastTS.Add(time.Nanosecond))
		if len(seg) > 0 {
			lat, lon := centroid(seg)
			out = append(out, transitVisit(cursor, lastTS, lat, lon, seg))
		}
	}
	return out
}

func transitVisit(from, to time.Time, lat, lon float64, pts []historyPoint) historyVisit {
	return historyVisit{
		ArrivedAt:  from,
		DepartedAt: to,
		Lat:        lat,
		Lon:        lon,
		PlaceName:  transitLabel(pts),
		PlaceType:  majorityMotion(pts),
		Kind:       "transit",
	}
}

func transitLabel(pts []historyPoint) string {
	switch majorityMotion(pts) {
	case "driving":
		return "Driving"
	case "walking":
		return "Walking"
	case "running":
		return "Running"
	case "cycling":
		return "Cycling"
	default:
		return "In transit"
	}
}

func majorityMotion(pts []historyPoint) string {
	counts := map[string]int{}
	best, bestN := "", 0
	for _, p := range pts {
		if p.MotionState == "" {
			continue
		}
		counts[p.MotionState]++
		if counts[p.MotionState] > bestN {
			best, bestN = p.MotionState, counts[p.MotionState]
		}
	}
	return best
}

func pointsInRange(points []historyPoint, from, to time.Time) []historyPoint {
	out := []historyPoint{}
	for _, p := range points {
		if !p.TS.Before(from) && p.TS.Before(to) {
			out = append(out, p)
		}
	}
	return out
}

func matchPlace(lat, lon float64, places []historyPlace) *historyPlace {
	var best *historyPlace
	bestR := math.MaxFloat64
	for i := range places {
		p := &places[i]
		if haversineMeters(lat, lon, p.Lat, p.Lon) <= p.RadiusMeters && p.RadiusMeters < bestR {
			best = p
			bestR = p.RadiusMeters
		}
	}
	return best
}

func placeID(p *historyPlace) string {
	if p == nil {
		return ""
	}
	return p.ID
}

func placeIDPtr(id *string) string {
	if id == nil {
		return ""
	}
	return *id
}

func centroid(points []historyPoint) (float64, float64) {
	if len(points) == 0 {
		return 0, 0
	}
	var lat, lon float64
	for _, p := range points {
		lat += p.Lat
		lon += p.Lon
	}
	n := float64(len(points))
	return lat / n, lon / n
}

func haversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	dLat := (lat2 - lat1) * math.Pi / 180
	dLon := (lon2 - lon1) * math.Pi / 180
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*math.Pi/180)*math.Cos(lat2*math.Pi/180)*
			math.Sin(dLon/2)*math.Sin(dLon/2)
	c := 2 * math.Asin(math.Min(1, math.Sqrt(a)))
	return earthRadiusMeters * c
}
