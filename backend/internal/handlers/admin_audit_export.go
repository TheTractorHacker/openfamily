package handlers

import (
	"context"
	"encoding/csv"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// auditExportMax caps one CSV export. The audit log is append-only and can be
// large; narrow the filters (dates, action) for older history.
const auditExportMax = 50000

// csvSafe neutralises spreadsheet formula injection: a cell that starts with
// = + - @ (or a tab/CR) is prefixed with an apostrophe so Excel and Sheets
// read it as text. Audit details contain user-chosen names, so this matters.
func csvSafe(s string) string {
	if s != "" && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		return "'" + s
	}
	return s
}

// AdminExportAudit streams the filtered audit log as CSV (same filters as
// AdminListAudit, minus paging), newest first, capped at auditExportMax rows.
// The export itself is recorded in the audit log.
// GET /api/admin/audit/export?user_id&action&q&from&to
func (s *Server) AdminExportAudit(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	q := r.URL.Query()
	q.Del("before_id")
	f, msg := parseAuditFilter(q)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	where, args := f.where()

	// Record the export BEFORE any data leaves the server, on a context a
	// disconnecting client cannot cancel. If the record cannot be written,
	// nothing is streamed.
	actx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Second)
	defer cancel()
	if err := s.auditStrict(actx, claims.UserID, "admin.audit_export", f.describe(), clientIP(r)); err != nil {
		slog.Error("audit export: could not record the export", "err", err)
		writeError(w, http.StatusInternalServerError, "failed to record the export; nothing was exported")
		return
	}

	args = append(args, auditExportMax)
	rows, err := s.Pool.Query(r.Context(), `
		SELECT a.id, a.created_at, COALESCE(a.user_id::text, ''), COALESCE(u.name, ''), COALESCE(u.email, ''),
		       COALESCE(a.family_id::text, ''), COALESCE(fm.name, ''), a.action, a.detail, a.ip_address
		FROM audit_log a
		LEFT JOIN users u ON u.id = a.user_id
		LEFT JOIN families fm ON fm.id = a.family_id
		`+where+fmt.Sprintf(` ORDER BY a.id DESC LIMIT $%d`, len(args)), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load audit log")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		`attachment; filename="audit-`+time.Now().UTC().Format("20060102T150405Z")+`.csv"`)
	cw := csv.NewWriter(w)
	_ = cw.Write([]string{"id", "time", "user_id", "user_name", "user_email", "family_id", "family_name", "action", "detail", "ip_address"})
	n := 0
	for rows.Next() {
		var id int64
		var at time.Time
		var uid, uname, uemail, fid, fname, action, detail, ip string
		if err := rows.Scan(&id, &at, &uid, &uname, &uemail, &fid, &fname, &action, &detail, &ip); err != nil {
			// Headers are already sent: never end a partial file as if it were
			// complete. Abort the connection so the client sees a failed download.
			slog.Error("audit export: row scan failed, aborting response", "err", err)
			panic(http.ErrAbortHandler)
		}
		_ = cw.Write([]string{
			strconv.FormatInt(id, 10), at.UTC().Format(time.RFC3339), uid, csvSafe(uname), csvSafe(uemail),
			fid, csvSafe(fname), csvSafe(action), csvSafe(detail), csvSafe(ip),
		})
		n++
	}
	if rows.Err() != nil {
		slog.Error("audit export: query failed mid-stream, aborting response", "err", rows.Err())
		panic(http.ErrAbortHandler)
	}
	cw.Flush()
	// Final row count, on an uncancellable context.
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Second)
	defer ccancel()
	s.logAudit(cctx, claims.UserID, "", "admin.audit_export_done", fmt.Sprintf("exported %d audit rows", n), clientIP(r))
}

// describe summarises the filters and the row cap for the audit record.
func (f auditFilter) describe() string {
	parts := []string{fmt.Sprintf("cap=%d", auditExportMax)}
	if f.UserID != "" {
		parts = append(parts, "user_id="+f.UserID)
	}
	if f.Action != "" {
		parts = append(parts, "action="+f.Action)
	}
	if f.Text != "" {
		parts = append(parts, "q="+f.Text)
	}
	if f.From != nil {
		parts = append(parts, "from="+f.From.UTC().Format(time.RFC3339))
	}
	if f.To != nil {
		parts = append(parts, "to="+f.To.UTC().Format(time.RFC3339))
	}
	return "started audit CSV export: " + strings.Join(parts, " ")
}

// auditStrict writes an audit row and reports failure, for records that must
// exist before a sensitive action proceeds (logAudit is best effort).
func (s *Server) auditStrict(ctx context.Context, userID, action, detail, ip string) error {
	if s.auditHook != nil {
		s.auditHook(userID, "", action, detail)
		return nil
	}
	_, err := s.Pool.Exec(ctx, `
		INSERT INTO audit_log (user_id, action, detail, ip_address) VALUES ($1, $2, $3, $4)`,
		userID, action, detail, ip)
	return err
}
