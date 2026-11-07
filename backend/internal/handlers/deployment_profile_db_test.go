package handlers

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/atrest"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

// Deployment profile (docs/design/PRIVACY_PROCESSING.md section 21). Needs TEST_DATABASE_URL.

func TestDeploymentProfileEndToEnd(t *testing.T) {
	e := newSrvEnv(t)
	ctx := context.Background()
	e.route("GET", "/api/admin/settings/deployment-profile", e.srv.AdminGetDeploymentProfile)
	e.route("PUT", "/api/admin/settings/deployment-profile", e.srv.AdminPutDeploymentProfile)
	reset := func() {
		_, _ = e.pool.Exec(ctx, `UPDATE server_profile SET deployment_profile = NULL, profile_set_at = NULL, setup_dismissed_at = NULL WHERE id = 1`)
	}
	reset()
	t.Cleanup(reset)
	t.Setenv("DEPLOYMENT_PROFILE", "")

	// Unset: reported as unset, acted on as cloud, no server preselected even with a pinned key.
	e.pin()
	m := e.mustCode("A", "GET", "/api/admin/settings/deployment-profile", nil, 200)
	if m["profile"] != "" || m["effective"] != "cloud" || m["source"] != "unset" || m["recommended_lane"] != "phone" || m["server_pinned"] != true {
		t.Fatalf("unset: %v", m)
	}
	if dev, _ := m["server_device"].(map[string]any); dev == nil || dev["short"] == "" || dev["digits"] == "" {
		t.Fatalf("server device words missing: %v", m["server_device"])
	}
	_, app, _ := e.do("B", "GET", "/e2ee/server-device", nil)
	if app["profile_effective"] != "cloud" || app["recommended_lane"] != "phone" || app["deployment_profile"] != "" {
		t.Fatalf("app view unset: %v", app)
	}

	// Env seeds the profile; unset env value garbage is ignored.
	t.Setenv("DEPLOYMENT_PROFILE", "nonsense")
	if _, _, eff := e.srv.DeploymentProfile(ctx); eff != "cloud" {
		t.Fatal("garbage env must read as cloud")
	}
	t.Setenv("DEPLOYMENT_PROFILE", "home")
	m = e.mustCode("A", "GET", "/api/admin/settings/deployment-profile", nil, 200)
	if m["profile"] != "home" || m["source"] != "env" || m["recommended_lane"] != "server" {
		t.Fatalf("env home: %v", m)
	}

	// Home needs a deliberate confirmation; invalid values are refused.
	e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{"profile": "home"}, 400)
	e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{"profile": "lan"}, 400)
	e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{}, 400)

	// The admin's choice beats the environment; cloud keeps the phone default.
	m = e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{"profile": "cloud"}, 200)
	if m["profile"] != "cloud" || m["source"] != "admin" || m["recommended_lane"] != "phone" {
		t.Fatalf("cloud: %v", m)
	}
	m = e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{"profile": "home", "confirm_home": true}, 200)
	if m["effective"] != "home" || m["recommended_lane"] != "server" {
		t.Fatalf("home: %v", m)
	}
	_, app, _ = e.do("B", "GET", "/e2ee/server-device", nil)
	if app["profile_effective"] != "home" || app["recommended_lane"] != "server" {
		t.Fatalf("app view home: %v", app)
	}
	// Home without a pinned server key never preselects the server.
	_, _ = e.pool.Exec(ctx, `DELETE FROM e2ee_server_device`)
	m = e.mustCode("A", "GET", "/api/admin/settings/deployment-profile", nil, 200)
	if m["recommended_lane"] != "phone" {
		t.Fatalf("home without server key: %v", m)
	}
	// It consents for nobody.
	var n int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_processing_pref`).Scan(&n)
	if n != 0 {
		t.Fatalf("profile created %d prefs", n)
	}
	var audits int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'admin.deployment_profile_changed'`).Scan(&audits)
	if audits < 2 {
		t.Fatalf("profile change not audit-logged (%d)", audits)
	}
	// Setup card can be dismissed and restored.
	m = e.mustCode("A", "PUT", "/api/admin/settings/deployment-profile", map[string]any{"dismiss_setup": true}, 200)
	if m["setup_dismissed"] != true {
		t.Fatalf("dismiss: %v", m)
	}
	// Honest at-rest report: locations are never claimed encrypted.
	ar, _ := m["at_rest"].(map[string]any)
	if ar["locations_encrypted"] != false || ar["disk_encryption_known"] != false {
		t.Fatalf("at_rest overclaims: %v", ar)
	}
}

func TestProtectedSecretsAreSealedInTheDatabase(t *testing.T) {
	e := newSrvEnv(t)
	ctx := context.Background()
	atrest.SetDefault(atrest.NewKeyring(atrest.NewDEK()))
	t.Cleanup(func() { atrest.SetDefault(nil) })
	_, _ = e.pool.Exec(ctx, `DELETE FROM sms_settings`)
	t.Cleanup(func() { _, _ = e.pool.Exec(ctx, `DELETE FROM sms_settings`) })

	if _, err := e.pool.Exec(ctx, `INSERT INTO sms_settings (id, account_sid, auth_token, from_number, public_base_url) VALUES (1, 'ACx', $1, '+1', '')`, sealSMSToken("twilio-secret-token")); err != nil {
		t.Fatal(err)
	}
	var raw string
	_ = e.pool.QueryRow(ctx, `SELECT auth_token FROM sms_settings WHERE id = 1`).Scan(&raw)
	if !strings.HasPrefix(raw, atrest.Prefix) || strings.Contains(raw, "twilio-secret-token") {
		t.Fatalf("token not sealed in the database: %q", raw)
	}
	row, ok, err := e.srv.readSMSSettings(ctx)
	if err != nil || !ok || row.AuthToken != "twilio-secret-token" {
		t.Fatalf("read back: %+v %v %v", row, ok, err)
	}
	// Legacy plaintext still reads (and is sealed by SealExisting at start-up).
	_, _ = e.pool.Exec(ctx, `UPDATE sms_settings SET auth_token = 'plain-legacy' WHERE id = 1`)
	if row, _, _ := e.srv.readSMSSettings(ctx); row.AuthToken != "plain-legacy" {
		t.Fatal("legacy plaintext unreadable")
	}
	if n, err := atrest.SealExisting(ctx, e.pool); err != nil || n < 1 {
		t.Fatalf("seal existing: %d %v", n, err)
	}
	_ = e.pool.QueryRow(ctx, `SELECT auth_token FROM sms_settings WHERE id = 1`).Scan(&raw)
	if !strings.HasPrefix(raw, atrest.Prefix) {
		t.Fatalf("existing value not sealed: %q", raw)
	}
	if row, _, _ := e.srv.readSMSSettings(ctx); row.AuthToken != "plain-legacy" {
		t.Fatal("value changed by sealing")
	}
	// Without the key a sealed value is an error, never garbage.
	atrest.SetDefault(nil)
	if _, _, err := e.srv.readSMSSettings(ctx); err == nil {
		t.Fatal("sealed value read without the key")
	}
}

// Every column listed in atrest.Columns must have all of its readers and writers go through
// atrest, and the Dawarich keys (auth.SealSecret format) must stay out of the list and
// survive enabling protection, sealing existing rows and a rewrap.
func TestColumnsAreCoveredAndDawarichKeyRoundTrips(t *testing.T) {
	for _, c := range atrest.Columns {
		if strings.HasPrefix(c.Table, "dawarich") {
			t.Fatalf("%s must not be in atrest.Columns (it uses auth.SealSecret)", c.Table)
		}
	}
	e := newSrvEnv(t)
	ctx := context.Background()
	t.Cleanup(func() { atrest.SetDefault(nil); _, _ = e.pool.Exec(ctx, `DELETE FROM dawarich_settings; DELETE FROM at_rest_keys`) })
	_, _ = e.pool.Exec(ctx, `DELETE FROM dawarich_settings; DELETE FROM at_rest_keys`)

	if e.srv.TM == nil {
		e.srv.TM = auth.NewTokenManager("test-secret-test-secret-test-secret-00", time.Hour, time.Hour)
	}
	sealed, err := e.srv.sealDawarichKey("dawarich-key-123")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO dawarich_settings (id, base_url, api_key) VALUES (1, 'http://d', $1)`, sealed); err != nil {
		t.Fatal(err)
	}
	const k1 = "0123456789abcdef0123456789abcdef-one"
	t.Setenv("OPENFAMILY_DATA_KEY", k1)
	if _, err := atrest.Load(ctx, e.pool); err != nil {
		t.Fatal(err)
	}
	if _, err := atrest.SealExisting(ctx, e.pool); err != nil {
		t.Fatal(err)
	}
	row, ok, err := e.srv.readDawarich(ctx)
	if err != nil || !ok || row.APIKey != "dawarich-key-123" {
		t.Fatalf("dawarich key after enabling at-rest: %+v %v", row, err)
	}
	const k2 = "0123456789abcdef0123456789abcdef-two"
	if err := atrest.Rewrap(ctx, e.pool, k1, k2); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OPENFAMILY_DATA_KEY", k2)
	if _, err := atrest.Load(ctx, e.pool); err != nil {
		t.Fatal(err)
	}
	if row, _, err := e.srv.readDawarich(ctx); err != nil || row.APIKey != "dawarich-key-123" {
		t.Fatalf("dawarich key after rewrap: %+v %v", row, err)
	}
}
