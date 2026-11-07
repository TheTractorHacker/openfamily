package handlers

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// ---- pure unit tests (no database) ----

func TestValidateMapStyleURL(t *testing.T) {
	ok := []string{"", "  ", "https://tiles.openfreemap.org/styles/liberty", "https://maps.example.com:8443/s.json?key=1"}
	for _, in := range ok {
		if _, err := validateMapStyleURL(in); err != nil {
			t.Errorf("%q should be valid: %v", in, err)
		}
	}
	bad := []string{
		"http://tiles.example.com/s.json", "ftp://x.example.com/s", "tiles.example.com/s.json", "https://",
		"https://user:pw@tiles.example.com/s.json", "https://tiles.example.com/s.json#frag",
		"https://localhost/s.json", "https://x.localhost/s.json", "https://127.0.0.1/s.json",
		"https://10.0.0.5/s.json", "https://192.168.1.2/s.json", "https://[::1]/s.json", "https://100.64.1.1/s",
		"https://nas.local/s.json", "javascript:alert(1)", "https://example.com/" + strings.Repeat("a", 600),
	}
	for _, in := range bad {
		if _, err := validateMapStyleURL(in); err == nil {
			t.Errorf("%q should be rejected", in)
		}
	}
}

func TestCheckMapStyle(t *testing.T) {
	good := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ok":
			_, _ = w.Write([]byte(`{"version":8,"sources":{},"layers":[{"id":"bg","type":"background"}]}`))
		case "/html":
			_, _ = w.Write([]byte(`<html>`))
		case "/empty":
			_, _ = w.Write([]byte(`{"version":8,"layers":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer good.Close()
	c := good.Client()
	ctx := context.Background()
	if err := checkMapStyle(ctx, c, good.URL+"/ok"); err != nil {
		t.Fatalf("valid style rejected: %v", err)
	}
	for _, p := range []string{"/html", "/empty", "/missing"} {
		if err := checkMapStyle(ctx, c, good.URL+p); err == nil {
			t.Errorf("%s should fail", p)
		}
	}
	// The production client must refuse loopback targets outright.
	if err := checkMapStyle(ctx, mapStyleClient(), good.URL+"/ok"); err == nil {
		t.Error("mapStyleClient must refuse a loopback host")
	}
}

func TestCSVSafeNeutralisesFormulas(t *testing.T) {
	for in, want := range map[string]string{
		"=1+1": "'=1+1", "+x": "'+x", "-x": "'-x", "@SUM(A1)": "'@SUM(A1)", "plain": "plain", "": "",
	} {
		if got := csvSafe(in); got != want {
			t.Errorf("csvSafe(%q)=%q want %q", in, got, want)
		}
	}
}

func TestBackupHealthFlags(t *testing.T) {
	now := time.Now()
	if b := backupHealth(nil, nil, now, 36*time.Hour); b.Status != "missing" || b.LastAt != nil {
		t.Fatalf("missing: %+v", b)
	}
	fresh := now.Add(-3 * time.Hour)
	if b := backupHealth(&fresh, nil, now, 36*time.Hour); b.Status != "ok" {
		t.Fatalf("fresh: %+v", b)
	}
	old := now.Add(-49 * time.Hour)
	if b := backupHealth(&old, nil, now, 36*time.Hour); b.Status != "stale" {
		t.Fatalf("stale: %+v", b)
	}
	mid := now.Add(-40 * time.Hour)
	if b := backupHealth(&mid, nil, now, 36*time.Hour); b.Status != "stale" || b.StaleAfterHours != 36 {
		t.Fatalf("40h old with a 36h limit must be stale: %+v", b)
	}
	if b := backupHealth(&mid, nil, now, 48*time.Hour); b.Status != "ok" {
		t.Fatalf("40h old with a 48h limit must be ok: %+v", b)
	}
}

// ---- database tests (TEST_DATABASE_URL) ----

func adminOpsEnv(t *testing.T) *circleEnv {
	t.Helper()
	e := newCircleEnv(t)
	if err := e.srv.EnsureThemeSchema(context.Background()); err != nil {
		t.Fatal(err)
	}
	e.srv.BuildVersion = "v-test"
	e.rt.Get("/api/admin/circles/{id}/members", e.srv.AdminListCircleMembers)
	e.rt.Delete("/api/admin/circles/{id}/members/{user_id}", e.srv.AdminRemoveCircleMember)
	e.rt.Get("/api/admin/audit/export", e.srv.AdminExportAudit)
	e.rt.Get("/api/admin/alerts", e.srv.AdminListAlerts)
	e.rt.Get("/api/admin/health", e.srv.AdminHealth)
	e.rt.Get("/api/admin/settings/map-style", e.srv.AdminGetMapStyle)
	e.rt.Put("/api/admin/settings/map-style", e.srv.AdminPutMapStyle)
	e.rt.Get("/config", e.srv.GetConfig)
	return e
}

func TestAdminCircleMembersListAndRemove(t *testing.T) {
	e := adminOpsEnv(t)
	c := e.createCircle("A", "Crew", "B")

	code, _, raw := e.do("A", "GET", "/api/admin/circles/"+c+"/members", nil)
	if code != 200 {
		t.Fatalf("list: %d %s", code, raw)
	}
	var ms []adminCircleMemberOut
	if err := json.Unmarshal(raw, &ms); err != nil {
		t.Fatal(err)
	}
	if len(ms) != 2 || ms[0].Role != "admin" || ms[0].UserID != e.ids["A"] || ms[1].Email == "" || !ms[1].SharingEnabled {
		t.Fatalf("members: %+v", ms)
	}
	for _, banned := range []string{"lat", "lon", "latitude", "position"} {
		if strings.Contains(strings.ToLower(string(raw)), `"`+banned+`"`) {
			t.Fatalf("members response must not carry coordinates (%s): %s", banned, raw)
		}
	}
	e.mustCode("A", "GET", "/api/admin/circles/00000000-0000-0000-0000-000000000000/members", nil, 404)
	e.mustCode("A", "GET", "/api/admin/circles/nope/members", nil, 404)

	// The last admin is protected; a plain member can be removed and loses access.
	e.mustCode("A", "DELETE", "/api/admin/circles/"+c+"/members/"+e.ids["A"], nil, 409)
	e.mustCode("A", "DELETE", "/api/admin/circles/"+c+"/members/"+e.ids["B"], nil, 200)
	e.mustCode("A", "DELETE", "/api/admin/circles/"+c+"/members/"+e.ids["B"], nil, 404)
	var n int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM circle_members WHERE circle_id = $1`, c).Scan(&n); err != nil || n != 1 {
		t.Fatalf("members left: %d %v", n, err)
	}
	var audits int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM audit_log WHERE action = 'admin.circle.member_removed' AND user_id = $1`, e.ids["A"]).Scan(&audits)
	if audits != 1 {
		t.Fatalf("removal not audited: %d", audits)
	}
}

func TestAdminAuditExportCSV(t *testing.T) {
	e := adminOpsEnv(t)
	ctx := context.Background()
	tag := "t" + time.Now().Format("150405.000000")
	for _, row := range []struct{ uid, action, detail string }{
		{e.ids["A"], "x." + tag + ".one", "=HYPERLINK(\"http://evil\")"},
		{e.ids["A"], "x." + tag + ".two", "second"},
		{e.ids["B"], "x." + tag + ".one", "third"},
	} {
		if _, err := e.pool.Exec(ctx, `INSERT INTO audit_log (user_id, action, detail, ip_address) VALUES ($1,$2,$3,'1.2.3.4')`,
			row.uid, row.action, row.detail); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `DELETE FROM audit_log WHERE action LIKE $1`, "x."+tag+"%") })

	get := func(qs string) ([][]string, *httptest.ResponseRecorder) {
		req := httptest.NewRequest("GET", "/api/admin/audit/export?"+qs, nil)
		req.Header.Set("X-Test-User", e.ids["A"])
		rec := httptest.NewRecorder()
		e.rt.ServeHTTP(rec, req)
		if rec.Code != 200 {
			t.Fatalf("%s: %d %s", qs, rec.Code, rec.Body.String())
		}
		recs, err := csv.NewReader(rec.Body).ReadAll()
		if err != nil {
			t.Fatal(err)
		}
		return recs, rec
	}
	recs, rec := get("action=x." + tag + ".*")
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/csv") {
		t.Fatalf("content type %q", ct)
	}
	if !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment;") {
		t.Fatalf("no attachment header")
	}
	if len(recs) != 4 || recs[0][0] != "id" || recs[0][7] != "action" {
		t.Fatalf("rows: %v", recs)
	}
	formula := false
	for _, r := range recs[1:] {
		if strings.HasPrefix(r[8], "'=HYPERLINK") {
			formula = true
		}
	}
	if !formula {
		t.Fatalf("formula cell not neutralised: %v", recs)
	}
	// Filter by exact action and by user.
	if recs, _ = get("action=x." + tag + ".one"); len(recs) != 3 {
		t.Fatalf("action filter: %v", recs)
	}
	if recs, _ = get("action=x." + tag + ".*&user_id=" + e.ids["B"]); len(recs) != 2 || recs[1][2] != e.ids["B"] {
		t.Fatalf("user filter: %v", recs)
	}
	// Date filter: nothing before 2000, everything through tomorrow.
	if recs, _ = get("action=x." + tag + ".*&to=2000-01-01"); len(recs) != 1 {
		t.Fatalf("to filter: %v", recs)
	}
	if recs, _ = get("action=x." + tag + ".*&from=2000-01-01&to=" + time.Now().Add(24*time.Hour).Format("2006-01-02")); len(recs) != 4 {
		t.Fatalf("from/to filter: %v", recs)
	}
	for _, bad := range []string{"from=garbage", "user_id=nope"} {
		req := httptest.NewRequest("GET", "/api/admin/audit/export?"+bad, nil)
		req.Header.Set("X-Test-User", e.ids["A"])
		rec := httptest.NewRecorder()
		e.rt.ServeHTTP(rec, req)
		if rec.Code != 400 {
			t.Errorf("%s: want 400 got %d", bad, rec.Code)
		}
	}
	var exports int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'admin.audit_export' AND user_id = $1 AND detail LIKE '%cap=50000%'`, e.ids["A"]).Scan(&exports)
	if exports < 1 {
		t.Fatal("the export itself must be audited")
	}
}

func TestAdminAlertsHideCoordinatesAndShowDeliveries(t *testing.T) {
	e := adminOpsEnv(t)
	ctx := context.Background()
	var fam, alert string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('AlertFam') RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam) })
	if err := e.pool.QueryRow(ctx, `
		INSERT INTO alerts (user_id, family_id, type, status, lat, lon, note, share_token)
		VALUES ($1,$2,'sos','active',47.123456,8.654321,'secret note',$3) RETURNING id`,
		e.ids["A"], fam, "tok-"+time.Now().Format("150405.000000")).Scan(&alert); err != nil {
		t.Fatal(err)
	}
	e.srv.recordDelivery(ctx, alert, e.ids["B"], "", "UserB", "push", "sent", "")
	e.srv.recordDelivery(ctx, alert, e.ids["C"], "", "UserC", "push", "failed", errCodeProvider)
	if _, err := e.pool.Exec(ctx, `UPDATE alert_deliveries SET state='acknowledged', acknowledged_at=now() WHERE alert_id=$1 AND recipient_user_id=$2`, alert, e.ids["B"]); err != nil {
		t.Fatal(err)
	}

	code, _, raw := e.do("A", "GET", "/api/admin/alerts?status=active&type=sos&limit=200", nil)
	if code != 200 {
		t.Fatalf("%d %s", code, raw)
	}
	body := string(raw)
	for _, leak := range []string{"47.12", "8.654", "secret note", "tok-", `"lat"`, `"lon"`, "share_token", "note"} {
		if strings.Contains(body, leak) {
			t.Fatalf("response leaks %q: %s", leak, body)
		}
	}
	var res struct {
		Alerts []adminAlertOut `json:"alerts"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		t.Fatal(err)
	}
	var got *adminAlertOut
	for i := range res.Alerts {
		if res.Alerts[i].ID == alert {
			got = &res.Alerts[i]
		}
	}
	if got == nil || !got.HasLocation || got.FamilyName != "AlertFam" || got.SenderName != "UserA" || len(got.Deliveries) != 2 {
		t.Fatalf("alert: %+v", got)
	}
	states := map[string]string{}
	for _, d := range got.Deliveries {
		states[d.Recipient] = d.State
		if d.Recipient == "UserB" && d.AcknowledgedAt == nil {
			t.Error("ack time missing")
		}
		if d.Recipient == "UserC" && d.Error != errCodeProvider {
			t.Errorf("error code: %q", d.Error)
		}
	}
	if states["UserB"] != "acknowledged" || states["UserC"] != "failed" {
		t.Fatalf("states: %v", states)
	}
	// Filters and validation.
	_, _, raw = e.do("A", "GET", "/api/admin/alerts?status=resolved", nil)
	if strings.Contains(string(raw), alert) {
		t.Fatal("status filter ignored")
	}
	e.mustCode("A", "GET", "/api/admin/alerts?status=bogus", nil, 400)
	e.mustCode("A", "GET", "/api/admin/alerts?before=nope", nil, 400)
}

func TestAdminHealthReportsBackupAndMigration(t *testing.T) {
	e := adminOpsEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `DELETE FROM backup_runs`); err != nil {
		t.Fatal(err)
	}
	read := func() adminHealthOut {
		code, _, raw := e.do("A", "GET", "/api/admin/health", nil)
		if code != 200 {
			t.Fatalf("%d %s", code, raw)
		}
		var h adminHealthOut
		if err := json.Unmarshal(raw, &h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	h := read()
	if h.ReleaseVersion != "v-test" || h.Migration.Version < 1 || h.DatabaseBytes <= 0 {
		t.Fatalf("health: %+v", h)
	}
	if h.Backup.Status != "missing" || len(h.Warnings) == 0 {
		t.Fatalf("missing backup not flagged: %+v", h)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_runs (taken_at, size_bytes) VALUES (now() - interval '3 days', 10)`); err != nil {
		t.Fatal(err)
	}
	if h = read(); h.Backup.Status != "stale" || len(h.Warnings) == 0 {
		t.Fatalf("stale backup not flagged: %+v", h.Backup)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_runs (size_bytes) VALUES (2048)`); err != nil {
		t.Fatal(err)
	}
	h = read()
	if h.Backup.Status != "ok" || h.Backup.SizeBytes == nil || *h.Backup.SizeBytes != 2048 || len(h.Warnings) != 0 {
		t.Fatalf("recent backup: %+v warnings=%v", h.Backup, h.Warnings)
	}
	_, _ = e.pool.Exec(ctx, `DELETE FROM backup_runs`)
}

func TestAdminMapStyleOverridesConfigWithoutRestart(t *testing.T) {
	e := adminOpsEnv(t)
	ctx := context.Background()
	e.srv.MapStyleURL = "https://env.example.com/style.json"
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `UPDATE app_theme_settings SET map_style_url = '' WHERE id = 1`) })
	_, _ = e.pool.Exec(ctx, `UPDATE app_theme_settings SET map_style_url = '' WHERE id = 1`)
	var changed []string
	e.srv.OnMapStyleChange = func(u string) { changed = append(changed, u) }

	cfgStyle := func() string {
		code, m, raw := e.do("", "GET", "/config", nil)
		if code != 200 {
			t.Fatalf("config: %d %s", code, raw)
		}
		return m["map_style_url"].(string)
	}
	if got := cfgStyle(); got != "https://env.example.com/style.json" {
		t.Fatalf("env default: %q", got)
	}
	e.mustCode("A", "PUT", "/api/admin/settings/map-style", map[string]string{"map_style_url": "http://insecure.example.com/s.json"}, 400)
	e.mustCode("A", "PUT", "/api/admin/settings/map-style", map[string]string{"map_style_url": "https://127.0.0.1/s.json"}, 400)
	if got := cfgStyle(); got != "https://env.example.com/style.json" {
		t.Fatalf("rejected value changed config: %q", got)
	}
	m := e.mustCode("A", "PUT", "/api/admin/settings/map-style", map[string]string{"map_style_url": "https://tiles.example.org/styles/x.json"}, 200)
	if m["effective"] != "https://tiles.example.org/styles/x.json" || m["env_default"] != "https://env.example.com/style.json" {
		t.Fatalf("put: %v", m)
	}
	if got := cfgStyle(); got != "https://tiles.example.org/styles/x.json" {
		t.Fatalf("config after set: %q", got)
	}
	if len(changed) != 1 || changed[0] != "https://tiles.example.org/styles/x.json" {
		t.Fatalf("CSP hook: %v", changed)
	}
	e.mustCode("A", "PUT", "/api/admin/settings/map-style", map[string]string{"map_style_url": ""}, 200)
	if got := cfgStyle(); got != "https://env.example.com/style.json" {
		t.Fatalf("config after clear: %q", got)
	}
}

func TestRequireAdminMFAMiddleware(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = TRUE WHERE id = ANY($1)`, []string{e.ids["A"], e.ids["B"]}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE users SET totp_enabled = TRUE, totp_secret = 'x' WHERE id = $1`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })
	call := func(enabled bool, user, amr string) (int, string) {
		h := middleware.RequirePlatformAdmin(e.pool)(middleware.RequireAdminMFA(e.pool, enabled)(ok))
		req := httptest.NewRequest("GET", "/api/admin/x", nil)
		req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: e.ids[user], AMR: amr}))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code, rec.Body.String()
	}
	if code, _ := call(false, "A", ""); code != 204 {
		t.Fatalf("setting off must not block: %d", code)
	}
	for _, tc := range []struct {
		name, user, amr string
		want            int
	}{
		{"no TOTP on the account", "A", "", 403},
		{"no TOTP on the account, forged-looking claim", "A", auth.AMRTOTP, 403},
		{"TOTP enabled but the token predates it (no amr)", "B", "", 403},
		{"token with an unknown method", "B", "pwd", 403},
		{"TOTP enabled and challenge passed", "B", auth.AMRTOTP, 204},
	} {
		code, body := call(true, tc.user, tc.amr)
		if code != tc.want {
			t.Errorf("%s: got %d want %d (%s)", tc.name, code, tc.want, body)
		}
		if tc.want == 403 && !strings.Contains(body, "admin_mfa_required") {
			t.Errorf("%s: body %s", tc.name, body)
		}
	}
	// Non-admins stay refused by the platform-admin gate, not the MFA one.
	if code, body := call(true, "C", auth.AMRTOTP); code != 403 || strings.Contains(body, "admin_mfa_required") {
		t.Fatalf("non-admin: %d %s", code, body)
	}
}

func TestMeReportsAdminMFARequired(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = TRUE WHERE id = ANY($1)`, []string{e.ids["A"], e.ids["B"]}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE users SET totp_enabled = TRUE, totp_secret = 'x' WHERE id = $1`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	e.rt.Get("/me", e.srv.GetMe)
	me := func(user, amr string) bool {
		req := httptest.NewRequest("GET", "/me", nil)
		req.Header.Set("X-Test-User", e.ids[user])
		req.Header.Set("X-Test-AMR", amr)
		rec := httptest.NewRecorder()
		e.rt.ServeHTTP(rec, req)
		var m map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &m)
		got, _ := m["admin_mfa_required"].(bool)
		return got
	}
	e.srv.RequireAdminMFA = false
	if me("A", "") {
		t.Fatal("flag off must never report")
	}
	e.srv.RequireAdminMFA = true
	for _, tc := range []struct {
		user, amr string
		want      bool
	}{{"A", "", true}, {"B", "", true}, {"B", auth.AMRTOTP, false}, {"C", "", false}} {
		if got := me(tc.user, tc.amr); got != tc.want {
			t.Errorf("user=%s amr=%q: got %v want %v", tc.user, tc.amr, got, tc.want)
		}
	}
}

func TestEnablingTOTPRekeysAdminSessions(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	e.srv.TM = auth.NewTokenManager("test-secret-test-secret-test-secret!", 15*time.Minute, time.Hour)
	var oldVer int
	if err := e.pool.QueryRow(ctx, `SELECT token_version FROM users WHERE id = $1`, e.ids["A"]).Scan(&oldVer); err != nil {
		t.Fatal(err)
	}
	// A pre-existing refresh session that must die.
	if err := e.srv.refreshSessions().Create(ctx, e.ids["A"], "old-jti", time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	pair, ok := e.srv.rekeyAdminSession(rec, httptest.NewRequest("POST", "/auth/totp/enable", nil), e.ids["A"])
	if !ok {
		t.Fatalf("rekey failed: %d %s", rec.Code, rec.Body.String())
	}
	acc, err := e.srv.TM.Parse(pair.AccessToken, auth.AccessToken)
	if err != nil || acc.AMR != auth.AMRTOTP || acc.TokenVersion != oldVer+1 {
		t.Fatalf("new access claims: %+v err=%v", acc, err)
	}
	ref, err := e.srv.TM.Parse(pair.RefreshToken, auth.RefreshToken)
	if err != nil || ref.AMR != auth.AMRTOTP {
		t.Fatalf("new refresh claims: %+v err=%v", ref, err)
	}
	var live int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM refresh_sessions WHERE user_id = $1 AND revoked_at IS NULL AND used_at IS NULL`, e.ids["A"]).Scan(&live)
	if live != 1 {
		t.Fatalf("only the new session may stay live, got %d", live)
	}
	// An access token minted before the bump no longer matches the user's version.
	if !e.srv.tokenVersionMatches(ctx, e.ids["A"], oldVer+1) || e.srv.tokenVersionMatches(ctx, e.ids["A"], oldVer) {
		t.Fatal("old token version must be rejected")
	}
}

func TestAdminAuditExportIsAuditedBeforeStreamingEvenIfClientLeaves(t *testing.T) {
	e := adminOpsEnv(t)
	ctx := context.Background()
	count := func() int {
		var n int
		_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'admin.audit_export' AND user_id = $1 AND detail LIKE '%action=zz.cancelled%'`, e.ids["A"]).Scan(&n)
		return n
	}
	// A client whose context is already cancelled (disconnected): the audit row
	// must still be written, with the filters in its detail.
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	req := httptest.NewRequest("GET", "/api/admin/audit/export?action=zz.cancelled", nil).WithContext(cctx)
	req.Header.Set("X-Test-User", e.ids["A"])
	e.rt.ServeHTTP(httptest.NewRecorder(), req)
	if count() != 1 {
		t.Fatalf("cancelled export was not audited: %d", count())
	}
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `DELETE FROM audit_log WHERE detail LIKE '%zz.cancelled%'`) })
}

func TestAdminAuditExportFailsClosedWhenAuditCannotBeWritten(t *testing.T) {
	e := adminOpsEnv(t)
	// A caller id that has no users row makes the audit insert violate its
	// foreign key: the export must refuse and stream nothing.
	req := httptest.NewRequest("GET", "/api/admin/audit/export", nil)
	req.Header.Set("X-Test-User", "00000000-0000-4000-8000-000000000000")
	e.ids["ghost"] = "00000000-0000-4000-8000-000000000000"
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	if rec.Code != 500 {
		t.Fatalf("want 500 got %d: %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "id,time") || strings.HasPrefix(rec.Header().Get("Content-Type"), "text/csv") {
		t.Fatalf("nothing may be streamed: %s", rec.Body.String())
	}
}
