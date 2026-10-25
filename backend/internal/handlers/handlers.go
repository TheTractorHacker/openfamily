// Package handlers implements the HTTP and WebSocket API endpoints.
package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// Server holds shared dependencies for all handlers.
type Server struct {
	Pool *pgxpool.Pool
	TM   *auth.TokenManager
	Push push.Dispatcher

	// VerbosePush controls whether push notifications include the tracked
	// user's name. When false (default), pushes name the place but omit the
	// user ("A family member arrived at School"); when true, they also include
	// the user's name ("Mom arrived at School").
	VerbosePush bool

	// NtfyBaseURL is the public ntfy origin advertised by GET /config.
	NtfyBaseURL string

	// APNsConfigured is true when the operator set an APNs key file. The
	// client uses this to skip iOS token registration when APNs cannot work.
	APNsConfigured bool

	// SMSEnv is the process environment fallback used when no admin
	// settings row exists (or a field on that row is empty).
	SMSEnv sms.Settings

	// SMS sends optional Twilio messages. A no-op dispatcher is used when
	// Twilio is unset so alerts still work in-app. Replaced at runtime when
	// an admin saves settings; readers must use SMSEnabled/sendSMS.
	smsMu sync.RWMutex
	SMS   sms.Dispatcher

	// AlertLimit rate-limits SOS and similar fan-out per user.
	AlertLimit *sms.Limiter

	// AlertCfg holds the configurable alert/SMS ceilings (see AlertLimits).
	AlertCfg AlertLimits

	// AuthLimit rate-limits login, register, refresh, and family join.
	AuthLimit *sms.Limiter

	// LocationLimit rate-limits POST /locations ingest per user so a
	// misbehaving or compromised client cannot flood the database. Nil
	// (tests) disables the check.
	LocationLimit *sms.Limiter

	// TileURL and SatelliteTileURL are raster templates advertised on GET /config.
	TileURL          string
	SatelliteTileURL string
	MapStyleURL string

	// PublicBaseURL is the https origin used to build SMS share links.
	PublicBaseURL string

	// SiteAddress is the public address Caddy serves (config: SITE_ADDRESS,
	// e.g. "openfamily.example.com" or ":80" for local dev). Read-only input
	// for the admin domain status card; the API never changes it.
	SiteAddress string

	// AllowedOrigin is the single cross-origin origin allowed for the WebSocket
	// stream (empty = same-origin only). It mirrors config.AllowedOrigin.
	AllowedOrigin string

	// RequireInvite gates registration behind an invite code. When true, a new
	// user must present a valid invite code to register (the auto-created first
	// platform admin is the only exception). Set from config: true whenever
	// PLATFORM_ADMIN_EMAIL is configured, so a managed server is closed by
	// default.
	RequireInvite bool

	// APKDir is the directory served by GET /api/admin/apk and where the latest
	// v* GitHub Release APK is cached (config: APK_DIR). Empty disables APK features.
	APKDir string
	// APKGitHubRepo is "owner/name" for the v* GitHub Release that holds the APK
	// (config: APK_GITHUB_REPO). Empty skips GitHub and serves APKDir as-is.
	APKGitHubRepo string
	// APKGitHubToken optionally authenticates GitHub API calls (config:
	// APK_GITHUB_TOKEN). The public OpenFamily repository does not need it.
	APKGitHubToken string
	// FlutterAppDir is the Flutter project root used by POST /api/admin/apk/build
	// (config: FLUTTER_APP_DIR, default "./app").
	FlutterAppDir string

	// BuildVersion is the git ref this binary was built from (ldflags; "dev" in
	// source runs). Shown read-only in the admin panel.
	BuildVersion string

	// apk tracks the platform APK build job state (at most one concurrent build).
	apk apkManager

	// viewAudit throttles repeated identical platform-admin location-view
	// audit rows. Nil writes every row.
	viewAudit *sms.Limiter

	// auditHook, when set (tests), receives audit entries instead of the DB.
	auditHook func(userID, familyID, action, detail string)

	// RefreshStore tracks refresh-token families for rotation and reuse
	// detection. Nil means the Postgres-backed store over Pool.
	RefreshStore refreshStore

	// hub fans out live location updates to connected WebSocket clients.
	hub *hub

	// locationRequests coalesces simultaneous on-demand refreshes and prevents
	// repeated map taps from waking the same phone more than once per cooldown.
	locationRequests *locationRequestGate

	// staleWatchdog rate-limits the automatic refresh requests sent when a
	// family snapshot shows a member has gone quiet (one attempt per member
	// per watchdog cooldown, independent of the user-facing cooldown).
	staleWatchdog *staleRequestGate
}

// New builds a Server.
func New(pool *pgxpool.Pool, tm *auth.TokenManager, push push.Dispatcher) *Server {
	return &Server{
		Pool:             pool,
		TM:               tm,
		Push:             push,
		hub:              newHub(),
		viewAudit:        sms.NewLimiter(),
		locationRequests: newLocationRequestGate(locationRequestCooldown),
		staleWatchdog:    newStaleRequestGate(staleRequestCooldown),
	}
}

// refreshSessions returns the refresh-token store.
func (s *Server) refreshSessions() refreshStore {
	if s.RefreshStore != nil {
		return s.RefreshStore
	}
	return pgRefreshStore{s.Pool}
}

// familyIDForUser resolves a user's current family ID from the database. It
// returns "" when the user has no family. This is preferred over the JWT
// family claim, which can go stale when a user joins or creates a family.
func (s *Server) familyIDForUser(ctx context.Context, userID string) (string, error) {
	var fid *string
	err := s.Pool.QueryRow(ctx, `SELECT family_id FROM users WHERE id = $1`, userID).Scan(&fid)
	if err != nil {
		return "", err
	}
	if fid == nil {
		return "", nil
	}
	return *fid, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
