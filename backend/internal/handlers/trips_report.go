package handlers

import (
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

// Weekly/monthly family driving report and per-trip events. Events are GPS
// ESTIMATES (see docs/driving.md) and as sensitive as trips: a viewer needs a
// circle in common with the subject AND the subject must share their location
// in that circle (circles.Authz.SharedWith).

// eventCounts holds per-kind event counts. PhoneUse is reserved and always
// null: the server cannot detect it from GPS.
type eventCounts struct {
	Speeding   int  `json:"speeding"`
	HardBrake  int  `json:"hard_brake"`
	RapidAccel int  `json:"rapid_accel"`
	PhoneUse   *int `json:"phone_use"`
}

func (c *eventCounts) add(kind string, n int) {
	switch kind {
	case trips.EventSpeeding:
		c.Speeding += n
	case trips.EventHardBrake:
		c.HardBrake += n
	case trips.EventRapidAccel:
		c.RapidAccel += n
	}
}

type reportTotals struct {
	Drives         int         `json:"drives"`
	DistanceM      float64     `json:"distance_m"`
	TopSpeedMps    float64     `json:"top_speed_mps"`
	TopSpeedUserID *string     `json:"top_speed_user_id"`
	Events         eventCounts `json:"events"`
}

type reportMember struct {
	UserID         string      `json:"user_id"`
	Name           string      `json:"name"`
	Drives         int         `json:"drives"`
	DistanceM      float64     `json:"distance_m"`
	TopSpeedMps    float64     `json:"top_speed_mps"`
	Events         eventCounts `json:"events"`
	PreviousEvents eventCounts `json:"previous_events"`

	prevDrives    int
	prevDistanceM float64
	prevTopSpeed  float64
}

type reportThresholds struct {
	SpeedingMps     float64 `json:"speeding_mps"`
	SpeedingSeconds float64 `json:"speeding_seconds"`
	HardBrakeMps2   float64 `json:"hard_brake_mps2"`
	RapidAccelMps2  float64 `json:"rapid_accel_mps2"`
}

type reportPeriod struct {
	start, end, prevStart, prevEnd time.Time // [start,end) instants
	startDay, endDay               string     // local calendar days, end inclusive
	prevStartDay, prevEndDay       string
}

// computeReportPeriod resolves the week (Monday start) or month containing
// startDay (YYYY-MM-DD, local) or, when empty, containing now, using a fixed
// UTC offset to derive the local date.
func computeReportPeriod(period, startDay string, now time.Time, offsetMin int) (reportPeriod, string) {
	loc := time.FixedZone("", offsetMin*60)
	date := now.In(loc)
	if startDay != "" {
		d, err := time.ParseInLocation("2006-01-02", startDay, loc)
		if err != nil {
			return reportPeriod{}, "start must be YYYY-MM-DD"
		}
		date = d
	}
	if period != "week" && period != "month" {
		return reportPeriod{}, "period must be week or month"
	}
	from, to, _ := periodBounds(period, date, loc)
	var pf time.Time
	if period == "week" {
		pf = from.AddDate(0, 0, -7)
	} else {
		pf = from.AddDate(0, -1, 0)
	}
	const dayFmt = "2006-01-02"
	return reportPeriod{
		start: from, end: to, prevStart: pf, prevEnd: from,
		startDay: from.Format(dayFmt), endDay: to.AddDate(0, 0, -1).Format(dayFmt),
		prevStartDay: pf.Format(dayFmt), prevEndDay: from.AddDate(0, 0, -1).Format(dayFmt),
	}, ""
}

// canViewSubject reports whether viewer may see subject's trips under the
// circle rules: themselves, or a common circle where subject shares location.
func (s *Server) canViewSubject(r *http.Request, viewerID, subjectID string) (bool, error) {
	if viewerID == subjectID {
		return true, nil
	}
	shared, err := circles.New(s.Pool).SharedWith(r.Context(), viewerID, subjectID)
	return len(shared) > 0, err
}

// TripsReport is the family driving report. GET /trips/report?period=week|month&start=YYYY-MM-DD&utc_offset_minutes=&circle_id=
func (s *Server) TripsReport(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	q := r.URL.Query()
	period := q.Get("period")
	if period == "" {
		period = "week"
	}
	offset := 0
	if v := q.Get("utc_offset_minutes"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < -14*60 || n > 14*60 {
			writeError(w, http.StatusBadRequest, "utc_offset_minutes must be between -840 and 840")
			return
		}
		offset = n
	}
	per, msg := computeReportPeriod(period, q.Get("start"), time.Now(), offset)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}

	az := circles.New(s.Pool)
	circleID := q.Get("circle_id")
	if circleID == "" {
		fam, err := s.familyIDForUser(r.Context(), claims.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load circle")
			return
		}
		if fam == "" {
			writeError(w, http.StatusNotFound, "circle not found")
			return
		}
		circleID = fam
	}
	if _, err := az.RequireMember(r.Context(), claims.UserID, circleID); err != nil {
		circleAuthError(w, err)
		return
	}
	vis, err := az.LocationVisibility(r.Context(), claims.UserID, []string{circleID})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	ids := []string{}
	for id, ok := range vis {
		if ok {
			ids = append(ids, id)
		}
	}

	members := map[string]*reportMember{}
	nameRows, err := s.Pool.Query(r.Context(), `SELECT id::text, name FROM users WHERE id = ANY($1::uuid[])`, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	for nameRows.Next() {
		m := &reportMember{}
		if err := nameRows.Scan(&m.UserID, &m.Name); err == nil {
			members[m.UserID] = m
		}
	}
	nameRows.Close()

	// Trips are hidden past retention, like everywhere else; rows older than
	// that simply contribute nothing.
	tripRows, err := s.Pool.Query(r.Context(), `
		SELECT user_id::text, (started_at >= $3) AS cur, count(*), COALESCE(sum(distance_m), 0), COALESCE(max(max_speed_mps), 0)
		FROM trips
		WHERE user_id = ANY($1::uuid[]) AND mode = 'driving' AND started_at >= $2 AND started_at < $4
		GROUP BY 1, 2`, ids, per.prevStart, per.start, per.end)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load trips")
		return
	}
	for tripRows.Next() {
		var uid string
		var cur bool
		var n int
		var dist, top float64
		if err := tripRows.Scan(&uid, &cur, &n, &dist, &top); err != nil {
			continue
		}
		m := members[uid]
		if m == nil {
			continue
		}
		if cur {
			m.Drives, m.DistanceM, m.TopSpeedMps = n, dist, top
		} else {
			m.prevDrives, m.prevDistanceM, m.prevTopSpeed = n, dist, top
		}
	}
	tripRows.Close()

	evRows, err := s.Pool.Query(r.Context(), `
		SELECT user_id::text, kind, (started_at >= $3) AS cur, count(*)
		FROM trip_events
		WHERE user_id = ANY($1::uuid[]) AND started_at >= $2 AND started_at < $4
		GROUP BY 1, 2, 3`, ids, per.prevStart, per.start, per.end)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load events")
		return
	}
	for evRows.Next() {
		var uid, kind string
		var cur bool
		var n int
		if err := evRows.Scan(&uid, &kind, &cur, &n); err != nil {
			continue
		}
		m := members[uid]
		if m == nil {
			continue
		}
		if cur {
			m.Events.add(kind, n)
		} else {
			m.PreviousEvents.add(kind, n)
		}
	}
	evRows.Close()

	list := make([]*reportMember, 0, len(members))
	for _, m := range members {
		list = append(list, m)
	}
	sort.Slice(list, func(a, b int) bool {
		if list[a].Name != list[b].Name {
			return list[a].Name < list[b].Name
		}
		return list[a].UserID < list[b].UserID
	})
	var cur, prev reportTotals
	out := make([]reportMember, 0, len(list))
	for _, m := range list {
		cur.Drives += m.Drives
		cur.DistanceM += m.DistanceM
		if m.TopSpeedMps > cur.TopSpeedMps {
			id := m.UserID
			cur.TopSpeedMps, cur.TopSpeedUserID = m.TopSpeedMps, &id
		}
		prev.Drives += m.prevDrives
		prev.DistanceM += m.prevDistanceM
		if m.prevTopSpeed > prev.TopSpeedMps {
			id := m.UserID
			prev.TopSpeedMps, prev.TopSpeedUserID = m.prevTopSpeed, &id
		}
		for _, p := range []struct {
			dst *eventCounts
			src eventCounts
		}{{&cur.Events, m.Events}, {&prev.Events, m.PreviousEvents}} {
			p.dst.Speeding += p.src.Speeding
			p.dst.HardBrake += p.src.HardBrake
			p.dst.RapidAccel += p.src.RapidAccel
		}
		out = append(out, *m)
	}
	ep := s.tripStore().EventParams
	writeJSON(w, http.StatusOK, map[string]any{
		"period": period, "start": per.startDay, "end": per.endDay,
		"prev_start": per.prevStartDay, "prev_end": per.prevEndDay,
		"totals": cur, "previous_totals": prev, "members": out,
		"thresholds": reportThresholds{SpeedingMps: ep.SpeedingMps, SpeedingSeconds: ep.SpeedingSeconds,
			HardBrakeMps2: ep.HardBrakeMps2, RapidAccelMps2: ep.RapidAccelMps2},
		"estimated": true,
	})
}

// TripEvents lists a trip's driving events. GET /trips/{id}/events
func (s *Server) TripEvents(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	st := s.tripStore()
	trip, err := st.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		// Missing, malformed id and lookup errors all answer 404 (no probing).
		writeError(w, http.StatusNotFound, "trip not found")
		return
	}
	ok, err := s.canViewSubject(r, claims.UserID, trip.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize")
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "trip not found")
		return
	}
	ev, err := st.Events(r.Context(), trip.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load events")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"trip_id": trip.ID, "estimated": true, "events": ev})
}
