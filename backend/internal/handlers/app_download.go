package handlers

import (
	"net/http"
	"path/filepath"
	"time"
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
