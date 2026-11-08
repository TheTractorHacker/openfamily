package handlers

import (
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/apkrelease"
)

const (
	apkPerIP    = 12
	apkWindow   = time.Hour
	apkMIMEType = "application/vnd.android.package-archive"
)

// PublicDownloadAPK serves GET /app.apk: the latest signed release APK, the
// same file the admin panel offers, so an invited family member can install the
// app from the invite page without an account. It exposes nothing that is not
// already a public GitHub Release, is rate limited per IP (a request can make
// the server sync from GitHub), and 404s when no APK is configured.
func (s *Server) PublicDownloadAPK(w http.ResponseWriter, r *http.Request) {
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey("apk", clientIP(r)), apkPerIP, apkWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	if s.APKDir == "" {
		writeError(w, http.StatusNotFound, "no app download is available")
		return
	}
	path, err := s.resolveAPK(r.Context())
	if err != nil {
		writeError(w, http.StatusNotFound, "no app download is available")
		return
	}
	w.Header().Set("Content-Type", apkMIMEType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(path)+`"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// A slow phone connection must not be cut off by the server-wide timeout.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	http.ServeFile(w, r, path)
}

const ipaMIMEType = "application/octet-stream"

// PublicDownloadIPA serves GET /app.ipa: the UNSIGNED iOS build attached to
// the latest release, for sideloading with AltStore or Sideloadly (it cannot
// be installed directly). Same rate limit, caching and 404 rules as /app.apk.
func (s *Server) PublicDownloadIPA(w http.ResponseWriter, r *http.Request) {
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey("ipa", clientIP(r)), apkPerIP, apkWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	if s.APKDir == "" || s.APKGitHubRepo == "" {
		writeError(w, http.StatusNotFound, "no iOS download is available")
		return
	}
	s.apk.syncMu.Lock()
	path, err := apkrelease.SyncIPA(r.Context(), apkrelease.Options{Repo: s.APKGitHubRepo, Token: s.APKGitHubToken, DestDir: s.APKDir})
	s.apk.syncMu.Unlock()
	if err != nil {
		cached := filepath.Join(s.APKDir, "openfamily-release.ipa")
		if _, statErr := os.Stat(cached); statErr != nil {
			writeError(w, http.StatusNotFound, "no iOS download is available")
			return
		}
		path = cached
	}
	w.Header().Set("Content-Type", ipaMIMEType)
	w.Header().Set("Content-Disposition", `attachment; filename="orbitly-unsigned.ipa"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	http.ServeFile(w, r, path)
}

// AdminDownloadIPA is GET /api/admin/ipa (platform admin): same file.
func (s *Server) AdminDownloadIPA(w http.ResponseWriter, r *http.Request) {
	s.PublicDownloadIPA(w, r)
}

// AdminBuildsOverview is GET /api/admin/builds: the latest release's Android
// and iOS files (sizes, sha256, date) and older releases.
func (s *Server) AdminBuildsOverview(w http.ResponseWriter, r *http.Request) {
	if s.APKGitHubRepo == "" {
		writeJSON(w, http.StatusOK, map[string]any{"configured": false})
		return
	}
	ov, err := apkrelease.ListOverview(r.Context(), apkrelease.Options{Repo: s.APKGitHubRepo, Token: s.APKGitHubToken}, 15)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"configured": true, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"configured": true, "overview": ov})
}
