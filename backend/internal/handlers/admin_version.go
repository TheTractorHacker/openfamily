package handlers

import (
	"net/http"

	"github.com/wheresfrank/openfamily/backend/internal/middleware"
)

// AdminVersion reports the git ref this server was built from. It is a
// read-only display; server upgrades are performed on the host with
// scripts/upgrade.sh, never through the API.
func (s *Server) AdminVersion(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"version": s.BuildVersion})
}
