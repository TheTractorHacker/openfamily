package backup

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// Agent is the long-running scheduler: it fires the cron schedule, serves
// admin-panel requests (back up now / test S3), and publishes a heartbeat.
type Agent struct {
	Runner *Runner
	DB     *DBRecorder
	Cron   *Cron
	Poll   time.Duration // request poll + heartbeat interval (default 10s)

	mu     sync.Mutex // one backup/probe at a time
	nextMu sync.Mutex
	next   time.Time
}

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
	sum := r.Cfg.Summary()
	a.setNext(a.Cron.Next(r.now().In(loc)))
	hb := func(boot bool) {
		n := a.getNext()
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
		"encryption", sum.Encryption, "destinations", len(sum.Destinations))
	if len(sum.Destinations) == 0 {
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
	if r.Cfg.RunOnStart {
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
		if now := r.now(); !now.Before(a.getNext()) {
			a.runBackup(ctx, "schedule")
			a.setNext(a.Cron.Next(r.now().In(loc)))
		}
		a.serveRequests(ctx)
	}
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
			msg, rerr = a.testS3(ctx)
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

func (a *Agent) testS3(ctx context.Context) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, st := range a.Runner.Stores {
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
