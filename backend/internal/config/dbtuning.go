package config

import (
	"math"
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

// Driving event thresholds (see docs/driving.md). Read from the environment on
// each call; invalid or non-positive values fall back to the defaults.
const (
	DefaultDrivingSpeedingMps     = 35.76 // 80 mph
	DefaultDrivingSpeedingSeconds = 30.0
	DefaultDrivingHardBrakeMps2   = 3.5
	DefaultDrivingRapidAccelMps2  = 3.5
)

// DrivingSpeedingMps is the speed above which a drive counts as speeding
// (env DRIVING_SPEEDING_MPS, metres per second).
func DrivingSpeedingMps() float64 {
	return getenvPositiveFloat("DRIVING_SPEEDING_MPS", DefaultDrivingSpeedingMps)
}

// DrivingSpeedingSeconds is how long speed must stay above the limit for one
// speeding event (env DRIVING_SPEEDING_SECONDS).
func DrivingSpeedingSeconds() float64 {
	return getenvPositiveFloat("DRIVING_SPEEDING_SECONDS", DefaultDrivingSpeedingSeconds)
}

// DrivingHardBrakeMps2 is the deceleration magnitude of a hard brake
// (env DRIVING_HARD_BRAKE_MPS2; a leading minus sign is accepted and ignored).
func DrivingHardBrakeMps2() float64 {
	return getenvPositiveFloat("DRIVING_HARD_BRAKE_MPS2", DefaultDrivingHardBrakeMps2)
}

// DrivingRapidAccelMps2 is the acceleration of a rapid start
// (env DRIVING_RAPID_ACCEL_MPS2).
func DrivingRapidAccelMps2() float64 {
	return getenvPositiveFloat("DRIVING_RAPID_ACCEL_MPS2", DefaultDrivingRapidAccelMps2)
}

func getenvPositiveFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && !math.IsNaN(f) && !math.IsInf(f, 0) && f != 0 {
			return math.Abs(f)
		}
	}
	return fallback
}
