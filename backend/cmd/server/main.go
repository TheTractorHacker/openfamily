// Command server runs the OpenFamily API.
package main

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/geocode"
	"github.com/TheTractorHacker/openfamily/backend/internal/db"
	handlers "github.com/TheTractorHacker/openfamily/backend/internal/handlers"
	mid "github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
	web "github.com/TheTractorHacker/openfamily/backend/web"
)

func main() {
	cfg := config.Load()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	// Fail fast on insecure configuration (missing/insecure JWT secret, and
	// insecure database/TLS defaults in production).
	if err := cfg.Validate(); err != nil {
		slog.Error("invalid configuration", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Apply migrations before serving.
	if err := db.Migrate(cfg.DatabaseURL); err != nil {
		slog.Error("migration failed", "err", err)
		os.Exit(1)
	}
	slog.Info("migrations applied")

	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("database connection failed", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	mid.IngestKeyTTL = cfg.IngestKeyTTL
	tm := auth.NewTokenManager(cfg.JWTSecret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)
	dispatcher := push.NewDispatcher(push.APNsConfig{
		KeyFile:    cfg.APNsKeyFile,
		KeyID:      cfg.APNsKeyID,
		TeamID:     cfg.APNsTeamID,
		Topic:      cfg.APNsTopic,
		Production: cfg.APNsProduction,
	})
	srv := handlers.New(pool, tm, dispatcher)
	if cfg.DirectPush {
		srv.Direct = push.NewDirectBroker(pool)
		dispatcher.SetDirect(srv.Direct)
		go srv.RunPushJanitor(ctx)
	}
	srv.VerbosePush = cfg.VerbosePush
	srv.NtfyBaseURL = cfg.NtfyBaseURL
	srv.TileURL = cfg.TileURL
	srv.SatelliteTileURL = cfg.SatelliteTileURL
	srv.MapStyleURL = cfg.MapStyleURL
	srv.APNsConfigured = cfg.APNsKeyFile != ""
	if geo, err := geocode.New(geocode.Settings{
		URL: cfg.GeocoderURL, Type: cfg.GeocoderType, Lang: cfg.GeocoderLang,
		AllowPrivate: cfg.GeocoderAllowPrivate, Version: config.BuildVersion(),
		FallbackURL: cfg.GeocoderFallbackURL, CensusEnabled: cfg.GeocoderCensusEnabled,
		GoogleAPIKey: cfg.GoogleMapsAPIKey, GoogleMonthlyCap: cfg.GoogleGeocodingMonthlyCap,
	}); err != nil {
		slog.Warn("geocoder disabled: invalid configuration", "reason", err.Error())
	} else if geo != nil {
		srv.Geocoder = geo
		if ferr := geo.FallbackError(); ferr != nil {
			slog.Warn("geocoder fallback disabled: invalid configuration", "reason", ferr.Error())
		}
		if gerr := geo.GoogleError(); gerr != nil {
			slog.Warn("google geocoding disabled: invalid configuration", "reason", gerr.Error())
		}
		slog.Info("geocoder enabled", "google", geo.GoogleEnabled(), "type", cfg.GeocoderType, "autocomplete", geo.Autocomplete())
		if geo.Public() {
			slog.Warn("GEOCODER_URL is the public nominatim.openstreetmap.org: autocomplete is disabled and explicit searches are limited to 1/second per its usage policy; prefer a self-hosted Photon")
		}
	}
	srv.SMSEnv = sms.Settings{
		AccountSID:    cfg.TwilioAccountSID,
		AuthToken:     cfg.TwilioAuthToken,
		From:          cfg.TwilioFrom,
		PublicBaseURL: cfg.PublicBaseURL,
	}
	if err := srv.LoadSMSSettings(ctx); err != nil {
		slog.Error("sms settings", "err", err)
		os.Exit(1)
	}
	srv.AlertLimit = sms.NewLimiter()
	srv.AlertCfg = handlers.AlertLimitsFromEnv()
	srv.AuthLimit = sms.NewLimiter()
	srv.LocationLimit = sms.NewLimiter()
	srv.AllowedOrigin = cfg.AllowedOrigin
	srv.SiteAddress = cfg.SiteAddress
	srv.APKDir = cfg.APKDir
	srv.APKGitHubRepo = cfg.APKGitHubRepo
	srv.APKGitHubToken = cfg.APKGitHubToken
	srv.FlutterAppDir = cfg.FlutterAppDir
	srv.BuildVersion = config.BuildVersion()
	// A managed server (one with a configured platform admin) closes open
	// registration: new users must present an invite code.
	srv.RequireInvite = cfg.PlatformAdminEmail != ""

	// Promote (or auto-create) the configured platform admin (idempotent, every
	// startup). This is the secure bootstrap for the first platform admin: no
	// credentials are hardcoded; it requires the env vars and, when the account
	// does not exist yet, PLATFORM_ADMIN_PASSWORD to create it.
	srv.BootstrapPlatformAdmin(ctx, cfg.PlatformAdminEmail, cfg.PlatformAdminPassword)

	// Background reconciliation self-heals any geofence evaluation that failed
	// or was interrupted during ingest.
	go srv.ReconcileGeofences(ctx)
	if err := srv.EnsureCrashSchema(ctx); err != nil {
		slog.Error("crash schema", "err", err)
		os.Exit(1)
	}
	if err := srv.EnsureDawarichSchema(ctx); err != nil {
		slog.Error("dawarich schema", "err", err)
		os.Exit(1)
	}
	go srv.RunDawarichSync(ctx)
	if err := srv.EnsureNotificationSchema(ctx); err != nil {
		slog.Error("notification prefs schema", "err", err)
		os.Exit(1)
	}
	if err := srv.EnsureThemeSchema(ctx); err != nil {
		slog.Warn("theme schema", "err", err)
	}

	// Segment new locations into trips (bounded, cancelled with ctx).
	go (&trips.Worker{Store: trips.NewStore(pool)}).Run(ctx)

	trustedProxies, err := resolveTrustedProxies(cfg)
	if err != nil {
		slog.Error("invalid TRUSTED_PROXIES", "err", err)
		os.Exit(1)
	}

	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(mid.ClientIP(trustedProxies))
	r.Use(middleware.Recoverer)
	r.Use(mid.SecurityHeaders)
	r.Use(mid.LimitBody(mid.BodyLimitFor))
	r.Use(cors(cfg.AllowedOrigin))

	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	r.Get("/config", srv.GetConfig)
	r.Get("/alerts/share/{token}", srv.ShareAlert)
	// Public invite landing page: static, no database access, no secrets.
	r.Get("/join/{code}", srv.JoinLanding)

	// Auth (unauthenticated).
	r.Post("/auth/register", srv.Register)
	r.Post("/auth/login", srv.Login)
	r.Post("/auth/refresh", srv.Refresh)
	r.Post("/auth/password/reset", srv.ResetPassword)

	// WebSocket stream (authenticates via Bearer header or Sec-WebSocket-Protocol subprotocol).
	r.Get("/ws/stream", srv.Stream)

	// Platform-admin live WebSocket stream (all families). Registered at the top
	// level like /ws/stream because the Sec-WebSocket-Protocol token carrier
	// cannot be seen by the RequireAuth/RequirePlatformAdmin middleware; the
	// handler enforces both checks itself (see AdminStream).
	r.Get("/api/admin/ws", srv.AdminStream)

	// Authenticated API.
	r.Group(func(r chi.Router) {
		r.Use(mid.NoStore)
		r.Use(mid.RequireAuth(tm))
		r.Use(mid.RequireTokenVersion(pool))

		r.Get("/me", srv.GetMe)
		r.Patch("/me", srv.UpdateMe)
		r.Patch("/me/password", srv.ChangeMyPassword)
		r.Delete("/me", srv.DeleteMe)
		r.Post("/auth/logout", srv.Logout)
		r.Post("/auth/logout-all", srv.LogoutAll)
		r.Post("/auth/password/change", srv.ChangePassword)
		r.Post("/auth/totp/setup", srv.TOTPSetup)
		r.Post("/auth/totp/enable", srv.TOTPEnable)
		r.Post("/auth/totp/disable", srv.TOTPDisable)
		r.Get("/auth/sessions", srv.ListSessions)
		r.Delete("/auth/sessions/{id}", srv.RevokeSession)
		r.Get("/me/export", srv.ExportMe)
		r.Post("/family/members/{id}/reset-code", srv.FamilyIssueResetCode)
		r.Get("/me/contacts", srv.ListContacts)
		r.Post("/me/contacts", srv.CreateContact)
		r.Delete("/me/contacts/{id}", srv.DeleteContact)
		r.Get("/me/notifications", srv.GetNotificationPrefs)
		r.Put("/me/notifications", srv.PutNotificationPrefs)

		// Account profile and avatar are deliberately private to the caller.
		r.Get("/api/profile", srv.GetProfile)
		r.Get("/api/profile/avatar", srv.GetProfileAvatar)
		r.Put("/api/profile/avatar", srv.PutProfileAvatar)
		r.Delete("/api/profile/avatar", srv.DeleteProfileAvatar)

		// Circles (multi-circle model, stage 1). Authorization is in
		// internal/circles; see docs/design/CIRCLES.md.
		r.Post("/circles", srv.CreateCircle)
		r.Get("/circles", srv.ListCircles)
		r.Post("/circles/join", srv.JoinCircle)
		r.Patch("/circles/{id}", srv.UpdateCircle)
		r.Delete("/circles/{id}", srv.DeleteCircle)
		r.Get("/circles/{id}/members", srv.ListCircleMembers)
		r.Delete("/circles/{id}/members/{user_id}", srv.RemoveCircleMember)
		r.Patch("/circles/{id}/members/{user_id}", srv.UpdateCircleMemberRole)
		r.Put("/circles/{id}/sharing", srv.SetCircleSharing)
		r.Post("/circles/{id}/invites", srv.CreateCircleInvite)
		r.Get("/circles/{id}/invites", srv.ListCircleInvites)
		r.Delete("/circles/{id}/invites/{invite_id}", srv.RevokeCircleInvite)
		r.Get("/circles/{id}/chat", srv.ListChatMessages)
		r.Post("/circles/{id}/chat", srv.SendChatMessage)
		r.Post("/circles/{id}/chat/read", srv.MarkChatRead)
		r.Get("/chat/unread", srv.ChatUnread)

		r.Post("/families", srv.CreateFamily)
		r.Get("/family", srv.GetFamily)
		r.Patch("/family", srv.RenameFamily)
		r.Post("/family/leave", srv.LeaveFamily)
		r.Get("/family/members", srv.ListMembers)
		r.Get("/family/members/{id}/avatar", srv.GetFamilyMemberAvatar)
		r.Get("/family/members/{id}/history", srv.GetMemberHistory)
		r.Get("/trips", srv.ListTrips)
		r.Get("/trips/summary", srv.TripsSummary)
		r.Get("/trips/report", srv.TripsReport)
		r.Get("/trips/{id}/events", srv.TripEvents)
		r.Post("/trips/compute", srv.ComputeTrips)
		r.Get("/trips/{id}", srv.GetTrip)
		r.Post("/family/members/{id}/location-request", srv.RequestMemberLocation)
		r.Patch("/family/members/{id}/role", srv.UpdateMemberRole)
		r.Patch("/family/members/{id}", srv.UpdateFamilyMember)
		r.Get("/members/{id}/notification-prefs", srv.GetMemberNotificationPrefs)
		r.Put("/members/{id}/notification-prefs", srv.PutMemberNotificationPrefs)
		r.Delete("/members/{id}/notification-prefs", srv.DeleteMemberNotificationPrefs)
		r.Post("/family/invites", srv.CreateFamilyInvite)
		r.Post("/family/join", srv.JoinFamily)

		r.Get("/family/geofences", srv.ListGeofences)
		r.Post("/family/geofences", srv.CreateGeofence)
		r.Patch("/family/geofences/{id}", srv.UpdateGeofence)
		r.Delete("/family/geofences/{id}", srv.DeleteGeofence)

		r.Get("/family/places", srv.ListPlaces)
		r.Post("/family/places", srv.CreatePlace)
		r.Patch("/family/places/{id}", srv.UpdatePlace)
		r.Delete("/family/places/{id}", srv.DeletePlace)

		r.Get("/geocode/search", srv.GeocodeSearch)
		r.Get("/geocode/reverse", srv.GeocodeReverse)

		r.Get("/audit", srv.ListAudit)

		r.Post("/devices", srv.RegisterDevice)
		r.Get("/devices", srv.ListDevices)
		r.Patch("/devices/{id}", srv.UpdateDevice)
		r.Post("/devices/{id}/ingest-key", srv.RotateDeviceIngestKey)
		r.Delete("/devices/{id}", srv.DeleteDevice)

		r.Post("/alerts/check-in", srv.PostCheckIn)
		r.Post("/alerts/help", srv.PostHelp)
		r.Post("/alerts/sos", srv.PostSOS)
		r.Get("/alerts", srv.ListAlerts)
		r.Get("/crashes", srv.ListCrashes)
		r.Put("/crashes/settings", srv.SetCrashDetection)
		r.Post("/crashes/{id}/status", srv.SetCrashStatus)
		r.Get("/alerts/{id}", srv.GetAlert)
		r.Post("/alerts/{id}/resolve", srv.ResolveAlert)
		r.Post("/alerts/{id}/ack", srv.AckAlert)
		r.Post("/alerts/{id}/share/revoke", srv.RevokeAlertShare)

		// Check-ins to chosen people, sharing pause, live shares
		// (docs/checkin-sharing.md).
		r.Post("/checkins", srv.PostCheckinTo)
		r.Get("/checkins", srv.ListCheckins)
		r.Get("/sharing/pause", srv.GetSharingPause)
		r.Put("/sharing/pause", srv.SetSharingPause)
		r.Delete("/sharing/pause", srv.ClearSharingPause)
		r.Post("/live-shares", srv.CreateLiveShare)
		r.Get("/live-shares", srv.ListLiveShares)
		r.Delete("/live-shares/{id}", srv.DeleteLiveShare)

		// Bubbles: temporary per-person geofences (docs/bubbles.md).
		r.Post("/bubbles", srv.CreateBubble)
		r.Get("/bubbles", srv.ListBubbles)
		r.Delete("/bubbles/{id}", srv.DeleteBubble)
	})

	// Location ingest: accepts either a Bearer access token or the per-device
	// ingest key (X-Device-Key), so the headless background reporter keeps
	// working after the 15-minute access token expires without ever holding
	// the 30-day refresh token outside secure storage.
	r.Group(func(r chi.Router) {
		r.Use(mid.NoStore)
		r.Use(mid.RequireAuthOrDeviceIngestKey(tm, pool))

		r.Post("/devices/heartbeat", srv.HeartbeatDevice)
		// Built-in direct push channel: SSE stream + delivery ack.
		r.Get("/push/stream", srv.PushStream)
		r.Post("/push/ack", srv.AckPush)
		r.Post("/locations", srv.IngestLocation)
		// Live boost: "I am looking at this member" (docs/live-tracking.md).
		r.Post("/locations/watch", srv.WatchMember)
		// Motion-sensor driving events (docs/driving.md).
		r.Post("/trips/sensor-events", srv.IngestSensorEvents)
		// Offline backfill: points queued while the device had no data,
		// delivered newest-first once connectivity returns. Relaxed freshness
		// rules, no geofence/broadcast side effects (see location_batch.go).
		r.Post("/locations/batch", srv.IngestLocationBatch)
	})

	// Platform admin API, namespaced under /api/admin/* so it never collides
	// with the admin SPA served at /admin/* (which falls back to index.html for
	// client-side routing). RequireAuth runs first (injects claims);
	// RequirePlatformAdmin re-reads the platform_admin flag from the DB on
	// every request (never trusts the JWT).
	r.Group(func(r chi.Router) {
		r.Use(mid.NoStore)
		r.Use(mid.RequireAuth(tm))
		r.Use(mid.RequireTokenVersion(pool))
		r.Use(mid.RequirePlatformAdmin(pool))

		r.Get("/api/admin/families", srv.AdminListFamilies)
		r.Post("/api/admin/families", srv.AdminCreateFamily)
		r.Patch("/api/admin/families/{id}", srv.AdminRenameFamily)
		r.Delete("/api/admin/families/{id}", srv.AdminDeleteFamily)
		r.Get("/api/admin/families/{id}/members", srv.AdminListFamilyMembers)
		r.Get("/api/admin/members", srv.AdminListMembers)
		r.Get("/api/admin/members/{id}/avatar", srv.GetAdminMemberAvatar)
		r.Get("/api/admin/members/{id}/history", srv.AdminGetMemberHistory)
		r.Patch("/api/admin/members/{id}/family", srv.AdminMoveMember)
		r.Get("/api/admin/users", srv.AdminListUsers)
		r.Post("/api/admin/users", srv.AdminCreateUser)
		r.Patch("/api/admin/users/{id}", srv.AdminUpdateUser)
		r.Patch("/api/admin/users/{id}/family", srv.AdminAssignUser)
		r.Patch("/api/admin/users/{id}/role", srv.AdminUpdateUserRole)
		r.Patch("/api/admin/users/{id}/password", srv.AdminResetUserPassword)
		r.Post("/api/admin/users/{id}/reset-code", srv.AdminIssueResetCode)
		r.Get("/api/admin/places", srv.AdminListPlaces)
		r.Get("/api/admin/invites", srv.AdminListInvites)
		r.Post("/api/admin/invites", srv.AdminCreateInvite)

		r.Get("/api/admin/apk", srv.AdminDownloadAPK)
		r.Post("/api/admin/apk/build", srv.AdminBuildAPK)
		r.Get("/api/admin/apk/status", srv.AdminAPKStatus)

		r.Get("/api/admin/settings/sms", srv.AdminGetSMSSettings)
		r.Put("/api/admin/settings/sms", srv.AdminPutSMSSettings)
		r.Delete("/api/admin/settings/sms", srv.AdminDeleteSMSSettings)
		r.Get("/api/admin/settings/theme", srv.AdminGetTheme)
		r.Put("/api/admin/settings/theme", srv.AdminPutTheme)
		r.Get("/api/admin/settings/dawarich", srv.AdminGetDawarich)
		r.Put("/api/admin/settings/dawarich", srv.AdminPutDawarich)
		r.Delete("/api/admin/settings/dawarich", srv.AdminDeleteDawarich)
		r.Post("/api/admin/settings/dawarich/test", srv.AdminTestDawarich)
		r.Post("/api/admin/settings/dawarich/sync", srv.AdminDawarichSyncNow)
		r.Get("/api/admin/settings/dawarich/users", srv.AdminListDawarichUsers)
		r.Put("/api/admin/settings/dawarich/users/{id}", srv.AdminPutDawarichUser)
		r.Delete("/api/admin/settings/dawarich/users/{id}", srv.AdminDeleteDawarichUser)

		// Domain status: read-only mirror of SITE_ADDRESS plus live DNS and
		// HTTPS health checks for the admin panel card.
		r.Get("/api/admin/domain/status", srv.AdminGetDomainStatus)

		// Read-only running version. Upgrades happen on the host (scripts/upgrade.sh).
		r.Get("/api/admin/version", srv.AdminVersion)
	})

	// Admin web panel (embedded static SPA) at /admin/*, served public. The page
	// loads unauthenticated and the client authenticates against the /api/admin/*
	// API above. The API lives under a separate /api/admin/* prefix, so it never
	// collides with this /admin/* catch-all. Unknown paths fall back to index.html
	// for client-side routing.
	adminFS, err := fs.Sub(web.Dist, "dist")
	if err != nil {
		slog.Error("admin web embed failed", "err", err)
		os.Exit(1)
	}
	adminIndex, err := web.Dist.ReadFile("dist/index.html")
	if err != nil {
		slog.Error("admin web index.html missing from embed", "err", err)
		os.Exit(1)
	}
	adminStatic := adminStaticHandler(adminFS, adminIndex)
	// The bare hostname lands on the admin panel.
	r.Get("/", rootRedirect)
	r.Get("/admin", adminIndexHandler(adminIndex))
	r.Get("/admin/", adminIndexHandler(adminIndex))
	r.Get("/admin/*", adminStatic)

	httpServer := newHTTPServer(cfg.HTTPAddr, r, defaultServerTimeouts)

	go func() {
		if cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
			slog.Info("listening (https)", "addr", cfg.HTTPAddr)
			if err := httpServer.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && !errors.Is(err, http.ErrServerClosed) {
				slog.Error("server error", "err", err)
				stop()
			}
			return
		}
		slog.Info("listening (http)", "addr", cfg.HTTPAddr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server error", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}

// resolveTrustedProxies decides whose forwarding headers are believed. Explicit
// TRUSTED_PROXIES wins; otherwise a deployment that says it is behind a TLS
// proxy (the compose default) trusts private/loopback peers, and everything
// else trusts nobody so client-supplied X-Forwarded-For/X-Real-IP cannot forge
// the address used for rate limiting and audit.
func resolveTrustedProxies(cfg config.Config) ([]*net.IPNet, error) {
	if cfg.TrustedProxies != "" {
		return mid.ParseTrustedProxies(cfg.TrustedProxies)
	}
	if cfg.TLSBehindProxy {
		return mid.DefaultProxyNets, nil
	}
	return nil, nil
}

// serverTimeouts are the net/http server deadlines (BSEC-005).
type serverTimeouts struct {
	ReadHeader, Read, Write, Idle time.Duration
}

// defaultServerTimeouts bound slow-header/slow-body clients and idle
// keep-alives. They do not affect WebSockets: net/http clears the connection
// deadlines when a handler hijacks the connection (coder/websocket does so in
// Accept), and the stream's liveness is covered by its own ping/pong.
// Handlers that legitimately stream for longer (the APK download) extend their
// own write deadline with http.ResponseController.
var defaultServerTimeouts = serverTimeouts{
	ReadHeader: 10 * time.Second,
	Read:       60 * time.Second,
	Write:      60 * time.Second,
	Idle:       120 * time.Second,
}

func newHTTPServer(addr string, h http.Handler, t serverTimeouts) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: t.ReadHeader,
		ReadTimeout:       t.Read,
		WriteTimeout:      t.Write,
		IdleTimeout:       t.Idle,
	}
}

// cors adds a permissive CORS policy for the configured origin (or none).
func cors(allowedOrigin string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if allowedOrigin != "" {
				w.Header().Set("Access-Control-Allow-Origin", allowedOrigin)
				w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			}
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// adminSPACSP is the Content-Security-Policy applied to every embedded admin
// panel response. The panel is served public and authenticates with JWTs kept
// in localStorage, so a strict script policy is the main defense-in-depth
// against XSS turning into account takeover:
//
//   - script-src 'self'          only bundled assets may execute (no inline/eval),
//     plus the pinned hash of the theme-bootstrap script embedded in
//     dist/index.html (see admin_csp_test.go, which fails the build if that
//     script changes without updating this hash)
//   - style-src 'unsafe-inline'  React style attributes and leaflet inline styles
//   - img-src https: data: blob: tile hosts come from server config, so any
//     HTTPS image host must stay allowed
//   - default-src 'self', object-src 'none', frame-ancestors 'none'
//   - connect-src                the MapLibre vector map fetches its style,
//     glyphs, sprites and tiles with fetch/XHR, so the OpenFreeMap host (and
//     the origin of an operator-set MAP_STYLE_URL) is allowed, nothing else
//   - worker-src/child-src blob: MapLibre runs its tile parser in a blob Worker
const defaultMapStyleOrigin = "https://tiles.openfreemap.org"

// adminSPACSP is built once at startup; see buildAdminCSP.
var adminSPACSP = buildAdminCSP(os.Getenv("MAP_STYLE_URL"))

// buildAdminCSP returns the admin CSP. styleURL is the optional operator
// MAP_STYLE_URL; its https origin is added to connect-src.
func buildAdminCSP(styleURL string) string {
	connect := "'self' " + defaultMapStyleOrigin
	if u, err := url.Parse(strings.TrimSpace(styleURL)); err == nil && u.Scheme == "https" && u.Host != "" {
		if origin := "https://" + u.Host; origin != defaultMapStyleOrigin {
			connect += " " + origin
		}
	}
	return "default-src 'self'; " +
		"script-src 'self' 'sha256-3+KRjeKvEdP+bglkPezOzH6i2TloyL+3eFCBV+90WH8='; " +
		"style-src 'self' 'unsafe-inline'; " +
		"img-src 'self' data: blob: https:; " +
		"connect-src " + connect + "; " +
		"worker-src 'self' blob:; " +
		"child-src blob:; " +
		"font-src 'self' data:; " +
		"object-src 'none'; " +
		"base-uri 'self'; " +
		"frame-ancestors 'none'"
}

// setAdminSPAHeaders applies the headers shared by every admin panel response.
func setAdminSPAHeaders(w http.ResponseWriter) {
	w.Header().Set("Content-Security-Policy", adminSPACSP)
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("X-Content-Type-Options", "nosniff")
}

// adminIndexHandler serves the embedded admin index.html (for /admin and
// /admin/). The body is pre-read so it does not re-read the embed per request.
func adminIndexHandler(index []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		setAdminSPAHeaders(w)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(index)
	}
}

// adminStaticHandler serves the embedded admin SPA assets at /admin/*, with a
// fallback to index.html for unknown paths (client-side routing). Existing
// files are served via http.FileServerFS; missing files return index.html so
// the SPA can take over the path. The admin API lives under /api/admin/* (a
// separate prefix), so it is never matched by this /admin/* wildcard.
func adminStaticHandler(fsys fs.FS, index []byte) http.HandlerFunc {
	fileServer := http.StripPrefix("/admin/", http.FileServerFS(fsys))
	return func(w http.ResponseWriter, r *http.Request) {
		setAdminSPAHeaders(w)
		// Sub-path below /admin/ (chi wildcard already ensured we are here).
		p := strings.TrimPrefix(r.URL.Path, "/admin/")
		if p == "" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write(index)
			return
		}
		if fi, err := fs.Stat(fsys, p); err == nil && !fi.IsDir() {
			fileServer.ServeHTTP(w, r)
			return
		}
		// SPA fallback for unknown paths.
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(index)
	}
}

// rootRedirect sends the bare hostname to the admin panel (302, not
// permanent, so a later landing page can replace it).
func rootRedirect(w http.ResponseWriter, req *http.Request) {
	http.Redirect(w, req, "/admin/", http.StatusFound)
}
