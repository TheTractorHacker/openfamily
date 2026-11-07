// Command backup is the optional OpenFamily backup service (compose profile
// "backup"). Subcommands:
//
//	daemon              run the schedule + serve admin-panel requests
//	run                 take one backup now (all configured destinations)
//	prune [--dry-run]   apply retention to every destination
//	test-s3             write/read/delete a probe object
//	list                list complete backups
//	fetch [-o FILE] [NAME|latest]   download, verify SHA-256, decrypt
//	keygen              print a new age key pair (private -> stdout, public -> stderr)
//
// Configuration is read from BACKUP_* / DATABASE_URL environment variables;
// see docs/backup-restore.md. Secrets are never printed.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TheTractorHacker/openfamily/backend/internal/backup"

	_ "time/tzdata"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: backup daemon|run|prune|test-s3|list|fetch|keygen")
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	if cmd == "keygen" {
		priv, pub, err := backup.GenerateKeyPair()
		if err != nil {
			fatal(err)
		}
		fmt.Println(priv)
		fmt.Fprintln(os.Stderr, "public key (BACKUP_AGE_RECIPIENT):", pub)
		fmt.Fprintln(os.Stderr, "Store the private key (stdout) OFF this server, e.g. in a password manager. Without it backups cannot be decrypted.")
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	getenv := os.Getenv
	if cmd != "daemon" && cmd != "run" {
		// Reading, listing, pruning and testing never upload a dump, so the
		// "refuse unencrypted S3 uploads" guard must not block them.
		getenv = func(k string) string {
			if k == "BACKUP_ALLOW_UNENCRYPTED" {
				return "true"
			}
			return os.Getenv(k)
		}
	}
	cfg, err := backup.LoadConfig(getenv)
	if err != nil {
		fatal(err)
	}
	var stores []backup.Store
	if cfg.LocalDir != "" {
		stores = append(stores, &backup.DirStore{Dir: cfg.LocalDir})
	}
	if cfg.S3 != nil {
		s, err := backup.NewS3Store(cfg.S3)
		if err != nil {
			fatal(err)
		}
		stores = append(stores, s)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	runner := &backup.Runner{Cfg: cfg, Stores: stores, Log: log, DumpCmd: os.Getenv("BACKUP_PG_DUMP")}

	needDB := cmd == "daemon" || cmd == "run"
	var rec *backup.DBRecorder
	if needDB {
		pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
		if err != nil {
			fatal(fmt.Errorf("database: %s", backup.Scrub(err.Error(), cfg.DatabaseSecrets())))
		}
		defer pool.Close()
		rec = &backup.DBRecorder{Pool: pool}
		runner.Rec = rec
	}

	switch cmd {
	case "daemon":
		cr, _ := backup.ParseCron(cfg.Schedule)
		a := &backup.Agent{Runner: runner, DB: rec, Cron: cr}
		if n, err := strconv.Atoi(os.Getenv("BACKUP_POLL_SECONDS")); err == nil && n > 0 && n <= 300 {
			a.Poll = time.Duration(n) * time.Second
		}
		if err := a.Serve(ctx); err != nil {
			fatal(err)
		}
	case "run":
		if _, err := runner.Run(ctx, "script"); err != nil {
			fatal(err)
		}
	case "prune":
		fs := flag.NewFlagSet("prune", flag.ExitOnError)
		dry := fs.Bool("dry-run", cfg.Retention.DryRun, "only list what would be deleted")
		_ = fs.Parse(args)
		for _, st := range stores {
			removed, err := runner.Prune(ctx, st, *dry)
			if err != nil {
				fatal(err)
			}
			for _, k := range removed {
				fmt.Printf("%s %s %s\n", map[bool]string{true: "would delete", false: "deleted"}[*dry], st.Kind(), k)
			}
		}
	case "test-s3":
		for _, st := range stores {
			if st.Kind() != "s3" {
				continue
			}
			steps, err := backup.Probe(ctx, st)
			fmt.Println(steps)
			if err != nil {
				fatal(err)
			}
			fmt.Println("S3 connection OK")
			return
		}
		fatal(fmt.Errorf("no S3 destination configured"))
	case "list":
		for _, st := range stores {
			es, _, err := backup.ListBackups(ctx, st)
			if err != nil {
				fatal(err)
			}
			for _, e := range es {
				fmt.Printf("%s\t%s\t%s\n", st.Kind(), e.Name, e.Time.Format("2006-01-02T15:04:05Z"))
			}
		}
	case "fetch":
		fs := flag.NewFlagSet("fetch", flag.ExitOnError)
		out := fs.String("o", "restore.dump", "output file for the decrypted dump")
		src := fs.String("from", "s3", "store to read: s3 or local")
		_ = fs.Parse(args)
		which := fs.Arg(0)
		var st backup.Store
		for _, s := range stores {
			if s.Kind() == *src {
				st = s
			}
		}
		if st == nil {
			fatal(fmt.Errorf("destination %q is not configured", *src))
		}
		man, err := backup.Fetch(ctx, st, which, *out, os.Getenv("BACKUP_AGE_IDENTITY_FILE"), os.Getenv("BACKUP_AGE_PASSPHRASE_FILE"))
		if err != nil {
			fatal(err)
		}
		fmt.Fprintf(os.Stderr, "fetched %s (%d bytes, sha256 %s verified, encryption %s)\n", man.Object, man.SizeBytes, man.SHA256, man.Encryption)
	default:
		fmt.Fprintln(os.Stderr, "unknown command", cmd)
		os.Exit(2)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
