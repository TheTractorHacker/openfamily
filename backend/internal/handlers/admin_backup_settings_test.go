package handlers

import (
	"context"
	"encoding/json"
	"filippo.io/age"
	"net/http"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

const (
	tSecret = "Zx9SuperSecretAccessKeyValue/abc123"
	tKeyID  = "AKIAIOSFODNN7EXAMPLE"
)

func goodSettings(pub string) map[string]any {
	return map[string]any{
		"s3_enabled": true, "endpoint": "https://s3.eu-central-003.backblazeb2.com", "region": "eu-central-003", "bucket": "my-family-backups",
		"prefix": "openfamily", "path_style": false, "storage_class": "", "insecure": false, "allow_private": false,
		"local_enabled": true, "age_recipients": []string{pub}, "schedule": "30 2 * * *", "timezone": "Europe/Berlin",
		"keep_daily": 7, "keep_weekly": 4, "keep_monthly": 6, "stale_hours": 30,
	}
}

func put(e *circleEnv, user string, settings map[string]any, extra map[string]any) (int, []byte) {
	e.srv.backupLimiter().Reset("backup:settings:" + e.ids["A"])
	return putRaw(e, user, settings, extra)
}

func putRaw(e *circleEnv, user string, settings map[string]any, extra map[string]any) (int, []byte) {
	body := map[string]any{"settings": settings}
	for k, v := range extra {
		body[k] = v
	}
	code, _, raw := e.do(user, "PUT", "/api/admin/backups/settings", body)
	return code, raw
}

func TestBackupSettingsAuthorization(t *testing.T) {
	e := backupsEnv(t)
	_, pub, _ := genAgePub(t)
	for _, c := range []struct{ m, p string }{{"GET", "/api/admin/backups/settings"}, {"PUT", "/api/admin/backups/settings"}} {
		code, _, raw := e.do("B", c.m, c.p, map[string]any{"settings": goodSettings(pub)})
		if code != http.StatusForbidden || strings.Contains(string(raw), "bucket") {
			t.Fatalf("%s as non-admin: %d %s", c.m, code, raw)
		}
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM backup_settings`).Scan(&n)
	if n != 0 {
		t.Fatal("non-admin wrote settings")
	}
}

func TestBackupSettingsSaveEncryptsAndNeverLeaks(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	priv, pub, _ := genAgePub(t)
	code, raw := put(e, "A", goodSettings(pub), map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret})
	if code != 200 {
		t.Fatalf("save: %d %s", code, raw)
	}
	var out backupSettingsOut
	_ = json.Unmarshal(raw, &out)
	if out.Values.Bucket != "my-family-backups" || out.Sources["bucket"] != "ui" || !out.Credentials.SecretSet || out.Credentials.AccessKeyHint != "…MPLE" {
		t.Fatalf("response: %+v", out)
	}
	_, _, gr := e.do("A", "GET", "/api/admin/backups/settings", nil)
	all := string(raw) + string(gr)

	// Stored sealed: not readable in the table, readable with the key.
	var blob []byte
	var settings string
	_ = e.pool.QueryRow(ctx, `SELECT credentials_enc, settings::text FROM backup_settings`).Scan(&blob, &settings)
	if len(blob) == 0 || strings.Contains(string(blob), tSecret) || strings.Contains(settings, tSecret) || strings.Contains(settings, tKeyID) {
		t.Fatal("credentials not sealed at rest")
	}
	c, err := backupsettings.Open(e.srv.BackupSettingsKey, blob)
	if err != nil || c.SecretKey != tSecret || c.AccessKeyID != tKeyID {
		t.Fatalf("cannot open sealed credentials: %v", err)
	}
	wrong, _ := backupsettings.DeriveKey("another-secret-0123456789abcdef")
	if _, err := backupsettings.Open(wrong, blob); err == nil {
		t.Fatal("opened with the wrong key")
	}

	// Audit: field names only.
	var audit string
	_ = e.pool.QueryRow(ctx, `SELECT string_agg(action || ' ' || coalesce(detail,''), ' | ') FROM audit_log WHERE action = 'admin.backup.settings'`).Scan(&audit)
	if !strings.Contains(audit, "bucket") || !strings.Contains(audit, "credentials(replaced)") {
		t.Fatalf("audit: %q", audit)
	}
	// Update without credentials keeps them.
	s2 := goodSettings(pub)
	s2["prefix"] = "other-folder"
	if code, raw = put(e, "A", s2, nil); code != 200 {
		t.Fatalf("update: %d %s", code, raw)
	}
	all += string(raw)
	_ = e.pool.QueryRow(ctx, `SELECT credentials_enc FROM backup_settings`).Scan(&blob)
	if c, err := backupsettings.Open(e.srv.BackupSettingsKey, blob); err != nil || c.SecretKey != tSecret {
		t.Fatal("credentials lost on a settings-only update")
	}
	// Clear.
	if code, raw = put(e, "A", s2, map[string]any{"clear_credentials": true}); code != 400 {
		t.Fatalf("S3 enabled without credentials must be refused, got %d %s", code, raw)
	}
	s2["s3_enabled"] = false
	if code, raw = put(e, "A", s2, map[string]any{"clear_credentials": true}); code != 200 {
		t.Fatalf("clear: %d %s", code, raw)
	}
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM backup_settings WHERE credentials_enc IS NOT NULL`).Scan(new(int))

	for _, bad := range []string{tSecret, tKeyID, priv, "AGE-SECRET-KEY", "credentials_enc"} {
		if strings.Contains(all, bad) || strings.Contains(audit, bad) {
			t.Fatalf("secret material %q leaked", bad)
		}
	}
}

func TestBackupSettingsValidation(t *testing.T) {
	e := backupsEnv(t)
	priv, pub, _ := genAgePub(t)
	creds := map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret}
	try := func(name string, mut func(m map[string]any), wantField string) {
		t.Helper()
		m := goodSettings(pub)
		mut(m)
		code, raw := put(e, "A", m, creds)
		if code != 400 || !strings.Contains(string(raw), `"`+wantField+`"`) {
			t.Errorf("%s: want 400 on %s, got %d %s", name, wantField, code, raw)
		}
		for _, leak := range []string{tSecret, tKeyID, priv} {
			if strings.Contains(string(raw), leak) {
				t.Errorf("%s: error response leaks a secret", name)
			}
		}
	}
	try("private key as recipient", func(m map[string]any) { m["age_recipients"] = []string{priv} }, "age_recipients")
	try("garbage recipient", func(m map[string]any) { m["age_recipients"] = []string{"nope"} }, "age_recipients")
	try("unencrypted S3", func(m map[string]any) { m["age_recipients"] = []string{} }, "age_recipients")
	try("plain http", func(m map[string]any) { m["endpoint"] = "http://minio.example.com:9000" }, "endpoint")
	try("metadata ip", func(m map[string]any) { m["endpoint"] = "https://169.254.169.254" }, "endpoint")
	try("metadata ip even when private allowed", func(m map[string]any) {
		m["endpoint"] = "http://169.254.169.254"
		m["insecure"] = true
		m["allow_private"] = true
	}, "endpoint")
	try("gcp metadata name", func(m map[string]any) { m["endpoint"] = "https://metadata.google.internal" }, "endpoint")
	try("loopback without allow-private", func(m map[string]any) { m["endpoint"] = "https://127.0.0.1:9000" }, "endpoint")
	try("private without allow-private", func(m map[string]any) { m["endpoint"] = "https://192.168.1.20:9000" }, "endpoint")
	try("localhost", func(m map[string]any) { m["endpoint"] = "https://localhost:9000" }, "endpoint")
	try("credentials in url", func(m map[string]any) { m["endpoint"] = "https://u:p@s3.example.com" }, "endpoint")
	try("path in url", func(m map[string]any) { m["endpoint"] = "https://s3.example.com/x" }, "endpoint")
	try("ipv6 metadata", func(m map[string]any) { m["endpoint"] = "https://[fd00:ec2::254]" }, "endpoint")
	try("bad bucket", func(m map[string]any) { m["bucket"] = "Bad Bucket!" }, "bucket")
	try("bad prefix", func(m map[string]any) { m["prefix"] = "../x" }, "prefix")
	try("bad cron", func(m map[string]any) { m["schedule"] = "every day" }, "schedule")
	try("bad tz", func(m map[string]any) { m["timezone"] = "Mars/Base" }, "timezone")
	try("retention range", func(m map[string]any) { m["keep_daily"] = 99999 }, "keep_daily")
	try("stale range", func(m map[string]any) { m["stale_hours"] = 0 }, "stale_hours")

	// LAN MinIO is allowed when explicitly enabled.
	m := goodSettings(pub)
	m["endpoint"], m["insecure"], m["allow_private"], m["path_style"] = "http://192.168.1.20:9000", true, true, true
	if code, raw := put(e, "A", m, creds); code != 200 {
		t.Fatalf("LAN MinIO with the explicit flags must be accepted: %d %s", code, raw)
	}
	// Unknown JSON fields are refused.
	e.srv.backupLimiter().Reset("backup:settings:" + e.ids["A"])
	if code, _, _ := e.do("A", "PUT", "/api/admin/backups/settings", map[string]any{"settings": goodSettings(pub), "evil": 1}); code != 400 {
		t.Fatalf("unknown field accepted: %d", code)
	}
}

func TestBackupSettingsEnvPinnedFieldsAreReadOnly(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	_, pub, _ := genAgePub(t)
	cfg := `{"destinations":[],"encryption":"age-x25519","schedule":"0 4 * * *","timezone":"UTC","retention":{},"env":{"BACKUP_S3_BUCKET":"env-bucket","BACKUP_SCHEDULE":"0 4 * * *","BACKUP_AGE_RECIPIENT":"` + pub + `"},"env_secrets":["BACKUP_S3_SECRET_ACCESS_KEY","BACKUP_S3_ACCESS_KEY_ID"]}`
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_agent (id, version, config) VALUES (1,'x',$1) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now(), config = $1`, cfg); err != nil {
		t.Fatal(err)
	}
	_, _, raw := e.do("A", "GET", "/api/admin/backups/settings", nil)
	var out backupSettingsOut
	_ = json.Unmarshal(raw, &out)
	if out.Values.Bucket != "env-bucket" || out.Sources["bucket"] != "env" || out.Sources["region"] != "default" || !out.Credentials.Pinned || out.Credentials.Source != "env" {
		t.Fatalf("env pins not reported: %s", raw)
	}
	// Changing a pinned field is refused and names the field.
	m := goodSettings(pub)
	m["bucket"], m["schedule"] = "env-bucket", "0 4 * * *"
	m["age_recipients"] = []string{pub}
	m["bucket"] = "other-bucket"
	code, raw := put(e, "A", m, nil)
	if code != 400 || !strings.Contains(string(raw), `"bucket"`) || !strings.Contains(string(raw), "environment") {
		t.Fatalf("pinned bucket change accepted: %d %s", code, raw)
	}
	// Credentials cannot be overridden either.
	m["bucket"] = "env-bucket"
	code, raw = put(e, "A", m, map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret})
	if code != 400 || !strings.Contains(string(raw), `"credentials"`) {
		t.Fatalf("pinned credentials overridden: %d %s", code, raw)
	}
	// Environment credentials also pin the destination: endpoint "" (AWS), TLS on, private allowed.
	m["endpoint"], m["allow_private"] = "", true
	// Re-submitting the pinned value (as the UI does) is fine; the env value is not frozen into the UI layer.
	if code, raw = put(e, "A", m, nil); code != 200 {
		t.Fatalf("unchanged pinned values: %d %s", code, raw)
	}
	var stored string
	_ = e.pool.QueryRow(ctx, `SELECT settings->>'bucket' FROM backup_settings`).Scan(&stored)
	if stored == "env-bucket" {
		t.Fatal("the environment's bucket was copied into the UI layer")
	}
}

func TestBackupSettingsRateLimitAndTestPayload(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	_, pub, _ := genAgePub(t)
	e.agent(true, false)
	// Test with unsaved values: queued sealed, secret not in the table.
	body := map[string]any{"settings": goodSettings(pub), "access_key_id": tKeyID, "secret_access_key": tSecret}
	if code, _, raw := e.do("A", "POST", "/api/admin/backups/test-s3", body); code != http.StatusAccepted {
		t.Fatalf("test with payload: %d %s", code, raw)
	}
	var blob []byte
	_ = e.pool.QueryRow(ctx, `SELECT payload_enc FROM backup_requests ORDER BY id DESC LIMIT 1`).Scan(&blob)
	if len(blob) == 0 || strings.Contains(string(blob), tSecret) {
		t.Fatal("payload missing or not sealed")
	}
	if raw, err := backupsettings.OpenPayload(e.srv.BackupSettingsKey, blob); err != nil || !strings.Contains(string(raw), tSecret) {
		t.Fatalf("payload unreadable by the service: %v", err)
	}
	e.finishOpenRequests()
	// Invalid unsaved values are refused before anything is queued.
	bad := goodSettings(pub)
	bad["endpoint"] = "https://169.254.169.254"
	if code, _, _ := e.do("A", "POST", "/api/admin/backups/test-s3", map[string]any{"settings": bad, "access_key_id": tKeyID, "secret_access_key": tSecret}); code != 400 {
		t.Fatalf("SSRF target accepted for a test: %d", code)
	}
	// Rate limit on PUT.
	last := 0
	for i := 0; i < 25; i++ {
		last, _ = putRaw(e, "A", goodSettings(pub), map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret})
		if last == http.StatusTooManyRequests {
			break
		}
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("settings rate limit never triggered (last=%d)", last)
	}
}

func TestStaleHoursFromSavedSettings(t *testing.T) {
	e := backupsEnv(t)
	_, pub, _ := genAgePub(t)
	if code, raw := put(e, "A", goodSettings(pub), map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret}); code != 200 {
		t.Fatalf("%d %s", code, raw)
	}
	_, _, raw := e.do("A", "GET", "/api/admin/backups", nil)
	var b adminBackupsOut
	_ = json.Unmarshal(raw, &b)
	if b.StaleAfterHours != 30 {
		t.Fatalf("stale hours from UI: %d", b.StaleAfterHours)
	}
	e.srv.BackupStaleHours = 12 // environment wins
	_, _, raw = e.do("A", "GET", "/api/admin/backups", nil)
	_ = json.Unmarshal(raw, &b)
	if b.StaleAfterHours != 12 {
		t.Fatalf("env must win: %d", b.StaleAfterHours)
	}
}

func genAgePub(t *testing.T) (priv, pub string, err error) {
	t.Helper()
	id, err := generateAge()
	if err != nil {
		t.Fatal(err)
	}
	return id[0], id[1], nil
}

func generateAge() ([2]string, error) {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		return [2]string{}, err
	}
	return [2]string{id.String(), id.Recipient().String()}, nil
}

func TestSavedCredentialsAreBoundToTheirDestination(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	_, pub, _ := genAgePub(t)
	creds := map[string]any{"access_key_id": tKeyID, "secret_access_key": tSecret}
	if code, raw := put(e, "A", goodSettings(pub), creds); code != 200 {
		t.Fatalf("%d %s", code, raw)
	}
	e.agent(true, false)
	const msg = "Re-enter the access key and secret because the endpoint changed"
	for name, mut := range map[string]func(m map[string]any){
		"endpoint":      func(m map[string]any) { m["endpoint"] = "https://attacker.example.net" },
		"region":        func(m map[string]any) { m["region"] = "us-east-1" },
		"allow_private": func(m map[string]any) { m["allow_private"] = true },
		"insecure": func(m map[string]any) {
			m["insecure"] = true
			m["endpoint"] = "http://s3.eu-central-003.backblazeb2.com"
		},
		"empty endpoint (AWS)": func(m map[string]any) { m["endpoint"] = "" },
	} {
		m := goodSettings(pub)
		mut(m)
		// Save without credentials: refused.
		code, raw := put(e, "A", m, nil)
		if code != 400 || !strings.Contains(string(raw), msg) {
			t.Errorf("%s: save without re-entering credentials: %d %s", name, code, raw)
		}
		// Test of the unsaved values without credentials: refused, nothing queued.
		e.srv.backupLimiter().Reset("backup:test_s3:" + e.ids["A"])
		code, _, raw = e.do("A", "POST", "/api/admin/backups/test-s3", map[string]any{"settings": m})
		if code != 400 || !strings.Contains(string(raw), msg) {
			t.Errorf("%s: test without credentials: %d %s", name, code, raw)
		}
	}
	var n int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM backup_requests WHERE payload_enc IS NOT NULL`).Scan(&n)
	if n != 0 {
		t.Fatalf("%d test request(s) queued without credentials", n)
	}
	// With new credentials the same change is accepted and the binding follows.
	m := goodSettings(pub)
	m["endpoint"] = "https://s3.example.org"
	if code, raw := put(e, "A", m, creds); code != 200 {
		t.Fatalf("re-entered credentials refused: %d %s", code, raw)
	}
	// Unrelated changes (bucket, retention) keep working without re-entry.
	m["bucket"], m["keep_daily"] = "another-bucket", 9
	if code, raw := put(e, "A", m, nil); code != 200 {
		t.Fatalf("unrelated change refused: %d %s", code, raw)
	}
	// The shared layer refuses too (defence in depth), even if the API check were bypassed.
	st, _ := backupsettings.Load(ctx, e.pool, nil)
	st.Settings.Endpoint = "https://evil.example.net"
	if err := backupsettings.Save(ctx, e.pool, e.srv.BackupSettingsKey, st.Settings, nil, false, "", st.Settings.Binding()); err == nil {
		t.Fatal("Save accepted stored credentials for a different destination")
	}
	// A legacy blob without a binding is never trusted.
	blob, _ := backupsettings.Seal(e.srv.BackupSettingsKey, backupsettings.Credentials{AccessKeyID: tKeyID, SecretKey: tSecret})
	_, _ = e.pool.Exec(ctx, `UPDATE backup_settings SET credentials_enc = $1`, blob)
	e.srv.backupLimiter().Reset("backup:settings:" + e.ids["A"])
	if code, raw := put(e, "A", m, nil); code != 400 || !strings.Contains(string(raw), msg) {
		t.Fatalf("unbound legacy credentials accepted: %d %s", code, raw)
	}
}

func TestEnvCredentialsPinTheDestination(t *testing.T) {
	e := backupsEnv(t)
	ctx := context.Background()
	_, pub, _ := genAgePub(t)
	cfg := `{"destinations":[],"encryption":"age-x25519","env":{"BACKUP_S3_BUCKET":"env-bucket","BACKUP_AGE_RECIPIENT":"` + pub + `"},"env_secrets":["BACKUP_S3_SECRET_ACCESS_KEY","BACKUP_S3_ACCESS_KEY_ID"]}`
	if _, err := e.pool.Exec(ctx, `INSERT INTO backup_agent (id, version, config) VALUES (1,'x',$1) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now(), config = $1`, cfg); err != nil {
		t.Fatal(err)
	}
	_, _, raw := e.do("A", "GET", "/api/admin/backups/settings", nil)
	var out backupSettingsOut
	_ = json.Unmarshal(raw, &out)
	pinned := strings.Join(out.Pinned, ",")
	for _, f := range []string{"endpoint", "insecure", "allow_private", "credentials"} {
		if !strings.Contains(pinned, f) || out.Sources[f] != "env" && f != "credentials" {
			t.Fatalf("%s not pinned by environment credentials: %v %v", f, out.Pinned, out.Sources)
		}
	}
	for name, mut := range map[string]func(m map[string]any){
		"endpoint":      func(m map[string]any) { m["endpoint"] = "https://attacker.example.net" },
		"insecure":      func(m map[string]any) { m["insecure"] = true },
		"allow_private": func(m map[string]any) { m["allow_private"] = false },
	} {
		m := goodSettings(pub)
		m["bucket"], m["endpoint"], m["insecure"], m["allow_private"] = "env-bucket", out.Values.Endpoint, out.Values.Insecure, out.Values.AllowPrivate
		mut(m)
		code, raw := put(e, "A", m, nil)
		if code != 400 || !strings.Contains(string(raw), "environment") {
			t.Errorf("%s change with env credentials accepted: %d %s", name, code, raw)
		}
		e.srv.backupLimiter().Reset("backup:test_s3:" + e.ids["A"])
		if code, _, raw = e.do("A", "POST", "/api/admin/backups/test-s3", map[string]any{"settings": m}); code != 400 {
			t.Errorf("%s: test against another endpoint with env credentials accepted: %d %s", name, code, raw)
		}
	}
}
