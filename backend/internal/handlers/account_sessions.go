package handlers

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const maxUserAgentLen = 256

type sessionOut struct {
	ID         string    `json:"id"`
	CreatedAt  time.Time `json:"created_at"`
	LastUsedAt time.Time `json:"last_used_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	UserAgent  string    `json:"user_agent"`
}

// tagSession records the client's User-Agent on a freshly created refresh
// family. Best effort: a failure never blocks login.
func (s *Server) tagSession(r *http.Request, jti string) {
	if s.Pool == nil {
		return
	}
	ua := r.UserAgent()
	if len(ua) > maxUserAgentLen {
		ua = ua[:maxUserAgentLen]
	}
	_, _ = s.Pool.Exec(r.Context(), `UPDATE refresh_sessions SET user_agent = $2 WHERE jti = $1`, jti, ua)
}

// ListSessions returns the caller's active refresh-token families (one per
// signed-in device/login). The id is the family id and is what
// DELETE /auth/sessions/{id} takes. "last_used_at" is the latest token
// rotation (the client refreshes about every access-token lifetime).
func (s *Server) ListSessions(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT family_id, min(created_at), max(created_at), max(expires_at), COALESCE(max(user_agent), '')
		FROM refresh_sessions
		WHERE user_id = $1
		GROUP BY family_id
		HAVING bool_or(used_at IS NULL AND revoked_at IS NULL AND expires_at > now())
		ORDER BY max(created_at) DESC
		LIMIT 100`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list sessions")
		return
	}
	defer rows.Close()
	out := []sessionOut{}
	for rows.Next() {
		var o sessionOut
		if err := rows.Scan(&o.ID, &o.CreatedAt, &o.LastUsedAt, &o.ExpiresAt, &o.UserAgent); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read sessions")
			return
		}
		out = append(out, o)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to list sessions")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// RevokeSession revokes one refresh family owned by the caller. Its refresh
// token stops working immediately; an access token already issued from it
// stays valid until it expires (at most the access TTL, 15 minutes by
// default). Use logout-all to cut access tokens off too.
func (s *Server) RevokeSession(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if id == "" || len(id) > 64 {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE refresh_sessions SET revoked_at = now()
		WHERE family_id = $1 AND user_id = $2 AND revoked_at IS NULL`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke session")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "auth.session_revoked", "revoked a session", clientIP(r))
	w.WriteHeader(http.StatusNoContent)
}

// LogoutAll ends every session of the caller, this one included: all refresh
// families are revoked, token_version is bumped (access tokens die at once),
// device ingest keys are revoked and live sockets are dropped.
func (s *Server) LogoutAll(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if err := s.endAllSessions(r, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to log out")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "auth.logout_all", "logged out of all sessions", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// endAllSessions is the shared "kill everything" step.
func (s *Server) endAllSessions(r *http.Request, userID string) error {
	if err := s.bumpTokenVersion(r.Context(), userID); err != nil {
		return err
	}
	if err := s.revokeAllSessions(r.Context(), userID); err != nil {
		return err
	}
	if err := s.revokeIngestKeys(r.Context(), userID); err != nil {
		return err
	}
	s.dropUserSockets(userID)
	return nil
}
