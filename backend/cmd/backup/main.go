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
	"encoding/json"
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
	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"

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
	key := backup.SettingsKey(os.Getenv)

	// Settings saved in the admin UI live in the database; the environment
	// still wins for anything it sets. `fetch` (disaster recovery) must work
	// without a database, so it uses the environment only.
	var pool *pgxpool.Pool
	var stored *backupsettings.Stored
	needDB := cmd == "daemon" || cmd == "run"
	if cmd != "fetch" && os.Getenv("DATABASE_URL") != "" {
		p, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
		if err == nil {
			c, cancel := context.WithTimeout(ctx, 10*time.Second)
			stored, err = backupsettings.Load(c, p, key)
			cancel()
			if err == nil {
				pool = p
			} else {
				p.Close()
			}
		}
		if pool == nil && needDB {
			fatal(fmt.Errorf("cannot reach the database"))
		}
	}
	if pool != nil {
		defer pool.Close()
	}
	if stored != nil && stored.HasCreds && stored.CredsErr != nil {
		fmt.Fprintln(os.Stderr, "warning:", stored.CredsErr)
	}
	cfg, err := backup.ResolveConfig(getenv, stored)
	if err != nil && stored != nil && stored.Exists && cmd == "daemon" {
		// Bad saved settings must not crash-loop the service: start on the
		// environment alone; the daemon reports the problem to the admin panel.
		fmt.Fprintln(os.Stderr, "warning: saved settings not applied:", backup.Scrub(err.Error(), nil))
		cfg, err = backup.ResolveConfig(getenv, nil)
	}
	if err != nil {
		fatal(err)
	}
	stores, err := backup.BuildStores(cfg)
	if err != nil {
		fatal(err)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	runner := &backup.Runner{Cfg: cfg, Stores: stores, Log: log, DumpCmd: os.Getenv("BACKUP_PG_DUMP")}
	var rec *backup.DBRecorder
	if needDB {
		rec = &backup.DBRecorder{Pool: pool}
		runner.Rec = rec
	}

	switch cmd {
	case "daemon":
		cr, _ := backup.ParseCron(cfg.Schedule)
		a := &backup.Agent{Runner: runner, DB: rec, Cron: cr, Getenv: os.Getenv, Key: key}
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
	case "settings-import":
		// Headless equivalent of the admin UI form: JSON settings on stdin,
		// credentials from BACKUP_IMPORT_ACCESS_KEY_ID / BACKUP_IMPORT_SECRET_ACCESS_KEY.
		if pool == nil || key == nil {
			fatal(fmt.Errorf("needs DATABASE_URL and BACKUP_SETTINGS_KEY"))
		}
		st := backupsettings.Defaults()
		if err := json.NewDecoder(os.Stdin).Decode(&st); err != nil {
			fatal(fmt.Errorf("settings JSON: %v", err))
		}
		if errs := backupsettings.ValidateSettings(&st); len(errs) > 0 {
			fatal(fmt.Errorf("invalid settings: %v", errs))
		}
		var cr *backupsettings.Credentials
		if id := os.Getenv("BACKUP_IMPORT_ACCESS_KEY_ID"); id != "" {
			cr = &backupsettings.Credentials{AccessKeyID: id, SecretKey: os.Getenv("BACKUP_IMPORT_SECRET_ACCESS_KEY")}
			if errs := backupsettings.ValidateCredentials(*cr); len(errs) > 0 {
				fatal(fmt.Errorf("invalid credentials: %v", errs))
			}
		}
		if err := backupsettings.Save(ctx, pool, key, st, cr, false, "", st.Binding()); err != nil {
			fatal(err)
		}
		fmt.Println("settings saved")
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
