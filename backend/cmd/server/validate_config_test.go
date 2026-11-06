package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

const goodSecret = "0123456789abcdef0123456789abcdef-SECRETVALUE"

func good() config.Config {
	return config.Config{AppEnv: "production", JWTSecret: goodSecret, TLSBehindProxy: true,
		DatabaseURL: "postgres://u:p@db/x?sslmode=require", PublicBaseURL: "https://of.example.com", GeocoderType: "photon"}
}

func TestValidateConfigOK(t *testing.T) {
	var b bytes.Buffer
	if rc := runValidateConfig(&b, good()); rc != 0 {
		t.Fatalf("rc=%d\n%s", rc, b.String())
	}
	if !strings.Contains(b.String(), "configuration OK") {
		t.Fatal(b.String())
	}
}

func TestValidateConfigFailsAndNeverPrintsSecrets(t *testing.T) {
	c := good()
	c.JWTSecret = "short"
	c.DatabaseURL = "postgres://u:hunter2pw@db/x?sslmode=disable"
	c.TwilioAccountSID = "ACsecretsid"
	c.TrustedProxies = "not-a-cidr"
	var b bytes.Buffer
	if rc := runValidateConfig(&b, c); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	out := b.String()
	for _, want := range []string{"JWT_SECRET", "DATABASE_URL", "TWILIO_ACCOUNT_SID", "TRUSTED_PROXIES", "fix:"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	for _, secret := range []string{"hunter2pw", "ACsecretsid", "short\n"} {
		if strings.Contains(out, secret) {
			t.Errorf("leaked %q", secret)
		}
	}
}

func TestValidateConfigWarningsAreNotFatal(t *testing.T) {
	c := good()
	c.PublicBaseURL = ""
	var b bytes.Buffer
	if rc := runValidateConfig(&b, c); rc != 0 || !strings.Contains(b.String(), "WARNING") {
		t.Fatalf("rc=%d\n%s", rc, b.String())
	}
}
