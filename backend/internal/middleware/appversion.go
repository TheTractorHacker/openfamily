package middleware

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Request and response headers of the app-compatibility handshake
// (docs/api-compat.md).
const (
	HeaderAppVersion  = "X-App-Version"
	HeaderAppPlatform = "X-App-Platform"
	// HeaderCompat carries the client's status: ok, recommended, required or
	// unknown. Sent on every response when the client reported a version.
	HeaderCompat    = "X-OpenFamily-Compat"
	HeaderMinApp    = "X-OpenFamily-Min-App-Version"
	HeaderLatestApp = "X-OpenFamily-Latest-App-Version"
)

type appInfoKey struct{}

// AppInfo is what the middleware learned about the calling app.
type AppInfo struct {
	Version  compat.Version
	Known    bool // the client sent a parsable version
	Platform string
	Status   compat.Status
}

// AppInfoFromContext returns the client info; the zero value (unknown) when
// the middleware did not run.
func AppInfoFromContext(ctx context.Context) AppInfo {
	a, _ := ctx.Value(appInfoKey{}).(AppInfo)
	if a.Status == "" {
		a.Status = compat.StatusUnknown
	}
	return a
}

// ContextWithAppInfo injects info into ctx (tests).
func ContextWithAppInfo(ctx context.Context, a AppInfo) context.Context {
	return context.WithValue(ctx, appInfoKey{}, a)
}

func cleanPlatform(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	switch s {
	case "android", "ios", "web":
		return s
	}
	return ""
}

// AppVersion parses X-App-Version, stores the result in the request context
// and advertises the compatibility status on the response. It never rejects a
// request. policy is called per request and must be cheap (cached).
func AppVersion(policy func(context.Context) compat.Policy) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			v, ok := compat.Parse(r.Header.Get(HeaderAppVersion))
			p := policy(r.Context())
			info := AppInfo{Version: v, Known: ok, Platform: cleanPlatform(r.Header.Get(HeaderAppPlatform)), Status: p.Classify(v, ok)}
			if ok {
				h := w.Header()
				h.Set(HeaderCompat, string(info.Status))
				h.Set(HeaderMinApp, p.Min.String())
				h.Set(HeaderLatestApp, p.Latest.String())
				// Let a browser app read the headers cross-origin.
				h.Add("Access-Control-Expose-Headers", HeaderCompat+", "+HeaderMinApp+", "+HeaderLatestApp)
			}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), appInfoKey{}, info)))
		})
	}
}

// versionRecorder writes (user, version, platform) rows, at most once per
// recordEvery for each key, so the per-request cost is a map lookup.
type versionRecorder struct {
	pool *pgxpool.Pool
	mu   sync.Mutex
	seen map[string]time.Time
}

const (
	recordEvery   = 10 * time.Minute
	recorderLimit = 50000
)

func (v *versionRecorder) due(key string, now time.Time) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.seen) >= recorderLimit {
		v.seen = map[string]time.Time{}
	}
	if t, ok := v.seen[key]; ok && now.Sub(t) < recordEvery {
		return false
	}
	v.seen[key] = now
	return true
}

// RecordAppVersion remembers which app version each authenticated user runs.
// Place it after RequireAuth. Failures are ignored: it is observability, not
// part of the request.
func RecordAppVersion(pool *pgxpool.Pool) func(http.Handler) http.Handler {
	rec := &versionRecorder{pool: pool, seen: map[string]time.Time{}}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if info := AppInfoFromContext(r.Context()); info.Known && pool != nil {
				if c := ClaimsFromContext(r.Context()); c != nil && c.UserID != "" {
					ver := info.Version.String()
					dev := DeviceIDHeader(r)
					if info.Platform != "" || dev != "" {
						if rec.due("dev|"+c.UserID+"|"+dev+"|"+info.Platform+"|"+ver, time.Now()) {
							ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*time.Second)
							_ = TouchDeviceVersion(ctx, pool, c.UserID, dev, info.Platform, ver)
							cancel()
						}
					}
					if rec.due(c.UserID+"|"+ver+"|"+info.Platform, time.Now()) {
						ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*time.Second)
						_, _ = pool.Exec(ctx, `
							INSERT INTO app_client_versions (user_id, app_version, platform)
							VALUES ($1, $2, $3)
							ON CONFLICT (user_id, app_version, platform) DO UPDATE SET last_seen = now()`,
							c.UserID, ver, info.Platform)
						cancel()
					}
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// HeaderDeviceID names the caller's own devices.id (sent by the app so the
// server can attribute a request to one phone; always checked against the
// caller before use).
const HeaderDeviceID = "X-Device-Id"

// DeviceIDHeader returns X-Device-Id when it is a well-formed UUID, else "".
func DeviceIDHeader(r *http.Request) string {
	v := strings.ToLower(strings.TrimSpace(r.Header.Get(HeaderDeviceID)))
	if len(v) != 36 {
		return ""
	}
	for i, ch := range v {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if ch != '-' {
				return ""
			}
		case (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'):
		default:
			return ""
		}
	}
	return v
}

// TouchDeviceVersion stores the app version on the device named by deviceID,
// and only if that device belongs to userID. Without a valid X-Device-Id
// nothing is written: guessing "the most recently seen device" stamped the new
// version onto a different phone of the same user. It never writes a
// coordinate. platform is kept for the signature only.
func TouchDeviceVersion(ctx context.Context, pool *pgxpool.Pool, userID, deviceID, platform, version string) error {
	if deviceID == "" {
		return nil
	}
	_, err := pool.Exec(ctx, `
		UPDATE devices SET app_version = $3
		WHERE id = $2::uuid AND user_id = $1 AND app_version IS DISTINCT FROM $3`,
		userID, deviceID, version)
	return err
}
