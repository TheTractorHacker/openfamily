package config

import (
	"testing"
)

func TestLoadTileDefaults(t *testing.T) {
	t.Setenv("TILE_URL", "")
	t.Setenv("SATELLITE_TILE_URL", "")
	cfg := Load()
	if cfg.TileURL != DefaultTileURL {
		t.Fatalf("tile=%q", cfg.TileURL)
	}
	if cfg.SatelliteTileURL != DefaultSatelliteTileURL {
		t.Fatalf("satellite=%q", cfg.SatelliteTileURL)
	}
}

func TestLoadTileOverride(t *testing.T) {
	t.Setenv("TILE_URL", "https://tiles.example.com/{z}/{x}/{y}.png?api_key=abc")
	t.Setenv("SATELLITE_TILE_URL", "https://sat.example.com/{z}/{y}/{x}")
	cfg := Load()
	if cfg.TileURL != "https://tiles.example.com/{z}/{x}/{y}.png?api_key=abc" {
		t.Fatalf("tile=%q", cfg.TileURL)
	}
	if cfg.SatelliteTileURL != "https://sat.example.com/{z}/{y}/{x}" {
		t.Fatalf("satellite=%q", cfg.SatelliteTileURL)
	}
}

func TestValidateProductionDBSSL(t *testing.T) {
	base := Config{AppEnv: "production", JWTSecret: "0123456789abcdef0123456789abcdef", TLSBehindProxy: true}
	cases := []struct {
		url     string
		allowOK bool
		wantErr bool
	}{
		{"postgres://u:p@db:5432/x?sslmode=disable", false, true},
		{"postgres://u:p@db:5432/x?sslmode=prefer", false, true},
		{"postgres://u:p@db:5432/x?sslmode=allow", false, true},
		{"postgres://u:p@db:5432/x", false, true},
		{"host=db user=u sslmode=disable", false, true},
		{"postgres://u:p@db:5432/x?sslmode=require", false, false},
		{"postgres://u:p@db:5432/x?sslmode=verify-full", false, false},
		{"host=db sslmode=verify-ca", false, false},
		{"postgres://u:p@db:5432/x?sslmode=disable", true, false},
	}
	for _, tc := range cases {
		c := base
		c.DatabaseURL = tc.url
		c.DBSSLDisableOK = tc.allowOK
		if err := c.Validate(); (err != nil) != tc.wantErr {
			t.Errorf("%q allowOK=%v: err=%v wantErr=%v", tc.url, tc.allowOK, err, tc.wantErr)
		}
	}
}
