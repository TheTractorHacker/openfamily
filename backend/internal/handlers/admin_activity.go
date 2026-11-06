package handlers

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Activity kinds the feed can return, in display order.
var activityKinds = []string{"arrival", "departure", "sos", "help", "check_in", "crash", "bubble_created", "bubble_entered", "bubble_left"}

// parseActivityKinds turns ?type=arrival,sos into a validated list; nil means
// every kind. Unknown names are an error rather than being ignored.
func parseActivityKinds(raw string) ([]string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ""
	}
	known := map[string]bool{}
	for _, k := range activityKinds {
		known[k] = true
	}
	var out []string
	seen := map[string]bool{}
	for _, k := range strings.Split(raw, ",") {
		k = strings.TrimSpace(k)
		if !known[k] {
			return nil, "unknown type: " + k
		}
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out, ""
}

type activityFilter struct {
	Limit    int
	Before   *time.Time
	Kinds    []string
	FamilyID string
}

func parseActivityFilter(q url.Values) (activityFilter, string) {
	f := activityFilter{Limit: adminLimit(q)}
	if v := q.Get("before"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			return f, "invalid before"
		}
		f.Before = &t
	}
	kinds, msg := parseActivityKinds(q.Get("type"))
	if msg != "" {
		return f, msg
	}
	f.Kinds = kinds
	if v := q.Get("family_id"); v != "" {
		if !circles.ValidID(v) {
			return f, "invalid family_id"
		}
		f.FamilyID = v
	}
	return f, ""
}

type activityOut struct {
	Kind       string    `json:"kind"`
	At         time.Time `json:"at"`
	UserID     string    `json:"user_id"`
	UserName   string    `json:"user_name"`
	FamilyID   *string   `json:"family_id"`
	FamilyName string    `json:"family_name"`
	Detail     string    `json:"detail"`
	Status     string    `json:"status"`
	Lat        *float64  `json:"lat,omitempty"`
	Lon        *float64  `json:"lon,omitempty"`
}

// Each inner SELECT applies the same three filters ($1 before, $2 kinds,
// $3 family) and its own LIMIT ($4), so a feed filtered to a rare kind is
// never starved by a chatty one.
const activitySQL = `
SELECT kind, at, user_id, user_name, family_id, family_name, detail, status, lat, lon FROM (
  (SELECT CASE ge.event_type WHEN 'enter' THEN 'arrival' ELSE 'departure' END AS kind,
          ge.ts AS at, u.id::text AS user_id, u.name AS user_name,
          u.family_id::text AS family_id, COALESCE(f.name, '') AS family_name,
          COALESCE(p.name, '') AS detail, '' AS status,
          ST_Y(ge.location) AS lat, ST_X(ge.location) AS lon
   FROM geofence_events ge
   JOIN users u ON u.id = ge.user_id
   LEFT JOIN families f ON f.id = u.family_id
   LEFT JOIN places p ON p.id = ge.place_id
   WHERE ($1::timestamptz IS NULL OR ge.ts < $1)
     AND ($2::text[] IS NULL OR (CASE ge.event_type WHEN 'enter' THEN 'arrival' ELSE 'departure' END) = ANY($2))
     AND ($3::uuid IS NULL OR u.family_id = $3)
   ORDER BY ge.ts DESC LIMIT $4)
  UNION ALL
  (SELECT a.type AS kind, a.created_at AS at, u.id::text, u.name,
          COALESCE(a.family_id, u.family_id)::text, COALESCE(f.name, ''),
          COALESCE(a.note, ''), a.status, a.lat, a.lon
   FROM alerts a
   JOIN users u ON u.id = a.user_id
   LEFT JOIN families f ON f.id = COALESCE(a.family_id, u.family_id)
   WHERE ($1::timestamptz IS NULL OR a.created_at < $1)
     AND ($2::text[] IS NULL OR a.type = ANY($2))
     AND ($3::uuid IS NULL OR COALESCE(a.family_id, u.family_id) = $3)
   ORDER BY a.created_at DESC LIMIT $4)
  UNION ALL
  (SELECT 'check_in', c.created_at, u.id::text, u.name,
          u.family_id::text, COALESCE(f.name, ''),
          c.note, CASE WHEN c.expires_at > now() THEN 'active' ELSE 'expired' END, c.lat, c.lon
   FROM checkins c
   JOIN users u ON u.id = c.user_id
   LEFT JOIN families f ON f.id = u.family_id
   WHERE ($1::timestamptz IS NULL OR c.created_at < $1)
     AND ($2::text[] IS NULL OR 'check_in' = ANY($2))
     AND ($3::uuid IS NULL OR u.family_id = $3)
   ORDER BY c.created_at DESC LIMIT $4)
  UNION ALL
  (SELECT 'crash', ce.occurred_at, u.id::text, u.name,
          u.family_id::text, COALESCE(f.name, ''),
          'Hard stop from ' || round(ce.speed_before_mps * 2.23694)::int || ' mph',
          ce.status, ce.lat, ce.lon
   FROM crash_events ce
   JOIN users u ON u.id = ce.user_id
   LEFT JOIN families f ON f.id = u.family_id
   WHERE ($1::timestamptz IS NULL OR ce.occurred_at < $1)
     AND ($2::text[] IS NULL OR 'crash' = ANY($2))
     AND ($3::uuid IS NULL OR u.family_id = $3)
   ORDER BY ce.occurred_at DESC LIMIT $4)
) feed
ORDER BY at DESC
LIMIT $5`

// AdminActivityFeed is a read-only, newest-first feed of arrivals, departures,
// SOS/help alerts, check-ins and crash reports across every family. Page back
// by passing the response's next_before as ?before=.
// GET /api/admin/activity?limit&before&type=arrival,sos&family_id
func (s *Server) AdminActivityFeed(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	f, msg := parseActivityFilter(r.URL.Query())
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	var before, family, kinds any
	if f.Before != nil {
		before = *f.Before
	}
	if f.FamilyID != "" {
		family = f.FamilyID
	}
	if f.Kinds != nil {
		kinds = f.Kinds
	}
	rows, err := s.Pool.Query(r.Context(), activitySQL, before, kinds, family, f.Limit+1, f.Limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load activity")
		return
	}
	defer rows.Close()
	adminID := middleware.ClaimsFromContext(r.Context()).UserID
	redact := s.adminLocationDenied(r.Context(), adminID, "", "read activity feed coordinates", clientIP(r))
	if !redact {
		s.auditAdminView(r.Context(), adminID, "", "read activity feed coordinates", clientIP(r))
	}
	out := []activityOut{}
	for rows.Next() {
		var a activityOut
		if err := rows.Scan(&a.Kind, &a.At, &a.UserID, &a.UserName, &a.FamilyID, &a.FamilyName,
			&a.Detail, &a.Status, &a.Lat, &a.Lon); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read activity")
			return
		}
		if redact {
			a.Lat, a.Lon = nil, nil
			// Arrival/departure details are place names: location-derived too.
			if a.Kind == "arrival" || a.Kind == "departure" {
				a.Detail = ""
			}
		}
		out = append(out, a)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read activity")
		return
	}
	var next *string
	if len(out) > f.Limit {
		out = out[:f.Limit]
		ts := out[len(out)-1].At.UTC().Format(time.RFC3339Nano)
		next = &ts
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "next_before": next})
}
