package handlers

// Deployment profile (docs/design/PRIVACY_PROCESSING.md section 21): one
// server-wide answer to "does this server run on hardware the family owns
// (home) or on rented/hosted hardware (cloud)?". It changes ADVICE and
// DEFAULTS only. It never consents for anyone, never signs anything and never
// turns server assistance on: every circle admin and member still signs on
// their own phone.
//
// Unset is treated as "cloud" everywhere (the careful side), so a box whose
// owner never chose cannot behave like a home box.

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/atrest"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	ProfileHome  = "home"
	ProfileCloud = "cloud"
)

// envDeploymentProfile reads DEPLOYMENT_PROFILE ("home", "cloud" or "").
func envDeploymentProfile() string {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("DEPLOYMENT_PROFILE")))
	if v == ProfileHome || v == ProfileCloud {
		return v
	}
	return ""
}

// storedProfile returns the admin's choice ("" when none) and when it was made.
func (s *Server) storedProfile(ctx context.Context) (string, *time.Time, bool) {
	if s.Pool == nil {
		return "", nil, false
	}
	var p *string
	var at, dismissed *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT deployment_profile, profile_set_at, setup_dismissed_at FROM server_profile WHERE id = 1`).Scan(&p, &at, &dismissed); err != nil {
		return "", nil, false
	}
	if p == nil {
		return "", at, dismissed != nil
	}
	return *p, at, dismissed != nil
}

// DeploymentProfile returns the configured profile ("home", "cloud" or "" when
// nobody chose), where it came from ("admin", "env" or "unset") and the
// profile every consumer must act on ("home" only when explicitly chosen).
// The admin's choice in Settings wins over DEPLOYMENT_PROFILE, which only seeds
// a fresh install.
func (s *Server) DeploymentProfile(ctx context.Context) (configured, source, effective string) {
	if p, _, _ := s.storedProfile(ctx); p != "" {
		configured, source = p, "admin"
	} else if e := envDeploymentProfile(); e != "" {
		configured, source = e, "env"
	} else {
		return "", "unset", ProfileCloud
	}
	if configured == ProfileHome {
		return configured, source, ProfileHome
	}
	return configured, source, ProfileCloud
}

// recommendedLane is what the app preselects: the server lane when a server key
// is enrolled AND the server runs at home or the admin chose it as the default
// (adminDefault, the "trusted server default" switch). A rented server stays on
// phone-only until the admin deliberately says otherwise. It is advice, never consent.
func recommendedLane(effective string, pinned, adminDefault bool) string {
	if pinned && (effective == ProfileHome || adminDefault) {
		return "server"
	}
	return "phone"
}

type atRestJSON struct {
	// KeyConfigured: OPENFAMILY_DATA_KEY is loaded and new secrets are sealed.
	KeyConfigured bool `json:"key_configured"`
	// ProtectedColumns lists what is sealed with that key.
	ProtectedColumns []string `json:"protected_columns"`
	// LocationsEncrypted is always false: positions, trips and history stay
	// plaintext in the database so PostGIS can query them (section 21.3).
	LocationsEncrypted bool `json:"locations_encrypted"`
	// DiskEncryptionKnown is always false: the server cannot see the disk.
	DiskEncryptionKnown bool `json:"disk_encryption_known"`
}

func atRestStatus() atRestJSON {
	cols := []string{}
	for _, c := range atrest.Columns {
		cols = append(cols, atrest.Label(c.Table, c.Col))
	}
	return atRestJSON{KeyConfigured: atrest.Enabled(), ProtectedColumns: cols}
}

func (s *Server) deploymentJSON(ctx context.Context) map[string]any {
	configured, source, effective := s.DeploymentProfile(ctx)
	dev, _ := s.pinnedServerDevice(ctx)
	enabled := serverMemberEnabled()
	pinned := enabled && dev != nil
	_, setAt, dismissed := s.storedProfile(ctx)

	out := map[string]any{
		"server_device_builtin": s.ServerDevice != nil,
		"profile":          configured,
		"effective":        effective,
		"source":           source,
		"env_value":        envDeploymentProfile(),
		"profile_set_at":   setAt,
		"recommended_lane": recommendedLane(effective, pinned, s.trustedServerDefaultSetting(ctx)),
		"token_configured": enabled,
		"server_pinned":    pinned,
		"setup_dismissed":  dismissed,
		"at_rest":          atRestStatus(),
		"server_device":    nil,
		"docs_path":        "/docs/server-setup",
	}
	if s.ServerDevice != nil {
		in := s.ServerDevice.Info()
		out["builtin"] = map[string]any{"state": in.State, "state_detail": in.StateDetail, "registered": in.Registered,
			"short": in.Short, "digits": in.Digits, "fingerprint": in.Fingerprint, "sealed": in.Sealed, "last_sync": in.LastSync}
	}
	if s.Pool != nil {
		var n int
		_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM circles WHERE e2ee_mode = 'private' AND NOT server_assist`).Scan(&n)
		out["private_circles_without_server"] = n
	}
	if pinned {
		out["server_device"] = map[string]any{
			"device_id": dev.DeviceID, "label": dev.Label, "fingerprint": dev.Fingerprint,
			"short": dev.Short, "digits": dev.Digits,
		}
	}
	// Backups: latest run, and whether it was encrypted (age). Informational.
	var at time.Time
	var status string
	var enc bool
	if s.Pool != nil {
		if err := s.Pool.QueryRow(ctx, `SELECT taken_at, status, encrypted FROM backup_runs ORDER BY taken_at DESC LIMIT 1`).Scan(&at, &status, &enc); err == nil {
			out["backups"] = map[string]any{"last_run_at": at, "last_status": status, "last_encrypted": enc}
		}
		var circles int
		_ = s.Pool.QueryRow(ctx, `SELECT count(*) FROM circles WHERE server_assist`).Scan(&circles)
		out["circles_with_server"] = circles
	}
	return out
}

// AdminGetDeploymentProfile: GET /api/admin/settings/deployment-profile
func (s *Server) AdminGetDeploymentProfile(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.deploymentJSON(r.Context()))
}

// AdminPutDeploymentProfile: PUT /api/admin/settings/deployment-profile
// body {"profile":"home"|"cloud","confirm_home":true} and/or {"dismiss_setup":true}.
// Choosing "home" needs confirm_home=true (a deliberate tick, never a default).
func (s *Server) AdminPutDeploymentProfile(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Profile      *string `json:"profile"`
		ConfirmHome  bool    `json:"confirm_home"`
		DismissSetup *bool   `json:"dismiss_setup"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || (req.Profile == nil && req.DismissSetup == nil) {
		writeError(w, http.StatusBadRequest, "profile (home or cloud) is required")
		return
	}
	ctx := r.Context()
	if req.Profile != nil {
		p := strings.ToLower(strings.TrimSpace(*req.Profile))
		if p != ProfileHome && p != ProfileCloud {
			writeError(w, http.StatusBadRequest, "profile must be home or cloud")
			return
		}
		if p == ProfileHome && !req.ConfirmHome {
			writeError(w, http.StatusBadRequest, "choose Home only if the server runs on hardware you own: confirm_home must be true")
			return
		}
		if _, err := s.Pool.Exec(ctx, `UPDATE server_profile SET deployment_profile = $1, profile_set_at = now(), profile_set_by = $2, updated_at = now() WHERE id = 1`, p, claims.UserID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save setting")
			return
		}
		detail := "set the deployment profile to " + p
		if p == ProfileHome {
			detail += " (server on hardware the family owns; the app may preselect server processing)"
		}
		s.logAudit(ctx, claims.UserID, "", "admin.deployment_profile_changed", detail, clientIP(r))
	}
	if req.DismissSetup != nil {
		q := `UPDATE server_profile SET setup_dismissed_at = now(), updated_at = now() WHERE id = 1`
		if !*req.DismissSetup {
			q = `UPDATE server_profile SET setup_dismissed_at = NULL, updated_at = now() WHERE id = 1`
		}
		if _, err := s.Pool.Exec(ctx, q); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save setting")
			return
		}
	}
	writeJSON(w, http.StatusOK, s.deploymentJSON(ctx))
}
