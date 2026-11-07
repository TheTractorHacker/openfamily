package backup

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

func TestResolveConfigEnvWinsUIFillsTheRest(t *testing.T) {
	_, pub, _ := GenerateKeyPair()
	st := &backupsettings.Stored{Exists: true, Settings: backupsettings.Defaults(),
		Creds: &backupsettings.Credentials{AccessKeyID: "UIKEYID12", SecretKey: "ui-secret-value"}}
	st.Settings.S3Enabled, st.Settings.Bucket, st.Settings.Region = true, "ui-bucket", "ui-region"
	st.Settings.AgeRecipients = []string{pub}
	st.Settings.Schedule, st.Settings.KeepDaily = "5 1 * * *", 3

	// UI only.
	c, err := ResolveConfig(env(map[string]string{}), st)
	if err != nil || c.S3 == nil || c.S3.Bucket != "ui-bucket" || c.S3.AccessKeyID != "UIKEYID12" || c.Schedule != "5 1 * * *" || c.Retention.Daily != 3 || c.S3.Prefix != "openfamily" {
		t.Fatalf("ui only: %+v %v", c, err)
	}
	// Env pins bucket and schedule; UI keeps the rest.
	c, err = ResolveConfig(env(map[string]string{"BACKUP_S3_BUCKET": "env-bucket", "BACKUP_SCHEDULE": "0 5 * * *"}), st)
	if err != nil || c.S3.Bucket != "env-bucket" || c.S3.Region != "ui-region" || c.Schedule != "0 5 * * *" || c.Retention.Daily != 3 {
		t.Fatalf("env wins: %+v %v", c.S3, err)
	}
	if c.EnvPublic["BACKUP_S3_BUCKET"] != "env-bucket" {
		t.Fatalf("pins not reported: %v", c.EnvPublic)
	}
	// Disabling S3 in the UI really disables it.
	st.Settings.S3Enabled = false
	if c, err = ResolveConfig(env(map[string]string{}), st); err != nil || c.S3 != nil {
		t.Fatalf("disabled: %v %v", c.S3, err)
	}
	// Guards still apply to UI-sourced values.
	st.Settings.S3Enabled, st.Settings.AgeRecipients = true, nil
	if _, err = ResolveConfig(env(map[string]string{}), st); err == nil {
		t.Fatal("unencrypted S3 from the UI accepted")
	}
	st.Settings.AgeRecipients = []string{pub}
	st.Settings.Endpoint = "http://minio:9000"
	if _, err = ResolveConfig(env(map[string]string{}), st); err == nil {
		t.Fatal("plain http from the UI accepted without the insecure flag")
	}
	st.Settings.Endpoint, st.Settings.AllowPrivate = "https://169.254.169.254", true
	if _, err = ResolveConfig(env(map[string]string{}), st); err == nil {
		t.Fatal("metadata endpoint accepted")
	}
	st.Settings.Endpoint = "https://10.0.0.5:9000"
	if _, err = ResolveConfig(env(map[string]string{}), st); err != nil {
		t.Fatalf("LAN endpoint with allow_private refused: %v", err)
	}
	st.Settings.AllowPrivate = false
	if _, err = ResolveConfig(env(map[string]string{}), st); err == nil {
		t.Fatal("LAN endpoint accepted without allow_private")
	}
}

func TestS3DialIsGuardedAfterResolution(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer srv.Close()
	// "localhost" passes literal checks when allowed, but the guard re-checks the dialed IP.
	cfg := &S3Config{Endpoint: "http://" + strings.Replace(srv.Listener.Addr().String(), "127.0.0.1", "localhost", 1), Insecure: true,
		Bucket: "bkt", AccessKeyID: "AKIAXXXX", SecretKey: "secretsecret", AllowPrivate: false}
	st, err := NewS3Store(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := st.List(ctx); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("loopback dial not refused: %v", err)
	}
}
