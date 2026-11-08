package handlers

import (
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/apkrelease"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const buildsListCount = 6 // the latest release plus the five before it

type adminBuildsOut struct {
	Configured bool                        `json:"configured"`
	Repo       string                      `json:"repo,omitempty"`
	Releases   []apkrelease.ReleaseSummary `json:"releases"`
	FetchedAt  *time.Time                  `json:"fetched_at,omitempty"`
	// Stale means GitHub could not be reached just now and Releases is the
	// last good copy; Error says why.
	Stale bool   `json:"stale,omitempty"`
	Error string `json:"error,omitempty"`
	// PublicAPK / PublicIPA are the stable server paths that always give the
	// latest file (the same paths the invite page uses).
	PublicAPK string `json:"public_apk"`
	PublicIPA string `json:"public_ipa"`
}

// AdminBuilds lists the assets (Android APK/AAB, Wear OS APK, iOS IPA, SBOM,
// checksums) of the latest GitHub releases. GET /api/admin/builds?refresh=1
// bypasses the cache. GitHub failures never become a 5xx: the response carries
// the last good copy marked stale, or an empty list with an error message.
func (s *Server) AdminBuilds(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	out := adminBuildsOut{Releases: []apkrelease.ReleaseSummary{}, PublicAPK: "/app.apk", PublicIPA: "/app.ipa"}
	if s.APKGitHubRepo == "" {
		out.Error = "No GitHub repository is configured for releases (APK_GITHUB_REPO), so there is nothing to list."
		writeJSON(w, http.StatusOK, out)
		return
	}
	out.Configured, out.Repo = true, s.APKGitHubRepo
	res := s.releases.Get(r.Context(), apkrelease.Options{Repo: s.APKGitHubRepo, Token: s.APKGitHubToken},
		buildsListCount, r.URL.Query().Get("refresh") == "1")
	if res.Releases != nil {
		out.Releases = res.Releases
		t := res.FetchedAt
		out.FetchedAt = &t
	}
	out.Stale = res.Stale
	if res.Err != nil {
		out.Error = res.Err.Error()
	}
	writeJSON(w, http.StatusOK, out)
}
