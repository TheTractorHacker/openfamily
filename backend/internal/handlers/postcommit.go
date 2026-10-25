package handlers

import (
	"log/slog"
	"sync/atomic"
)

// boundedRunner limits the goroutines the ingest path spawns after commit.
// At most maxQueued tasks exist at once (running or waiting); at most
// maxRunning of them run concurrently, so a burst cannot exhaust the database
// pool or spawn unbounded goroutines. Excess tasks are dropped: geofence state
// is re-evaluated by the 60 s reconcile loop and the live map refreshes on the
// next point, so a shed task is a delay, not data loss.
type boundedRunner struct {
	queued  chan struct{}
	running chan struct{}
	dropped atomic.Int64
}

func newBoundedRunner(maxRunning, maxQueued int) *boundedRunner {
	if maxRunning < 1 {
		maxRunning = 1
	}
	if maxQueued < maxRunning {
		maxQueued = maxRunning
	}
	return &boundedRunner{
		queued:  make(chan struct{}, maxQueued),
		running: make(chan struct{}, maxRunning),
	}
}

// Submit runs fn on a new goroutine unless the runner is saturated. It reports
// whether the task was accepted.
func (b *boundedRunner) Submit(fn func()) bool {
	select {
	case b.queued <- struct{}{}:
	default:
		if n := b.dropped.Add(1); n == 1 || n%100 == 0 {
			slog.Warn("post-commit work shed: runner saturated", "dropped_total", n)
		}
		return false
	}
	go func() {
		b.running <- struct{}{}
		defer func() {
			<-b.running
			<-b.queued
		}()
		fn()
	}()
	return true
}

// postCommitRunner bounds geofence evaluation and live broadcasts started by
// the ingest handlers. 16 concurrent tasks stay below the default pool size.
var postCommitRunner = newBoundedRunner(16, 256)
