package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Simulated old-version requests: the app announces itself with X-App-Version
// and the server must classify it, advertise the status and apply shims.

func compatRouter(s *Server) chi.Router {
	r := chi.NewRouter()
	r.Use(middleware.AppVersion(s.CompatPolicy))
	r.Get("/compat", s.GetCompat)
	r.Get("/config", s.GetConfig)
	return r
}

func getWithVersion(rt http.Handler, path, ver string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if ver != "" {
		req.Header.Set("X-App-Version", ver)
		req.Header.Set("X-App-Platform", "android")
	}
	w := httptest.NewRecorder()
	rt.ServeHTTP(w, req)
	return w
}

// pinCompatReleases fixes the release list these tests were written against, so
// adding a release to compat.Releases does not rewrite their expectations.
func pinCompatReleases(t *testing.T) {
	t.Helper()
	old := compat.Releases
	compat.Releases = []string{"0.14.0", "0.15.0", "0.16.0", "0.17.0", "0.18.0", "0.19.0", "0.20.0"}
	t.Cleanup(func() { compat.Releases = old })
}

func TestCompatEndpointPerVersion(t *testing.T) {
	pinCompatReleases(t)
	rt := compatRouter(&Server{})
	cases := []struct {
		ver, status string
		required    bool
		recommended bool
	}{
		{"0.20.1", "ok", false, false},
		{"0.19.0+55", "ok", false, false},
		{"0.18.2", "recommended", false, true},
		{"0.16.0", "recommended", false, true},
		{"0.15.1", "required", true, false},
		{"0.9.5", "required", true, false},
		{"", "unknown", false, false},
		{"garbage", "unknown", false, false},
	}
	for _, c := range cases {
		w := getWithVersion(rt, "/compat", c.ver)
		if w.Code != 200 {
			t.Fatalf("%q: %d", c.ver, w.Code)
		}
		var in compat.Info
		if err := json.Unmarshal(w.Body.Bytes(), &in); err != nil {
			t.Fatal(err)
		}
		if string(in.Status) != c.status || in.UpgradeRequired != c.required || in.UpgradeRecommended != c.recommended {
			t.Errorf("%q: got %+v", c.ver, in)
		}
		if c.ver != "" && c.status != "unknown" {
			if h := w.Header().Get("X-OpenFamily-Compat"); h != c.status {
				t.Errorf("%q: header %q want %q", c.ver, h, c.status)
			}
			if w.Header().Get("X-OpenFamily-Min-App-Version") == "" {
				t.Errorf("%q: missing min header", c.ver)
			}
		} else if w.Header().Get("X-OpenFamily-Compat") != "" {
			t.Errorf("%q: unknown clients get no compat header", c.ver)
		}
	}
	// ?v= works for clients that cannot set headers (browser, curl).
	w := getWithVersion(rt, "/compat?v=0.10.0", "")
	var in compat.Info
	_ = json.Unmarshal(w.Body.Bytes(), &in)
	if !in.UpgradeRequired {
		t.Errorf("?v=0.10.0: %+v", in)
	}
}

func TestConfigCarriesCompat(t *testing.T) {
	pinCompatReleases(t)
	s := &Server{}
	w := getWithVersion(compatRouter(s), "/config", "0.14.0")
	var body struct {
		Compat compat.Info `json:"compat"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.Compat.UpgradeRequired || body.Compat.MinSupportedVersion != "0.16.0" {
		t.Fatalf("%+v", body.Compat)
	}
}

func TestEnvPinChangesPolicy(t *testing.T) {
	s := &Server{MinSupportedAppVersion: "0.10.0"}
	w := getWithVersion(compatRouter(s), "/compat", "0.12.0")
	var in compat.Info
	_ = json.Unmarshal(w.Body.Bytes(), &in)
	if in.UpgradeRequired || in.MinSupportedVersion != "0.10.0" {
		t.Fatalf("%+v", in)
	}
}

// Shim: a Private circle shown to an app that predates E2EE carries the update
// hint in its name (the one field every version renders); newer apps and
// header-less clients see the plain name.
func TestPrivateCircleShimPerVersion(t *testing.T) {
	mk := func(ver string) circleOut {
		ctx := context.Background()
		if v, ok := compat.Parse(ver); ok {
			ctx = middleware.ContextWithAppInfo(ctx, middleware.AppInfo{Version: v, Known: true})
		}
		c := circleOut{Name: "Family", E2EEMode: "private"}
		applyCircleCompat(ctx, &c)
		return c
	}
	if c := mk("0.14.2"); !c.UpdateRequired || !strings.Contains(c.Name, "update the app") || c.MinAppVersion != "0.15.0" {
		t.Errorf("0.14.2: %+v", c)
	}
	for _, v := range []string{"0.15.0", "0.20.1", ""} {
		if c := mk(v); c.UpdateRequired || c.Name != "Family" || c.MinAppVersion != "0.15.0" {
			t.Errorf("%q: %+v", v, c)
		}
	}
	plain := circleOut{Name: "Home", E2EEMode: "off"}
	applyCircleCompat(middleware.ContextWithAppInfo(context.Background(), middleware.AppInfo{Version: compat.Version{Minor: 3}, Known: true}), &plain)
	if plain.Name != "Home" || plain.MinAppVersion != "" || plain.UpdateRequired {
		t.Errorf("standard circle must be untouched: %+v", plain)
	}
}

// "Require server processing": apps below required_server are told in the circle name; the circle stays usable.
func TestRequiredServerCircleNudgesOldApps(t *testing.T) {
	mk := func(ver string, opt string) circleOut {
		ctx := context.Background()
		if v, ok := compat.Parse(ver); ok {
			ctx = middleware.ContextWithAppInfo(ctx, middleware.AppInfo{Version: v, Known: true})
		}
		c := circleOut{Name: "Family", E2EEMode: "private", ServerAssist: true, MemberOptOut: opt}
		applyCircleCompat(ctx, &c)
		return c
	}
	if c := mk("0.26.26", "required_server"); c.UpdateRequired || !strings.Contains(c.Name, "update the app to keep sharing") || c.MinAppVersion != "0.26.27" {
		t.Errorf("old app: %+v", c)
	}
	for _, v := range []string{"0.26.27", "0.27.0", ""} {
		if c := mk(v, "required_server"); c.Name != "Family" || c.UpdateRequired {
			t.Errorf("%q: %+v", v, c)
		}
	}
	if c := mk("0.26.26", "allowed"); c.Name != "Family" {
		t.Errorf("an optional circle must not nudge: %+v", c)
	}
}

func TestRefuseUnsupportedAppEnforcement(t *testing.T) {
	pinCompatReleases(t)
	run := func(enforce bool, ver string) (refused bool, code int, body string) {
		s := &Server{}
		s.compatCache.loaded, s.compatCache.at = true, time.Now()
		s.compatCache.current = compatSettings{Enforce: enforce}
		r := chi.NewRouter()
		r.Use(middleware.AppVersion(s.CompatPolicy))
		r.Post("/locations", func(w http.ResponseWriter, req *http.Request) {
			if s.refuseUnsupportedApp(w, req) {
				refused = true
				return
			}
			w.WriteHeader(204)
		})
		req := httptest.NewRequest(http.MethodPost, "/locations", nil)
		if ver != "" {
			req.Header.Set("X-App-Version", ver)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return refused, w.Code, w.Body.String()
	}
	refused, code, body := run(true, "0.12.0")
	if !refused || code != http.StatusUpgradeRequired {
		t.Fatalf("old app, enforcing: refused=%v code=%d", refused, code)
	}
	var b map[string]any
	_ = json.Unmarshal([]byte(body), &b)
	if b["code"] != "upgrade_required" || b["upgrade_required"] != true || b["min_supported_version"] != "0.16.0" {
		t.Fatalf("body %v", b)
	}
	for name, c := range map[string]struct {
		enforce bool
		ver     string
	}{
		"not enforcing":   {false, "0.12.0"},
		"in window":       {true, "0.17.0"},
		"no version sent": {true, ""},
		"current release": {true, "0.20.1"},
	} {
		if refused, code, _ := run(c.enforce, c.ver); refused || code != 204 {
			t.Errorf("%s: refused=%v code=%d", name, refused, code)
		}
	}
}

// ---- database-backed: recording, admin API, settings ----

func compatDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestCompatRecordAndAdmin(t *testing.T) {
	pinCompatReleases(t)
	pool := compatDB(t)
	ctx := context.Background()
	s := &Server{Pool: pool, hub: newHub()}
	var uid string
	email := "compat-" + time.Now().Format("150405.000000") + "@example.test"
	if err := pool.QueryRow(ctx, `INSERT INTO users (email, name, password_hash) VALUES ($1,'Old Phone','x') RETURNING id::text`, email).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, uid) })
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `UPDATE app_compat_settings SET min_supported_override='', enforce_writes=false WHERE id=1`)
	})
	s.compatCache.invalidate()

	r := chi.NewRouter()
	r.Use(middleware.AppVersion(s.CompatPolicy))
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
			next.ServeHTTP(w, req)
		})
	})
	r.Use(middleware.RecordAppVersion(pool))
	r.Get("/me", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	r.Get("/api/admin/compat", s.AdminGetCompat)
	r.Put("/api/admin/compat", s.AdminPutCompat)

	for i := 0; i < 3; i++ { // repeated calls: one row, throttled
		req := httptest.NewRequest(http.MethodGet, "/me", nil)
		req.Header.Set("X-App-Version", "0.12.1")
		req.Header.Set("X-App-Platform", "android")
		r.ServeHTTP(httptest.NewRecorder(), req)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM app_client_versions WHERE user_id=$1 AND app_version='0.12.1' AND platform='android'`, uid).Scan(&n); err != nil || n != 1 {
		t.Fatalf("rows=%d err=%v", n, err)
	}
	// A request without the header records nothing.
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/me", nil))
	if _ = pool.QueryRow(ctx, `SELECT count(*) FROM app_client_versions WHERE user_id=$1`, uid).Scan(&n); n != 1 {
		t.Fatalf("rows=%d", n)
	}

	type adminOut struct {
		Policy struct {
			Min      string `json:"min_supported_version"`
			Source   string `json:"source"`
			Override string `json:"override"`
			Enforce  bool   `json:"enforce_writes"`
		} `json:"policy"`
		Versions []adminCompatVersion `json:"versions"`
		Outside  []adminCompatUser    `json:"outside_window"`
		People   []adminCompatUser    `json:"people"`
		Server   struct {
			Release string `json:"release"`
		} `json:"server"`
		Experience map[string]string `json:"experience"`
	}
	get := func() adminOut {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/admin/compat", nil))
		var o adminOut
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &o) != nil {
			t.Fatalf("admin get: %d %s", w.Code, w.Body.String())
		}
		return o
	}
	o := get()
	found := false
	for _, v := range o.Versions {
		if v.AppVersion == "0.12.1" && v.Platform == "android" && v.Users >= 1 && v.Status == "required" {
			found = true
		}
	}
	if !found {
		t.Fatalf("0.12.1 not listed as required: %+v", o.Versions)
	}
	outside := false
	for _, u := range o.Outside {
		outside = outside || u.UserID == uid
	}
	if !outside {
		t.Fatalf("user not listed outside the window: %+v", o.Outside)
	}

	// The per-person list says what this person experiences and offers a message.
	var me *adminCompatUser
	for i := range o.People {
		if o.People[i].UserID == uid {
			me = &o.People[i]
		}
	}
	if me == nil || me.Status != "required" || !strings.Contains(me.Experience, "Update required") ||
		!strings.HasPrefix(me.UpdateMessage, "Hi") || len(me.MissingFeatures) == 0 {
		t.Fatalf("person entry: %+v", me)
	}
	if o.Server.Release == "" || o.Experience["ok"] == "" || o.Experience["required"] == "" {
		t.Fatalf("server/experience missing: %+v %+v", o.Server, o.Experience)
	}

	put := func(body string) int {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(http.MethodPut, "/api/admin/compat", strings.NewReader(body)))
		return w.Code
	}
	if c := put(`{"min_supported_override":"nonsense"}`); c != 400 {
		t.Fatalf("bad override accepted: %d", c)
	}
	if c := put(`{"min_supported_override":"0.12.0","enforce_writes":true}`); c != 200 {
		t.Fatalf("put: %d", c)
	}
	o = get()
	if o.Policy.Min != "0.12.0" || o.Policy.Source != "admin" || !o.Policy.Enforce {
		t.Fatalf("policy after override: %+v", o.Policy)
	}
	for _, u := range o.Outside {
		if u.UserID == uid {
			t.Fatal("0.12.1 is inside the window after lowering the minimum")
		}
	}
	if c := put(`{"min_supported_override":""}`); c != 200 {
		t.Fatalf("clear: %d", c)
	}
	if o = get(); o.Policy.Source != "window" || o.Policy.Min != "0.16.0" {
		t.Fatalf("policy after clear: %+v", o.Policy)
	}
}
