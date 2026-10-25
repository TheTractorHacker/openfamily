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
