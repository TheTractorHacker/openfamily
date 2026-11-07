package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Sign-in hygiene: an app install that signs in again replaces its previous
// sign-in, idle sign-ins expire, and a user cannot pile up unlimited ones.

const (
	defaultSessionIdleDays = 14
	defaultMaxSessions     = 20
	sessionSweepInterval   = time.Hour
	HeaderInstallID        = "X-Install-Id"
)

type securitySettings struct {
	SessionIdleDays    int `json:"session_idle_days"`
	MaxSessionsPerUser int `json:"max_sessions_per_user"`
}

func (s *Server) loadSecuritySettings(ctx context.Context) securitySettings {
	out := securitySettings{defaultSessionIdleDays, defaultMaxSessions}
	if s.Pool == nil {
		return out
	}
	_ = s.Pool.QueryRow(ctx, `SELECT session_idle_days, max_sessions_per_user FROM security_settings WHERE id = 1`).
		Scan(&out.SessionIdleDays, &out.MaxSessionsPerUser)
	return out
}

// installIDHeader returns X-Install-Id when well formed, else "".
func installIDHeader(r *http.Request) string {
	v := strings.TrimSpace(r.Header.Get(HeaderInstallID))
	if !validInstallID(v) {
		return ""
	}
	return v
}

// tagSessionClient stores the client key on a fresh sign-in, revokes the
// user's older sign-ins from the same install, and trims the oldest ones when
// the user is over the per-user cap. Best effort: never blocks login.
func (s *Server) tagSessionClient(r *http.Request, userID, jti string) {
	if s.Pool == nil {
		return
	}
	ctx := r.Context()
	if key := installIDHeader(r); key != "" {
		_, _ = s.Pool.Exec(ctx, `UPDATE refresh_sessions SET client_key = $2 WHERE jti = $1`, jti, key)
		_, _ = s.Pool.Exec(ctx, `
			UPDATE refresh_sessions SET revoked_at = now()
			WHERE user_id = $1 AND client_key = $2 AND revoked_at IS NULL
			  AND family_id <> (SELECT family_id FROM refresh_sessions WHERE jti = $3)`, userID, key, jti)
	}
	max := s.loadSecuritySettings(ctx).MaxSessionsPerUser
	_, _ = s.Pool.Exec(ctx, `
		UPDATE refresh_sessions SET revoked_at = now()
		WHERE revoked_at IS NULL AND user_id = $1 AND family_id IN (
		  SELECT family_id FROM refresh_sessions
		  WHERE user_id = $1
		  GROUP BY family_id
		  HAVING bool_or(used_at IS NULL AND revoked_at IS NULL AND expires_at > now())
		  ORDER BY max(created_at) DESC OFFSET $2)`, userID, max)
}

// SweepIdleSessions revokes sign-ins with no token rotation for idle days.
func (s *Server) SweepIdleSessions(ctx context.Context) (int64, error) {
	days := s.loadSecuritySettings(ctx).SessionIdleDays
	tag, err := s.Pool.Exec(ctx, `
		UPDATE refresh_sessions SET revoked_at = now()
		WHERE revoked_at IS NULL AND family_id IN (
		  SELECT family_id FROM refresh_sessions GROUP BY family_id
		  HAVING max(created_at) < now() - make_interval(days => $1))`, days)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// RunSessionSweep blocks until ctx is cancelled, sweeping idle sign-ins and
// long-expired rows on a timer.
func (s *Server) RunSessionSweep(ctx context.Context) {
	t := time.NewTicker(sessionSweepInterval)
	defer t.Stop()
	for {
		_, _ = s.SweepIdleSessions(ctx)
		_ = s.refreshSessions().Purge(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// AdminGetSecuritySettings is GET /api/admin/settings/security.
func (s *Server) AdminGetSecuritySettings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"settings": s.loadSecuritySettings(r.Context()),
		"defaults": securitySettings{defaultSessionIdleDays, defaultMaxSessions},
	})
}

// AdminPutSecuritySettings is PUT /api/admin/settings/security.
func (s *Server) AdminPutSecuritySettings(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req securitySettings
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.SessionIdleDays < 1 || req.SessionIdleDays > 365 {
		writeError(w, http.StatusBadRequest, "session_idle_days must be between 1 and 365")
		return
	}
	if req.MaxSessionsPerUser < 1 || req.MaxSessionsPerUser > 500 {
		writeError(w, http.StatusBadRequest, "max_sessions_per_user must be between 1 and 500")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE security_settings SET session_idle_days = $1, max_sessions_per_user = $2, updated_at = now() WHERE id = 1`,
		req.SessionIdleDays, req.MaxSessionsPerUser); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.security_settings",
		fmt.Sprintf("sessions: idle %d days, max %d per user", req.SessionIdleDays, req.MaxSessionsPerUser), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"settings": req})
}
