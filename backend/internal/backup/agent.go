package backup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

// Agent is the long-running scheduler: it fires the cron schedule, serves
// admin-panel requests (back up now / test S3), and publishes a heartbeat.
type Agent struct {
	Runner *Runner
	DB     *DBRecorder
	Cron   *Cron
	Poll   time.Duration // request poll + heartbeat interval (default 10s)

	// Getenv is the real environment (pins). Key seals the saved credentials.
	// When both DB and Getenv are set the saved UI settings are re-read every
	// poll and applied without restarting the container.
	Getenv func(string) string
	Key    []byte

	// hasSuccess overrides DB.HasSuccess in tests.
	hasSuccess func(context.Context) bool

	settingsAt  time.Time // UpdatedAt of the settings version currently applied
	settingsErr string

	mu     sync.Mutex // one backup/probe at a time
	nextMu sync.Mutex
	next   time.Time
	sum    Summary
}

func (a *Agent) setSummary(s Summary) { a.nextMu.Lock(); a.sum = s; a.nextMu.Unlock() }
func (a *Agent) getSummary() Summary  { a.nextMu.Lock(); defer a.nextMu.Unlock(); return a.sum }

func (a *Agent) setNext(t time.Time) { a.nextMu.Lock(); a.next = t; a.nextMu.Unlock() }
func (a *Agent) getNext() time.Time  { a.nextMu.Lock(); defer a.nextMu.Unlock(); return a.next }

func (a *Agent) poll() time.Duration {
	if a.Poll > 0 {
		return a.Poll
	}
	return 10 * time.Second
}

// Serve blocks until ctx is cancelled.
func (a *Agent) Serve(ctx context.Context) error {
	r := a.Runner
	log := r.log()
	loc := r.Cfg.Location
	a.setSummary(r.Cfg.Summary())
	a.setNext(a.Cron.Next(r.now().In(loc)))
	hb := func(boot bool) {
		n := a.getNext()
		sum := a.getSummary()
		c, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		if err := a.DB.Heartbeat(c, r.Cfg.Version, &n, sum, boot); err != nil {
			log.Warn("heartbeat failed", "error", r.scrub(err.Error()))
		}
	}
	if err := a.DB.FailStale(ctx); err != nil {
		log.Warn("could not reset stale requests", "error", r.scrub(err.Error()))
	}
	hb(true)
	log.Info("backup service started", "schedule", r.Cfg.Schedule, "timezone", loc.String(), "next_run", a.getNext().Format(time.RFC3339),
		"encryption", a.getSummary().Encryption, "destinations", len(a.getSummary().Destinations))
	if len(a.getSummary().Destinations) == 0 {
		log.Warn("no destination configured: set BACKUP_S3_BUCKET and/or BACKUP_LOCAL_DIR")
	}
	// The heartbeat runs on its own goroutine so a long dump never makes the
	// service look dead in the admin panel.
	go func() {
		t := time.NewTicker(a.poll())
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				hb(false)
			}
		}
	}()
	a.reload(ctx)
	if a.shouldRunOnStart(ctx) {
		a.runBackup(ctx, "schedule")
	}
	t := time.NewTicker(a.poll())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
		a.reload(ctx)
		if now := r.now(); !now.Before(a.getNext()) {
			a.runBackup(ctx, "schedule")
			a.setNext(a.Cron.Next(r.now().In(loc)))
		}
		a.serveRequests(ctx)
	}
}

// shouldRunOnStart: always with BACKUP_RUN_ON_START=true; with "first" only
// while no backup has ever succeeded and a destination is configured.
func (a *Agent) shouldRunOnStart(ctx context.Context) bool {
	cfg := a.Runner.Cfg
	if cfg.RunOnStart {
		return true
	}
	if !cfg.RunOnFirstStart || !cfg.HasDestination() {
		return false
	}
	if a.hasSuccess != nil {
		return !a.hasSuccess(ctx)
	}
	if a.DB == nil || a.DB.Pool == nil {
		return false
	}
	c, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return !a.DB.HasSuccess(c)
}

func (a *Agent) runBackup(ctx context.Context, trigger string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	t0 := time.Now()
	recs, err := a.Runner.Run(ctx, trigger)
	if err != nil {
		a.Runner.log().Error("backup failed", "trigger", trigger, "error", a.Runner.scrub(err.Error()))
		return "", err
	}
	var size int64
	for _, r := range recs {
		size = r.SizeBytes
	}
	return fmt.Sprintf("Backup finished in %s (%d bytes, %d destination(s)).", time.Since(t0).Round(time.Second), size, len(recs)), nil
}

func (a *Agent) serveRequests(ctx context.Context) {
	for ctx.Err() == nil {
		req, err := a.DB.Claim(ctx)
		if err != nil {
			a.Runner.log().Warn("request poll failed", "error", a.Runner.scrub(err.Error()))
			return
		}
		if req == nil {
			return
		}
		var msg string
		var rerr error
		switch req.Kind {
		case "backup":
			msg, rerr = a.runBackup(ctx, "manual")
		case "test_s3":
			msg, rerr = a.testS3(ctx, req.Payload)
		default:
			rerr = fmt.Errorf("unknown request kind")
		}
		ok := rerr == nil
		if !ok {
			msg = a.Runner.scrub(rerr.Error())
		}
		fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		if err := a.DB.Finish(fctx, req.ID, ok, msg); err != nil {
			slog.Warn("could not finish request", "error", a.Runner.scrub(err.Error()))
		}
		cancel()
	}
}

// testPayload is what the admin UI sends to test unsaved form values.
type testPayload struct {
	Settings    backupsettings.Settings     `json:"settings"`
	Credentials *backupsettings.Credentials `json:"credentials,omitempty"`
}

func (a *Agent) testS3(ctx context.Context, payload []byte) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	stores := a.Runner.Stores
	if len(payload) > 0 {
		if a.Key == nil {
			return "", fmt.Errorf("the backup service has no BACKUP_SETTINGS_KEY, so it cannot read unsaved settings")
		}
		raw, err := backupsettings.OpenPayload(a.Key, payload)
		if err != nil {
			return "", fmt.Errorf("could not read the test request")
		}
		var p testPayload
		if json.Unmarshal(raw, &p) != nil {
			return "", fmt.Errorf("could not read the test request")
		}
		st, err := backupsettings.Load(ctx, a.DB.Pool, a.Key)
		if err != nil {
			return "", err
		}
		st.Exists, st.Settings = true, p.Settings
		if p.Credentials != nil {
			// Typed for exactly this test: never mixed with stored credentials.
			st.Creds, st.CredsFresh = p.Credentials, true
		}
		cfg, err := ResolveConfig(a.getenv(), st)
		if err != nil {
			return "", a.scrubWith(err, p.Credentials)
		}
		if cfg.S3 == nil {
			return "", errNoS3
		}
		s3, err := NewS3Store(cfg.S3)
		if err != nil {
			return "", err
		}
		stores = []Store{s3}
		defer func() { _ = cfg }()
		c, cancel := context.WithTimeout(ctx, 60*time.Second)
		defer cancel()
		t0 := time.Now()
		steps, err := Probe(c, s3)
		if err != nil {
			return "", fmt.Errorf("S3 connection test failed (%v): %s", steps, Scrub(err.Error(), cfg.secrets()))
		}
		return fmt.Sprintf("S3 connection OK (%s) in %s.", join(steps), time.Since(t0).Round(time.Millisecond)), nil
	}
	for _, st := range stores {
		if st.Kind() != "s3" {
			continue
		}
		c, cancel := context.WithTimeout(ctx, 60*time.Second)
		defer cancel()
		t0 := time.Now()
		steps, err := Probe(c, st)
		if err != nil {
			return "", fmt.Errorf("S3 connection test failed (%v): %w", steps, err)
		}
		return fmt.Sprintf("S3 connection OK (%s) in %s.", join(steps), time.Since(t0).Round(time.Millisecond)), nil
	}
	return "", fmt.Errorf("no S3 destination is configured")
}

func join(s []string) string {
	out := ""
	for i, x := range s {
		if i > 0 {
			out += ", "
		}
		out += x
	}
	return out
}

func (a *Agent) getenv() func(string) string {
	if a.Getenv != nil {
		return a.Getenv
	}
	return os.Getenv
}

func (a *Agent) scrubWith(err error, c *backupsettings.Credentials) error {
	var secrets []string
	if c != nil {
		secrets = []string{c.SecretKey, c.AccessKeyID}
	}
	return errors.New(Scrub(err.Error(), secrets))
}

// reload applies newly saved UI settings. On any problem the running
// configuration stays active and the (scrubbed) reason is published.
func (a *Agent) reload(ctx context.Context) {
	if a.DB == nil || a.DB.Pool == nil {
		return
	}
	r := a.Runner
	st, err := backupsettings.Load(ctx, a.DB.Pool, a.Key)
	if err != nil {
		return
	}
	if st.Exists && st.UpdatedAt.Equal(a.settingsAt) {
		return
	}
	if !st.Exists && a.settingsAt.IsZero() {
		return
	}
	apply := func() error {
		if st.HasCreds && st.CredsErr != nil {
			return st.CredsErr
		}
		cfg, err := ResolveConfig(a.getenv(), st)
		if err != nil {
			return err
		}
		cfg.DatabaseURL, cfg.WorkDir, cfg.Version, cfg.RunOnStart, cfg.RunOnFirstStart = r.Cfg.DatabaseURL, r.Cfg.WorkDir, r.Cfg.Version, r.Cfg.RunOnStart, r.Cfg.RunOnFirstStart
		cr, err := ParseCron(cfg.Schedule)
		if err != nil {
			return err
		}
		stores, err := BuildStores(cfg)
		if err != nil {
			return err
		}
		a.mu.Lock()
		r.Cfg, r.Stores, a.Cron = cfg, stores, cr
		a.mu.Unlock()
		a.setNext(cr.Next(r.now().In(cfg.Location)))
		return nil
	}
	if err := apply(); err != nil {
		a.settingsErr = Scrub(err.Error(), r.Cfg.DatabaseSecrets())
		r.log().Warn("saved backup settings could not be applied; keeping the previous configuration", "error", a.settingsErr)
	} else {
		a.settingsErr = ""
		r.log().Info("applied backup settings saved in the admin panel")
	}
	a.settingsAt = st.UpdatedAt
	sum := r.Cfg.Summary()
	sum.SettingsError = a.settingsErr
	if st.Exists {
		t := st.UpdatedAt
		sum.SettingsUpdatedAt = &t
	}
	a.setSummary(sum)
}

// BuildStores creates the destinations described by a configuration.
func BuildStores(cfg *Config) ([]Store, error) {
	var stores []Store
	if cfg.LocalDir != "" {
		stores = append(stores, &DirStore{Dir: cfg.LocalDir})
	}
	if cfg.S3 != nil {
		s, err := NewS3Store(cfg.S3)
		if err != nil {
			return nil, err
		}
		stores = append(stores, s)
	}
	return stores, nil
}
