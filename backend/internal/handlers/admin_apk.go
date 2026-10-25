package handlers

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/wheresfrank/openfamily/backend/internal/apkrelease"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
)

// apkBuildStatus is the lifecycle state of an APK build job.
type apkBuildStatus string

const (
	apkIdle     apkBuildStatus = "idle"
	apkBuilding apkBuildStatus = "building"
	apkSuccess  apkBuildStatus = "success"
	apkFailed   apkBuildStatus = "failed"
)

// buildTimeout caps how long a single flutter build may run before it is
// cancelled and marked failed.
const buildTimeout = 30 * time.Minute

// apkManager tracks the in-memory state of the platform APK build job. There is
// at most one concurrent build: a second trigger while building is rejected.
// The state is process-local (not persisted) since a build is a transient
// operation tied to the running server.
type apkManager struct {
	mu         sync.Mutex
	status     apkBuildStatus
	startedAt  *time.Time
	finishedAt *time.Time
	artifact   string // absolute path of the last successful artifact
	lastError  string
	lastOutput string // tail of the build output (for failed diagnostics)

	// syncMu serializes GitHub Release fetches so two overlapping downloads
	// cannot truncate the cached APK.
	syncMu sync.Mutex
}

// apkStatusOut is the JSON shape returned by GET /api/admin/apk/status.
type apkStatusOut struct {
	Status       apkBuildStatus          `json:"status"`
	StartedAt    *time.Time              `json:"started_at,omitempty"`
	FinishedAt   *time.Time              `json:"finished_at,omitempty"`
	Artifact     string                  `json:"artifact_path,omitempty"`
	LastError    string                  `json:"last_error,omitempty"`
	Release      *apkrelease.ReleaseInfo `json:"release,omitempty"`
	ReleaseError string                  `json:"release_error,omitempty"`
}

// snapshot returns a copy of the current build state under the lock.
func (a *apkManager) snapshot() apkStatusOut {
	a.mu.Lock()
	defer a.mu.Unlock()
	return apkStatusOut{
		Status:     a.status,
		StartedAt:  a.startedAt,
		FinishedAt: a.finishedAt,
		Artifact:   a.artifact,
		LastError:  a.lastError,
	}
}

// begin attempts to transition idle/success/failed -> building. It returns
// false (without changing state) when a build is already in progress.
func (a *apkManager) begin() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.status == apkBuilding {
		return false
	}
	now := time.Now()
	a.status = apkBuilding
	a.startedAt = &now
	a.finishedAt = nil
	a.artifact = ""
	a.lastError = ""
	a.lastOutput = ""
	return true
}

// finish records the terminal state of a build.
func (a *apkManager) finish(status apkBuildStatus, artifact, lastErr, lastOut string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	a.status = status
	a.finishedAt = &now
	a.artifact = artifact
	a.lastError = lastErr
	a.lastOutput = lastOut
}

// AdminAPKStatus returns the current build status.
func (s *Server) AdminAPKStatus(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	out := s.apk.snapshot()
	if s.APKGitHubRepo != "" {
		info, err := apkrelease.LatestInfo(r.Context(), apkrelease.Options{
			Repo:  s.APKGitHubRepo,
			Token: s.APKGitHubToken,
		})
		if err != nil {
			out.ReleaseError = err.Error()
		} else {
			out.Release = &info
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminDownloadAPK serves the latest Android APK. When APK_GITHUB_REPO is set,
// it syncs the latest published v* semver GitHub Release asset into APKDir
// (skipping the download when the cached file already matches) and then serves
// that file. CI apk-* tags are not used. If GitHub is unreachable, a previously
// cached APK is served. It returns 404 when APK_DIR is unset or no APK can be
// obtained.
func (s *Server) AdminDownloadAPK(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.APKDir == "" {
		writeError(w, http.StatusNotFound, "APK_DIR is not configured; no APK available")
		return
	}
	path, err := s.resolveAPK(r.Context())
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(path)+`"`)
	// The APK is tens of MiB; the server-wide WriteTimeout must not cut off a
	// slow download.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	http.ServeFile(w, r, path)
}

// resolveAPK returns a local path to the APK to serve. The latest v* GitHub
// Release is the source of truth when configured; APKDir is only a cache
// (and a fallback if GitHub fails).
func (s *Server) resolveAPK(ctx context.Context) (string, error) {
	if s.APKGitHubRepo == "" {
		path, err := latestAPK(s.APKDir)
		if err != nil {
			return "", errors.New("no APK release is available")
		}
		return path, nil
	}

	s.apk.syncMu.Lock()
	defer s.apk.syncMu.Unlock()

	path, err := apkrelease.Sync(ctx, apkrelease.Options{
		Repo:    s.APKGitHubRepo,
		Token:   s.APKGitHubToken,
		DestDir: s.APKDir,
	})
	if err == nil {
		return path, nil
	}

	if cached, cacheErr := latestAPK(s.APKDir); cacheErr == nil {
		slog.Warn("github apk sync failed; serving cached apk", "err", err)
		return cached, nil
	}
	return "", err
}

// AdminBuildAPK triggers a background APK build. It returns:
//   - 501 "build not available on this server" when the flutter binary is absent,
//   - 409 when a build is already in progress,
//   - 202 when the build has been started (status is then polled via /api/admin/apk/status).
//
// The build runs `flutter build apk --release` in FlutterAppDir, then copies
// the resulting app-release.apk into APKDir. Build start and result are
// audit-logged as platform admin actions.
func (s *Server) AdminBuildAPK(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if s.APKDir == "" {
		writeError(w, http.StatusConflict, "APK_DIR is not configured; cannot build")
		return
	}
	if _, err := exec.LookPath("flutter"); err != nil {
		slog.Warn("admin apk build: flutter SDK not found on PATH")
		writeError(w, http.StatusNotImplemented, "build not available on this server: flutter SDK not found")
		return
	}
	if !s.apk.begin() {
		writeError(w, http.StatusConflict, "a build is already in progress")
		return
	}

	s.logAudit(r.Context(), claims.UserID, "", "admin.apk_build",
		"triggered APK build in "+s.FlutterAppDir, clientIP(r))

	// Run the build detached so the HTTP response is not blocked. The
	// background context decouples the build from the request lifecycle.
	go s.runAPKBuild(claims.UserID, clientIP(r))
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "building"})
}

// runAPKBuild executes the flutter build and publishes the artifact. It always
// records a terminal state via apkManager.finish and audit-logs the result.
func (s *Server) runAPKBuild(userID, ip string) {
	ctx, cancel := context.WithTimeout(context.Background(), buildTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "flutter", "build", "apk", "--release")
	cmd.Dir = s.FlutterAppDir
	out, err := cmd.CombinedOutput()
	tail := tailOutput(out)

	if err != nil {
		s.apk.finish(apkFailed, "", err.Error(), tail)
		slog.Error("admin apk build failed", "err", err, "app_dir", s.FlutterAppDir)
		s.logAudit(context.Background(), userID, "", "admin.apk_build_failed",
			"APK build failed: "+err.Error(), ip)
		return
	}

	// Flutter's default release output location.
	src := filepath.Join(s.FlutterAppDir, "build", "app", "outputs", "flutter-apk", "app-release.apk")
	if _, statErr := os.Stat(src); statErr != nil {
		s.apk.finish(apkFailed, "", "built APK not found at "+src, tail)
		slog.Error("admin apk build: artifact not found", "path", src)
		s.logAudit(context.Background(), userID, "", "admin.apk_build_failed",
			"APK build produced no artifact at "+src, ip)
		return
	}

	if mkErr := os.MkdirAll(s.APKDir, 0o755); mkErr != nil {
		s.apk.finish(apkFailed, "", "cannot create APK_DIR: "+mkErr.Error(), tail)
		slog.Error("admin apk build: cannot create apk dir", "dir", s.APKDir, "err", mkErr)
		s.logAudit(context.Background(), userID, "", "admin.apk_build_failed",
			"cannot create APK_DIR "+s.APKDir, ip)
		return
	}
	dst := filepath.Join(s.APKDir, "openfamily-release.apk")
	if copyErr := copyFile(src, dst); copyErr != nil {
		s.apk.finish(apkFailed, "", "cannot copy artifact: "+copyErr.Error(), tail)
		slog.Error("admin apk build: copy failed", "src", src, "dst", dst, "err", copyErr)
		s.logAudit(context.Background(), userID, "", "admin.apk_build_failed",
			"cannot copy artifact to "+dst, ip)
		return
	}

	absDst, _ := filepath.Abs(dst)
	s.apk.finish(apkSuccess, absDst, "", tail)
	slog.Info("admin apk build succeeded", "artifact", absDst)
	s.logAudit(context.Background(), userID, "", "admin.apk_build_done",
		"APK build succeeded: "+absDst, ip)
}

// latestAPK returns the most recently modified *.apk file in dir. It returns an
// error when the directory cannot be read or contains no APK.
func latestAPK(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var newest string
	var newestMT time.Time
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if filepath.Ext(name) != ".apk" {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().After(newestMT) || newest == "" {
			newest = filepath.Join(dir, name)
			newestMT = info.ModTime()
		}
	}
	if newest == "" {
		return "", errors.New("no apk found")
	}
	return newest, nil
}

// copyFile copies src to dst, truncating dst if it exists.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}

// tailOutput returns the last ~4KB of build output for diagnostics, trimmed of
// trailing whitespace.
func tailOutput(out []byte) string {
	const max = 4096
	if len(out) <= max {
		return string(out)
	}
	return string(out[len(out)-max:])
}
