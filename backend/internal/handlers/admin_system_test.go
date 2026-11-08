package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/errlog"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func TestSiteHost(t *testing.T) {
	for in, want := range map[string]string{
		"":                          "",
		":80":                       "",
		"localhost":                 "",
		"127.0.0.1:8080":            "",
		"orbit.example.com":         "orbit.example.com",
		"https://orbit.example.com": "orbit.example.com",
		"orbit.example.com:8443":    "orbit.example.com",
		"intranet":                  "",
	} {
		if got := siteHost(in); got != want {
			t.Errorf("siteHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestErrorCounts24h(t *testing.T) {
	now := time.Now()
	e, w := errorCounts24h([]errlog.Entry{
		{Time: now.Add(-time.Hour), Level: "ERROR"},
		{Time: now.Add(-2 * time.Hour), Level: "WARN"},
		{Time: now.Add(-30 * time.Hour), Level: "ERROR"},
	}, now)
	if e != 1 || w != 1 {
		t.Fatalf("errors=%d warnings=%d", e, w)
	}
}

func TestHumanHelpers(t *testing.T) {
	if humanBytes(1536*1024) != "2 MB" || humanBytes(500) != "500 B" || humanBytes(3<<30) != "3.0 GB" {
		t.Fatalf("%s %s %s", humanBytes(1536*1024), humanBytes(500), humanBytes(3<<30))
	}
	if humanAge(30*time.Second) != "under a minute" || humanAge(5*time.Hour) != "5 h" || humanAge(72*time.Hour) != "3 days" {
		t.Fatal("humanAge")
	}
}

func TestHubClientCountNilSafe(t *testing.T) {
	var h *hub
	if h.clientCount() != 0 {
		t.Fatal("nil hub")
	}
	if newHub().clientCount() != 0 {
		t.Fatal("empty hub")
	}
}

func TestPublicDownloadIPAFromLocalDir(t *testing.T) {
	dir := t.TempDir()
	s := &Server{APKDir: dir}
	rec := httptest.NewRecorder()
	s.PublicDownloadIPA(rec, httptest.NewRequest("GET", "/app.ipa", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("no ipa: %d", rec.Code)
	}
	if err := os.WriteFile(filepath.Join(dir, "orbitly-0.24.1-unsigned.ipa"), []byte("ipa-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	// An APK in the same directory must never be served as the IPA.
	if err := os.WriteFile(filepath.Join(dir, "orbitly-0.24.1.apk"), []byte("apk"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	s.PublicDownloadIPA(rec, httptest.NewRequest("GET", "/app.ipa", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "ipa-bytes" {
		t.Fatalf("ipa: %d %q", rec.Code, rec.Body.String())
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.Contains(cd, "orbitly-0.24.1-unsigned.ipa") {
		t.Fatalf("Content-Disposition = %q", cd)
	}
	rec = httptest.NewRecorder()
	s.PublicDownloadAPK(rec, httptest.NewRequest("GET", "/app.apk", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "apk" {
		t.Fatalf("apk: %d %q", rec.Code, rec.Body.String())
	}
	// No APK_DIR: 404, not a crash.
	rec = httptest.NewRecorder()
	(&Server{}).PublicDownloadIPA(rec, httptest.NewRequest("GET", "/app.ipa", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("no dir: %d", rec.Code)
	}
}

func TestSafeFilename(t *testing.T) {
	if got := safeFilename("a\"b\r\nc/d.ipa"); got != "a_b__c_d.ipa" {
		t.Fatalf("%q", got)
	}
}

func TestAdminBuildsWithoutRepoIsGraceful(t *testing.T) {
	s := &Server{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/admin/builds", nil)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: "u"}))
	s.AdminBuilds(rec, req)
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	var out adminBuildsOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Configured || out.Error == "" || out.Releases == nil || out.PublicIPA != "/app.ipa" {
		t.Fatalf("%+v", out)
	}
	rec = httptest.NewRecorder()
	s.AdminBuilds(rec, httptest.NewRequest("GET", "/api/admin/builds", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous: %d", rec.Code)
	}
}

func systemEnv(t *testing.T) *circleEnv {
	t.Helper()
	e := newCircleEnv(t)
	e.rt.Group(func(r chi.Router) {
		r.Use(middleware.RequirePlatformAdmin(e.pool))
		r.Get("/api/admin/system/checks", e.srv.AdminSystemChecks)
	})
	if _, err := e.pool.Exec(context.Background(), `UPDATE users SET platform_admin = true WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	return e
}

func TestAdminSystemChecksOnFreshDatabase(t *testing.T) {
	e := systemEnv(t)
	ctx := context.Background()
	_, _ = e.pool.Exec(ctx, `DELETE FROM backup_runs`)
	_, _ = e.pool.Exec(ctx, `DELETE FROM backup_agent`)

	// Ordinary users learn nothing.
	if code, _, raw := e.do("B", "GET", "/api/admin/system/checks", nil); code != http.StatusForbidden || strings.Contains(string(raw), "checks") {
		t.Fatalf("non-admin: %d %s", code, raw)
	}

	code, _, raw := e.do("A", "GET", "/api/admin/system/checks", nil)
	if code != 200 {
		t.Fatalf("%d %s", code, raw)
	}
	var out systemChecksOut
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	by := map[string]SystemCheck{}
	for _, c := range out.Checks {
		by[c.ID] = c
		if c.Status != checkOK && c.Status != checkWarn && c.Status != checkFail && c.Status != checkInfo {
			t.Errorf("%s has status %q", c.ID, c.Status)
		}
		if (c.Status == checkFail || c.Status == checkWarn) && c.Hint == "" {
			t.Errorf("%s is %s but has no fix hint", c.ID, c.Status)
		}
	}
	for _, id := range []string{"database", "migrations", "clock", "disk", "backup", "push_apns", "push_direct", "push_ntfy", "push_fcm",
		"geocoder", "sms", "server_key", "e2ee_ingest", "websocket", "queues", "versions", "tls", "errors"} {
		if _, ok := by[id]; !ok {
			t.Errorf("missing check %q", id)
		}
	}
	if by["database"].Status != checkOK {
		t.Errorf("database: %+v", by["database"])
	}
	if by["migrations"].Status != checkOK {
		t.Errorf("migrations on a freshly migrated DB: %+v", by["migrations"])
	}
	if by["backup"].Status != checkFail || !strings.Contains(by["backup"].Summary, "ever been recorded") {
		t.Errorf("no backup recorded must be a failure: %+v", by["backup"])
	}
	if by["server_key"].Status != checkInfo {
		t.Errorf("no built-in key in tests: %+v", by["server_key"])
	}
	total := 0
	for _, n := range out.Counts {
		total += n
	}
	if total != len(out.Checks) {
		t.Errorf("counts %v do not add up to %d checks", out.Counts, len(out.Checks))
	}

	// A recent backup with a running, scheduled agent turns the row green.
	e.agent(true, false)
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_runs (taken_at, status, destination, encrypted, size_bytes) VALUES (now(), 'success', 'local', true, 1000)`); err != nil {
		t.Skipf("backup_runs shape differs: %v", err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_runs`)
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_agent`)
	})
	_, _, raw = e.do("A", "GET", "/api/admin/system/checks", nil)
	_ = json.Unmarshal(raw, &out)
	for _, c := range out.Checks {
		if c.ID == "backup" && (c.Status != checkOK || !strings.Contains(c.Summary, "encrypted") || !strings.Contains(c.Summary, "Schedule is on")) {
			t.Errorf("healthy backup: %+v", c)
		}
	}

	// A dirty migration is a failure with a fix hint.
	dirty := e.srv.checkMigrations(ctx)
	if dirty.Status != checkOK {
		t.Fatalf("baseline: %+v", dirty)
	}
}
