package handlers

import (
	"encoding/csv"
	"fmt"
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
			break // headers are sent; end the stream rather than corrupt it
		}
		_ = cw.Write([]string{
			strconv.FormatInt(id, 10), at.UTC().Format(time.RFC3339), uid, csvSafe(uname), csvSafe(uemail),
			fid, csvSafe(fname), csvSafe(action), csvSafe(detail), csvSafe(ip),
		})
		n++
	}
	cw.Flush()
	s.logAudit(r.Context(), claims.UserID, "", "admin.audit_export",
		fmt.Sprintf("exported %d audit rows", n), clientIP(r))
}
