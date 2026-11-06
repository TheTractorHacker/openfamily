package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/config"
	"github.com/TheTractorHacker/openfamily/backend/internal/db"
	"github.com/TheTractorHacker/openfamily/backend/internal/handlers"
)

// runE2EEFingerprints also implements `server e2ee-log-head`: it verifies the whole
// transparency log (hash chain and every signature) and prints the head so the
// operator can compare it with the "Compare log head" screen on the phones.
// It implements `server e2ee-fingerprints [--all]`: print every
// user's device key fingerprints from the database so the operator can compare
// them with the phone (Settings > Security > Encryption keys). Read-only and
// public data only; it does not run migrations.
func runE2EEFingerprints(cfg config.Config, cmd string, args []string) int {
	all := false
	for _, a := range args {
		switch a {
		case "--all":
			all = true
		default:
			fmt.Fprintf(os.Stderr, "usage: server e2ee-fingerprints [--all]\n")
			return 2
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, "database connection failed:", err)
		return 1
	}
	defer pool.Close()
	if cmd == "e2ee-log-head" {
		if err := handlers.PrintE2EELogHead(ctx, pool, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "log verification FAILED:", err)
			return 1
		}
		return 0
	}
	if err := handlers.PrintE2EEFingerprints(ctx, pool, os.Stdout, all); err != nil {
		fmt.Fprintln(os.Stderr, "query failed:", err)
		return 1
	}
	return 0
}
