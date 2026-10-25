// Package config loads server configuration from environment variables.
package config

import (
	"errors"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

// Insecure defaults that must never be used in production.
const (
	defaultDatabaseURL = "postgres://openfamily:openfamily@localhost:5432/openfamily?sslmode=disable"
	insecureJWTSecret  = "change-me-in-production"

	// DefaultTileURL is the public OSM raster template. Operators override
	// TILE_URL when they want another provider or a self-hosted endpoint.
	DefaultTileURL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
	// DefaultSatelliteTileURL is Esri World Imagery. Override with SATELLITE_TILE_URL.
	DefaultSatelliteTileURL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
)

// Config holds all runtime configuration, sourced from environment variables.
type Config struct {
	// HTTPAddr is the listen address for the HTTP server, e.g. ":8080".
	HTTPAddr string

	// DatabaseURL is the PostgreSQL connection string (postgres://...).
	DatabaseURL string

	// JWTSecret signs access and refresh tokens. Must be a long random string.
	JWTSecret string

	// AccessTokenTTL is the lifetime of a short-lived access token.
	AccessTokenTTL time.Duration

	// RefreshTokenTTL is the lifetime of a refresh token.
	RefreshTokenTTL time.Duration

	// AllowedOrigin is the CORS origin allowed for the API (empty = same-origin only).
	AllowedOrigin string

	// AppEnv is the deployment environment: "development" (default) or
	// "production". Production enables fail-fast checks for insecure defaults.
	AppEnv string

	// TLSCertFile and TLSKeyFile enable direct HTTPS when both are set. A
	// reverse proxy (Caddy/nginx) remains the recommended production path, but
	// direct TLS is supported for self-hosted deployments.
	TLSCertFile string
	TLSKeyFile  string

	// TLSBehindProxy acknowledges that a reverse proxy terminates TLS, so the
	// app may serve plain HTTP on a private network even in production.
	TLSBehindProxy bool

	// InsecureHTTP explicitly opts out of the TLS requirement (e.g. for a
	// self-hosted deployment on a trusted private network). It logs a loud
	// warning; do not use it to serve cleartext location data on the public
	// internet.
	InsecureHTTP bool

	// VerbosePush controls push content. When false (default), pushes name the
	// PLACE but omit the tracked USER's name ("A family member arrived at
	// School"), so the push provider never sees who. When true, pushes also
	// include the user's name ("Mom arrived at School"). The place name is a
	// user-defined label, not a coordinate, so it is safe to include in both
	// modes.
	VerbosePush bool

	// NtfyBaseURL is the public ntfy origin (no trailing slash) exposed by
	// GET /config so a generic APK can register UnifiedPush without a
	// dart-define. Empty means the client should skip ntfy-specific hints.
	NtfyBaseURL string

	// TileURL and SatelliteTileURL are raster {z}/{x}/{y} templates advertised
	// on GET /config. Empty env uses the public OSM / Esri defaults. A provider
	// API key belongs in the URL (query or path); /config is public, so treat
	// that key as app-visible quota, not a server secret.
	TileURL          string
	SatelliteTileURL string

	// APNs push notification credentials (optional; empty KeyFile disables APNs).
	APNsKeyFile    string
	APNsKeyID      string
	APNsTeamID     string
	APNsTopic      string
	APNsProduction bool

	// PlatformAdminEmail bootstraps the first platform admin. When set, on
	// startup the server promotes the existing user with this email to
	// platform_admin = TRUE (the platform-admin flag is added by migration
	// 000013). If no user with that email exists yet, the server auto-creates
	// the account (using PlatformAdminPassword) so the admin is the FIRST user
	// to log in. Empty disables promotion (admin panel is simply unreachable
	// until an operator sets it). The comparison is case-insensitive on the
	// lowercased email column.
	PlatformAdminEmail string

	// PlatformAdminPassword is the password for the auto-created first admin
	// account. It is only used when PlatformAdminEmail is set and no user with
	// that email exists yet. Empty means the account cannot be auto-created
	// (the operator must register it manually first, as before).
	PlatformAdminPassword string

	// APKDir is the directory served by GET /api/admin/apk and where the latest
	// GitHub Release APK is cached. Empty disables APK download (the endpoint
	// returns a clear "not configured" error). Should be an absolute path or
	// resolvable from the server's working directory.
	APKDir string

	// APKGitHubRepo is the "owner/name" repository whose latest published v*
	// semver GitHub Release holds the Android APK. Empty disables GitHub
	// fetch and serves whatever is already in APKDir (used by the optional
	// on-server build).
	APKGitHubRepo string

	// APKGitHubToken is a GitHub PAT used to fetch release assets. Required
	// when the repository is private (Contents: Read is enough).
	APKGitHubToken string

	// FlutterAppDir is the Flutter project root (containing pubspec.yaml) used
	// by POST /api/admin/apk/build to run "flutter build apk". Defaults to "./app"
	// (the repo's Flutter app). The build is only attempted when the flutter
	// binary is on PATH (exec.LookPath).
	FlutterAppDir string

	// BuildVersion is the git ref embedded at build time (ldflags -X). "dev"
	// for source runs; the updater sidecar's DEPLOY_REF_FILE takes precedence
	// at runtime when present.
	BuildVersion string

	// DeployRefFile is the file where the updater sidecar records the deployed
	// git ref (config: DEPLOY_REF_FILE). Read at request time so the admin
	// panel shows which commit is running. Empty disables the lookup.
	DeployRefFile string

	// UpdaterURL is the base URL of the updater sidecar service that applies
	// server updates (config: UPDATER_URL, e.g. http://updater:8081). Empty
	// disables self-update: the admin button reports versions only.
	UpdaterURL string

	// UpdaterToken is the shared secret required by the updater sidecar
	// (config: UPDATER_TOKEN). Must match the sidecar's value exactly.
	UpdaterToken string

	// Twilio credentials. Empty AccountSID, AuthToken, or From disables SMS;
	// in-app push and WebSocket alerts still work.
	TwilioAccountSID string
	TwilioAuthToken  string
	TwilioFrom       string

	// PublicBaseURL is the https origin used in SMS share links
	// (https://example.com/alerts/share/{token}). Empty or non-https falls
	// back to putting lat/lon in the SMS body.
	PublicBaseURL string

	// SiteAddress is the public address Caddy serves (config: SITE_ADDRESS,
	// e.g. "openfamily.example.com" or ":80" for local HTTP-only dev). It is
	// passed through to the api service so the admin panel can show domain
	// status; empty means "not configured".
	SiteAddress string

	// TrustedProxies is a comma-separated list of CIDRs/IPs of reverse proxies
	// whose X-Forwarded-For header is believed (config: TRUSTED_PROXIES). Empty
	// means: trust the private/loopback ranges when TLS_BEHIND_PROXY=true (the
	// compose Caddy setup), otherwise trust nobody and use the TCP peer
	// address. "none" forces trusting nobody.
	TrustedProxies string

	// IngestKeyTTL is the sliding server-side lifetime of a device ingest key
	// (config: INGEST_KEY_TTL, default 90 days; 0 disables expiry). Each use in
	// the second half of the window renews it.
	IngestKeyTTL time.Duration
}

// buildVersion is overridden at build time with:
//
//	-ldflags "-X github.com/wheresfrank/openfamily/backend/internal/config.buildVersion=$(git rev-parse --short HEAD)"
var buildVersion = "dev"

// BuildVersion returns the git ref embedded at build time ("dev" by default).
func BuildVersion() string { return buildVersion }

// Load reads configuration from the environment, applying sensible defaults.
func Load() Config {
	return Config{
		HTTPAddr:              getenv("HTTP_ADDR", ":8080"),
		DatabaseURL:           getenv("DATABASE_URL", defaultDatabaseURL),
		JWTSecret:             getenv("JWT_SECRET", ""),
		AccessTokenTTL:        getenvDuration("ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL:       getenvDuration("REFRESH_TOKEN_TTL", 30*24*time.Hour),
		AllowedOrigin:         getenv("ALLOWED_ORIGIN", ""),
		AppEnv:                getenv("APP_ENV", "development"),
		TLSCertFile:           getenv("TLS_CERT_FILE", ""),
		TLSKeyFile:            getenv("TLS_KEY_FILE", ""),
		TLSBehindProxy:        getenvBool("TLS_BEHIND_PROXY", false),
		InsecureHTTP:          getenvBool("INSECURE_HTTP", false),
		VerbosePush:           getenvBool("VERBOSE_PUSH", false),
		NtfyBaseURL:           strings.TrimRight(getenv("NTFY_BASE_URL", ""), "/"),
		TileURL:               getenv("TILE_URL", DefaultTileURL),
		SatelliteTileURL:      getenv("SATELLITE_TILE_URL", DefaultSatelliteTileURL),
		APNsKeyFile:           getenv("APNS_KEY_FILE", ""),
		APNsKeyID:             getenv("APNS_KEY_ID", ""),
		APNsTeamID:            getenv("APNS_TEAM_ID", ""),
		APNsTopic:             getenv("APNS_TOPIC", ""),
		APNsProduction:        getenvBool("APNS_PRODUCTION", false),
		PlatformAdminEmail:    getenv("PLATFORM_ADMIN_EMAIL", ""),
		PlatformAdminPassword: getenv("PLATFORM_ADMIN_PASSWORD", ""),
		APKDir:                getenv("APK_DIR", ""),
		APKGitHubRepo:         getenv("APK_GITHUB_REPO", ""),
		APKGitHubToken:        getenv("APK_GITHUB_TOKEN", ""),
		FlutterAppDir:         getenv("FLUTTER_APP_DIR", "./app"),
		BuildVersion:          buildVersion,
		DeployRefFile:         getenv("DEPLOY_REF_FILE", ""),
		UpdaterURL:            strings.TrimRight(getenv("UPDATER_URL", ""), "/"),
		UpdaterToken:          getenv("UPDATER_TOKEN", ""),
		TwilioAccountSID:      getenv("TWILIO_ACCOUNT_SID", ""),
		TwilioAuthToken:       getenv("TWILIO_AUTH_TOKEN", ""),
		TwilioFrom:            getenv("TWILIO_FROM", ""),
		PublicBaseURL:         strings.TrimRight(getenv("PUBLIC_BASE_URL", ""), "/"),
		SiteAddress:           strings.TrimSpace(getenv("SITE_ADDRESS", "")),
		TrustedProxies:        strings.TrimSpace(getenv("TRUSTED_PROXIES", "")),
		IngestKeyTTL:          getenvDuration("INGEST_KEY_TTL", 90*24*time.Hour),
	}
}

// Validate returns an error describing any insecure configuration. It fails
// fast on a missing/insecure JWT secret and on missing TLS in every environment,
// and on insecure database defaults in production.
func (c Config) Validate() error {
	var errs []error
	if c.JWTSecret == "" || c.JWTSecret == insecureJWTSecret || len(c.JWTSecret) < 32 {
		errs = append(errs, errors.New("JWT_SECRET must be set to a long random value (at least 32 bytes)"))
	}
	if c.AppEnv == "production" {
		if c.DatabaseURL == "" || c.DatabaseURL == defaultDatabaseURL {
			errs = append(errs, errors.New("DATABASE_URL must be explicitly configured in production"))
		} else if strings.Contains(c.DatabaseURL, "sslmode=disable") {
			errs = append(errs, errors.New("DATABASE_URL must not use sslmode=disable in production"))
		}
	}
	// TLS is required in every environment: cleartext lat/lon must never be
	// served silently. An explicit INSECURE_HTTP=true opt-out is allowed (with
	// a loud warning) for trusted private networks.
	if (c.TLSCertFile == "" || c.TLSKeyFile == "") && !c.TLSBehindProxy {
		if c.InsecureHTTP {
			slog.Warn("config: INSECURE_HTTP=true — serving cleartext HTTP; location data is not encrypted in transit")
		} else {
			errs = append(errs, errors.New("TLS must be configured (TLS_CERT_FILE/TLS_KEY_FILE) or TLS_BEHIND_PROXY=true; set INSECURE_HTTP=true to explicitly opt out"))
		}
	}
	return errors.Join(errs...)
}

func getenvBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return fallback
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}
