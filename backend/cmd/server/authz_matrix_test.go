package main

// SEC-006: cross-tenant authorization matrix.
//
// The route table in main.go is parsed (go/ast), so the matrix covers EVERY
// route that is registered there, including ones added later:
//
//   - A route outside any RequireAuth* group must be listed in publicRoutes
//     (an explicit, reviewed allow-list) or the test fails.
//   - Every authenticated route is mounted on a router built from main.go's own
//     middleware chain and handler methods (reflection on *handlers.Server),
//     then exercised as users of family A against real resources of family B.
//   - A path parameter this file cannot map to a family-B resource fails the
//     test, so a new id-bearing route cannot ship untested.
//
// Assertions: unauthenticated and bad-token calls are 401; platform-admin
// routes are 403 for ordinary users; any route that names a family-B resource
// is a 4xx for family-A callers and never changes B's data; routes without
// ids never leak B markers into the response. The WebSocket endpoints get the
// same treatment in TestAuthzMatrixWebSocket.
//
// Needs TEST_DATABASE_URL (skipped otherwise); CI provides it.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/handlers"
	mid "github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// ---------------------------------------------------------------- route table

type parsedRoute struct {
	method, path, handler string
	mws                   []string
}

func (r parsedRoute) key() string { return r.method + " " + r.path }

func (r parsedRoute) has(mw string) bool {
	for _, m := range r.mws {
		if m == mw {
			return true
		}
	}
	return false
}

// authed reports whether the route sits behind an authentication middleware.
func (r parsedRoute) authed() bool {
	return r.has("RequireAuth") || r.has("RequireAuthOrDeviceIngestKey")
}

func mwName(e ast.Expr) string {
	switch v := e.(type) {
	case *ast.CallExpr:
		return mwName(v.Fun)
	case *ast.SelectorExpr:
		return v.Sel.Name
	case *ast.Ident:
		return v.Name
	}
	return "?"
}

func parseMainRoutes(t *testing.T) []parsedRoute {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var mainFn *ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "main" {
			mainFn = fd
		}
	}
	if mainFn == nil {
		t.Fatal("main() not found")
	}
	var out []parsedRoute
	var walk func(stmts []ast.Stmt, mws []string, depth int)
	walk = func(stmts []ast.Stmt, mws []string, depth int) {
		cur := append([]string(nil), mws...)
		for _, st := range stmts {
			es, ok := st.(*ast.ExprStmt)
			if !ok {
				continue
			}
			call, ok := es.X.(*ast.CallExpr)
			if !ok {
				continue
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				continue
			}
			if id, ok := sel.X.(*ast.Ident); !ok || id.Name != "r" {
				continue
			}
			switch sel.Sel.Name {
			case "Use":
				if depth > 0 { // top-level middleware is global plumbing
					cur = append(cur, mwName(call.Args[0]))
				}
			case "Group":
				fl, ok := call.Args[0].(*ast.FuncLit)
				if !ok {
					t.Fatalf("unsupported r.Group argument at %s", fset.Position(call.Pos()))
				}
				walk(fl.Body.List, cur, depth+1)
			case "Get", "Post", "Put", "Patch", "Delete":
				lit, ok := call.Args[0].(*ast.BasicLit)
				if !ok {
					t.Fatalf("non-literal route path at %s", fset.Position(call.Pos()))
				}
				p, _ := strconv.Unquote(lit.Value)
				h := ""
				if hs, ok := call.Args[1].(*ast.SelectorExpr); ok {
					if x, ok := hs.X.(*ast.Ident); ok && x.Name == "srv" {
						h = hs.Sel.Name
					}
				}
				out = append(out, parsedRoute{
					method: strings.ToUpper(sel.Sel.Name), path: p, handler: h,
					mws: append([]string(nil), cur...),
				})
			default:
				t.Fatalf("router call r.%s at %s is not understood by the authz matrix; teach authz_matrix_test.go about it",
					sel.Sel.Name, fset.Position(call.Pos()))
			}
		}
	}
	walk(mainFn.Body.List, nil, 0)
	if len(out) < 100 {
		t.Fatalf("parsed only %d routes from main.go; parser out of date?", len(out))
	}
	return out
}

// publicRoutes are the routes deliberately reachable without a session. Adding
// a route outside the authenticated groups requires adding it here.
var publicRoutes = map[string]string{
	"GET /healthz":                     "liveness",
	"GET /config":                      "public server config",
	"GET /alerts/share/{token}":        "unguessable SOS share token",
	"GET /integrations/ha/v1/ping":     "scoped integration token (ofha_...), checked in the handler; see TestAuthzMatrixHAAPI",
	"GET /integrations/ha/v1/members":  "scoped integration token (ofha_...); see TestAuthzMatrixHAAPI and handlers/ha_integrations_db_test.go",
	"GET /integrations/ha/v1/places":   "scoped integration token (ofha_...); see TestAuthzMatrixHAAPI",
	"GET /integrations/ha/v1/events":   "scoped integration token (ofha_...); see TestAuthzMatrixHAAPI",
	"GET /join/{code}":                 "static invite landing page",
	"GET /invites/{code}/preview":      "public: privacy setup of the invited circle only; per-IP rate limit, generic 404",
	"GET /.well-known/apple-app-site-association": "iOS Universal Links association file (static)",
	"GET /app.apk":                     "signed APK for invitees",
	"GET /s/{token}":                   "share-link viewer (hash lookup)",
	"GET /s/{token}/data":              "share-link viewer",
	"GET /s/{token}/photo":             "share-link viewer",
	"POST /auth/register":              "credentials",
	"POST /auth/login":                 "credentials",
	"POST /auth/refresh":               "refresh token in body",
	"POST /auth/password/reset":        "reset code in body",
	"POST /auth/passkeys/login/begin":  "passkey ceremony (challenge is single-use)",
	"POST /auth/passkeys/login/finish": "passkey assertion verified against stored key",
	"GET /ws/stream":                   "self-authenticating (TestAuthzMatrixWebSocket)",
	"GET /api/admin/ws":                "self-authenticating (TestAuthzMatrixWebSocket)",
	"PUT /internal/e2ee/server-device": "server-device bearer token (404 when unconfigured); see e2ee_server_member_db_test.go",
	"POST /internal/e2ee/ingest":       "server-device bearer token + re-verified member consents; see e2ee_server_member_db_test.go",
	"GET /":                            "redirect",
	"GET /admin":                       "static SPA",
	"GET /admin/":                      "static SPA",
	"GET /admin/*":                     "static SPA",
}

// selfDestructive routes take no resource id; they act on the caller's own
// account (or session), so executing them mid-run would break the fixture
// without exercising a cross-tenant surface.
var selfDestructive = map[string]bool{
	"DELETE /me":                 true,
	"POST /auth/logout":          true,
	"POST /auth/logout-all":      true,
	"POST /family/leave":         true,
	"PATCH /me/password":         true,
	"POST /auth/password/change": true,
}

// ----------------------------------------------------------------- fixture

type actor struct {
	id, token string
}

type authzFixture struct {
	pool *pgxpool.Pool
	srv  *handlers.Server
	tm   *auth.TokenManager
	rt   http.Handler

	famA, famB                string
	aAdmin, aMember, outsider actor
	bAdmin, bMember           actor
	ids                       map[string]string // resource name -> family-B id
	markers                   []string
}

const bLat, bLon = 12.345678, 65.432109

func newAuthzFixture(t *testing.T, routes []parsedRoute) *authzFixture {
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
	t.Cleanup(pool.Close)

	tm := auth.NewTokenManager("authz-matrix-test-secret-0123456789abcdef", 15*time.Minute, 24*time.Hour)
	srv := handlers.New(pool, tm, push.NewDispatcher(push.APNsConfig{}))
	srv.AlertLimit = sms.NewLimiter()
	srv.AlertCfg = handlers.AlertLimitsFromEnv()
	srv.AuthLimit = sms.NewLimiter()
	srv.LocationLimit = sms.NewLimiter()
	srv.RequireInvite = false
	// main.go creates these lazily-managed tables at startup; the matrix must do
	// the same so it passes on a freshly migrated database, independent of which
	// other test packages ran first.
	for name, ensure := range map[string]func(context.Context) error{
		"crash": srv.EnsureCrashSchema, "dawarich": srv.EnsureDawarichSchema, "notify events": srv.EnsureNotifyEventsSchema,
		"notification prefs": srv.EnsureNotificationSchema, "theme": srv.EnsureThemeSchema,
	} {
		if err := ensure(ctx); err != nil {
			t.Fatalf("ensure %s schema: %v", name, err)
		}
	}

	f := &authzFixture{pool: pool, srv: srv, tm: tm, ids: map[string]string{}}
	one := func(q string, args ...any) string {
		t.Helper()
		var id string
		if err := pool.QueryRow(ctx, q, args...).Scan(&id); err != nil {
			t.Fatalf("seed: %v\n%s", err, q)
		}
		return id
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("seed: %v\n%s", err, q)
		}
	}
	tag := strconv.FormatInt(time.Now().UnixNano(), 36)
	f.famA = one(`INSERT INTO families (name) VALUES ('A-' || $1) RETURNING id`, tag)
	f.famB = one(`INSERT INTO families (name) VALUES ('BSECRETFAMILY-' || $1) RETURNING id`, tag)
	pwHash, err := auth.HashPassword("Zzzzzzzz1!")
	if err != nil {
		t.Fatal(err)
	}
	mkUser := func(label, name, fam, role string) actor {
		var famArg any
		if fam != "" {
			famArg = fam
		}
		email := fmt.Sprintf("%s-%s@authz.example.com", strings.ToLower(label), tag)
		id := one(`INSERT INTO users (email, name, password_hash, family_id, role) VALUES ($1,$2,$5,$3,$4) RETURNING id`,
			email, name, famArg, role, pwHash)
		tok, err := tm.IssueAccess(id, fam, 0)
		if err != nil {
			t.Fatal(err)
		}
		if fam == f.famB {
			f.markers = append(f.markers, email)
		}
		return actor{id: id, token: tok}
	}
	f.aAdmin = mkUser("aadmin", "Alice Admin", f.famA, "admin")
	f.aMember = mkUser("amember", "Alan Member", f.famA, "member")
	f.outsider = mkUser("outsider", "Olive Outsider", "", "member")
	f.bAdmin = mkUser("badmin", "BSECRETADMIN", f.famB, "admin")
	f.bMember = mkUser("bmember", "BSECRETMEMBER", f.famB, "member")
	f.markers = append(f.markers, "BSECRETADMIN", "BSECRETMEMBER", "BSECRETFAMILY", "BSECRETPLACE", "BSECRETCHAT", "BSECRETCONTACT", "15555550123",
		f.bAdmin.id, f.bMember.id, f.famB, "12.345678", "65.432109")

	// Family B resources: one of every kind that has an id in a route.
	f.ids["member"] = f.bMember.id
	exec(`INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1,$2,$3,now())`, f.bMember.id, bLat, bLon)
	f.ids["device"] = one(`INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, f.bMember.id)
	f.ids["place"] = one(`INSERT INTO places (family_id, name, geom, radius_meters, circle_id)
		VALUES ($1,'BSECRETPLACE',ST_SetSRID(ST_MakePoint($3,$2),4326),150,$1) RETURNING id`, f.famB, bLat, bLon)
	f.ids["geofence"] = one(`INSERT INTO geofences (family_id, place_id) VALUES ($1,$2) RETURNING id`, f.famB, f.ids["place"])
	f.ids["alert"] = one(`INSERT INTO alerts (user_id, family_id, type, share_token) VALUES ($1,$2,'sos',$3) RETURNING id`,
		f.bMember.id, f.famB, "tok-"+tag)
	f.ids["chat"] = one(`INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1,$2,'BSECRETCHAT') RETURNING id`,
		f.famB, f.bAdmin.id)
	f.ids["invite"] = one(`INSERT INTO invite_codes (code, family_id, circle_id, created_by) VALUES ($1,$2,$2,$3) RETURNING id`,
		"BINV"+strings.ToUpper(tag), f.famB, f.bAdmin.id)
	f.ids["share_link"] = one(`INSERT INTO share_links (user_id, token_hash, label, expires_at)
		VALUES ($1, sha256($2::bytea), 'BSECRETLINK', now() + interval '1 hour') RETURNING id`, f.bMember.id, []byte("b"+tag))
	f.ids["ha_token"] = one(`INSERT INTO ha_integrations (user_id, name, token_hash, token_hint, scopes, circle_ids)
		VALUES ($1, 'BSECRETHA', sha256($2::bytea), '...zzzz', ARRAY['presence','location'], ARRAY[$3]::uuid[]) RETURNING id`,
		f.bMember.id, []byte("ha"+tag), f.famB)
	f.ids["live_share"] = one(`INSERT INTO live_shares (owner_id, viewer_id, expires_at) VALUES ($1,$2,now()+interval '1 hour') RETURNING id`,
		f.bMember.id, f.bAdmin.id)
	f.ids["bubble"] = one(`INSERT INTO bubbles (circle_id, creator_id, subject_id, lat, lon, radius_m, expires_at)
		VALUES ($1,$2,$3,$4,$5,200,now()+interval '1 hour') RETURNING id`, f.famB, f.bAdmin.id, f.bMember.id, bLat, bLon)
	f.ids["trip"] = one(`INSERT INTO trips (user_id, started_at, ended_at, distance_m, max_speed_mps, avg_speed_mps, mode, speed_source,
		start_lat, start_lon, end_lat, end_lon, point_count)
		VALUES ($1, now()-interval '2 hours', now()-interval '1 hour', 1000, 20, 10, 'driving', 'device_gps', $2,$3,$2,$3, 10) RETURNING id`,
		f.bMember.id, bLat, bLon)
	f.ids["trip_event"] = one(`INSERT INTO trip_events (user_id, kind, started_at, ended_at, magnitude)
		VALUES ($1,'hard_brake', now()-interval '90 minutes', now()-interval '89 minutes', 5) RETURNING id`, f.bMember.id)
	f.ids["session"] = one(`INSERT INTO refresh_sessions (user_id, family_id, jti, expires_at)
		VALUES ($1,$2,$3, now()+interval '1 day') RETURNING jti`, f.bMember.id, f.famB, "jti-"+tag)
	f.ids["passkey"] = one(`INSERT INTO passkey_credentials (user_id, credential_id, credential, name)
		VALUES ($1, decode(md5($2),'hex'), '{}'::jsonb, 'BSECRETPASSKEY') RETURNING id`, f.bMember.id, "pk-"+tag)
	f.ids["contact"] = one(`INSERT INTO emergency_contacts (user_id, name, phone, phone_digits)
		VALUES ($1,'BSECRETCONTACT','+15555550123','15555550123') RETURNING id`, f.bMember.id)
	f.ids["e2ee_device"] = one(`INSERT INTO device_keys (device_id, user_id, ed25519_pub, x25519_pub, fingerprint, signature,
		registered_by_device_id, registered_by_pub, registration_action, registration_signature, initial)
		VALUES (gen_random_uuid(), $1, decode(md5($2),'hex') || decode(md5($2 || 'x'),'hex'), decode(md5($2 || 'y'),'hex') || decode(md5($2 || 'z'),'hex'),
		        encode(sha256($2::bytea),'hex'), decode(md5($2),'hex') || decode(md5($2),'hex') || decode(md5($2),'hex') || decode(md5($2),'hex'), gen_random_uuid(),
		        decode(md5($2),'hex') || decode(md5($2),'hex'), 1, decode(md5($2),'hex') || decode(md5($2),'hex') || decode(md5($2),'hex') || decode(md5($2),'hex'), true)
		RETURNING device_id`, f.bMember.id, "e2ee-"+tag)
	f.ids["circle"] = f.famB
	f.ids["crash"] = "00000000-0000-4000-8000-0000000000c1"
	f.ids["family"] = f.famB
	f.ids["user"] = f.bMember.id

	t.Cleanup(func() {
		bg := context.Background()
		for _, fam := range []string{f.famA, f.famB} {
			_, _ = pool.Exec(bg, `DELETE FROM circles WHERE id = $1 OR created_by IN (SELECT id FROM users WHERE family_id = $1)`, fam)
			_, _ = pool.Exec(bg, `DELETE FROM places WHERE family_id = $1`, fam)
		}
		for _, a := range []actor{f.aAdmin, f.aMember, f.outsider, f.bAdmin, f.bMember} {
			_, _ = pool.Exec(bg, `DELETE FROM users WHERE id = $1`, a.id)
		}
		for _, fam := range []string{f.famA, f.famB} {
			_, _ = pool.Exec(bg, `DELETE FROM families WHERE id = $1`, fam)
		}
	})

	f.rt = f.buildRouter(t, routes)
	return f
}

// buildRouter mounts every authenticated route with main.go's own middleware
// chain and handler methods.
func (f *authzFixture) buildRouter(t *testing.T, routes []parsedRoute) http.Handler {
	t.Helper()
	r := chi.NewRouter()
	sv := reflect.ValueOf(f.srv)
	for _, rt := range routes {
		if rt.handler == "" {
			continue
		}
		m := sv.MethodByName(rt.handler)
		if !m.IsValid() {
			t.Fatalf("%s: handler method %s not found on *handlers.Server", rt.key(), rt.handler)
		}
		hf, ok := m.Interface().(func(http.ResponseWriter, *http.Request))
		if !ok {
			t.Fatalf("%s: %s is not an http handler func", rt.key(), rt.handler)
		}
		var mws []func(http.Handler) http.Handler
		for _, name := range rt.mws {
			switch name {
			case "NoStore":
				mws = append(mws, mid.NoStore)
			case "RequireAuth":
				mws = append(mws, mid.RequireAuth(f.tm))
			case "RequireTokenVersion":
				mws = append(mws, mid.RequireTokenVersion(f.pool))
			case "RequirePlatformAdmin":
				mws = append(mws, mid.RequirePlatformAdmin(f.pool))
			case "RequireAdminMFA":
				// Flag off here (pass-through); the MFA gate has its own tests.
				mws = append(mws, mid.RequireAdminMFA(f.pool, false))
			case "RequireAuthOrDeviceIngestKey":
				mws = append(mws, mid.RequireAuthOrDeviceIngestKey(f.tm, f.pool))
			default:
				t.Fatalf("%s: middleware %s is not understood by the authz matrix; add it to buildRouter", rt.key(), name)
			}
		}
		r.With(mws...).MethodFunc(rt.method, rt.path, hf)
	}
	return r
}

// victimID maps a path parameter of a route to a real family-B resource.
func (f *authzFixture) victimID(t *testing.T, rt parsedRoute, param string) string {
	t.Helper()
	p := rt.path
	switch param {
	case "user_id":
		return f.ids["user"]
	case "invite_id":
		return f.ids["invite"]
	case "msgId":
		return f.ids["chat"]
	case "eventId":
		return f.ids["trip_event"]
	case "placeId":
		return f.ids["place"]
	case "id":
		for prefix, name := range map[string]string{
			"/auth/sessions/":                     "session",
			"/auth/passkeys/":                     "passkey",
			"/family/members/":                    "member",
			"/members/":                           "member",
			"/api/admin/members/":                 "member",
			"/api/admin/users/":                   "user",
			"/api/admin/settings/dawarich/users/": "user",
			"/api/admin/families":                 "family",
			"/family/geofences/":                  "geofence",
			"/family/places/":                     "place",
			"/api/admin/places/":                  "place",
			"/devices/":                           "device",
			"/e2ee/devices/":                      "e2ee_device",
			"/me/contacts/":                       "contact",
			"/alerts/":                            "alert",
			"/crashes/":                           "crash",
			"/trips/":                             "trip",
			"/live-shares/":                       "live_share",
			"/bubbles/":                           "bubble",
			"/api/admin/bubbles":                  "bubble",
			"/share-links/":                       "share_link",
			"/integrations/ha/tokens/":            "ha_token",
			"/api/admin/share-links/":             "share_link",
			"/api/admin/sessions/":                "session",
			"/api/admin/invites/":                 "invite",
			"/api/admin/circles/":                 "circle",
			"/circles/":                           "circle",
		} {
			if strings.HasPrefix(p, prefix) {
				return f.ids[name]
			}
		}
	}
	t.Fatalf("%s: no family-B resource mapped for {%s}; extend victimID in authz_matrix_test.go", rt.key(), param)
	return ""
}

func (f *authzFixture) concretePath(t *testing.T, rt parsedRoute) (string, bool) {
	t.Helper()
	out := rt.path
	hadParam := false
	for {
		i := strings.Index(out, "{")
		if i < 0 {
			break
		}
		j := strings.Index(out[i:], "}")
		name := out[i+1 : i+j]
		out = out[:i] + f.victimID(t, rt, name) + out[i+j+1:]
		hadParam = true
	}
	return out, hadParam
}

// genericBody carries the union of the field names the handlers accept so a
// request gets past input validation and actually reaches its authorization
// check.
const genericBody = `{"name":"x","text":"x","body":"x","message":"x","label":"x","note":"x","type":"home",` +
	`"lat":1.5,"lon":2.5,"radius_meters":150,"radius_m":150,"radius":150,"role":"admin",` +
	`"enabled":true,"email":"zz@example.com","phone":"+15555550100","password":"Zzzzzzzz1!","code":"BINV",` +
	`"family_id":"%FAM%","circle_id":"%FAM%","place_id":"%PLACE%","user_id":"%USER%","member_id":"%USER%",` +
	`"viewer_id":"%USER%","subject_id":"%USER%","device_id":"%DEV%","platform":"android","status":"resolved",` +
	`"expires_in_minutes":60,"duration_minutes":60,"minutes":60,"hours":1,"icon":"x","format":"csv",` +
	`"user_ids":["%USER%"],"recipient_ids":["%USER%"],"ts":"2026-01-01T00:00:00Z"}`

func (f *authzFixture) body() []byte {
	r := strings.NewReplacer("%FAM%", f.famB, "%PLACE%", f.ids["place"], "%USER%", f.bMember.id, "%DEV%", f.ids["device"])
	return []byte(r.Replace(genericBody))
}

func (f *authzFixture) do(method, path, token string, body []byte) (code int, resp string, panicked any) {
	var rdr *bytes.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	req.RemoteAddr = "192.0.2.10:1234"
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	func() {
		defer func() { panicked = recover() }()
		f.rt.ServeHTTP(rec, req)
	}()
	return rec.Code, rec.Body.String(), panicked
}

// snapshot fingerprints every table row that belongs to family B (and the
// account rows of its members) so any cross-tenant write is detected.
func (f *authzFixture) snapshot(t *testing.T) string {
	t.Helper()
	q := `SELECT concat_ws('|',
	  (SELECT coalesce(string_agg(u::text, ',' ORDER BY u.id), '') FROM users u WHERE u.family_id = $1 OR u.id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(p::text, ',' ORDER BY p.id), '') FROM places p WHERE p.family_id = $1),
	  (SELECT coalesce(string_agg(g::text, ',' ORDER BY g.id), '') FROM geofences g WHERE g.family_id = $1),
	  (SELECT coalesce(string_agg(d::text, ',' ORDER BY d.id), '') FROM devices d WHERE d.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(dk::text, ',' ORDER BY dk.device_id), '') FROM device_keys dk WHERE dk.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(kw::text, ',' ORDER BY kw.recipient_device_id), '') FROM circle_key_wraps kw WHERE kw.circle_id = $1),
	  (SELECT coalesce(string_agg(a::text, ',' ORDER BY a.id), '') FROM alerts a WHERE a.family_id = $1),
	  (SELECT coalesce(string_agg(c::text, ',' ORDER BY c.id), '') FROM chat_messages c WHERE c.circle_id = $1),
	  (SELECT coalesce(string_agg(i::text, ',' ORDER BY i.id), '') FROM invite_codes i WHERE i.family_id = $1 OR i.circle_id = $1),
	  (SELECT coalesce(string_agg(s::text, ',' ORDER BY s.id), '') FROM share_links s WHERE s.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(l::text, ',' ORDER BY l.id), '') FROM live_shares l WHERE l.owner_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(h::text, ',' ORDER BY h.id), '') FROM ha_integrations h WHERE h.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(b::text, ',' ORDER BY b.id), '') FROM bubbles b WHERE b.circle_id = $1),
	  (SELECT coalesce(string_agg(tr::text, ',' ORDER BY tr.id), '') FROM trips tr WHERE tr.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(te::text, ',' ORDER BY te.id), '') FROM trip_events te WHERE te.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(rs::text, ',' ORDER BY rs.jti), '') FROM refresh_sessions rs WHERE rs.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(cm::text, ',' ORDER BY cm.user_id), '') FROM circle_members cm WHERE cm.circle_id = $1),
	  (SELECT coalesce(string_agg(ci::text, ',' ORDER BY ci.id), '') FROM circles ci WHERE ci.id = $1),
	  (SELECT coalesce(string_agg(mp::text, ',' ORDER BY mp.user_id), '') FROM member_positions mp WHERE mp.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(ec::text, ',' ORDER BY ec.id), '') FROM emergency_contacts ec WHERE ec.user_id = ANY($2::uuid[])),
	  (SELECT coalesce(string_agg(ge::text, ',' ORDER BY ge.id), '') FROM geofence_events ge WHERE ge.user_id = ANY($2::uuid[])))`
	var s string
	if err := f.pool.QueryRow(context.Background(), q, f.famB, []string{f.bAdmin.id, f.bMember.id}).Scan(&s); err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	return s
}

// ------------------------------------------------------------------- tests

func TestAuthzMatrixRouteClassification(t *testing.T) {
	routes := parseMainRoutes(t)
	seen := map[string]bool{}
	for _, r := range routes {
		if seen[r.key()] {
			t.Errorf("route %s registered twice", r.key())
		}
		seen[r.key()] = true
		if r.authed() {
			if r.handler == "" {
				t.Errorf("%s: authenticated route with a non-srv handler is not covered by the matrix", r.key())
			}
			if !r.has("RequireTokenVersion") && !r.has("RequireAuthOrDeviceIngestKey") {
				t.Errorf("%s: authenticated route without RequireTokenVersion (revoked tokens would work)", r.key())
			}
			if strings.HasPrefix(r.path, "/api/admin/") && !r.has("RequirePlatformAdmin") {
				t.Errorf("%s: admin API route without RequirePlatformAdmin", r.key())
			}
			continue
		}
		if _, ok := publicRoutes[r.key()]; !ok {
			t.Errorf("%s is reachable without authentication but is not in publicRoutes; review it and add it if intended", r.key())
		}
	}
	var stale []string
	for k := range publicRoutes {
		if !seen[k] {
			stale = append(stale, k)
		}
	}
	sort.Strings(stale)
	if len(stale) > 0 {
		t.Errorf("publicRoutes lists routes that no longer exist: %v", stale)
	}
}

func TestAuthzMatrix(t *testing.T) {
	routes := parseMainRoutes(t)
	f := newAuthzFixture(t, routes)
	before := f.snapshot(t)

	var authed []parsedRoute
	for _, r := range routes {
		if r.authed() && r.handler != "" {
			authed = append(authed, r)
		}
	}

	type result struct{ checked, idRoutes int }
	var res result
	fail := func(rt parsedRoute, who, format string, args ...any) {
		t.Errorf("%s as %s: %s", rt.key(), who, fmt.Sprintf(format, args...))
	}

	actors := []struct {
		name string
		a    actor
	}{{"A-admin", f.aAdmin}, {"A-member", f.aMember}, {"no-family user", f.outsider}}

	// 1. Authentication: no token and a forged token are 401 everywhere.
	for _, rt := range authed {
		path, _ := f.concretePath(t, rt)
		for _, tok := range []string{"", "not-a-jwt"} {
			code, _, pn := f.do(rt.method, path, tok, f.body())
			if pn != nil {
				fail(rt, "anonymous", "panic: %v", pn)
				continue
			}
			if code != http.StatusUnauthorized {
				fail(rt, "anonymous("+tok+")", "status %d, want 401", code)
			}
		}
	}

	// 2. Platform-admin API: ordinary users are 403, including family admins.
	for _, rt := range authed {
		if !rt.has("RequirePlatformAdmin") {
			continue
		}
		path, _ := f.concretePath(t, rt)
		for _, ac := range actors {
			code, body, pn := f.do(rt.method, path, ac.a.token, f.body())
			if pn != nil {
				fail(rt, ac.name, "panic: %v", pn)
			} else if code != http.StatusForbidden {
				fail(rt, ac.name, "status %d, want 403 (%s)", code, trunc(body))
			}
		}
	}

	// 3. Tenant isolation for the user-facing API.
	for _, rt := range authed {
		if rt.has("RequirePlatformAdmin") {
			continue
		}
		key := rt.key()
		if selfDestructive[key] {
			continue
		}
		path, hasID := f.concretePath(t, rt)
		for _, ac := range actors {
			code, body, pn := f.do(rt.method, path, ac.a.token, f.body())
			res.checked++
			if pn != nil {
				fail(rt, ac.name, "panic: %v", pn)
				continue
			}
			if code >= 500 && !(code == http.StatusServiceUnavailable && strings.HasPrefix(rt.path, "/geocode/")) {
				fail(rt, ac.name, "status %d (%s)", code, trunc(body))
			}
			if hasID {
				if code < 400 {
					fail(rt, ac.name, "IDOR: %s on %s returned %d (%s)", rt.method, path, code, trunc(body))
				}
			}
			for _, m := range f.markers {
				if strings.Contains(body, m) {
					fail(rt, ac.name, "response leaks family-B data %q: %s", m, trunc(body))
					break
				}
			}
		}
		if hasID {
			res.idRoutes++
		}
	}

	after := f.snapshot(t)
	if before != after {
		t.Errorf("family B data changed during the run:\n before: %s\n after:  %s", trunc2(before), trunc2(after))
	}
	t.Logf("authz matrix: %d authenticated routes, %d with resource ids, %d requests, 3 actors", len(authed), res.idRoutes, res.checked)
}

func TestAuthzMatrixWebSocket(t *testing.T) {
	routes := parseMainRoutes(t)
	f := newAuthzFixture(t, routes)

	mux := chi.NewRouter()
	mux.Get("/ws/stream", f.srv.Stream)
	mux.Get("/api/admin/ws", f.srv.AdminStream)
	mux.With(mid.RequireAuthOrDeviceIngestKey(f.tm, f.pool)).Post("/locations", f.srv.IngestLocation)
	ts := httptest.NewServer(mux)
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http")

	dial := func(path, token string) (*websocket.Conn, int, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		h := http.Header{}
		if token != "" {
			h.Set("Authorization", "Bearer "+token)
		}
		c, resp, err := websocket.Dial(ctx, wsURL+path, &websocket.DialOptions{HTTPHeader: h})
		code := 0
		if resp != nil {
			code = resp.StatusCode
		}
		return c, code, err
	}

	// No token / forged token.
	for _, tok := range []string{"", "junk"} {
		if c, code, err := dial("/ws/stream", tok); err == nil {
			_ = c.CloseNow()
			t.Fatalf("/ws/stream connected with token %q", tok)
		} else if code != http.StatusUnauthorized {
			t.Fatalf("/ws/stream token %q: status %d, want 401 (%v)", tok, code, err)
		}
	}
	// A user without a circle cannot open the stream.
	if c, _, err := dial("/ws/stream", f.outsider.token); err == nil {
		_ = c.CloseNow()
		t.Fatal("user with no circle connected to /ws/stream")
	}
	// Subscribing to another family's circle is a 404 and never a stream.
	if c, code, err := dial("/ws/stream?circle_id="+f.famB, f.aMember.token); err == nil {
		_ = c.CloseNow()
		t.Fatal("family-A member subscribed to family-B circle")
	} else if code != http.StatusNotFound {
		t.Fatalf("foreign circle subscribe: status %d, want 404 (%v)", code, err)
	}
	// Platform-admin stream: ordinary users, even family admins, get 403.
	for _, ac := range []actor{f.aAdmin, f.aMember, f.bAdmin} {
		if c, code, err := dial("/api/admin/ws", ac.token); err == nil {
			_ = c.CloseNow()
			t.Fatal("non-platform-admin connected to /api/admin/ws")
		} else if code != http.StatusForbidden {
			t.Fatalf("/api/admin/ws as non-admin: status %d, want 403 (%v)", code, err)
		}
	}

	// Live isolation: A is connected; B's member reports a position, then A's
	// own member reports one. A must receive only its own family's frames and
	// the snapshot must not list family B.
	conn, _, err := dial("/ws/stream", f.aAdmin.token)
	if err != nil {
		t.Fatalf("family-A stream: %v", err)
	}
	defer conn.CloseNow()
	frames := make(chan string, 64)
	go func() {
		for {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			_, b, err := conn.Read(ctx)
			cancel()
			if err != nil {
				close(frames)
				return
			}
			frames <- string(b)
		}
	}()
	post := func(a actor, lat, lon float64) {
		devID := ""
		if err := f.pool.QueryRow(context.Background(),
			`INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, a.id).Scan(&devID); err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(map[string]any{"device_id": devID, "lat": lat, "lon": lon,
			"ts": time.Now().UTC().Format(time.RFC3339Nano), "accuracy_meters": 5})
		req, _ := http.NewRequest("POST", ts.URL+"/locations", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+a.token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			t.Fatalf("location post as %s: %d", a.id, resp.StatusCode)
		}
	}
	post(f.bMember, 33.333333, 44.444444)
	post(f.aMember, 22.222222, 55.555555)

	var got []string
	gotOwn := false
	deadline := time.After(6 * time.Second)
loop:
	for {
		select {
		case fr, ok := <-frames:
			if !ok {
				break loop
			}
			got = append(got, fr)
			if strings.Contains(fr, "22.222222") {
				gotOwn = true
				break loop
			}
		case <-deadline:
			break loop
		}
	}
	if !gotOwn {
		t.Fatalf("positive control failed: family A never received its own member's live frame; frames=%v", got)
	}
	for _, fr := range got {
		for _, m := range append(f.markers, "33.333333", "44.444444") {
			if strings.Contains(fr, m) {
				t.Fatalf("family-A stream leaked family-B data %q in frame %s", m, trunc(fr))
			}
		}
	}
}

// TestAuthzMatrixHAAPI covers the token-authenticated Home Assistant routes,
// which sit outside the session groups: no token, a user session JWT, a
// malformed or unknown token and a revoked token are all 401; a token without
// the route's scope is 403; and a family-A token never shows family-B data.
func TestAuthzMatrixHAAPI(t *testing.T) {
	routes := parseMainRoutes(t)
	f := newAuthzFixture(t, routes)
	ctx := context.Background()

	mux := chi.NewRouter()
	mux.Get("/integrations/ha/v1/ping", f.srv.HAPing)
	mux.Get("/integrations/ha/v1/members", f.srv.HAMembers)
	mux.Get("/integrations/ha/v1/places", f.srv.HAPlaces)
	mux.Get("/integrations/ha/v1/events", f.srv.HAEvents)
	paths := []string{"/integrations/ha/v1/ping", "/integrations/ha/v1/members", "/integrations/ha/v1/places", "/integrations/ha/v1/events?after=0"}
	// every HA route main.go registers must be mounted here too
	have := map[string]bool{}
	for _, p := range paths {
		have["GET "+strings.SplitN(p, "?", 2)[0]] = true
	}
	for _, rt := range routes {
		if strings.HasPrefix(rt.path, "/integrations/ha/v1/") && !have[rt.key()] {
			t.Errorf("%s is not covered by TestAuthzMatrixHAAPI", rt.key())
		}
	}
	get := func(path, tok string) (int, string) {
		req := httptest.NewRequest("GET", path, nil)
		req.RemoteAddr = "192.0.2.77:1234"
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code, rec.Body.String()
	}
	mint := func(owner actor, circle string, scopes ...string) (string, string) {
		raw := make([]byte, 32)
		for i := range raw {
			raw[i] = byte(i*7 + len(scopes) + len(circle))
		}
		tok := "ofha_" + base64.RawURLEncoding.EncodeToString(append(raw[:16:16], []byte(owner.id + circle)[:16]...))
		var id string
		if err := f.pool.QueryRow(ctx, `INSERT INTO ha_integrations (user_id, name, token_hash, scopes, circle_ids)
			VALUES ($1,'matrix',sha256($2::bytea),$3,ARRAY[$4]::uuid[]) RETURNING id`, owner.id, []byte(tok), scopes, circle).Scan(&id); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = f.pool.Exec(ctx, `DELETE FROM ha_integrations WHERE id = $1`, id) })
		return tok, id
	}
	for _, p := range paths {
		for _, tok := range []string{"", "junk", f.aAdmin.token, "ofha_" + strings.Repeat("A", 43)} {
			if code, body := get(p, tok); code != http.StatusUnauthorized {
				t.Errorf("GET %s with token %.12q: %d, want 401 (%s)", p, tok, code, trunc(body))
			}
		}
	}
	tokA, idA := mint(f.aAdmin, f.famA, "presence", "location", "places", "events", "driving")
	for _, p := range paths {
		code, body := get(p, tokA)
		if code != http.StatusOK {
			t.Errorf("GET %s with a valid family-A token: %d %s", p, code, trunc(body))
		}
		for _, m := range append(f.markers, "65.432109", "12.345678") {
			if strings.Contains(body, m) {
				t.Errorf("GET %s leaks family-B data %q: %s", p, m, trunc(body))
			}
		}
	}
	// A token that names family B's circle but whose owner is not a member of it sees nothing.
	tokX, _ := mint(f.aMember, f.famB, "presence", "location", "places", "events")
	for _, p := range paths[1:3] {
		code, body := get(p, tokX)
		if code != http.StatusOK {
			t.Errorf("GET %s forged-scope token: %d", p, code)
		}
		for _, m := range append(f.markers, "65.432109", "12.345678") {
			if strings.Contains(body, m) {
				t.Errorf("GET %s with a token scoped to a foreign circle leaks %q: %s", p, m, trunc(body))
			}
		}
	}
	// Wrong scope.
	tokP, _ := mint(f.aMember, f.famA, "presence")
	for _, p := range []string{"/integrations/ha/v1/places", "/integrations/ha/v1/events?after=0"} {
		if code, _ := get(p, tokP); code != http.StatusForbidden {
			t.Errorf("GET %s with presence-only token: %d, want 403", p, code)
		}
	}
	// Revoked.
	if _, err := f.pool.Exec(ctx, `UPDATE ha_integrations SET revoked_at = now() WHERE id = $1`, idA); err != nil {
		t.Fatal(err)
	}
	for _, p := range paths {
		if code, _ := get(p, tokA); code != http.StatusUnauthorized {
			t.Errorf("GET %s with a revoked token: %d, want 401", p, code)
		}
	}
}

func trunc(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 160 {
		return s[:160] + "..."
	}
	return s
}

func trunc2(s string) string {
	if len(s) > 600 {
		return s[:600] + "..."
	}
	return s
}
