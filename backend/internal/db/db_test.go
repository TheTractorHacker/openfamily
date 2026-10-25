package db

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/wheresfrank/openfamily/backend/internal/config"
)

const testURL = "postgres://u:p@localhost:5432/d?sslmode=disable"

func TestPoolConfigDefaultsAndOverride(t *testing.T) {
	cfg, err := poolConfig(testURL, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if int(cfg.MaxConns) != config.DefaultDBMaxConns || cfg.MaxConns <= 10 {
		t.Fatalf("MaxConns=%d", cfg.MaxConns)
	}
	if cfg.MaxConnLifetime != 30*time.Minute || cfg.MaxConnIdleTime != 5*time.Minute {
		t.Fatalf("lifetimes %v %v", cfg.MaxConnLifetime, cfg.MaxConnIdleTime)
	}
	cfg, _ = poolConfig(testURL, Options{MaxConns: 40})
	if cfg.MaxConns != 40 {
		t.Fatalf("MaxConns=%d", cfg.MaxConns)
	}
	if _, err := poolConfig("://bad", Options{}); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestOptionsFromEnv(t *testing.T) {
	t.Setenv("DB_MAX_CONNS", "33")
	t.Setenv("LOCATION_RETENTION_DAYS", "45")
	o := OptionsFromEnv()
	if o.MaxConns != 33 || o.RetentionDays != 45 {
		t.Fatalf("%+v", o)
	}
}

func TestApplyRetentionPolicyRejectsNonPositive(t *testing.T) {
	if err := ApplyRetentionPolicy(context.Background(), nil, 0); err == nil {
		t.Fatal("expected error")
	}
}

func TestRetentionSQLIsGuarded(t *testing.T) {
	if !strings.Contains(retentionRemoveSQL, "if_exists => true") || !strings.Contains(retentionAddSQL, "if_not_exists => true") {
		t.Fatal("retention SQL must be idempotent")
	}
}
