package handlers

import (
	"errors"
	"net/http"
	"path/filepath"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/apkrelease"
)

const (
	apkPerIP    = 12
	apkWindow   = time.Hour
	apkMIMEType = "application/vnd.android.package-archive"
	ipaMIMEType = "application/octet-stream"
)

// PublicDownloadAPK serves GET /app.apk: the latest signed release APK, the
// same file the admin panel offers, so an invited family member can install the
// app from the invite page without an account. It exposes nothing that is not
// already a public GitHub Release, is rate limited per IP (a request can make
// the server sync from GitHub), and 404s when no APK is configured. When the
// release has one APK per CPU type, the universal one is served, else arm64-v8a.
func (s *Server) PublicDownloadAPK(w http.ResponseWriter, r *http.Request) {
	s.publicDownload(w, r, "apk", apkMIMEType, apkrelease.KindAndroidAPK,
		func(r *http.Request) (string, error) { return s.resolveAPK(r.Context()) })
}

// PublicDownloadIPA serves GET /app.ipa: the unsigned iOS build from the latest
// release that has one. It must be re-signed before it installs (see
// docs/design/IOS_RELEASE.md). Same caching, rate limit and name tolerance as
// /app.apk.
func (s *Server) PublicDownloadIPA(w http.ResponseWriter, r *http.Request) {
	s.publicDownload(w, r, "ipa", ipaMIMEType, apkrelease.KindIOSIPA, s.resolveIPA)
}

func (s *Server) publicDownload(w http.ResponseWriter, r *http.Request, key, mime, kind string, resolve func(ctxr *http.Request) (string, error)) {
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey(key, clientIP(r)), apkPerIP, apkWindow) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	if s.APKDir == "" {
		writeError(w, http.StatusNotFound, "no app download is available")
		return
	}
	path, err := resolve(r)
	if err != nil {
		writeError(w, http.StatusNotFound, "no app download is available")
		return
	}
	name := apkrelease.CachedName(s.APKDir, kind)
	if name == "" || filepath.Base(path) != cachedFileFor(kind) {
		name = filepath.Base(path)
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Content-Disposition", `attachment; filename="`+safeFilename(name)+`"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// A slow phone connection must not be cut off by the server-wide timeout.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	http.ServeFile(w, r, path)
}

func cachedFileFor(kind string) string {
	if kind == apkrelease.KindIOSIPA {
		return "openfamily-release.ipa"
	}
	return "openfamily-release.apk"
}

// safeFilename keeps a header value free of quotes and control characters.
func safeFilename(n string) string {
	out := make([]rune, 0, len(n))
	for _, c := range n {
		if c < 0x20 || c == '"' || c == '\\' || c == '/' || c > 0x7e {
			c = '_'
		}
		out = append(out, c)
	}
	return string(out)
}

// resolveIPA mirrors resolveAPK for the unsigned IPA.
func (s *Server) resolveIPA(r *http.Request) (string, error) {
	if s.APKGitHubRepo == "" {
		path, err := latestFileExt(s.APKDir, ".ipa")
		if err != nil {
			return "", errors.New("no IPA release is available")
		}
		return path, nil
	}
	s.apk.syncMu.Lock()
	defer s.apk.syncMu.Unlock()
	path, err := apkrelease.SyncIPA(r.Context(), apkrelease.Options{Repo: s.APKGitHubRepo, Token: s.APKGitHubToken, DestDir: s.APKDir})
	if err == nil {
		return path, nil
	}
	if cached, cacheErr := latestFileExt(s.APKDir, ".ipa"); cacheErr == nil {
		return cached, nil
	}
	return "", err
}
