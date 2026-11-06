package handlers

import (
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/errlog"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// backupStaleAfter is how old the newest backup may be before the health page
// flags it. Daily backups are the documented routine; two days leaves slack.
const backupStaleAfter = 48 * time.Hour

type healthBackup struct {
	LastAt    *time.Time `json:"last_at"`
	SizeBytes *int64     `json:"size_bytes"`
	AgeHours  *float64   `json:"age_hours"`
	// Status is "ok", "stale" (older than StaleAfterHours) or "missing"
	// (no backup has ever been recorded).
	Status          string `json:"status"`
	StaleAfterHours int    `json:"stale_after_hours"`
}

type healthMigration struct {
	Version int64 `json:"version"`
	Dirty   bool  `json:"dirty"`
}

type adminHealthOut struct {
	ReleaseVersion string          `json:"release_version"`
	Migration      healthMigration `json:"migration"`
	DatabaseBytes  int64           `json:"database_bytes"`
	Backup         healthBackup    `json:"backup"`
	RecentErrors   []errlog.Entry  `json:"recent_errors"`
	// Warnings are short human-readable flags, empty when everything is fine.
	Warnings []string `json:"warnings"`
}

// backupHealth classifies the newest backup time relative to now.
func backupHealth(last *time.Time, size *int64, now time.Time) healthBackup {
	b := healthBackup{LastAt: last, SizeBytes: size, Status: "missing", StaleAfterHours: int(backupStaleAfter / time.Hour)}
	if last == nil {
		return b
	}
	age := now.Sub(*last).Hours()
	b.AgeHours = &age
	b.Status = "ok"
	if now.Sub(*last) > backupStaleAfter {
		b.Status = "stale"
	}
	return b
}

// AdminHealth reports server state at a glance: migration version, database
// size, newest backup, release version and recent warnings/errors. Read-only;
// it exposes no configuration values or secrets.
// GET /api/admin/health
func (s *Server) AdminHealth(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	out := adminHealthOut{ReleaseVersion: s.BuildVersion, Warnings: []string{}}
	ctx := r.Context()

	if err := s.Pool.QueryRow(ctx, `SELECT version, dirty FROM schema_migrations LIMIT 1`).
		Scan(&out.Migration.Version, &out.Migration.Dirty); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to read migration version")
		return
	}
	if err := s.Pool.QueryRow(ctx, `SELECT pg_database_size(current_database())`).Scan(&out.DatabaseBytes); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read database size")
		return
	}
	var last *time.Time
	var size *int64
	if err := s.Pool.QueryRow(ctx, `SELECT taken_at, size_bytes FROM backup_runs ORDER BY taken_at DESC LIMIT 1`).
		Scan(&last, &size); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to read backups")
		return
	}
	out.Backup = backupHealth(last, size, time.Now())
	out.RecentErrors = errlog.Default.Recent(20)

	switch out.Backup.Status {
	case "missing":
		out.Warnings = append(out.Warnings, "No backup has been recorded. Run ./scripts/backup.sh and schedule it daily.")
	case "stale":
		out.Warnings = append(out.Warnings, "The last backup is more than 48 hours old.")
	}
	if out.Migration.Dirty {
		out.Warnings = append(out.Warnings, "The last database migration did not finish cleanly.")
	}
	writeJSON(w, http.StatusOK, out)
}
