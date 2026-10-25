package db

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SQL used by ApplyRetentionPolicy. Kept as constants so tests can assert on
// them without a database.
const (
	// retentionAvailableSQL is true when TimescaleDB's retention API exists.
	retentionAvailableSQL = `SELECT to_regproc('add_retention_policy') IS NOT NULL
		AND to_regproc('remove_retention_policy') IS NOT NULL`

	// retentionCurrentSQL is true when the locations retention job already
	// drops chunks older than $1 days; no row means no policy exists.
	retentionCurrentSQL = `SELECT (config->>'drop_after')::interval = make_interval(days => $1::int)
		FROM timescaledb_information.jobs
		WHERE proc_name = 'policy_retention' AND hypertable_name = 'locations'
		LIMIT 1`

	retentionRemoveSQL = `SELECT remove_retention_policy('locations', if_exists => true)`
	retentionAddSQL    = `SELECT add_retention_policy('locations', make_interval(days => $1::int), if_not_exists => true)`
)

// ApplyRetentionPolicy makes the locations retention policy drop chunks older
// than days. It is idempotent: when the existing policy already matches it does
// nothing, otherwise it replaces the policy inside one transaction. It is a
// no-op when TimescaleDB's retention functions are not installed.
//
// Retention is chunk-granular, so rows can outlive the window by up to one
// chunk interval (7 days by default); the history API enforces the exact window.
func ApplyRetentionPolicy(ctx context.Context, pool *pgxpool.Pool, days int) error {
	if days <= 0 {
		return fmt.Errorf("retention days must be positive, got %d", days)
	}
	var available bool
	if err := pool.QueryRow(ctx, retentionAvailableSQL).Scan(&available); err != nil {
		return fmt.Errorf("check retention support: %w", err)
	}
	if !available {
		slog.Warn("timescaledb retention API unavailable; skipping retention policy")
		return nil
	}

	var same *bool
	rows, err := pool.Query(ctx, retentionCurrentSQL, days)
	if err != nil {
		return fmt.Errorf("read retention policy: %w", err)
	}
	if rows.Next() {
		if err := rows.Scan(&same); err != nil {
			rows.Close()
			return fmt.Errorf("scan retention policy: %w", err)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("read retention policy: %w", err)
	}
	if same != nil && *same {
		return nil
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, retentionRemoveSQL); err != nil {
		return fmt.Errorf("remove retention policy: %w", err)
	}
	if _, err := tx.Exec(ctx, retentionAddSQL, days); err != nil {
		return fmt.Errorf("add retention policy: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	slog.Info("location retention policy applied", "days", days)
	return nil
}
