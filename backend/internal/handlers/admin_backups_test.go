package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

func backupsEnv(t *testing.T) *circleEnv {
	t.Helper()
	e := newCircleEnv(t)
	// Same guard chain as main.go for the platform-admin group.
	e.rt.Group(func(r chi.Router) {
		r.Use(middleware.RequirePlatformAdmin(e.pool))
		r.Get("/api/admin/backups", e.srv.AdminGetBackups)
		r.Post("/api/admin/backups/run", e.srv.AdminBackupRun)
		r.Post("/api/admin/backups/test-s3", e.srv.AdminBackupTestS3)
		r.Get("/api/admin/health", e.srv.AdminHealth)
		r.Get("/api/admin/backups/settings", e.srv.AdminGetBackupSettings)
		r.Put("/api/admin/backups/settings", e.srv.AdminPutBackupSettings)
	})
	if k, err := backupsettings.DeriveKey("test-settings-secret-0123456789"); err == nil {
		e.srv.BackupSettingsKey = k
	}
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = true WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	clean := func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_requests`)
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_agent`)
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_runs`)
		_, _ = e.pool.Exec(ctx, `DELETE FROM backup_settings`)
		_, _ = e.pool.Exec(ctx, `DELETE FROM audit_log WHERE action LIKE 'admin.backup.%'`)
	}
	clean()
	t.Cleanup(clean)
	return e
}

func (e *circleEnv) agent(alive bool, withS3 bool) {
	hb := "now()"
	if !alive {
		hb = "now() - interval '1 hour'"
	}
	cfg := `{"destinations":[{"kind":"local","target":"/backups"}],"encryption":"age-x25519","schedule":"15 3 * * *","timezone":"UTC","retention":{"daily":7,"weekly":4,"monthly":6,"dry_run":false}}`
	if withS3 {
		cfg = `{"destinations":[{"kind":"s3","target":"s3://bkt/of @ s3.example.com"}],"encryption":"age-x25519","schedule":"15 3 * * *","timezone":"UTC","retention":{"daily":7,"weekly":4,"monthly":6,"dry_run":false}}`
	}
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO backup_agent (id, heartbeat_at, version, next_run_at, config) VALUES (1, `+hb+`, 'abc1234', now() + interval '3 hours', $1)
		ON CONFLICT (id) DO UPDATE SET heartbeat_at = EXCLUDED.heartbeat_at, config = EXCLUDED.config`, cfg); err != nil {
		e.t.Fatal(err)
	}
}

func (e *circleEnv) finishOpenRequests() {
	_, _ = e.pool.Exec(context.Background(), `UPDATE backup_requests SET status='done', finished_at=now(), message='ok' WHERE status IN ('pending','running')`)
}

func TestAdminBackupsAuthorization(t *testing.T) {
	e := backupsEnv(t)
	e.agent(true, true)
	// B is an ordinary user (maybe a family admin elsewhere): 403 everywhere, no data.
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/admin/backups"}, {"POST", "/api/admin/backups/run"}, {"POST", "/api/admin/backups/test-s3"},
	} {
		code, _, raw := e.do("B", c.method, c.path, nil)
		if code != http.StatusForbidden {
			t.Errorf("%s %s as non-admin: %d, want 403", c.method, c.path, code)
		}
		if strings.Contains(string(raw), "s3.example.com") || strings.Contains(string(raw), "age-x25519") {
			t.Errorf("%s %s leaked backup config to a non-admin: %s", c.method, c.path, raw)
		}
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM backup_requests`).Scan(&n)
	if n != 0 {
		t.Fatalf("non-admin queued %d request(s)", n)
	}
	// Unauthenticated (no claims) -> 401/403 from the guard.
	if code, _, _ := e.do("", "POST", "/api/admin/backups/run", nil); code != 401 && code != 403 {
		t.Fatalf("anonymous: %d", code)
	}
}

func TestAdminBackupRunQueuesAuditsAndRateLimits(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()

	// No agent -> 503 with a helpful message, nothing queued.
	code, _, raw := e.do("A", "POST", "/api/admin/backups/run", nil)
	if code != http.StatusServiceUnavailable || !strings.Contains(string(raw), "docker compose up -d") {
		t.Fatalf("no agent: %d %s", code, raw)
	}
	e.agent(false, false) // stale heartbeat counts as not running
	if code, _, _ = e.do("A", "POST", "/api/admin/backups/run", nil); code != http.StatusServiceUnavailable {
		t.Fatalf("dead agent: %d", code)
	}

	e.agent(true, false)
	if code, _, raw = e.do("A", "POST", "/api/admin/backups/run", nil); code != http.StatusAccepted {
		t.Fatalf("run: %d %s", code, raw)
	}
	// One at a time.
	if code, _, _ = e.do("A", "POST", "/api/admin/backups/run", nil); code != http.StatusConflict {
		t.Fatalf("second concurrent request: %d, want 409", code)
	}
	var audits int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'admin.backup.run' AND user_id = $1`, e.ids["A"]).Scan(&audits)
	if audits != 1 {
		t.Fatalf("audit rows: %d", audits)
	}
	// Rate limit: 4 per hour per admin (the 409 above also counted).
	e.finishOpenRequests()
	var last int
	for i := 0; i < 6; i++ {
		last, _, _ = e.do("A", "POST", "/api/admin/backups/run", nil)
		e.finishOpenRequests()
		if last == http.StatusTooManyRequests {
			break
		}
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("rate limit never triggered (last=%d)", last)
	}
	_, _ = e.pool.Exec(ctx, `DELETE FROM audit_log WHERE action IN ('admin.backup.run','admin.backup.test_s3')`)
}

func TestAdminBackupTestS3NeedsS3(t *testing.T) {
	e := backupsEnv(t)
	e.agent(true, false)
	if code, _, _ := e.do("A", "POST", "/api/admin/backups/test-s3", nil); code != http.StatusConflict {
		t.Fatalf("without S3: %d, want 409", code)
	}
	e.agent(true, true)
	if code, _, raw := e.do("A", "POST", "/api/admin/backups/test-s3", nil); code != http.StatusAccepted {
		t.Fatalf("with S3: %d %s", code, raw)
	}
	_, _ = e.pool.Exec(context.Background(), `DELETE FROM audit_log WHERE action = 'admin.backup.test_s3'`)
}

func TestAdminGetBackupsAndHealthLocalAndS3(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	e.srv.BuildVersion = "v-test"
	read := func() (adminBackupsOut, adminHealthOut, string) {
		code, _, raw := e.do("A", "GET", "/api/admin/backups", nil)
		if code != 200 {
			t.Fatalf("backups: %d %s", code, raw)
		}
		var b adminBackupsOut
		if err := json.Unmarshal(raw, &b); err != nil {
			t.Fatal(err)
		}
		code, _, hraw := e.do("A", "GET", "/api/admin/health", nil)
		if code != 200 {
			t.Fatalf("health: %d %s", code, hraw)
		}
		var h adminHealthOut
		_ = json.Unmarshal(hraw, &h)
		return b, h, string(raw) + string(hraw)
	}
	b, h, _ := read()
	if b.Agent != nil || b.LastSuccess != nil || h.Backup.Status != "missing" || b.StaleAfterHours != 36 {
		t.Fatalf("empty: %+v %+v", b, h.Backup)
	}
	e.agent(true, true)
	// Old success + newer S3 failure -> stale + failure warning with the scrubbed error.
	for _, q := range []string{
		`INSERT INTO backup_runs (taken_at, status, destination, size_bytes, encrypted, trigger) VALUES (now() - interval '40 hours', 'success', 'local', 100, false, 'schedule')`,
		`INSERT INTO backup_runs (taken_at, status, destination, size_bytes, error, trigger) VALUES (now() - interval '1 hour', 'failed', 's3', 0, 'upload to s3://bkt/of failed: AccessDenied', 'schedule')`,
	} {
		if _, err := e.pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	b, h, _ = read()
	if h.Backup.Status != "stale" || b.LastFailure == nil || b.LastSuccess == nil || b.Agent == nil || !b.Agent.Running {
		t.Fatalf("stale case: %+v", b)
	}
	joined := strings.Join(h.Warnings, " | ")
	if !strings.Contains(joined, "36 hours") || !strings.Contains(joined, "AccessDenied") {
		t.Fatalf("warnings: %v", h.Warnings)
	}
	if len(b.Failing) != 1 || b.Failing[0].Dest != "s3" {
		t.Fatalf("failing: %+v", b.Failing)
	}
	// A LATER local success must not hide the S3 failure.
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_runs (taken_at, status, destination, size_bytes, trigger) VALUES (now() - interval '30 minutes', 'success', 'local', 100, 'schedule')`); err != nil {
		t.Fatal(err)
	}
	b, h, _ = read()
	if h.Backup.Status != "ok" || !strings.Contains(strings.Join(h.Warnings, " | "), "attempt to s3 failed") || len(b.Failing) != 1 {
		t.Fatalf("s3 failure hidden by a newer local success: %v %+v", h.Warnings, b.Failing)
	}
	// Fresh S3 success clears the warnings and is reported with destination/encryption.
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_runs (status, destination, size_bytes, encrypted, object_key, duration_ms, trigger) VALUES ('success', 's3', 4096, true, 's3://bkt/of/openfamily-1.dump.age', 1234, 'manual')`); err != nil {
		t.Fatal(err)
	}
	b, h, _ = read()
	if h.Backup.Status != "ok" || h.Backup.Destination != "s3" || !h.Backup.Encrypted || len(h.Warnings) != 0 {
		t.Fatalf("ok case: %+v %v", h.Backup, h.Warnings)
	}
	if b.LastSuccess.Dest != "s3" || b.LastSuccess.SizeBytes != 4096 || len(b.Recent) != 4 {
		t.Fatalf("%+v", b)
	}
	// Agent silent for an hour -> health warns (opted-in installs only).
	e.agent(false, true)
	if _, h, _ = read(); !strings.Contains(strings.Join(h.Warnings, " "), "stopped reporting") {
		t.Fatalf("dead agent not flagged: %v", h.Warnings)
	}
	_ = time.Now
}

// Secrets must never reach the API, audit log or errors. The service publishes
// only a non-secret summary; this test plants secret-looking values everywhere
// a careless implementation could pick them up from and scans every response
// plus the audit log.
func TestBackupAPIsNeverExposeSecrets(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	const secretKey, accessKey, ageKey = "SuperSecretAccessKey123456", "AKIASECRETKEYID99", "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
	t.Setenv("BACKUP_S3_SECRET_ACCESS_KEY", secretKey)
	t.Setenv("BACKUP_S3_ACCESS_KEY_ID", accessKey)
	t.Setenv("AWS_SECRET_ACCESS_KEY", secretKey)
	e.agent(true, true)
	_, _ = e.pool.Exec(ctx, `INSERT INTO backup_runs (status, destination, size_bytes, error, trigger) VALUES ('failed','s3',0,'upload to s3://bkt/of failed: AccessDenied','manual')`)

	var all strings.Builder
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/admin/backups"}, {"GET", "/api/admin/health"}, {"POST", "/api/admin/backups/test-s3"},
		{"POST", "/api/admin/backups/run"}, {"POST", "/api/admin/backups/run"}, {"GET", "/api/admin/backups"},
	} {
		_, _, raw := e.do("A", c.method, c.path, nil)
		all.Write(raw)
	}
	var audit strings.Builder
	rows, err := e.pool.Query(ctx, `SELECT action || ' ' || coalesce(detail,'') FROM audit_log WHERE action LIKE 'admin.backup.%'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		audit.WriteString(s)
	}
	rows.Close()
	if audit.Len() == 0 {
		t.Fatal("expected audit rows")
	}
	for _, sec := range []string{secretKey, accessKey, ageKey, "AGE-SECRET-KEY", "secret_access_key", "SecretKey"} {
		if strings.Contains(all.String(), sec) || strings.Contains(audit.String(), sec) {
			t.Fatalf("secret material %q found in an API response or audit entry", sec)
		}
	}
	_, _ = e.pool.Exec(ctx, `DELETE FROM audit_log WHERE action LIKE 'admin.backup.%'`)
}
