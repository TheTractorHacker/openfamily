package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// The API never holds S3 credentials or dump tools. The optional `backup`
// compose service owns them; this file only reads what that service publishes
// (backup_agent, backup_runs: non-secret) and queues requests for it
// (backup_requests). No secret can therefore reach an API response.

const (
	backupAgentAlive   = 90 * time.Second
	backupRunPerHour   = 4
	backupTestPerHour  = 10
	backupRateWindow   = time.Hour
	backupRecentLimit  = 10
	backupRequestStale = 2 * time.Hour
)

func (s *Server) backupLimiter() *sms.Limiter {
	s.backupOnce.Do(func() { s.backupLimit = sms.NewLimiter() })
	return s.backupLimit
}

// backupStaleAfter: BACKUP_STALE_HOURS (environment) wins, then the value saved
// in the admin UI, then 36 hours.
func (s *Server) backupStaleAfter(ctx context.Context) time.Duration {
	if s.BackupStaleHours > 0 {
		return time.Duration(s.BackupStaleHours) * time.Hour
	}
	var h *int
	if err := s.Pool.QueryRow(ctx, `SELECT (settings->>'stale_hours')::int FROM backup_settings WHERE id = 1`).Scan(&h); err == nil && h != nil && *h > 0 {
		return time.Duration(*h) * time.Hour
	}
	return 36 * time.Hour
}

type backupRunOut struct {
	At         time.Time `json:"at"`
	Status     string    `json:"status"`
	Dest       string    `json:"destination"`
	Encrypted  bool      `json:"encrypted"`
	SizeBytes  int64     `json:"size_bytes"`
	DurationMs *int64    `json:"duration_ms"`
	ObjectKey  *string   `json:"object_key"`
	Error      *string   `json:"error"`
	Trigger    string    `json:"trigger"`
}

type backupRequestOut struct {
	ID          int64      `json:"id"`
	Kind        string     `json:"kind"`
	Status      string     `json:"status"`
	Message     *string    `json:"message"`
	RequestedAt time.Time  `json:"requested_at"`
	FinishedAt  *time.Time `json:"finished_at"`
}

type backupAgentOut struct {
	Running       bool            `json:"running"`
	HeartbeatAt   time.Time       `json:"heartbeat_at"`
	StartedAt     time.Time       `json:"started_at"`
	Version       string          `json:"version"`
	NextRunAt     *time.Time      `json:"next_run_at"`
	Configuration json.RawMessage `json:"config"`
}

type adminBackupsOut struct {
	Agent           *backupAgentOut `json:"agent"`
	StaleAfterHours int             `json:"stale_after_hours"`
	LastSuccess     *backupRunOut   `json:"last_success"`
	LastFailure     *backupRunOut   `json:"last_failure"`
	// Failing holds, per destination, the latest run when it failed.
	Failing []backupRunOut    `json:"failing"`
	Recent  []backupRunOut    `json:"recent"`
	Request *backupRequestOut `json:"request"`
}

const backupRunCols = `taken_at, status, destination, encrypted, size_bytes, duration_ms, object_key, error, trigger`

func scanBackupRun(row pgx.Row) (*backupRunOut, error) {
	var o backupRunOut
	if err := row.Scan(&o.At, &o.Status, &o.Dest, &o.Encrypted, &o.SizeBytes, &o.DurationMs, &o.ObjectKey, &o.Error, &o.Trigger); err != nil {
		return nil, err
	}
	return &o, nil
}

// AdminGetBackups reports the backup service state: configured destinations
// and schedule (as published by the service, never secrets), last
// success/failure, recent runs and the latest admin request.
// GET /api/admin/backups
func (s *Server) AdminGetBackups(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	ctx := r.Context()
	out := adminBackupsOut{StaleAfterHours: int(s.backupStaleAfter(r.Context()) / time.Hour), Recent: []backupRunOut{}, Failing: []backupRunOut{}}

	var a backupAgentOut
	err := s.Pool.QueryRow(ctx, `SELECT heartbeat_at, started_at, version, next_run_at, config FROM backup_agent WHERE id = 1`).
		Scan(&a.HeartbeatAt, &a.StartedAt, &a.Version, &a.NextRunAt, &a.Configuration)
	switch {
	case err == nil:
		a.Running = time.Since(a.HeartbeatAt) < backupAgentAlive
		out.Agent = &a
	case !errors.Is(err, pgx.ErrNoRows):
		writeError(w, http.StatusInternalServerError, "failed to read backup service state")
		return
	}
	for _, q := range []struct {
		where string
		dst   **backupRunOut
	}{{`status = 'success'`, &out.LastSuccess}, {`status = 'failed'`, &out.LastFailure}} {
		o, err := scanBackupRun(s.Pool.QueryRow(ctx, `SELECT `+backupRunCols+` FROM backup_runs WHERE `+q.where+` ORDER BY taken_at DESC LIMIT 1`))
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusInternalServerError, "failed to read backups")
			return
		}
		*q.dst = o
	}
	rows, err := s.Pool.Query(ctx, `SELECT `+backupRunCols+` FROM backup_runs ORDER BY taken_at DESC LIMIT $1`, backupRecentLimit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backups")
		return
	}
	defer rows.Close()
	for rows.Next() {
		o, err := scanBackupRun(rows)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read backups")
			return
		}
		out.Recent = append(out.Recent, *o)
	}
	frows, err := s.Pool.Query(ctx, `SELECT `+backupRunCols+` FROM (
		SELECT DISTINCT ON (destination) * FROM backup_runs ORDER BY destination, taken_at DESC) latest
		WHERE status = 'failed' ORDER BY destination`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backups")
		return
	}
	defer frows.Close()
	for frows.Next() {
		o, err := scanBackupRun(frows)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read backups")
			return
		}
		out.Failing = append(out.Failing, *o)
	}
	var q backupRequestOut
	err = s.Pool.QueryRow(ctx, `SELECT id, kind, status, message, requested_at, finished_at FROM backup_requests ORDER BY id DESC LIMIT 1`).
		Scan(&q.ID, &q.Kind, &q.Status, &q.Message, &q.RequestedAt, &q.FinishedAt)
	if err == nil {
		out.Request = &q
	} else if !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to read backup requests")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// AdminBackupRun asks the backup service to take a backup now.
// POST /api/admin/backups/run
func (s *Server) AdminBackupRun(w http.ResponseWriter, r *http.Request) {
	s.enqueueBackupRequest(w, r, "backup", backupRunPerHour, "admin.backup.run", "requested an immediate backup")
}

// AdminBackupTestS3 asks the backup service to write and delete a small probe
// object in the configured S3 bucket.
// POST /api/admin/backups/test-s3
func (s *Server) AdminBackupTestS3(w http.ResponseWriter, r *http.Request) {
	s.enqueueBackupRequest(w, r, "test_s3", backupTestPerHour, "admin.backup.test_s3", "requested an S3 connection test")
}

func (s *Server) enqueueBackupRequest(w http.ResponseWriter, r *http.Request, kind string, perHour int, action, detail string) {
	var payload []byte
	var hasPayload bool
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.backupLimiter().Allow("backup:"+kind+":"+claims.UserID, perHour, backupRateWindow) {
		w.Header().Set("Retry-After", "3600")
		writeError(w, http.StatusTooManyRequests, "too many backup requests; try again later")
		return
	}
	ctx := r.Context()
	var hb time.Time
	var cfg json.RawMessage
	err := s.Pool.QueryRow(ctx, `SELECT heartbeat_at, config FROM backup_agent WHERE id = 1`).Scan(&hb, &cfg)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && time.Since(hb) > backupAgentAlive) {
		writeError(w, http.StatusServiceUnavailable, "The backup service is not running. Start it with: docker compose --profile backup up -d backup")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backup service state")
		return
	}
	if kind == "test_s3" {
		// Optional body: the unsaved form values to test (sealed, never logged).
		if r.ContentLength != 0 {
			p, ok := s.sealTestPayload(w, r)
			if !ok {
				return
			}
			payload, hasPayload = p, true
		}
	}
	if kind == "test_s3" && !hasPayload {
		var c struct {
			Destinations []struct {
				Kind string `json:"kind"`
			} `json:"destinations"`
		}
		hasS3 := false
		if json.Unmarshal(cfg, &c) == nil {
			for _, d := range c.Destinations {
				hasS3 = hasS3 || d.Kind == "s3"
			}
		}
		if !hasS3 {
			writeError(w, http.StatusConflict, "No S3 destination is configured on the backup service")
			return
		}
	}
	// Expire requests a dead service left open, then allow only one at a time.
	_, _ = s.Pool.Exec(ctx, `UPDATE backup_requests SET status = 'failed', finished_at = now(), payload_enc = NULL, message = 'Timed out waiting for the backup service.'
		WHERE status IN ('pending','running') AND requested_at < now() - $1::interval`, fmt.Sprintf("%d seconds", int(backupRequestStale.Seconds())))
	var id int64
	err = s.Pool.QueryRow(ctx, `
		INSERT INTO backup_requests (kind, requested_by, payload_enc)
		SELECT $1, $2, $3 WHERE NOT EXISTS (SELECT 1 FROM backup_requests WHERE status IN ('pending','running'))
		RETURNING id`, kind, claims.UserID, payload).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusConflict, "another backup request is still in progress")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to queue the request")
		return
	}
	s.logAudit(ctx, claims.UserID, "", action, detail, clientIP(r))
	writeJSON(w, http.StatusAccepted, map[string]any{"id": id, "kind": kind, "status": "pending"})
}
