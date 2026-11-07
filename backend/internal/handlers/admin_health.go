package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/errlog"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

type healthBackup struct {
	LastAt    *time.Time `json:"last_at"`
	SizeBytes *int64     `json:"size_bytes"`
	AgeHours  *float64   `json:"age_hours"`
	// Status is "ok", "stale" (older than StaleAfterHours) or "missing"
	// (no backup has ever been recorded).
	Status          string `json:"status"`
	StaleAfterHours int    `json:"stale_after_hours"`
	Destination     string `json:"destination,omitempty"`
	Encrypted       bool   `json:"encrypted"`
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
func backupHealth(last *time.Time, size *int64, now time.Time, staleAfter time.Duration) healthBackup {
	b := healthBackup{LastAt: last, SizeBytes: size, Status: "missing", StaleAfterHours: int(staleAfter / time.Hour)}
	if last == nil {
		return b
	}
	age := now.Sub(*last).Hours()
	b.AgeHours = &age
	b.Status = "ok"
	if now.Sub(*last) > staleAfter {
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
	var dest *string
	var enc bool
	if err := s.Pool.QueryRow(ctx, `SELECT taken_at, size_bytes, destination, encrypted FROM backup_runs WHERE status = 'success' ORDER BY taken_at DESC LIMIT 1`).
		Scan(&last, &size, &dest, &enc); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to read backups")
		return
	}
	out.Backup = backupHealth(last, size, time.Now(), s.backupStaleAfter())
	if dest != nil {
		out.Backup.Destination, out.Backup.Encrypted = *dest, enc
	}
	out.RecentErrors = errlog.Default.Recent(20)

	switch out.Backup.Status {
	case "missing":
		out.Warnings = append(out.Warnings, "No backup has been recorded. Enable the scheduled backup service (docker compose --profile backup up -d) or run ./scripts/backup.sh daily.")
	case "stale":
		out.Warnings = append(out.Warnings, fmt.Sprintf("The last successful backup is more than %d hours old.", out.Backup.StaleAfterHours))
	}
	// A destination whose most recent attempt failed deserves its own banner,
	// even when another destination (say the local disk) succeeded afterwards.
	// The error text was scrubbed of secrets by the backup service.
	if rows, err := s.Pool.Query(ctx, `
		SELECT destination, error FROM (
		  SELECT DISTINCT ON (destination) destination, status, error, taken_at
		  FROM backup_runs ORDER BY destination, taken_at DESC) latest
		WHERE status = 'failed' ORDER BY destination`); err == nil {
		for rows.Next() {
			var dst string
			var e *string
			if rows.Scan(&dst, &e) == nil {
				msg := "The last backup attempt to " + dst + " failed"
				if e != nil && *e != "" {
					msg += ": " + *e
				}
				out.Warnings = append(out.Warnings, msg)
			}
		}
		rows.Close()
	}
	var hb time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT heartbeat_at FROM backup_agent WHERE id = 1`).Scan(&hb); err == nil && time.Since(hb) > 10*time.Minute {
		out.Warnings = append(out.Warnings, "The backup service has stopped reporting. Check: docker compose --profile backup ps backup")
	}
	if out.Migration.Dirty {
		out.Warnings = append(out.Warnings, "The last database migration did not finish cleanly.")
	}
	writeJSON(w, http.StatusOK, out)
}
