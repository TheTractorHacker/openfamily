package handlers

// Admin "trust this server by default" setting (docs/design/E2EE.md, Trusted-
// server mode). It is ONLY a recommendation shown to clients. It never creates
// a consent, never changes e2ee_server_member(), and grants the server nothing:
// every member's phone must still sign a consent for each circle.

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// trustedServerDefaultSetting reads the stored admin flag (errors read as false).
func (s *Server) trustedServerDefaultSetting(ctx context.Context) bool {
	if s.Pool == nil {
		return false
	}
	var v bool
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_trusted_server_default FROM app_theme_settings WHERE id = 1`).Scan(&v); err != nil {
		return false
	}
	return v
}

func (s *Server) trustedDefaultJSON(ctx context.Context) map[string]any {
	dev, _ := s.pinnedServerDevice(ctx)
	enabled := serverMemberEnabled()
	return map[string]any{
		"trusted_server_default": s.trustedServerDefaultSetting(ctx),
		"token_configured":       enabled,
		"server_device_pinned":   enabled && dev != nil,
	}
}

// AdminGetTrustedServerDefault: GET /api/admin/settings/e2ee-trusted-default
func (s *Server) AdminGetTrustedServerDefault(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.trustedDefaultJSON(r.Context()))
}

// AdminPutTrustedServerDefault: PUT /api/admin/settings/e2ee-trusted-default
func (s *Server) AdminPutTrustedServerDefault(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		TrustedServerDefault *bool `json:"trusted_server_default"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || req.TrustedServerDefault == nil {
		writeError(w, http.StatusBadRequest, "trusted_server_default (true or false) is required")
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`UPDATE app_theme_settings SET e2ee_trusted_server_default = $1, updated_at = now() WHERE id = 1`, *req.TrustedServerDefault); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save setting")
		return
	}
	detail := "turned the trusted-server default off"
	if *req.TrustedServerDefault {
		detail = "turned the trusted-server default on (a recommendation only; every member must still consent)"
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.e2ee_trusted_default_changed", detail, clientIP(r))
	writeJSON(w, http.StatusOK, s.trustedDefaultJSON(r.Context()))
}
