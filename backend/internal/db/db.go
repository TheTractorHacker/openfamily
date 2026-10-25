// Package db manages the PostgreSQL connection pool and migrations.
package db

import (
	"context"
	"embed"
	"fmt"
	"log/slog"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/config"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Options tunes the connection pool and startup steps.
type Options struct {
	// MaxConns is the pool size (DB_MAX_CONNS, default 25).
	MaxConns int
	// RetentionDays drives the locations retention policy applied at startup
	// (LOCATION_RETENTION_DAYS, default 90). Zero skips the step.
	RetentionDays int
}

// OptionsFromEnv builds Options from DB_MAX_CONNS and LOCATION_RETENTION_DAYS.
func OptionsFromEnv() Options {
	return Options{
		MaxConns:      config.DBMaxConns(),
		RetentionDays: config.LocationRetentionDays(),
	}
}

// poolConfig parses the URL and applies pool sizing and lifetimes.
func poolConfig(databaseURL string, opts Options) (*pgxpool.Config, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	if opts.MaxConns <= 0 {
		opts.MaxConns = config.DefaultDBMaxConns
	}
	cfg.MaxConns = int32(opts.MaxConns)
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = time.Minute
	return cfg, nil
}

// Connect opens a pgx connection pool sized from the environment, verifies
// connectivity, and applies the configured location retention policy. The
// signature is unchanged for existing callers.
func Connect(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	return ConnectWithOptions(ctx, databaseURL, OptionsFromEnv())
}

// ConnectWithOptions is Connect with explicit options.
func ConnectWithOptions(ctx context.Context, databaseURL string, opts Options) (*pgxpool.Pool, error) {
	cfg, err := poolConfig(databaseURL, opts)
	if err != nil {
		return nil, err
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}

	if opts.RetentionDays > 0 {
		// Best effort: a failure here must not stop the API from serving.
		if err := ApplyRetentionPolicy(ctx, pool, opts.RetentionDays); err != nil {
			slog.Error("apply location retention policy", "days", opts.RetentionDays, "err", err)
		}
	}
	return pool, nil
}

// Migrate applies all pending SQL migrations from the embedded filesystem.
func Migrate(databaseURL string) error {
	src, err := iofs.New(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("load embedded migrations: %w", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, databaseURL)
	if err != nil {
		return fmt.Errorf("init migrate: %w", err)
	}
	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return fmt.Errorf("apply migrations: %w", err)
	}
	return nil
}
