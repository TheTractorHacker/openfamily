package config

import (
	"os"
	"strconv"
	"time"
)

const (
	// DefaultLocationRetentionDays is how long location history is kept when
	// LOCATION_RETENTION_DAYS is unset or invalid.
	DefaultLocationRetentionDays = 90

	// DefaultDBMaxConns is the pgx pool size when DB_MAX_CONNS is unset or
	// invalid. Postgres' default max_connections is 100, so 25 leaves ample
	// headroom for a single API instance plus the migration connection.
	DefaultDBMaxConns = 25
)

// LocationRetentionDays returns the configured location history retention in
// days (env LOCATION_RETENTION_DAYS, default 90). Non-numeric or non-positive
// values fall back to the default. It is read from the environment on each
// call so the history API and the startup retention policy always agree.
func LocationRetentionDays() int {
	return getenvPositiveInt("LOCATION_RETENTION_DAYS", DefaultLocationRetentionDays)
}

// LocationRetention is LocationRetentionDays as a duration.
func LocationRetention() time.Duration {
	return time.Duration(LocationRetentionDays()) * 24 * time.Hour
}

// DBMaxConns returns the pool size (env DB_MAX_CONNS, default 25).
func DBMaxConns() int {
	return getenvPositiveInt("DB_MAX_CONNS", DefaultDBMaxConns)
}

func getenvPositiveInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return fallback
}
