package handlers

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"time"
)

// Integration API (token-authenticated, read-only): /integrations/ha/v1/*.
//
// The privacy rules, in one place:
//   - A token sees only circles it was scoped to AND whose owner is still a live
//     member (membership is read on every request).
//   - A member's location is reported only through a circle in which they share
//     their location (sharing_enabled, no active pause) AND the server may hold
//     plaintext (circle not Private, or Private in consented trusted-server mode:
//     NOT e2ee_plaintext_blocked). Otherwise the member is listed with a state
//     only: "unavailable_private_circle" or "sharing_off". No coordinates, no
//     battery, no speed, no timestamps are derived from such a circle.
//   - The owner gets no special case: not even their own position is returned
//     through a blocked Private circle.
//   - Coordinates additionally need the "location" scope.

type haCircle struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	State    string `json:"state"` // "ok" | "unavailable_private_circle"
	readable bool
}

// haCircles lists the token's circles that its owner is still a live member of.
func (s *Server) haCircles(ctx context.Context, integ *haIntegration) ([]haCircle, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id::text, c.name, NOT e2ee_plaintext_blocked(c.id)
		FROM live_circle_members m JOIN circles c ON c.id = m.circle_id
		WHERE m.user_id = $1 AND c.id = ANY($2::uuid[])
		ORDER BY c.name, c.id`, integ.UserID, integ.CircleIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []haCircle{}
	for rows.Next() {
		var c haCircle
		if err := rows.Scan(&c.ID, &c.Name, &c.readable); err != nil {
			return nil, err
		}
		c.State = "ok"
		if !c.readable {
			c.State = haStateUnavailablePrivate
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

type haPlaceRef struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	IsHome bool   `json:"is_home"`
}

type haLocation struct {
	Lat       float64  `json:"lat"`
	Lon       float64  `json:"lon"`
	AccuracyM *float64 `json:"accuracy_m"`
}

type haDriving struct {
	Drives24h    int        `json:"drives_24h"`
	DistanceM24h float64    `json:"distance_m_24h"`
	MaxSpeedMPS  float64    `json:"max_speed_mps_24h"`
	LastDriveEnd *time.Time `json:"last_drive_ended_at"`
	MotionState  *string    `json:"motion_state"`
}

type haMember struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	State string `json:"state"` // home | not_home | <place name> | unknown | unavailable_private_circle | sharing_off
	// LocationAvailable is true when the server is allowed to report this
	// member's position to this token (it can still be omitted by scope).
	LocationAvailable bool        `json:"location_available"`
	Reason            string      `json:"unavailable_reason,omitempty"`
	Place             *haPlaceRef `json:"place"`
	BatteryPct        *float64    `json:"battery_pct"`
	Charging          *bool       `json:"charging,omitempty"` // omitted when the phone did not say
	SpeedMPS          *float64    `json:"speed_mps"`
	LastSeen          *time.Time  `json:"last_seen"`
	Location          *haLocation `json:"location,omitempty"`
	Driving           *haDriving  `json:"driving,omitempty"`
	SOSActive         *bool       `json:"sos_active,omitempty"`
	CrashActive       *bool       `json:"crash_active,omitempty"`
}

// HAPing reports who the token is. It is the config-flow connectivity check.
func (s *Server) HAPing(w http.ResponseWriter, r *http.Request) {
	integ, ok := s.haAuth(w, r, "")
	if !ok {
		return
	}
	cs, err := s.haCircles(r.Context(), integ)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"api": 1, "name": integ.Name, "scopes": integ.Scopes, "circles": cs,
		"webhook_signature": "v1=hex(hmac_sha256(secret, timestamp + \".\" + body))",
	})
}

// HAMembers lists members across the token's circles.
func (s *Server) HAMembers(w http.ResponseWriter, r *http.Request) {
	integ, ok := s.haAuth(w, r, haScopePresence)
	if !ok {
		return
	}
	ctx := r.Context()
	cs, err := s.haCircles(ctx, integ)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	ids := make([]string, 0, len(cs))
	readable := map[string]bool{}
	for _, c := range cs {
		ids = append(ids, c.ID)
		readable[c.ID] = c.readable
	}
	type agg struct {
		name        string
		shareCircle map[string]bool // readable circles in which the member shares
		blocked     bool            // member of a Private circle without a server device
	}
	users := map[string]*agg{}
	var order []string
	rows, err := s.Pool.Query(ctx, `
		SELECT m.user_id::text, u.name, m.circle_id::text,
		       (m.sharing_enabled AND NOT `+pausedExprSQL("m.user_id")+`), e2ee_member_plaintext_ok(m.circle_id, m.user_id)
		FROM live_circle_members m JOIN users u ON u.id = m.user_id
		WHERE m.circle_id = ANY($1::uuid[]) ORDER BY u.name, m.user_id`, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	for rows.Next() {
		var uid, name, cid string
		var sharing, memberReadable bool
		if err := rows.Scan(&uid, &name, &cid, &sharing, &memberReadable); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
		a := users[uid]
		if a == nil {
			a = &agg{name: name, shareCircle: map[string]bool{}}
			users[uid] = a
			order = append(order, uid)
		}
		if !memberReadable { // per member: only a member whose own lane lets the server read them
			a.blocked = true
		} else if sharing {
			a.shareCircle[cid] = true
		}
	}
	rows.Close()
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	var visible []string
	for _, uid := range order {
		if len(users[uid].shareCircle) > 0 {
			visible = append(visible, uid)
		}
	}
	pos, err := s.haPositions(ctx, visible)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	pres, err := s.haPresence(ctx, visible, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	var drv map[string]*haDriving
	if integ.has(haScopeDriving) {
		if drv, err = s.haDriving(ctx, visible); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
	}
	var sos, crash map[string]bool
	if integ.has(haScopeEvents) {
		if sos, crash, err = s.haActiveFlags(ctx, order, ids); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
	}
	members := make([]haMember, 0, len(order))
	for _, uid := range order {
		a := users[uid]
		m := haMember{ID: uid, Name: a.name}
		if integ.has(haScopeEvents) {
			t, f := sos[uid], crash[uid]
			m.SOSActive, m.CrashActive = &t, &f
		}
		if len(a.shareCircle) == 0 {
			m.State = haStateSharingOff
			if a.blocked {
				m.State = haStateUnavailablePrivate
			}
			m.Reason = m.State
			members = append(members, m)
			continue
		}
		m.LocationAvailable = true
		p := pos[uid]
		if p != nil {
			m.BatteryPct, m.Charging, m.SpeedMPS, m.LastSeen = p.battery, p.charging, p.speed, p.ts
			if integ.has(haScopeLocation) {
				m.Location = &haLocation{Lat: p.lat, Lon: p.lon, AccuracyM: p.acc}
			}
		}
		m.State = "unknown"
		if p != nil {
			m.State = "not_home"
		}
		for _, pr := range pres[uid] {
			if !a.shareCircle[pr.circle] {
				continue
			}
			if pr.at {
				m.Place = &haPlaceRef{ID: pr.placeID, Name: pr.name, IsHome: pr.typ == "home"}
				m.State = pr.name
				if pr.typ == "home" {
					m.State = "home"
				}
				break
			}
		}
		if integ.has(haScopeDriving) {
			d := drv[uid]
			if d == nil {
				d = &haDriving{}
			}
			if p != nil {
				d.MotionState = p.motion
			}
			m.Driving = d
		}
		members = append(members, m)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"generated_at": time.Now().UTC(), "circles": cs, "members": members,
	})
}

type haPos struct {
	lat, lon            float64
	acc, battery, speed *float64
	ts                  *time.Time
	motion              *string
	charging            *bool
}

func (s *Server) haPositions(ctx context.Context, userIDs []string) (map[string]*haPos, error) {
	out := map[string]*haPos{}
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT user_id::text, lat, lon, accuracy_meters, battery_pct, speed_mps, ts, motion_state, charging
		FROM member_positions WHERE user_id = ANY($1::uuid[]) AND NOT e2ee_keeps_data_on_phone(user_id)`, userIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		var p haPos
		if err := rows.Scan(&uid, &p.lat, &p.lon, &p.acc, &p.battery, &p.speed, &p.ts, &p.motion, &p.charging); err != nil {
			return nil, err
		}
		out[uid] = &p
	}
	return out, rows.Err()
}

type haPresenceRow struct {
	circle, placeID, name, typ string
	at                         bool
	ts                         time.Time
}

// haPresence is placePresence restricted to places of the token's circles,
// returned per user as candidates ("at" first, then most recent) so the caller
// can keep only places belonging to a circle in which the member shares.
func (s *Server) haPresence(ctx context.Context, userIDs, circleIDs []string) (map[string][]haPresenceRow, error) {
	out := map[string][]haPresenceRow{}
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT l.user_id::text, COALESCE(p.circle_id, p.family_id)::text, p.id::text, p.name, p.type,
		       l.event_type = 'enter', l.ts
		FROM (
			SELECT DISTINCT ON (user_id, geofence_id) user_id, geofence_id, place_id, event_type, ts
			FROM geofence_events
			WHERE user_id = ANY($1::uuid[]) AND place_id IS NOT NULL
			ORDER BY user_id, geofence_id, ts DESC
		) l
		JOIN places p ON p.id = l.place_id AND COALESCE(p.circle_id, p.family_id) = ANY($2::uuid[])
		ORDER BY l.user_id, (l.event_type = 'enter') DESC, l.ts DESC`, userIDs, circleIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		var r haPresenceRow
		if err := rows.Scan(&uid, &r.circle, &r.placeID, &r.name, &r.typ, &r.at, &r.ts); err != nil {
			return nil, err
		}
		out[uid] = append(out[uid], r)
	}
	return out, rows.Err()
}

func (s *Server) haDriving(ctx context.Context, userIDs []string) (map[string]*haDriving, error) {
	out := map[string]*haDriving{}
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT user_id::text, count(*), COALESCE(sum(distance_m), 0), COALESCE(max(max_speed_mps), 0), max(ended_at)
		FROM trips WHERE user_id = ANY($1::uuid[]) AND mode = 'driving' AND ended_at > now() - interval '24 hours'
		GROUP BY user_id`, userIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		var d haDriving
		if err := rows.Scan(&uid, &d.Drives24h, &d.DistanceM24h, &d.MaxSpeedMPS, &d.LastDriveEnd); err != nil {
			return nil, err
		}
		out[uid] = &d
	}
	return out, rows.Err()
}

// haActiveFlags reports an unresolved SOS (24 h) and an unresolved possible
// crash (6 h) per user, for alerts raised in the token's circles. They carry no
// position, so they are reported even for Private circles.
func (s *Server) haActiveFlags(ctx context.Context, userIDs, circleIDs []string) (sos, crash map[string]bool, err error) {
	sos, crash = map[string]bool{}, map[string]bool{}
	if len(userIDs) == 0 {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT user_id::text FROM alerts
		WHERE user_id = ANY($1::uuid[]) AND family_id = ANY($2::uuid[]) AND type = 'sos'
		  AND status = 'active' AND created_at > now() - interval '24 hours'`, userIDs, circleIDs)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err == nil {
			sos[u] = true
		}
	}
	rows.Close()
	rows, err = s.Pool.Query(ctx, `
		SELECT DISTINCT user_id::text FROM crash_events
		WHERE user_id = ANY($1::uuid[]) AND status = 'possible' AND resolved_at IS NULL
		  AND occurred_at > now() - interval '6 hours'`, userIDs)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err == nil {
			crash[u] = true
		}
	}
	return sos, crash, rows.Err()
}

type haPlace struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	CircleID string   `json:"circle_id"`
	Lat      *float64 `json:"lat"`
	Lon      *float64 `json:"lon"`
	RadiusM  *float64 `json:"radius_m"`
}

// HAPlaces lists saved places (zones) of the token's readable circles.
func (s *Server) HAPlaces(w http.ResponseWriter, r *http.Request) {
	integ, ok := s.haAuth(w, r, haScopePlaces)
	if !ok {
		return
	}
	cs, err := s.haCircles(r.Context(), integ)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	var ids []string
	for _, c := range cs {
		if c.readable {
			ids = append(ids, c.ID)
		}
	}
	places := []haPlace{}
	if len(ids) > 0 {
		rows, err := s.Pool.Query(r.Context(), `
			SELECT p.id::text, p.name, p.type, COALESCE(p.circle_id, p.family_id)::text,
			       ST_Y(p.geom), ST_X(p.geom), p.radius_meters
			FROM places p WHERE COALESCE(p.circle_id, p.family_id) = ANY($1::uuid[])
			ORDER BY p.name, p.id`, ids)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
		defer rows.Close()
		for rows.Next() {
			var p haPlace
			if err := rows.Scan(&p.ID, &p.Name, &p.Type, &p.CircleID, &p.Lat, &p.Lon, &p.RadiusM); err != nil {
				writeError(w, http.StatusInternalServerError, "server_error")
				return
			}
			places = append(places, p)
		}
		if rows.Err() != nil {
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"circles": cs, "places": places})
}

// HAEvents is the pull side of the event feed: GET ?after=<id>&limit=<n>. It
// returns exactly what the webhook would have delivered (same visibility
// rules), oldest first, with next_after to resume from. A first call without
// "after" returns nothing but the current position, so history is never dumped.
func (s *Server) HAEvents(w http.ResponseWriter, r *http.Request) {
	integ, ok := s.haAuth(w, r, haScopeEvents)
	if !ok {
		return
	}
	ctx := r.Context()
	q := r.URL.Query()
	var head int64
	if err := s.Pool.QueryRow(ctx, `SELECT COALESCE(max(id), 0) FROM ha_events`).Scan(&head); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	if q.Get("after") == "" {
		writeJSON(w, http.StatusOK, map[string]any{"events": []any{}, "next_after": head})
		return
	}
	after, err := strconv.ParseInt(q.Get("after"), 10, 64)
	if err != nil || after < 0 {
		writeError(w, http.StatusBadRequest, "after must be a non-negative integer")
		return
	}
	limit := 50
	if v, err := strconv.Atoi(q.Get("limit")); err == nil && v >= 1 && v <= 100 {
		limit = v
	}
	evs, err := s.haLoadEvents(ctx, after, 100)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error")
		return
	}
	out := []map[string]any{}
	next := after
	for _, ev := range evs {
		next = ev.ID
		p, vis, err := s.haEventPayload(ctx, integ, ev)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "server_error")
			return
		}
		if vis {
			out = append(out, p)
		}
		if len(out) >= limit {
			break
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i]["id"].(int64) < out[j]["id"].(int64) })
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "next_after": next})
}
