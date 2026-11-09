package backup

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DBRecorder writes run records to backup_runs.
type DBRecorder struct{ Pool *pgxpool.Pool }

func (d *DBRecorder) RecordRun(ctx context.Context, r RunRecord) error {
	_, err := d.Pool.Exec(ctx, `
		INSERT INTO backup_runs (status, destination, encrypted, object_key, size_bytes, duration_ms, error, trigger)
		VALUES ($1, $2, $3, NULLIF($4,''), $5, $6, NULLIF($7,''), $8)`,
		r.Status, r.Destination, r.Encrypted, r.ObjectKey, r.SizeBytes, r.Duration.Milliseconds(), r.Error, r.Trigger)
	return err
}

// HasSuccess reports whether any backup has ever succeeded. On error it
// answers true so a database hiccup never triggers an unplanned dump.
func (d *DBRecorder) HasSuccess(ctx context.Context) bool {
	var ok bool
	if err := d.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM backup_runs WHERE status = 'success')`).Scan(&ok); err != nil {
		return true
	}
	return ok
}

func (d *DBRecorder) SchemaVersion(ctx context.Context) int64 {
	var v int64
	if err := d.Pool.QueryRow(ctx, `SELECT version FROM schema_migrations LIMIT 1`).Scan(&v); err != nil {
		return 0
	}
	return v
}

// Heartbeat publishes liveness, the next scheduled run and the non-secret
// configuration summary for the admin panel.
func (d *DBRecorder) Heartbeat(ctx context.Context, version string, next *time.Time, sum Summary, boot bool) error {
	cfg, _ := json.Marshal(sum)
	if boot {
		_, err := d.Pool.Exec(ctx, `
			INSERT INTO backup_agent (id, heartbeat_at, started_at, version, next_run_at, config)
			VALUES (1, now(), now(), $1, $2, $3)
			ON CONFLICT (id) DO UPDATE SET heartbeat_at = now(), started_at = now(), version = $1, next_run_at = $2, config = $3`,
			version, next, cfg)
		return err
	}
	_, err := d.Pool.Exec(ctx, `
		INSERT INTO backup_agent (id, version, next_run_at, config) VALUES (1, $1, $2, $3)
		ON CONFLICT (id) DO UPDATE SET heartbeat_at = now(), version = $1, next_run_at = $2, config = $3`,
		version, next, cfg)
	return err
}

// Request is a queued admin action.
type Request struct {
	ID      int64
	Kind    string
	Payload []byte // encrypted; test_s3 with unsaved form values
}

// FailStale marks requests left running by a previous process as failed.
func (d *DBRecorder) FailStale(ctx context.Context) error {
	_, err := d.Pool.Exec(ctx, `
		UPDATE backup_requests SET status = 'failed', finished_at = now(), payload_enc = NULL, message = 'The backup service restarted before finishing this request.'
		WHERE status = 'running'`)
	return err
}

// Claim takes the oldest pending request, or returns nil.
func (d *DBRecorder) Claim(ctx context.Context) (*Request, error) {
	var q Request
	err := d.Pool.QueryRow(ctx, `
		UPDATE backup_requests SET status = 'running', started_at = now()
		WHERE id = (SELECT id FROM backup_requests WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
		RETURNING id, kind, payload_enc`).Scan(&q.ID, &q.Kind, &q.Payload)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &q, nil
}

func (d *DBRecorder) Finish(ctx context.Context, id int64, ok bool, msg string) error {
	st := "done"
	if !ok {
		st = "failed"
	}
	_, err := d.Pool.Exec(ctx, `UPDATE backup_requests SET status = $2, finished_at = now(), message = $3, payload_enc = NULL WHERE id = $1`, id, st, msg)
	return err
}
