package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// Wire-efficiency helpers (docs/developers/api-efficiency.md). Everything here
// is additive: a request without the new query parameters gets the exact
// response it always got, so apps 0.20-0.24 are unaffected.

const (
	// deltaMaxAge: a cursor older than this is answered with a full list, so a
	// phone that was asleep for hours never merges onto a stale base.
	deltaMaxAge = 15 * time.Minute
	// deltaSkew is subtracted from the next cursor so a change committed at the
	// same instant the response was built is never missed (merging is idempotent).
	deltaSkew = 2 * time.Second
)

// compactMemberFields is what `view=compact` keeps: the map and people list,
// without email, phone, TOTP state or account timestamps.
var compactMemberFields = []string{
	"id", "name", "role", "lat", "lon", "ts", "battery_pct", "speed_mps", "heading_deg",
	"motion_state", "accuracy_meters", "last_seen_at", "place_presence",
	"has_avatar", "avatar_version", "circle_ids", "sharing_circle_ids",
}

// parseFieldSelection returns the requested top-level field set, or nil for
// "everything". `fields=a,b` wins over `view=compact`. "id" is always kept.
func parseFieldSelection(r *http.Request, compact []string) map[string]bool {
	q := r.URL.Query()
	var names []string
	if f := strings.TrimSpace(q.Get("fields")); f != "" {
		names = strings.Split(f, ",")
	} else if q.Get("view") == "compact" && compact != nil {
		names = compact
	} else {
		return nil
	}
	set := map[string]bool{"id": true}
	for _, n := range names {
		if n = strings.TrimSpace(n); n != "" && len(n) <= 40 {
			set[n] = true
		}
	}
	return set
}

// selectFields marshals v (a slice of structs) and keeps only the named
// top-level keys of each element.
func selectFields(v any, keep map[string]bool) ([]map[string]any, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var rows []map[string]any
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, err
	}
	for _, row := range rows {
		if keep == nil {
			continue
		}
		for k := range row {
			if !keep[k] {
				delete(row, k)
			}
		}
	}
	return rows, nil
}

// deltaCursor is "<unix-ms>-<layout>": the time of the snapshot and a short
// hash of the structure of the list (which ids exist, who shares where).
// A phone sends it back as ?since=. If the structure changed the server
// answers with a full list instead of a delta, so membership, role and
// visibility changes can never be missed even though they have no timestamp.
func makeDeltaCursor(now time.Time, layout string) string {
	return strconv.FormatInt(now.Add(-deltaSkew).UnixMilli(), 10) + "-" + layout
}

func parseDeltaCursor(s string, now time.Time) (since time.Time, layout string, ok bool) {
	ms, lay, found := strings.Cut(s, "-")
	if !found || lay == "" || len(lay) > 32 {
		return time.Time{}, "", false
	}
	n, err := strconv.ParseInt(ms, 10, 64)
	if err != nil || n <= 0 {
		return time.Time{}, "", false
	}
	t := time.UnixMilli(n)
	if t.After(now.Add(time.Minute)) || now.Sub(t) > deltaMaxAge {
		return time.Time{}, "", false
	}
	return t, lay, true
}

func hashLayout(parts []string) string {
	sort.Strings(parts)
	sum := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:6])
}

// memberChangedAt is the newest timestamp that can change what a viewer sees
// of a member.
func memberChangedAt(m models.MemberWithLocation) time.Time {
	t := m.UpdatedAt
	for _, p := range []*time.Time{m.TS, m.LastSeenAt, m.AvatarUpdatedAt} {
		if p != nil && p.After(t) {
			t = *p
		}
	}
	return t
}

type listDelta struct {
	Cursor string `json:"cursor"`
	// Full is true when Items is the whole list (first sync, stale or
	// mismatched cursor): replace local state. False: merge Items by id and
	// drop every local row whose id is not in IDs (that is the tombstone).
	Full  bool             `json:"full"`
	Items []map[string]any `json:"items"`
	IDs   []string         `json:"ids"`
}

// deltaRow is one list element with what the delta logic needs to know.
type deltaRow struct {
	ID      string
	Layout  string    // structural fingerprint of this row (see makeDeltaCursor)
	Changed time.Time // newest change a viewer could see
	V       any       // the element as the legacy endpoint returns it
}

// writeDeltaList writes a list honouring ?view=, ?fields= and ?since=. legacy
// is the unchanged response (the array the endpoint always returned); without
// any of the new parameters it is written as-is.
func writeDeltaList(w http.ResponseWriter, r *http.Request, rows []deltaRow, legacy any, compact []string) {
	keep := parseFieldSelection(r, compact)
	since := r.URL.Query().Get("since")
	if keep == nil && since == "" {
		writeJSON(w, http.StatusOK, legacy)
		return
	}
	now := time.Now()
	parts := make([]string, 0, len(rows))
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		parts = append(parts, row.ID+"|"+row.Layout)
		ids = append(ids, row.ID)
	}
	layout := hashLayout(parts)
	d := listDelta{Full: true, IDs: ids, Cursor: makeDeltaCursor(now, layout)}
	out := make([]any, 0, len(rows))
	t, lay, ok := time.Time{}, "", false
	if since != "" {
		t, lay, ok = parseDeltaCursor(since, now)
	}
	if ok && lay == layout {
		d.Full = false
	}
	for _, row := range rows {
		if d.Full || row.Changed.After(t) {
			out = append(out, row.V)
		}
	}
	items, err := selectFields(out, keep)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to build list")
		return
	}
	if items == nil {
		items = []map[string]any{}
	}
	d.Items = items
	if since == "" {
		writeJSON(w, http.StatusOK, items) // field selection only: legacy array shape
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// writeMemberList writes the member list (see writeDeltaList).
func (s *Server) writeMemberList(w http.ResponseWriter, r *http.Request, members []models.MemberWithLocation) {
	rows := make([]deltaRow, 0, len(members))
	for _, m := range members {
		rows = append(rows, deltaRow{
			ID: m.ID, Changed: memberChangedAt(m), V: m,
			Layout: fmt.Sprintf("%s|%s|%t|%s|%s", m.Role, m.Name, m.Lat != nil,
				strings.Join(m.CircleIDs, ","), strings.Join(m.SharingCircleIDs, ",")),
		})
	}
	writeDeltaList(w, r, rows, members, compactMemberFields)
}
