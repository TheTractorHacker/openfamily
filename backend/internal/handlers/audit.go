package handlers

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// auditEntry is the API representation of a single audit log row.
type auditEntry struct {
	ID        int64     `json:"id"`
	UserID    *string   `json:"user_id,omitempty"`
	FamilyID  *string   `json:"family_id,omitempty"`
	Action    string    `json:"action"`
	Detail    string    `json:"detail"`
	IPAddress string    `json:"ip_address"`
	CreatedAt time.Time `json:"created_at"`
}

// logAudit writes a best-effort audit log entry. It never fails the request:
// a failed write is logged and dropped. userID/familyID may be empty (e.g. a
// failed login where the account is unknown), in which case NULL is stored.
func (s *Server) logAudit(ctx context.Context, userID, familyID, action, detail, ipAddress string) {
	if s.auditHook != nil { // test seam: capture instead of writing
		s.auditHook(userID, familyID, action, detail)
		return
	}
	var uid, fid any
	if userID != "" {
		uid = userID
	}
	if familyID != "" {
		fid = familyID
	}
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO audit_log (user_id, family_id, action, detail, ip_address)
		VALUES ($1, $2, $3, $4, $5)`,
		uid, fid, action, detail, ipAddress); err != nil {
		slog.Error("audit log write failed", "action", action, "err", err)
	}
}

// auditViewThrottle collapses repeated identical operator reads (an admin
// panel polling the member list) into one audit row per window.
const auditViewThrottle = time.Minute

// auditAdminView records a platform admin reading live or historical
// locations (BSEC-007). familyID is the family whose members were viewed, so
// that family's admins can see it in GET /audit; it is empty for reads that
// span every family. Identical reads by the same admin within auditViewThrottle
// write one row. Best effort, like all audit writes.
func (s *Server) auditAdminView(ctx context.Context, adminID, familyID, detail, ipAddress string) {
	if s.viewAudit != nil && !s.viewAudit.Allow("adminview:"+adminID+"|"+familyID+"|"+detail, 1, auditViewThrottle) {
		return
	}
	s.logAudit(ctx, adminID, familyID, "admin.location_view", detail, ipAddress)
}

// clientIP extracts the client IP from r.RemoteAddr, stripping any port.
// middleware.ClientIP has already rewritten RemoteAddr to the real client when
// the peer is a trusted proxy, so this is the effective source address.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ListAudit returns the most recent audit log entries for the caller's family
// (admin only).
func (s *Server) ListAudit(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}
	if familyID == "" {
		writeError(w, http.StatusNotFound, "no family")
		return
	}
	isAdmin, err := s.userIsAdmin(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load role")
		return
	}
	if !isAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}

	rows, err := s.Pool.Query(r.Context(), `
		SELECT id, user_id, family_id, action, detail, ip_address, created_at
		FROM audit_log
		WHERE family_id = $1 OR (family_id IS NULL AND user_id = $2)
		ORDER BY created_at DESC
		LIMIT 100`, familyID, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list audit log")
		return
	}
	defer rows.Close()

	entries := []auditEntry{}
	for rows.Next() {
		var e auditEntry
		if err := rows.Scan(&e.ID, &e.UserID, &e.FamilyID, &e.Action, &e.Detail, &e.IPAddress, &e.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to scan audit entry")
			return
		}
		entries = append(entries, e)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read audit log")
		return
	}
	writeJSON(w, http.StatusOK, entries)
}
