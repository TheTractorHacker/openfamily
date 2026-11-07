package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	adminPageDefault = 50
	adminPageMax     = 200
)

// adminLimit parses ?limit= with the shared admin page bounds.
func adminLimit(q url.Values) int {
	n, err := strconv.Atoi(q.Get("limit"))
	if err != nil || n < 1 {
		return adminPageDefault
	}
	if n > adminPageMax {
		return adminPageMax
	}
	return n
}

// parseAdminTime accepts RFC 3339 or a bare YYYY-MM-DD date (UTC midnight).
func parseAdminTime(s string) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, nil
	}
	return time.Parse("2006-01-02", s)
}

// escapeLike makes s safe to embed in a LIKE pattern (escape char is '\').
func escapeLike(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}

// auditFilter is the parsed query of GET /api/admin/audit.
type auditFilter struct {
	Limit    int
	BeforeID int64
	UserID   string
	Action   string // exact action, or a prefix when it ends in '*' or '.'
	Text     string // substring of detail
	From, To *time.Time
}

func parseAuditFilter(q url.Values) (auditFilter, string) {
	f := auditFilter{Limit: adminLimit(q)}
	if v := q.Get("before_id"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			return f, "invalid before_id"
		}
		f.BeforeID = n
	}
	if v := q.Get("user_id"); v != "" {
		if !circles.ValidID(v) {
			return f, "invalid user_id"
		}
		f.UserID = v
	}
	f.Action = strings.TrimSpace(q.Get("action"))
	if len(f.Action) > 100 {
		return f, "action too long"
	}
	f.Text = strings.TrimSpace(q.Get("q"))
	if len(f.Text) > 200 {
		return f, "q too long"
	}
	if v := q.Get("from"); v != "" {
		t, err := parseAdminTime(v)
		if err != nil {
			return f, "invalid from"
		}
		f.From = &t
	}
	if v := q.Get("to"); v != "" {
		t, err := parseAdminTime(v)
		if err != nil {
			return f, "invalid to"
		}
		// A bare date means "through the end of that day".
		if len(v) == len("2006-01-02") {
			t = t.Add(24*time.Hour - time.Nanosecond)
		}
		f.To = &t
	}
	return f, ""
}

// where builds the WHERE clause and its arguments (placeholders from $1).
func (f auditFilter) where() (string, []any) {
	var conds []string
	var args []any
	add := func(cond string, v any) {
		args = append(args, v)
		conds = append(conds, fmt.Sprintf(cond, len(args)))
	}
	if f.BeforeID > 0 {
		add("a.id < $%d", f.BeforeID)
	}
	if f.UserID != "" {
		add("a.user_id = $%d", f.UserID)
	}
	if f.Action != "" {
		if strings.HasSuffix(f.Action, "*") || strings.HasSuffix(f.Action, ".") {
			add(`a.action LIKE $%d ESCAPE '\'`, escapeLike(strings.TrimSuffix(f.Action, "*"))+"%")
		} else {
			add("a.action = $%d", f.Action)
		}
	}
	if f.Text != "" {
		add(`a.detail ILIKE $%d ESCAPE '\'`, "%"+escapeLike(f.Text)+"%")
	}
	if f.From != nil {
		add("a.created_at >= $%d", *f.From)
	}
	if f.To != nil {
		add("a.created_at <= $%d", *f.To)
	}
	if len(conds) == 0 {
		return "", args
	}
	return "WHERE " + strings.Join(conds, " AND "), args
}

type auditEntryOut struct {
	ID         int64     `json:"id"`
	UserID     *string   `json:"user_id"`
	UserName   string    `json:"user_name"`
	UserEmail  string    `json:"user_email"`
	FamilyID   *string   `json:"family_id"`
	FamilyName string    `json:"family_name"`
	Action     string    `json:"action"`
	Detail     string    `json:"detail"`
	IPAddress  string    `json:"ip_address"`
	CreatedAt  time.Time `json:"created_at"`
}

// AdminListAudit returns audit_log entries, newest first, keyset-paginated by
// id (pass the response's next_before_id as before_id for the next page).
// GET /api/admin/audit?limit&before_id&user_id&action&q&from&to
func (s *Server) AdminListAudit(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	f, msg := parseAuditFilter(r.URL.Query())
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	where, args := f.where()
	args = append(args, f.Limit+1)
	rows, err := s.Pool.Query(r.Context(), `
		SELECT a.id, a.user_id::text, COALESCE(u.name, ''), COALESCE(u.email, ''),
		       a.family_id::text, COALESCE(fm.name, ''),
		       a.action, a.detail, a.ip_address, a.created_at
		FROM audit_log a
		LEFT JOIN users u ON u.id = a.user_id
		LEFT JOIN families fm ON fm.id = a.family_id
		`+where+fmt.Sprintf(` ORDER BY a.id DESC LIMIT $%d`, len(args)), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load audit log")
		return
	}
	defer rows.Close()
	out := []auditEntryOut{}
	for rows.Next() {
		var e auditEntryOut
		if err := rows.Scan(&e.ID, &e.UserID, &e.UserName, &e.UserEmail, &e.FamilyID, &e.FamilyName,
			&e.Action, &e.Detail, &e.IPAddress, &e.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read audit log")
			return
		}
		out = append(out, e)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read audit log")
		return
	}
	var next *int64
	if len(out) > f.Limit {
		out = out[:f.Limit]
		id := out[len(out)-1].ID
		next = &id
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": out, "next_before_id": next})
}

// AdminListAuditActions returns the distinct action names seen recently, for
// the filter dropdown.
// GET /api/admin/audit/actions
func (s *Server) AdminListAuditActions(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT DISTINCT action FROM audit_log
		WHERE created_at > now() - interval '90 days'
		ORDER BY action LIMIT 300`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load actions")
		return
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read actions")
			return
		}
		out = append(out, a)
	}
	writeJSON(w, http.StatusOK, out)
}

type adminSessionOut struct {
	ID         string    `json:"id"` // refresh family id; what DELETE takes
	UserID     string    `json:"user_id"`
	UserName   string    `json:"user_name"`
	UserEmail  string    `json:"user_email"`
	UserAgent  string    `json:"user_agent"`
	CreatedAt  time.Time `json:"created_at"`
	LastUsedAt time.Time `json:"last_used_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	// Current marks the sign-in this very request is using.
	Current bool `json:"current"`
}

// AdminListSessions lists active sign-ins (refresh-token families), newest
// activity first; ?user_id= narrows to one account.
// GET /api/admin/sessions
func (s *Server) AdminListSessions(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := r.URL.Query().Get("user_id")
	if userID != "" && !circles.ValidID(userID) {
		writeError(w, http.StatusBadRequest, "invalid user_id")
		return
	}
	var uid any
	if userID != "" {
		uid = userID
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT rs.family_id, rs.user_id::text, u.name, u.email,
		       COALESCE(max(rs.user_agent), ''), min(rs.created_at), max(rs.created_at), max(rs.expires_at)
		FROM refresh_sessions rs
		JOIN users u ON u.id = rs.user_id
		WHERE ($1::uuid IS NULL OR rs.user_id = $1::uuid)
		GROUP BY rs.family_id, rs.user_id, u.name, u.email
		HAVING bool_or(rs.used_at IS NULL AND rs.revoked_at IS NULL AND rs.expires_at > now())
		ORDER BY max(rs.created_at) DESC
		LIMIT 2000`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list sessions")
		return
	}
	defer rows.Close()
	out := []adminSessionOut{}
	for rows.Next() {
		var o adminSessionOut
		if err := rows.Scan(&o.ID, &o.UserID, &o.UserName, &o.UserEmail, &o.UserAgent,
			&o.CreatedAt, &o.LastUsedAt, &o.ExpiresAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read sessions")
			return
		}
		o.Current = claims.SessionID != "" && o.ID == claims.SessionID
		out = append(out, o)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to list sessions")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminRevokeSession revokes one refresh family. Its refresh token stops
// working immediately; an access token already issued lives until it expires
// (the access TTL), exactly like the user's own RevokeSession.
// DELETE /api/admin/sessions/{id}
func (s *Server) AdminRevokeSession(w http.ResponseWriter, r *http.Request) {
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
	var target string
	err := s.Pool.QueryRow(r.Context(), `
		WITH r AS (
			UPDATE refresh_sessions SET revoked_at = now()
			WHERE family_id = $1 AND revoked_at IS NULL
			RETURNING user_id
		)
		SELECT user_id::text FROM r LIMIT 1`, id).Scan(&target)
	if errors.Is(err, pgx.ErrNoRows) {
		// No unrevoked row: unknown or already revoked.
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke session")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.session_revoked",
		"revoked a session of user "+target, clientIP(r))
	w.WriteHeader(http.StatusNoContent)
}

// AdminBulkRevokeSessions revokes many sign-ins at once.
// POST /api/admin/sessions/bulk-revoke
//
//	{"mode":"all_except_current"}            every sign-in but the caller's own
//	{"mode":"inactive","days":N}             sign-ins with no activity for N days
//	optional: "user_id" to narrow to one account, "dry_run":true for a count
//	preview, "include_current":true to allow cutting off the caller's own
//	sign-in (refused otherwise).
//
// Activity is the newest refresh token of the sign-in: the apps and the admin
// panel rotate it every few minutes while in use.
func (s *Server) AdminBulkRevokeSessions(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Mode           string `json:"mode"`
		Days           int    `json:"days"`
		UserID         string `json:"user_id"`
		DryRun         bool   `json:"dry_run"`
		IncludeCurrent bool   `json:"include_current"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	days := 0
	switch req.Mode {
	case "all_except_current":
	case "inactive":
		if req.Days < 1 || req.Days > 3650 {
			writeError(w, http.StatusBadRequest, "days must be between 1 and 3650")
			return
		}
		days = req.Days
	default:
		writeError(w, http.StatusBadRequest, "mode must be all_except_current or inactive")
		return
	}
	if req.Mode == "all_except_current" && req.IncludeCurrent {
		writeError(w, http.StatusBadRequest, "include_current cannot be combined with all_except_current")
		return
	}
	var uid any
	if req.UserID != "" {
		if !circles.ValidID(req.UserID) {
			writeError(w, http.StatusBadRequest, "invalid user_id")
			return
		}
		uid = req.UserID
	}
	if claims.SessionID == "" && !req.IncludeCurrent {
		// An older access token does not say which sign-in is the caller's, so
		// the caller's own session cannot be protected: refuse rather than guess.
		writeError(w, http.StatusConflict, "cannot tell which session is yours; sign in again, then retry")
		return
	}
	// Families that qualify. The caller's own family is skipped unless asked.
	const target = `
		SELECT family_id FROM refresh_sessions
		WHERE ($1::uuid IS NULL OR user_id = $1::uuid)
		  AND ($3 OR family_id <> $2)
		GROUP BY family_id
		HAVING bool_or(used_at IS NULL AND revoked_at IS NULL AND expires_at > now())
		   AND ($4 = 0 OR max(created_at) < now() - make_interval(days => $4))`
	args := []any{uid, claims.SessionID, req.IncludeCurrent, days}
	if req.DryRun {
		var n int
		if err := s.Pool.QueryRow(r.Context(), `SELECT count(*) FROM (`+target+`) t`, args...).Scan(&n); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to count sessions")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"count": n, "dry_run": true})
		return
	}
	var n int
	err := s.Pool.QueryRow(r.Context(), `
		WITH t AS (`+target+`),
		r AS (UPDATE refresh_sessions SET revoked_at = now()
		      WHERE family_id IN (SELECT family_id FROM t) AND revoked_at IS NULL RETURNING family_id)
		SELECT count(DISTINCT family_id) FROM r`, args...).Scan(&n)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke sessions")
		return
	}
	detail := fmt.Sprintf("revoked %d sign-ins (%s)", n, req.Mode)
	if days > 0 {
		detail = fmt.Sprintf("revoked %d sign-ins inactive for %d days", n, days)
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.sessions_bulk_revoked", detail, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"count": n, "revoked": n, "dry_run": false})
}
