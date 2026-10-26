package config

import "testing"

func TestLocationRetentionDays(t *testing.T) {
	cases := map[string]int{"": 90, "30": 30, "365": 365, "0": 90, "-5": 90, "abc": 90}
	for in, want := range cases {
		t.Setenv("LOCATION_RETENTION_DAYS", in)
		if got := LocationRetentionDays(); got != want {
			t.Errorf("LOCATION_RETENTION_DAYS=%q: got %d want %d", in, got, want)
		}
	}
	t.Setenv("LOCATION_RETENTION_DAYS", "2")
	if got := LocationRetention().Hours(); got != 48 {
		t.Errorf("retention hours = %v", got)
	}
}

func TestDBMaxConns(t *testing.T) {
	cases := map[string]int{"": 25, "50": 50, "0": 25, "x": 25, "-1": 25}
	for in, want := range cases {
		t.Setenv("DB_MAX_CONNS", in)
		if got := DBMaxConns(); got != want {
			t.Errorf("DB_MAX_CONNS=%q: got %d want %d", in, got, want)
		}
	}
}

func TestDrivingThresholds(t *testing.T) {
	t.Setenv("DRIVING_SPEEDING_MPS", "")
	t.Setenv("DRIVING_SPEEDING_SECONDS", "")
	t.Setenv("DRIVING_HARD_BRAKE_MPS2", "")
	t.Setenv("DRIVING_RAPID_ACCEL_MPS2", "")
	if DrivingSpeedingMps() != 35.76 || DrivingSpeedingSeconds() != 30 || DrivingHardBrakeMps2() != 3.5 || DrivingRapidAccelMps2() != 3.5 {
		t.Fatal("defaults changed")
	}
	t.Setenv("DRIVING_SPEEDING_MPS", "31.3")
	t.Setenv("DRIVING_SPEEDING_SECONDS", "45")
	t.Setenv("DRIVING_HARD_BRAKE_MPS2", "-4.2") // sign is ignored
	t.Setenv("DRIVING_RAPID_ACCEL_MPS2", "junk")
	if DrivingSpeedingMps() != 31.3 || DrivingSpeedingSeconds() != 45 || DrivingHardBrakeMps2() != 4.2 || DrivingRapidAccelMps2() != 3.5 {
		t.Fatal("env not applied")
	}
	t.Setenv("DRIVING_SPEEDING_SECONDS", "0")
	if DrivingSpeedingSeconds() != 30 {
		t.Fatal("zero should fall back")
	}
}
