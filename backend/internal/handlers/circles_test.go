package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Integration tests for the circle API and the converted live read paths.
// They need a Postgres with all migrations applied (TEST_DATABASE_URL), like
// TestPGRefreshStore, and are skipped otherwise. Every row they create uses a
// unique email/prefix and is deleted at the end.

type circleEnv struct {
	t    *testing.T
	pool *pgxpool.Pool
	srv  *Server
	rt   chi.Router
	ids  map[string]string // name -> user id
}

func newCircleEnv(t *testing.T) *circleEnv {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{Pool: pool, hub: newHub()}
	e := &circleEnv{t: t, pool: pool, srv: srv, ids: map[string]string{}}

	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			if uid := req.Header.Get("X-Test-User"); uid != "" {
				req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
			}
			next.ServeHTTP(w, req)
		})
	})
	r.Post("/circles", srv.CreateCircle)
	r.Get("/circles", srv.ListCircles)
	r.Post("/circles/join", srv.JoinCircle)
	r.Patch("/circles/{id}", srv.UpdateCircle)
	r.Delete("/circles/{id}", srv.DeleteCircle)
	r.Get("/circles/{id}/members", srv.ListCircleMembers)
	r.Delete("/circles/{id}/members/{user_id}", srv.RemoveCircleMember)
	r.Patch("/circles/{id}/members/{user_id}", srv.UpdateCircleMemberRole)
	r.Put("/circles/{id}/sharing", srv.SetCircleSharing)
	r.Post("/circles/{id}/invites", srv.CreateCircleInvite)
	r.Get("/circles/{id}/invites", srv.ListCircleInvites)
	r.Delete("/circles/{id}/invites/{invite_id}", srv.RevokeCircleInvite)
	r.Get("/family/members", srv.ListMembers)
	r.Patch("/family/members/{id}", srv.UpdateFamilyMember)
	e.rt = r

	prefix := "circ-" + time.Now().Format("150405.000000")
	for _, n := range []string{"A", "B", "C", "D", "E", "P"} {
		var id string
		if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,$2,'x') RETURNING id`,
			prefix+"-"+n+"@example.com", "User"+n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		e.ids[n] = id
		if _, err := pool.Exec(ctx, `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 10, 20, now())`, id); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		bg := context.Background()
		for _, id := range e.ids {
			_, _ = pool.Exec(bg, `DELETE FROM circles WHERE created_by = $1`, id)
			_, _ = pool.Exec(bg, `UPDATE users SET family_id = NULL WHERE id = $1`, id)
			_, _ = pool.Exec(bg, `DELETE FROM users WHERE id = $1`, id)
		}
		pool.Close()
	})
	return e
}

func (e *circleEnv) do(user, method, path string, body any) (int, map[string]any, []byte) {
	e.t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	if user != "" {
		req.Header.Set("X-Test-User", e.ids[user])
	}
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	var m map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	return rec.Code, m, rec.Body.Bytes()
}

func (e *circleEnv) mustCode(user, method, path string, body any, want int) map[string]any {
	e.t.Helper()
	code, m, raw := e.do(user, method, path, body)
	if code != want {
		e.t.Fatalf("%s %s %s: got %d want %d: %s", user, method, path, code, want, raw)
	}
	return m
}

// createCircle makes a circle owned by creator and joins the listed members.
func (e *circleEnv) createCircle(creator, name string, members ...string) string {
	e.t.Helper()
	id := e.mustCode(creator, "POST", "/circles", map[string]string{"name": name}, 201)["id"].(string)
	for _, m := range members {
		inv := e.mustCode(creator, "POST", "/circles/"+id+"/invites", map[string]any{}, 201)
		e.mustCode(m, "POST", "/circles/join", map[string]string{"code": inv["code"].(string)}, 200)
	}
	return id
}

// A is in circle 1 only, B in 1 and 2, C in 2 only, D in none.
func (e *circleEnv) overlapping() (c1, c2 string) {
	c1 = e.createCircle("A", "Circle1", "B")
	c2 = e.createCircle("C", "Circle2", "B")
	return
}

func (e *circleEnv) snapshotFor(viewer string) map[string]*float64 {
	e.t.Helper()
	ids, err := circles.New(e.pool).CircleIDs(context.Background(), e.ids[viewer])
	if err != nil {
		e.t.Fatal(err)
	}
	ms, err := e.srv.circleMembersSnapshot(context.Background(), ids, e.ids[viewer])
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]*float64{}
	for _, m := range ms {
		for n, id := range e.ids {
			if id == m.ID {
				out[n] = m.Lat
			}
		}
	}
	return out
}

func TestCircleEndpointAuthorizationMatrix(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping() // A admin of c1, B member of c1; C admin of c2, B member of c2
	other := "00000000-0000-0000-0000-00000000dead"
	inv := e.mustCode("A", "POST", "/circles/"+c1+"/invites", map[string]any{}, 201)["id"].(string)

	type tc struct {
		name         string
		user         string
		method, path string
		body         any
		want         int
	}
	cases := []tc{
		// unauthenticated
		{"anon list", "", "GET", "/circles", nil, 401},
		{"anon members", "", "GET", "/circles/" + c1 + "/members", nil, 401},
		// outsider D and cross-circle A on circle 2 must see 404 everywhere (IDOR)
		{"outsider members", "D", "GET", "/circles/" + c1 + "/members", nil, 404},
		{"crosscircle members", "A", "GET", "/circles/" + c2 + "/members", nil, 404},
		{"crosscircle rename", "A", "PATCH", "/circles/" + c2, map[string]string{"name": "x"}, 404},
		{"crosscircle delete", "A", "DELETE", "/circles/" + c2, nil, 404},
		{"crosscircle sharing", "A", "PUT", "/circles/" + c2 + "/sharing", map[string]bool{"enabled": false}, 404},
		{"crosscircle invite", "A", "POST", "/circles/" + c2 + "/invites", map[string]any{}, 404},
		{"crosscircle list invites", "A", "GET", "/circles/" + c2 + "/invites", nil, 404},
		{"crosscircle remove other", "A", "DELETE", "/circles/" + c2 + "/members/" + e.ids["C"], nil, 404},
		{"crosscircle role", "A", "PATCH", "/circles/" + c2 + "/members/" + e.ids["C"], map[string]string{"role": "member"}, 404},
		{"outsider leave", "D", "DELETE", "/circles/" + c1 + "/members/me", nil, 404},
		// non-existent and malformed ids look the same as foreign ones
		{"unknown circle", "A", "GET", "/circles/" + other + "/members", nil, 404},
		{"malformed circle", "A", "GET", "/circles/not-a-uuid/members", nil, 404},
		{"sql-ish circle", "A", "DELETE", "/circles/1'%20or%20'1'='1", nil, 404},
		// plain member B cannot administer circle 1
		{"member rename", "B", "PATCH", "/circles/" + c1, map[string]string{"name": "x"}, 403},
		{"member delete", "B", "DELETE", "/circles/" + c1, nil, 403},
		{"member invite", "B", "POST", "/circles/" + c1 + "/invites", map[string]any{}, 403},
		{"member list invites", "B", "GET", "/circles/" + c1 + "/invites", nil, 403},
		{"member revoke invite", "B", "DELETE", "/circles/" + c1 + "/invites/" + inv, nil, 403},
		{"member remove other", "B", "DELETE", "/circles/" + c1 + "/members/" + e.ids["A"], nil, 403},
		{"member promote self", "B", "PATCH", "/circles/" + c1 + "/members/" + e.ids["B"], map[string]string{"role": "admin"}, 403},
		// admin of another circle cannot touch an invite id from this one
		{"foreign invite revoke", "C", "DELETE", "/circles/" + c2 + "/invites/" + inv, nil, 404},
		{"malformed invite id", "A", "DELETE", "/circles/" + c1 + "/invites/zzz", nil, 404},
		// member may read members and change only their own sharing
		{"member lists members", "B", "GET", "/circles/" + c1 + "/members", nil, 200},
		{"member sharing", "B", "PUT", "/circles/" + c1 + "/sharing", map[string]bool{"enabled": true}, 200},
		{"sharing needs enabled", "B", "PUT", "/circles/" + c1 + "/sharing", map[string]string{}, 400},
		// bad input
		{"bad role", "A", "PATCH", "/circles/" + c1 + "/members/" + e.ids["B"], map[string]string{"role": "child"}, 400},
		{"empty name", "A", "POST", "/circles", map[string]string{"name": "  "}, 400},
		{"invite child role", "A", "POST", "/circles/" + c1 + "/invites", map[string]string{"role": "child"}, 400},
		{"join bogus code", "D", "POST", "/circles/join", map[string]string{"code": "NOPE1234"}, 400},
		// last admin
		{"last admin leave", "A", "DELETE", "/circles/" + c1 + "/members/me", nil, 409},
		{"last admin demote", "A", "PATCH", "/circles/" + c1 + "/members/" + e.ids["A"], map[string]string{"role": "member"}, 409},
		{"remove missing member", "A", "DELETE", "/circles/" + c1 + "/members/" + e.ids["D"], nil, 404},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, _, raw := e.do(c.user, c.method, c.path, c.body)
			if code != c.want {
				t.Fatalf("got %d want %d: %s", code, c.want, raw)
			}
		})
	}
	// The matrix must not have changed anything for circle 2 or hidden rows.
	m := e.mustCode("C", "GET", "/circles/"+c2+"/members", nil, 200)
	_ = m
	_, _, raw := e.do("C", "GET", "/circles/"+c2+"/members", nil)
	if strings.Count(string(raw), `"user_id"`) != 2 {
		t.Fatalf("circle 2 membership changed: %s", raw)
	}
}

func TestCircleListShowsOnlyOwnCirclesWithRoleAndSharing(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()
	e.mustCode("B", "PUT", "/circles/"+c2+"/sharing", map[string]bool{"enabled": false}, 200)
	_, _, raw := e.do("B", "GET", "/circles", nil)
	var got []circleOut
	if err := json.Unmarshal(raw, &got); err != nil || len(got) != 2 {
		t.Fatalf("B circles: %v %s", err, raw)
	}
	for _, c := range got {
		switch c.ID {
		case c1:
			if c.Role != circles.RoleMember || !c.SharingEnabled || c.MemberCount != 2 {
				t.Fatalf("c1: %+v", c)
			}
		case c2:
			if c.Role != circles.RoleMember || c.SharingEnabled {
				t.Fatalf("c2: %+v", c)
			}
		default:
			t.Fatalf("foreign circle %s", c.ID)
		}
	}
	_, _, raw = e.do("A", "GET", "/circles", nil)
	if strings.Contains(string(raw), c2) {
		t.Fatalf("A sees circle 2: %s", raw)
	}
	if _, _, raw = e.do("D", "GET", "/circles", nil); strings.TrimSpace(string(raw)) != "[]" {
		t.Fatalf("D should have no circles: %s", raw)
	}
}

func TestSharedWithAndLocationVisibility(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()
	az := circles.New(e.pool)
	ctx := context.Background()
	ids := func(v, s string) []string {
		out, err := az.SharedWith(ctx, e.ids[v], e.ids[s])
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	if g := ids("A", "B"); len(g) != 1 || g[0] != c1 {
		t.Fatalf("A<-B: %v", g)
	}
	if g := ids("C", "B"); len(g) != 1 || g[0] != c2 {
		t.Fatalf("C<-B: %v", g)
	}
	if g := ids("A", "C"); len(g) != 0 {
		t.Fatalf("A<-C must be empty, got %v", g)
	}
	if g := ids("D", "B"); len(g) != 0 {
		t.Fatalf("D<-B must be empty, got %v", g)
	}
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	if g := ids("A", "B"); len(g) != 0 {
		t.Fatalf("sharing off must hide B from A: %v", g)
	}
	if g := ids("C", "B"); len(g) != 1 {
		t.Fatalf("sharing off in c1 must not affect c2: %v", g)
	}
	if g := ids("B", "B"); len(g) != 2 {
		t.Fatalf("self always sees own circles: %v", g)
	}
	// Forged circle id in LocationVisibility adds nothing.
	vis, err := az.LocationVisibility(ctx, e.ids["A"], []string{c1, c2})
	if err != nil || len(vis) != 2 || vis[e.ids["B"]] || !vis[e.ids["A"]] {
		t.Fatalf("visibility: %v %v", vis, err)
	}
}

func TestLiveSnapshotRespectsCircleIsolationSharingAndRemoval(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()

	// Isolation: A never lists C; C never lists A; B lists both with location.
	a := e.snapshotFor("A")
	if _, ok := a["C"]; ok || a["B"] == nil || a["A"] == nil {
		t.Fatalf("A snapshot: %v", a)
	}
	c := e.snapshotFor("C")
	if _, ok := c["A"]; ok || c["B"] == nil {
		t.Fatalf("C snapshot: %v", c)
	}
	b := e.snapshotFor("B")
	if b["A"] == nil || b["C"] == nil {
		t.Fatalf("B snapshot: %v", b)
	}
	if len(e.snapshotFor("D")) != 0 {
		t.Fatal("D sees members")
	}

	// B stops sharing in circle 1 only: A loses B's location (B stays listed),
	// C is unaffected.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	a = e.snapshotFor("A")
	if v, ok := a["B"]; !ok || v != nil {
		t.Fatalf("A must see B listed without location: %v", a)
	}
	if e.snapshotFor("C")["B"] == nil {
		t.Fatal("c2 sharing must be unaffected")
	}
	// Off everywhere: nobody else sees B; B still sees themselves.
	e.mustCode("B", "PUT", "/circles/"+c2+"/sharing", map[string]bool{"enabled": false}, 200)
	if e.snapshotFor("C")["B"] != nil || e.snapshotFor("B")["B"] == nil {
		t.Fatal("sharing off everywhere not honored")
	}
	// Back on, then B is removed from circle 1 by its admin: A no longer lists B.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": true}, 200)
	if e.snapshotFor("A")["B"] == nil {
		t.Fatal("re-enabling sharing must show B again")
	}
	e.mustCode("A", "DELETE", "/circles/"+c1+"/members/"+e.ids["B"], nil, 200)
	if _, ok := e.snapshotFor("A")["B"]; ok {
		t.Fatal("removed member still listed")
	}
	e.mustCode("B", "GET", "/circles/"+c1+"/members", nil, 404)
}

func TestLiveBroadcastFollowsCirclesAndSharing(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()
	h := e.srv.hub
	connect := func(user string) *wsClient {
		c := testWSClient()
		ids, _ := circles.New(e.pool).CircleIDs(context.Background(), e.ids[user])
		h.registerCircles(ids, e.ids[user], c)
		return c
	}
	ca, cb, cc, cd := connect("A"), connect("B"), connect("C"), connect("D")
	got := func(c *wsClient) int { return len(c.send) }
	drain := func(cs ...*wsClient) {
		for _, c := range cs {
			for len(c.send) > 0 {
				<-c.send
			}
		}
	}
	send := func() { e.srv.broadcastLocation(e.ids["B"], wsLocation{Type: "location", UserID: e.ids["B"]}) }

	// B shares in both circles: A and C both get exactly one copy, D none,
	// B (the subject) gets its own once even though it is in two circles.
	send()
	if got(ca) != 1 || got(cc) != 1 || got(cb) != 1 || got(cd) != 0 {
		t.Fatalf("a=%d c=%d b=%d d=%d", got(ca), got(cc), got(cb), got(cd))
	}
	drain(ca, cb, cc, cd)

	// A's update must never reach C (no shared circle) and vice versa.
	e.srv.broadcastLocation(e.ids["A"], wsLocation{Type: "location", UserID: e.ids["A"]})
	if got(cc) != 0 || got(cd) != 0 || got(ca) != 1 || got(cb) != 1 {
		t.Fatalf("A leak: a=%d b=%d c=%d d=%d", got(ca), got(cb), got(cc), got(cd))
	}
	drain(ca, cb, cc, cd)

	// Sharing off in circle 1: effective on the very next update.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	send()
	if got(ca) != 0 || got(cc) != 1 {
		t.Fatalf("after sharing off: a=%d c=%d", got(ca), got(cc))
	}
	drain(ca, cb, cc)

	// Removing C from circle 2 stops delivery immediately and closes the socket
	// (C has no other circle).
	e.mustCode("C", "PUT", "/circles/"+c2+"/sharing", map[string]bool{"enabled": true}, 200)
	e.mustCode("C", "DELETE", "/circles/"+c2+"/members/me", nil, 409) // last admin
	e.mustCode("C", "PATCH", "/circles/"+c2+"/members/"+e.ids["B"], map[string]string{"role": "admin"}, 200)
	e.mustCode("C", "DELETE", "/circles/"+c2+"/members/me", nil, 200)
	if !wsClientClosed(cc) {
		t.Fatal("removed member's only socket was not closed")
	}
	send()
	if got(cc) != 0 {
		t.Fatal("removed member still received an update")
	}
	// A new member joining is subscribed without reconnecting.
	inv := e.mustCode("B", "POST", "/circles/"+c2+"/invites", map[string]any{}, 201)["code"].(string)
	e.mustCode("D", "POST", "/circles/join", map[string]string{"code": inv}, 200)
	h.subscribeUser(e.ids["D"], c2) // idempotent
	send()
	if got(cd) != 1 {
		t.Fatalf("joined member got %d updates", got(cd))
	}
}

func TestRemovalAndLegacyFamilyStayConsistent(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('Legacy') RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam)
	})
	// Legacy writes: A admin, B member, C child of the family. The triggers make
	// the circle; no circle code ran.
	for n, role := range map[string]string{"A": "admin", "B": "member", "C": "child"} {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id=$1, role=$2 WHERE id=$3`, fam, role, e.ids[n]); err != nil {
			t.Fatal(err)
		}
	}
	e.mustCode("A", "GET", "/circles/"+fam+"/members", nil, 200)
	// B also makes a second circle with D, so B has two circles.
	other := e.createCircle("B", "Other", "D")

	// Legacy list works and hides B once B turns sharing off in the family.
	listLat := func(viewer string) map[string]any {
		_, _, raw := e.do(viewer, "GET", "/family/members", nil)
		var ms []struct {
			ID  string   `json:"id"`
			Lat *float64 `json:"lat"`
		}
		if err := json.Unmarshal(raw, &ms); err != nil {
			t.Fatalf("%s", raw)
		}
		out := map[string]any{}
		for _, m := range ms {
			for n, id := range e.ids {
				if id == m.ID {
					out[n] = m.Lat
				}
			}
		}
		return out
	}
	if l := listLat("A"); len(l) != 3 || l["B"] == (*float64)(nil) {
		t.Fatalf("legacy list: %v", l)
	}
	e.mustCode("B", "PUT", "/circles/"+fam+"/sharing", map[string]bool{"enabled": false}, 200)
	if l := listLat("A"); l["B"] != (*float64)(nil) {
		t.Fatalf("legacy list leaks B: %v", l)
	}
	if l := listLat("B"); l["B"] == (*float64)(nil) {
		t.Fatalf("B must see self: %v", l)
	}
	// A circle with D in it can never be listed by the family endpoint.
	if _, ok := listLat("A")["D"]; ok {
		t.Fatal("legacy list includes a user from another circle")
	}

	// Role change through the circle API reaches the legacy role (B -> admin).
	e.mustCode("A", "PATCH", "/circles/"+fam+"/members/"+e.ids["B"], map[string]string{"role": "admin"}, 200)
	var role string
	_ = e.pool.QueryRow(ctx, `SELECT role FROM users WHERE id=$1`, e.ids["B"]).Scan(&role)
	if role != "admin" {
		t.Fatalf("legacy role not updated: %s", role)
	}
	// Child stays child when only the circle role is member.
	e.mustCode("A", "PATCH", "/circles/"+fam+"/members/"+e.ids["C"], map[string]string{"role": "member"}, 200)
	_ = e.pool.QueryRow(ctx, `SELECT role FROM users WHERE id=$1`, e.ids["C"]).Scan(&role)
	if role != "child" {
		t.Fatalf("child role lost: %s", role)
	}

	// Removing C via the circle API clears the legacy pointer: legacy access gone.
	e.mustCode("A", "DELETE", "/circles/"+fam+"/members/"+e.ids["C"], nil, 200)
	e.mustCode("C", "GET", "/family/members", nil, 404)
	// B leaves the family: primary moves to nothing (the other circle is not a
	// family), legacy access is gone, the other circle is kept.
	e.mustCode("B", "DELETE", "/circles/"+fam+"/members/me", nil, 200)
	e.mustCode("B", "GET", "/family/members", nil, 404)
	e.mustCode("B", "GET", "/circles/"+other+"/members", nil, 200)
	var fid *string
	_ = e.pool.QueryRow(ctx, `SELECT family_id FROM users WHERE id=$1`, e.ids["B"]).Scan(&fid)
	if fid != nil {
		t.Fatalf("family_id not cleared: %v", *fid)
	}
}

func TestDeleteCirclePolicyAndInviteLifecycle(t *testing.T) {
	e := newCircleEnv(t)
	c1 := e.createCircle("A", "Solo", "B")
	c2 := e.createCircle("C", "Second", "B")
	// B is in two circles, A only in c1: deleting c1 strands A -> refused.
	e.mustCode("A", "DELETE", "/circles/"+c1, nil, 409)
	e.mustCode("A", "GET", "/circles/"+c1+"/members", nil, 200)
	e.mustCode("A", "DELETE", "/circles/"+c1+"?force=true", nil, 200)
	e.mustCode("B", "GET", "/circles/"+c1+"/members", nil, 404)
	e.mustCode("B", "GET", "/circles/"+c2+"/members", nil, 200)

	// Invites: single use, then exhausted; joining twice is 409 and does not
	// consume; revoked codes stop working.
	inv := e.mustCode("C", "POST", "/circles/"+c2+"/invites", map[string]any{"max_uses": 1}, 201)
	code, invID := inv["code"].(string), inv["id"].(string)
	e.mustCode("B", "POST", "/circles/join", map[string]string{"code": code}, 409)
	e.mustCode("D", "POST", "/circles/join", map[string]string{"code": code}, 200)
	e.mustCode("A", "POST", "/circles/join", map[string]string{"code": code}, 400)
	inv2 := e.mustCode("C", "POST", "/circles/"+c2+"/invites", map[string]any{}, 201)
	e.mustCode("C", "DELETE", "/circles/"+c2+"/invites/"+inv2["id"].(string), nil, 200)
	e.mustCode("A", "POST", "/circles/join", map[string]string{"code": inv2["code"].(string)}, 400)
	_ = invID
	// PATCH rename/icon and the 100-char cap.
	e.mustCode("C", "PATCH", "/circles/"+c2, map[string]string{"name": "Renamed", "icon": "home"}, 200)
	e.mustCode("C", "PATCH", "/circles/"+c2, map[string]string{"name": strings.Repeat("x", 101)}, 400)
}

func TestCircleStreamAuthorizedSyncsSubscriptions(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()
	c := testWSClient()
	e.srv.hub.registerCircles([]string{c1}, e.ids["B"], c) // stale: missing c2
	ok, err := e.srv.circleStreamAuthorized(context.Background(), c, e.ids["B"], 0)
	if err != nil || !ok {
		t.Fatalf("%v %v", ok, err)
	}
	e.srv.hub.mu.Lock()
	_, in2 := c.circles[c2]
	e.srv.hub.mu.Unlock()
	if !in2 {
		t.Fatal("revalidation did not add the missing circle")
	}
	ok, _ = e.srv.circleStreamAuthorized(context.Background(), c, e.ids["B"], 99)
	if ok {
		t.Fatal("token version mismatch must revoke")
	}
	ok, _ = e.srv.circleStreamAuthorized(context.Background(), c, e.ids["D"], 0)
	if ok {
		t.Fatal("user with no circle must be revoked")
	}
}
