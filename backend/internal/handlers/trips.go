package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

const (
	maxTripListRange     = 31 * 24 * time.Hour
	defaultTripListLimit = 100
	maxTripListLimit     = 500
	defaultRoutePoints   = 300
	maxRoutePoints       = 1000
	// defaultSpeedThresholdMps is 70 mph / 112 km/h, used when the client
	// does not pass speed_threshold_mps.
	defaultSpeedThresholdMps = 31.3
)

// tripComputeSlots bounds concurrent on-demand recomputations.
var tripComputeSlots = make(chan struct{}, 2)

// tripUnits documents the units of every numeric field so clients can convert.
var tripUnits = map[string]string{"speed": "m/s", "distance": "m", "duration": "s"}

func (s *Server) tripStore() *trips.Store { return trips.NewStore(s.Pool) }

// tripTarget resolves which user's trips the caller may read, applying the
// same family membership rule as member history. It writes the error response
// itself when access is denied. self is true when the caller is the target.
func (s *Server) tripTarget(w http.ResponseWriter, r *http.Request, userID string) (target, targetFamily string, ok bool) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", "", false
	}
	if userID == "" {
		userID = claims.UserID
	}
	callerFamily, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return "", "", false
	}
	if userID == claims.UserID {
		return userID, callerFamily, true
	}
	targetFamily, found, err := s.userFamilyID(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member")
		return "", "", false
	}
	if status, msg, allowed := familyHistoryAccess(callerFamily, targetFamily, found); !allowed {
		writeError(w, status, msg)
		return "", "", false
	}
	return userID, targetFamily, true
}

func parseOptionalRange(r *http.Request, now time.Time, defaultSpan time.Duration) (time.Time, time.Time, string) {
	to := now
	if v := r.URL.Query().Get("to"); v != "" {
		t, err := parseRFC3339(v)
		if err != nil {
			return time.Time{}, time.Time{}, "to must be RFC3339"
		}
		to = t
	}
	from := to.Add(-defaultSpan)
	if v := r.URL.Query().Get("from"); v != "" {
		t, err := parseRFC3339(v)
		if err != nil {
			return time.Time{}, time.Time{}, "from must be RFC3339"
		}
		from = t
	}
	if !to.After(from) {
		return time.Time{}, time.Time{}, "to must be after from"
	}
	return from, to, ""
}

// ListTrips returns a member's trips. GET /trips?user_id=&from=&to=&limit=
func (s *Server) ListTrips(w http.ResponseWriter, r *http.Request) {
	target, _, ok := s.tripTarget(w, r, r.URL.Query().Get("user_id"))
	if !ok {
		return
	}
	from, to, msg := parseOptionalRange(r, time.Now(), 7*24*time.Hour)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if to.Sub(from) > maxTripListRange {
		writeError(w, http.StatusBadRequest, "range must be at most 31 days")
		return
	}
	limit := defaultTripListLimit
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > maxTripListLimit {
			writeError(w, http.StatusBadRequest, "limit must be 1-500")
			return
		}
		limit = n
	}
	rows, err := s.tripStore().List(r.Context(), target, from, to, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load trips")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"user_id": target, "from": from, "to": to, "units": tripUnits, "trips": rows})
}

// GetTrip returns one trip with a downsampled route. GET /trips/{id}
func (s *Server) GetTrip(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	st := s.tripStore()
	trip, err := st.Get(r.Context(), chi.URLParam(r, "id"))
	if errors.Is(err, trips.ErrNotFound) {
		writeError(w, http.StatusNotFound, "trip not found")
		return
	}
	if err != nil {
		// A malformed id is a client error, anything else a server error; do
		// not distinguish to avoid probing.
		writeError(w, http.StatusNotFound, "trip not found")
		return
	}
	// Cross-family access answers 404 (not 403) so trip ids cannot be probed.
	if trip.UserID != claims.UserID {
		callerFamily, err := s.familyIDForUser(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load family")
			return
		}
		targetFamily, found, err := s.userFamilyID(r.Context(), trip.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load member")
			return
		}
		if _, _, allowed := familyHistoryAccess(callerFamily, targetFamily, found); !allowed {
			writeError(w, http.StatusNotFound, "trip not found")
			return
		}
	}
	maxPts := defaultRoutePoints
	if v := r.URL.Query().Get("max_points"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 2 || n > maxRoutePoints {
			writeError(w, http.StatusBadRequest, "max_points must be 2-1000")
			return
		}
		maxPts = n
	}
	route, err := st.Route(r.Context(), trip, maxPts)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load route")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"units": tripUnits, "trip": trip, "route": route})
}

// periodBounds returns [start, end) for a day/week(Mon)/month period that
// contains date in loc.
func periodBounds(period string, date time.Time, loc *time.Location) (time.Time, time.Time, bool) {
	d := date.In(loc)
	day := time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, loc)
	switch period {
	case "day":
		return day, day.AddDate(0, 0, 1), true
	case "week":
		off := (int(day.Weekday()) + 6) % 7
		start := day.AddDate(0, 0, -off)
		return start, start.AddDate(0, 0, 7), true
	case "month":
		start := time.Date(d.Year(), d.Month(), 1, 0, 0, 0, 0, loc)
		return start, start.AddDate(0, 1, 0), true
	}
	return time.Time{}, time.Time{}, false
}

// TripsSummary is the driving report. GET /trips/summary?user_id=&period=day|week|month&date=&tz=&speed_threshold_mps=
func (s *Server) TripsSummary(w http.ResponseWriter, r *http.Request) {
	target, _, ok := s.tripTarget(w, r, r.URL.Query().Get("user_id"))
	if !ok {
		return
	}
	q := r.URL.Query()
	period := q.Get("period")
	if period == "" {
		period = "day"
	}
	loc := time.UTC
	if v := q.Get("tz"); v != "" {
		l, err := time.LoadLocation(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "tz must be an IANA time zone")
			return
		}
		loc = l
	}
	date := time.Now()
	if v := q.Get("date"); v != "" {
		d, err := time.ParseInLocation("2006-01-02", v, loc)
		if err != nil {
			writeError(w, http.StatusBadRequest, "date must be YYYY-MM-DD")
			return
		}
		date = d
	}
	from, to, valid := periodBounds(period, date, loc)
	if !valid {
		writeError(w, http.StatusBadRequest, "period must be day, week or month")
		return
	}
	threshold := defaultSpeedThresholdMps
	if v := q.Get("speed_threshold_mps"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f <= 0 || f > 90 {
			writeError(w, http.StatusBadRequest, "speed_threshold_mps must be between 0 and 90")
			return
		}
		threshold = f
	}
	sum, err := s.tripStore().Summary(r.Context(), target, from, to, threshold)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to build summary")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"units": tripUnits, "period": period, "summary": sum})
}

// ComputeTrips recomputes the caller's own trips for a range of up to 7 days.
// POST /trips/compute?from=&to=
func (s *Server) ComputeTrips(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	from, to, msg := parseOptionalRange(r, time.Now(), 24*time.Hour)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if to.Sub(from) > trips.MaxComputeRange {
		writeError(w, http.StatusBadRequest, "range must be at most 7 days")
		return
	}
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}
	select {
	case tripComputeSlots <- struct{}{}:
		defer func() { <-tripComputeSlots }()
	default:
		writeError(w, http.StatusTooManyRequests, "trip computation is busy, retry shortly")
		return
	}
	n, err := s.tripStore().ComputeRange(r.Context(), claims.UserID, familyID, from, to)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to compute trips")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": from, "to": to, "trips_written": n})
}
