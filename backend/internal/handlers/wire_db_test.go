package handlers

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
)

// Wire-efficiency endpoints against a real database (TEST_DATABASE_URL).

func newWireEnv(t *testing.T) *circleEnv {
	t.Helper()
	chi.RegisterMethod(QueryMethod)
	e := newCircleEnv(t)
	e.srv.QueryMethod = true
	e.rt.Get("/app/bootstrap", e.srv.Bootstrap)
	e.rt.Get("/chat/unread", e.srv.ChatUnread)
	e.rt.Get("/family/places", e.srv.ListPlaces)
	e.rt.Post("/family/places", e.srv.CreatePlace)
	e.rt.Patch("/family/places/{id}", e.srv.UpdatePlace)
	e.rt.Delete("/family/places/{id}", e.srv.DeletePlace)
	e.rt.Get("/family/members/{id}/history", e.srv.GetMemberHistory)
	e.rt.Post("/family/history/query", e.srv.HistoryQuery)
	e.rt.MethodFunc(QueryMethod, "/family/history/query", e.srv.HistoryQuery)
	e.rt.Get("/audit", e.srv.ListAudit)
	return e
}

func (e *circleEnv) raw(user, method, path string, body any, hdr map[string]string) *httptest.ResponseRecorder {
	e.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if user != "" {
		req.Header.Set("X-Test-User", e.ids[user])
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	middleware.ETag(e.rt).ServeHTTP(rec, req)
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder, v any) {
	t.Helper()
	if err := json.Unmarshal(rec.Body.Bytes(), v); err != nil {
		t.Fatalf("bad json (%d): %s", rec.Code, rec.Body.String())
	}
}

func TestMembersDeltaAndCompact(t *testing.T) {
	e := newWireEnv(t)
	e.createCircle("A", "C1", "B")
	e.createCircle("C", "Other", "D") // A must never see C or D

	// compact: same people, no email, still an array.
	var full, compact []map[string]any
	decode(t, e.raw("A", "GET", "/family/members?circle_id=all", nil, nil), &full)
	rec := e.raw("A", "GET", "/family/members?circle_id=all&view=compact", nil, nil)
	decode(t, rec, &compact)
	if len(full) != 2 || len(compact) != 2 {
		t.Fatalf("A should see exactly A and B, got %d/%d", len(full), len(compact))
	}
	for _, m := range compact {
		if _, ok := m["email"]; ok {
			t.Fatal("compact view leaked email")
		}
		if m["id"] == e.ids["C"] || m["id"] == e.ids["D"] {
			t.Fatal("saw a member of another circle")
		}
	}

	time.Sleep(2100 * time.Millisecond) // the cursor is skewed back by 2 s: let the setup writes age out
	// first sync: full + cursor
	var d listDelta
	decode(t, e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since=none", nil, nil), &d)
	if !d.Full || len(d.Items) != 2 || len(d.IDs) != 2 || d.Cursor == "" {
		t.Fatalf("first sync: %+v", d)
	}
	time.Sleep(100 * time.Millisecond)
	// nothing changed: empty delta
	var d2 listDelta
	decode(t, e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since="+d.Cursor, nil, nil), &d2)
	if d2.Full || len(d2.Items) != 0 || len(d2.IDs) != 2 {
		t.Fatalf("idle delta: %+v", d2)
	}
	// B moves: only B in the delta
	if _, err := e.pool.Exec(context.Background(), `UPDATE member_positions SET lat = 11, ts = now() WHERE user_id = $1`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	var d3 listDelta
	decode(t, e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since="+d.Cursor, nil, nil), &d3)
	if d3.Full || len(d3.Items) != 1 || d3.Items[0]["id"] != e.ids["B"] || d3.Items[0]["lat"].(float64) != 11 {
		t.Fatalf("move delta: %+v", d3)
	}
	// B leaves the circle: layout changes, full list, B gone from ids (the tombstone).
	e.mustCode("A", "DELETE", "/circles/"+e.listCircleID("A", "C1")+"/members/"+e.ids["B"], nil, 200)
	var d4 listDelta
	decode(t, e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since="+d.Cursor, nil, nil), &d4)
	if !d4.Full || len(d4.IDs) != 1 || d4.IDs[0] != e.ids["A"] {
		t.Fatalf("removal must force a full list without B: %+v", d4)
	}
	// garbage cursor behaves like a first sync, never an error
	if rec := e.raw("A", "GET", "/family/members?circle_id=all&since=%00%00", nil, nil); rec.Code != 200 {
		t.Fatalf("garbage cursor: %d", rec.Code)
	}
}

func (e *circleEnv) listCircleID(user, name string) string {
	e.t.Helper()
	_, _, raw := e.do(user, "GET", "/circles", nil)
	var rows []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		e.t.Fatal(err)
	}
	for _, r := range rows {
		if strings.HasPrefix(r.Name, name) {
			return r.ID
		}
	}
	e.t.Fatalf("circle %q not found", name)
	return ""
}

func TestETagOnRealEndpoint(t *testing.T) {
	e := newWireEnv(t)
	e.createCircle("A", "C1", "B")
	rec := e.raw("A", "GET", "/circles", nil, nil)
	tag := rec.Header().Get("ETag")
	if rec.Code != 200 || tag == "" {
		t.Fatalf("no etag: %d %v", rec.Code, rec.Header())
	}
	rec = e.raw("A", "GET", "/circles", nil, map[string]string{"If-None-Match": tag})
	if rec.Code != 304 || rec.Body.Len() != 0 {
		t.Fatalf("expected 304, got %d", rec.Code)
	}
	// Another user with the same validator must not get a 304 for their own (different) body.
	rec = e.raw("C", "GET", "/circles", nil, map[string]string{"If-None-Match": tag})
	if rec.Code == 304 {
		t.Fatal("validator matched across users")
	}
	e.createCircle("A", "C2", "B")
	rec = e.raw("A", "GET", "/circles", nil, map[string]string{"If-None-Match": tag})
	if rec.Code != 200 {
		t.Fatalf("changed data must return 200, got %d", rec.Code)
	}
}

func TestPlacesDelta(t *testing.T) {
	e := newWireEnv(t)
	// Places live in the legacy family; give A and B one.
	var fam string
	ctx := context.Background()
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('wire') RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM families WHERE id = $1`, fam)
	})
	for _, n := range []string{"A", "B"} {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = 'admin' WHERE id = $2`, fam, e.ids[n]); err != nil {
			t.Fatal(err)
		}
	}
	var p1, p2 string
	for i, dst := range []*string{&p1, &p2} {
		if err := e.pool.QueryRow(ctx, `INSERT INTO places (family_id, name, type, geom, radius_meters) VALUES ($1,$2,'custom', ST_SetSRID(ST_MakePoint(-0.1,51.5),4326), 100) RETURNING id`,
			fam, []string{"Home", "School"}[i]).Scan(dst); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(2100 * time.Millisecond) // the cursor is skewed back by 2 s: let the setup writes age out
	var d listDelta
	decode(t, e.raw("A", "GET", "/family/places?since=none", nil, nil), &d)
	if !d.Full || len(d.Items) != 2 {
		t.Fatalf("first: %+v", d)
	}
	time.Sleep(100 * time.Millisecond)
	if _, err := e.pool.Exec(ctx, `UPDATE places SET name = 'Home 2' WHERE id = $1`, p1); err != nil {
		t.Fatal(err)
	}
	var d2 listDelta
	decode(t, e.raw("A", "GET", "/family/places?since="+d.Cursor, nil, nil), &d2)
	if d2.Full || len(d2.Items) != 1 || d2.Items[0]["name"] != "Home 2" || len(d2.IDs) != 2 {
		t.Fatalf("edit delta (trigger should bump updated_at): %+v", d2)
	}
	if _, err := e.pool.Exec(ctx, `DELETE FROM places WHERE id = $1`, p2); err != nil {
		t.Fatal(err)
	}
	var d3 listDelta
	decode(t, e.raw("A", "GET", "/family/places?since="+d.Cursor, nil, nil), &d3)
	if !d3.Full || len(d3.IDs) != 1 || d3.IDs[0] != p1 {
		t.Fatalf("delete must show as a shorter ids list: %+v", d3)
	}
	// legacy call unchanged: plain array
	var legacy []map[string]any
	decode(t, e.raw("A", "GET", "/family/places", nil, nil), &legacy)
	if len(legacy) != 1 {
		t.Fatalf("legacy: %v", legacy)
	}
	// An outsider (no family) sees nothing of it.
	if rec := e.raw("C", "GET", "/family/places?since=none", nil, nil); rec.Code == 200 && strings.Contains(rec.Body.String(), p1) {
		t.Fatal("outsider saw a place")
	}
}

func TestBootstrapShapeAndAuthz(t *testing.T) {
	e := newWireEnv(t)
	e.createCircle("A", "C1", "B")
	e.createCircle("C", "Other", "D")
	rec := e.raw("A", "GET", "/app/bootstrap", nil, nil)
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	var b struct {
		ServerTime string            `json:"server_time"`
		Features   map[string]string `json:"features"`
		Wire       map[string]any    `json:"wire"`
		Circles    []map[string]any  `json:"circles"`
		Members    listDelta         `json:"members"`
		Unread     json.RawMessage   `json:"unread"`
		Errors     map[string]int    `json:"errors"`
	}
	decode(t, rec, &b)
	if b.ServerTime == "" || b.Features["wire_v2"] == "" || b.Wire["bootstrap"] != true || b.Wire["query"] != true {
		t.Fatalf("missing envelope fields: %s", rec.Body.String())
	}
	if len(b.Circles) != 1 || len(b.Members.Items) != 2 || b.Members.Cursor == "" || len(b.Errors) != 0 {
		t.Fatalf("shape: circles=%d members=%d errors=%v", len(b.Circles), len(b.Members.Items), b.Errors)
	}
	for _, m := range b.Members.Items {
		if _, ok := m["email"]; ok || m["id"] == e.ids["C"] || m["id"] == e.ids["D"] {
			t.Fatalf("leak in bootstrap members: %v", m)
		}
	}
	if len(b.Unread) == 0 {
		t.Fatal("unread missing")
	}
	// 304 on repeat
	tag := rec.Header().Get("ETag")
	if tag == "" {
		t.Fatal("bootstrap not ETag'd")
	}
	// the body embeds server_time, so a repeat differs; ETag is still set and valid for the exact body.
	// A user with no circle gets nulls plus error codes, not a failure.
	rec = e.raw("E", "GET", "/app/bootstrap", nil, nil)
	var b2 struct {
		Members json.RawMessage `json:"members"`
		Errors  map[string]int  `json:"errors"`
	}
	decode(t, rec, &b2)
	if rec.Code != 200 || string(b2.Members) != "null" || b2.Errors["members"] != 404 {
		t.Fatalf("no-circle user: %d %s", rec.Code, rec.Body.String())
	}
	if rec := e.raw("", "GET", "/app/bootstrap", nil, nil); rec.Code != 401 {
		t.Fatalf("unauthenticated: %d", rec.Code)
	}
}

func seedTrail(t *testing.T, e *circleEnv, user string, n int, end time.Time) {
	t.Helper()
	ctx := context.Background()
	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1,'android','w') RETURNING id`, e.ids[user]).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO locations (device_id, ts, geom, speed_mps, battery_pct, motion_state, source)
		SELECT $1, $2::timestamptz - (g * interval '30 seconds'),
		       ST_SetSRID(ST_MakePoint(-0.1 + g*0.00005, 51.5 + g*0.00005 + 0.00002*(g%3)), 4326), 5, 80, 'moving', 'gps'
		FROM generate_series(0, $3::int - 1) g`, dev, end, n); err != nil {
		t.Fatal(err)
	}
}

func TestHistorySimplifyAndQuery(t *testing.T) {
	e := newWireEnv(t)
	e.createCircle("A", "C1", "B")
	e.createCircle("C", "Other", "D")
	now := time.Now().UTC()
	seedTrail(t, e, "B", 600, now)
	seedTrail(t, e, "D", 50, now)
	win := func(h int) map[string]string {
		return map[string]string{"from": now.Add(-time.Duration(h) * time.Hour).Format(time.RFC3339), "to": now.Add(time.Minute).Format(time.RFC3339)}
	}
	q := "?from=" + win(6)["from"] + "&to=" + win(6)["to"]
	type hist struct {
		Trail []trailPoint `json:"trail"`
	}
	var raw, thin hist
	decode(t, e.raw("A", "GET", "/family/members/"+e.ids["B"]+"/history"+q, nil, nil), &raw)
	decode(t, e.raw("A", "GET", "/family/members/"+e.ids["B"]+"/history"+q+"&simplify=25&max_points=40", nil, nil), &thin)
	if len(raw.Trail) < 100 {
		t.Fatalf("seed not visible: %d", len(raw.Trail))
	}
	if len(thin.Trail) > 40 || len(thin.Trail) < 2 {
		t.Fatalf("not bounded: %d", len(thin.Trail))
	}
	if thin.Trail[0].TS != raw.Trail[0].TS || thin.Trail[len(thin.Trail)-1].TS != raw.Trail[len(raw.Trail)-1].TS {
		t.Fatal("endpoints must be preserved")
	}
	if rec := e.raw("A", "GET", "/family/members/"+e.ids["B"]+"/history"+q+"&max_points=3", nil, nil); rec.Code != 400 {
		t.Fatalf("bound: %d", rec.Code)
	}
	// Authz: A may not read D (another circle), by GET or by QUERY/POST.
	if rec := e.raw("A", "GET", "/family/members/"+e.ids["D"]+"/history"+q, nil, nil); rec.Code != 403 {
		t.Fatalf("outsider GET: %d", rec.Code)
	}
	body := map[string]any{"member_id": e.ids["B"], "windows": []map[string]string{win(6), win(2), {"from": "bad", "to": "worse"}}, "max_points": 30}
	for _, method := range []string{"POST", "QUERY"} {
		rec := e.raw("A", method, "/family/history/query", body, nil)
		if rec.Code != 200 || rec.Header().Get("Accept-Query") == "" {
			t.Fatalf("%s: %d %s", method, rec.Code, rec.Body.String())
		}
		var out struct {
			Results []struct {
				Status  int   `json:"status"`
				History *hist `json:"history"`
			} `json:"results"`
		}
		decode(t, rec, &out)
		if len(out.Results) != 3 || out.Results[0].Status != 200 || len(out.Results[0].History.Trail) > 30 || out.Results[2].Status != 400 {
			t.Fatalf("%s results: %s", method, rec.Body.String())
		}
	}
	denied := map[string]any{"member_id": e.ids["D"], "windows": []map[string]string{win(6)}}
	for _, method := range []string{"POST", "QUERY"} {
		rec := e.raw("A", method, "/family/history/query", denied, nil)
		var out struct {
			Results []struct {
				Status int `json:"status"`
			} `json:"results"`
		}
		decode(t, rec, &out)
		if rec.Code != 200 || out.Results[0].Status != 403 || strings.Contains(rec.Body.String(), `"trail"`) {
			t.Fatalf("%s outsider: %s", method, rec.Body.String())
		}
	}
	// Flag off: QUERY refused, POST fine.
	e.srv.QueryMethod = false
	if rec := e.raw("A", "QUERY", "/family/history/query", body, nil); rec.Code != 405 {
		t.Fatalf("flag off QUERY: %d", rec.Code)
	}
	if rec := e.raw("A", "POST", "/family/history/query", body, nil); rec.Code != 200 {
		t.Fatalf("flag off POST: %d", rec.Code)
	}
}

func TestAuditPagination(t *testing.T) {
	e := newWireEnv(t)
	ctx := context.Background()
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('wire-audit') RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM audit_log WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(context.Background(), `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM families WHERE id = $1`, fam)
	})
	if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = 'admin' WHERE id = $2`, fam, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO audit_log (user_id, family_id, action, detail, created_at)
		SELECT $2, $1, 'test', 'row ' || g, now() - g * interval '1 minute' FROM generate_series(1, 25) g`, fam, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	seen := map[float64]bool{}
	path := "/audit?limit=10"
	pages := 0
	for path != "" {
		rec := e.raw("A", "GET", path, nil, nil)
		if rec.Code != 200 {
			t.Fatalf("%d %s", rec.Code, rec.Body.String())
		}
		var rows []map[string]any
		decode(t, rec, &rows)
		if len(rows) > 10 {
			t.Fatalf("page too big: %d", len(rows))
		}
		for _, r := range rows {
			id := r["id"].(float64)
			if seen[id] {
				t.Fatalf("duplicate across pages: %v", id)
			}
			seen[id] = true
		}
		pages++
		next := rec.Header().Get("X-Next-Cursor")
		path = ""
		if next != "" {
			path = "/audit?limit=10&before=" + strings.ReplaceAll(next, "+", "%2B")
		}
		if pages > 5 {
			t.Fatal("runaway paging")
		}
	}
	if len(seen) != 25 {
		t.Fatalf("expected 25 rows over pages, got %d", len(seen))
	}
	for _, bad := range []string{"limit=0", "limit=201", "limit=x", "before=notatime"} {
		if rec := e.raw("A", "GET", "/audit?"+bad, nil, nil); rec.Code != 400 {
			t.Errorf("%s: %d", bad, rec.Code)
		}
	}
	_ = http.StatusOK
}

// TestWireMeasure prints payload sizes for the endpoints a phone hits at start
// and on the map, raw and gzip, before/after the wire features. Opt-in
// (OF_WIRE_MEASURE=1) and meant for docs/developers/api-efficiency.md; the
// numbers are from this server with seeded data, not from a phone.
func TestWireMeasure(t *testing.T) {
	if os.Getenv("OF_WIRE_MEASURE") != "1" {
		t.Skip("set OF_WIRE_MEASURE=1")
	}
	e := newWireEnv(t)
	cid := e.createCircle("A", "Family", "B", "C", "D", "E", "P")
	_ = cid
	now := time.Now().UTC()
	seedTrail(t, e, "B", 2900, now) // ~24 h at one fix per 30 s
	gz := func(b []byte) int {
		var buf bytes.Buffer
		w, _ := gzip.NewWriterLevel(&buf, gzip.BestSpeed)
		_, _ = w.Write(b)
		_ = w.Close()
		return buf.Len()
	}
	row := func(label string, rec *httptest.ResponseRecorder) {
		t.Logf("WIREMETRIC %-46s status=%d raw=%6d gzip=%6d", label, rec.Code, rec.Body.Len(), gz(rec.Body.Bytes()))
	}
	row("GET /circles", e.raw("A", "GET", "/circles", nil, nil))
	row("GET /family/members?circle_id=all (legacy)", e.raw("A", "GET", "/family/members?circle_id=all", nil, nil))
	row("GET /family/members ...&view=compact", e.raw("A", "GET", "/family/members?circle_id=all&view=compact", nil, nil))
	var d listDelta
	rec := e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since=none", nil, nil)
	decode(t, rec, &d)
	row("GET members compact, first delta sync (full)", rec)
	time.Sleep(2200 * time.Millisecond)
	row("GET members compact, idle delta (nothing new)", e.raw("A", "GET", "/family/members?circle_id=all&view=compact&since="+d.Cursor, nil, nil))
	full := e.raw("A", "GET", "/family/members?circle_id=all", nil, nil)
	r304 := e.raw("A", "GET", "/family/members?circle_id=all", nil, map[string]string{"If-None-Match": full.Header().Get("ETag")})
	t.Logf("WIREMETRIC %-46s status=%d raw=%6d (headers only)", "GET members legacy, repeat with If-None-Match", r304.Code, r304.Body.Len())
	from, to := now.Add(-25*time.Hour+time.Minute).Format(time.RFC3339), now.Add(time.Minute).Format(time.RFC3339)
	h := "/family/members/" + e.ids["B"] + "/history?from=" + from + "&to=" + to
	row("GET history 24h (legacy, 30 s buckets)", e.raw("A", "GET", h, nil, nil))
	row("GET history 24h ?simplify=15&max_points=300", e.raw("A", "GET", h+"&simplify=15&max_points=300", nil, nil))
	row("GET history 24h ?max_points=100 (map thumbnail)", e.raw("A", "GET", h+"&max_points=100", nil, nil))
	bs := e.raw("A", "GET", "/app/bootstrap", nil, nil)
	row("GET /app/bootstrap (circles+members+unread+compat)", bs)
	var hv struct {
		Trail  []json.RawMessage `json:"trail"`
		Visits []json.RawMessage `json:"visits"`
	}
	decode(t, e.raw("A", "GET", h, nil, nil), &hv)
	t.Logf("WIREMETRIC legacy history has %d trail points and %d visits", len(hv.Trail), len(hv.Visits))
	legacyTotal := 0
	for _, p := range []string{"/circles", "/family/members?circle_id=all", "/chat/unread"} {
		legacyTotal += e.raw("A", "GET", p, nil, nil).Body.Len()
	}
	t.Logf("WIREMETRIC cold start, the three data requests (circles, members, unread) = 3 requests, %d bytes raw; bootstrap = 1 request (compact members + compat + features), %d bytes raw", legacyTotal, bs.Body.Len())
}
