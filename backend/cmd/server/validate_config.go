package main

import (
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	mid "github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// finding is one configuration problem with a remediation. Messages name the
// variable but never include its value, so the report is safe to paste into
// an issue or CI log (secrets are never printed).
type finding struct {
	Level string // "error" or "warning"
	Key   string
	Msg   string
	Fix   string
}

// validateConfig inspects cfg and returns every problem found. It reuses
// Config.Validate (the boot-time gate) so the command can never disagree with
// the server, then adds non-fatal and format checks.
func validateConfig(cfg config.Config) []finding {
	var out []finding
	add := func(level, key, msg, fix string) { out = append(out, finding{level, key, msg, fix}) }

	if err := cfg.Validate(); err != nil {
		var errs []error
		if j, ok := err.(interface{ Unwrap() []error }); ok {
			errs = j.Unwrap()
		} else {
			errs = []error{err}
		}
		for _, e := range errs {
			msg := e.Error()
			key, fix := "config", "See docs/self-hosting.md."
			switch {
			case strings.HasPrefix(msg, "JWT_SECRET"):
				key, fix = "JWT_SECRET", "Generate one with: openssl rand -hex 32 (or run ./scripts/setup.sh)."
			case strings.HasPrefix(msg, "DATABASE_URL must be explicitly"):
				key, fix = "DATABASE_URL", "Set DATABASE_URL to your Postgres connection string."
			case strings.HasPrefix(msg, "DATABASE_URL"):
				key, fix = "DATABASE_URL", "Use sslmode=require or verify-full, or set DB_SSL_DISABLE_OK=true if Postgres is only reachable on a private network."
			case strings.HasPrefix(msg, "TLS"):
				key, fix = "TLS_BEHIND_PROXY", "Set TLS_CERT_FILE and TLS_KEY_FILE, or TLS_BEHIND_PROXY=true behind a TLS proxy (INSECURE_HTTP=true only on trusted private networks)."
			}
			add("error", key, msg, fix)
		}
	}

	if cfg.TLSCertFile != "" || cfg.TLSKeyFile != "" {
		if cfg.TLSCertFile == "" || cfg.TLSKeyFile == "" {
			add("error", "TLS_CERT_FILE", "TLS_CERT_FILE and TLS_KEY_FILE must be set together", "Set both, or neither.")
		} else {
			for k, p := range map[string]string{"TLS_CERT_FILE": cfg.TLSCertFile, "TLS_KEY_FILE": cfg.TLSKeyFile} {
				if st, err := os.Stat(p); err != nil || st.IsDir() {
					add("error", k, "file is missing or unreadable", "Mount the file into the container and point "+k+" at its path.")
				}
			}
		}
	}
	if cfg.InsecureHTTP {
		add("warning", "INSECURE_HTTP", "cleartext HTTP is enabled; location data is not encrypted in transit", "Put TLS in front (docker compose --profile proxy) and unset INSECURE_HTTP.")
	}
	if cfg.AppEnv != "production" {
		add("warning", "APP_ENV", "APP_ENV is not \"production\"; database TLS enforcement is relaxed", "Set APP_ENV=production for real deployments.")
	}
	if cfg.PublicBaseURL != "" {
		if u, err := url.Parse(cfg.PublicBaseURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			add("error", "PUBLIC_BASE_URL", "must be an absolute http(s) URL", "Example: https://openfamily.example.com")
		} else if u.Scheme == "http" && cfg.AppEnv == "production" {
			add("warning", "PUBLIC_BASE_URL", "uses http:// in production", "Use https:// so share links and invites are secure.")
		}
	} else {
		add("warning", "PUBLIC_BASE_URL", "not set; share links and invites cannot embed an absolute URL", "Set PUBLIC_BASE_URL to the public https URL.")
	}
	if cfg.TrustedProxies != "" {
		if _, err := mid.ParseTrustedProxies(cfg.TrustedProxies); err != nil {
			add("error", "TRUSTED_PROXIES", "is not a valid comma-separated list of IPs/CIDRs", "Example: 10.0.0.0/8,172.16.0.0/12")
		}
	}
	for k, v := range map[string]string{"TILE_URL": cfg.TileURL, "SATELLITE_TILE_URL": cfg.SatelliteTileURL, "MAP_STYLE_URL": cfg.MapStyleURL, "NTFY_BASE_URL": cfg.NtfyBaseURL} {
		if v == "" {
			continue
		}
		if u, err := url.Parse(v); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			add("error", k, "must be an absolute http(s) URL", "Fix or unset "+k+".")
		}
	}
	if cfg.GeocoderType != "photon" && cfg.GeocoderType != "nominatim" && cfg.GeocoderType != "" {
		add("warning", "GEOCODER_TYPE", "unrecognised geocoder type", "Use photon or nominatim.")
	}
	if (cfg.PlatformAdminEmail == "") != (cfg.PlatformAdminPassword == "") {
		add("error", "PLATFORM_ADMIN_EMAIL", "PLATFORM_ADMIN_EMAIL and PLATFORM_ADMIN_PASSWORD must be set together", "Set both or neither.")
	}
	if cfg.PlatformAdminPassword != "" && len(cfg.PlatformAdminPassword) < 12 {
		add("warning", "PLATFORM_ADMIN_PASSWORD", "is shorter than 12 characters", "Use a longer password.")
	}
	if tw := []string{cfg.TwilioAccountSID, cfg.TwilioAuthToken, cfg.TwilioFrom}; (tw[0] != "" || tw[1] != "" || tw[2] != "") && (tw[0] == "" || tw[1] == "" || tw[2] == "") {
		add("error", "TWILIO_ACCOUNT_SID", "Twilio is partially configured", "Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN and TWILIO_FROM together, or none.")
	}
	if ap := []string{cfg.APNsKeyFile, cfg.APNsKeyID, cfg.APNsTeamID, cfg.APNsTopic}; (ap[0] != "" || ap[1] != "" || ap[2] != "" || ap[3] != "") && (ap[0] == "" || ap[1] == "" || ap[2] == "" || ap[3] == "") {
		add("error", "APNS_KEY_FILE", "APNs is partially configured", "Set APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC together, or none.")
	}
	return out
}

// runValidateConfig prints the report and returns the process exit code:
// 0 when there are no errors (warnings alone are fine), 1 otherwise.
func runValidateConfig(w io.Writer, cfg config.Config) int {
	fs := validateConfig(cfg)
	nerr := 0
	for _, f := range fs {
		if f.Level == "error" {
			nerr++
		}
		fmt.Fprintf(w, "%-7s %s: %s\n        fix: %s\n", strings.ToUpper(f.Level), f.Key, f.Msg, f.Fix)
	}
	if nerr > 0 {
		fmt.Fprintf(w, "\nconfiguration INVALID: %d error(s)\n", nerr)
		return 1
	}
	fmt.Fprintln(w, "\nconfiguration OK")
	return 0
}
