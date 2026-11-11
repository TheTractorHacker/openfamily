package handlers

import (
	"sync"
	"time"
)

// Dawarich sync backoff.
//
// The sync loop ticks every minute. Without a backoff an unreachable or
// rejecting Dawarich server was hit (and logged) once a minute for as long as
// it stayed down: a day of outage was 1440 identical warnings and 1440 failed
// requests per account. Each destination (the main account or one mapped
// person) now keeps its own consecutive-failure count and is skipped until its
// next retry time. A success, a change to the settings, or the admin pressing
// "Sync now" starts it over.
const (
	// dawarichBackoffBase is the wait after the first failure; it doubles on
	// each further failure.
	dawarichBackoffBase = 2 * time.Minute
	// dawarichBackoffMax is the longest wait between attempts.
	dawarichBackoffMax = time.Hour
	// dawarichLogEvery is how often an unchanged failure is logged again.
	dawarichLogEvery = 30 * time.Minute
)

// dawarichBackoffDelay is the wait after the given number of consecutive
// failures: 2, 4, 8, 16, 32 minutes, then one hour.
func dawarichBackoffDelay(failures int) time.Duration {
	if failures < 1 {
		return 0
	}
	d := dawarichBackoffBase
	for i := 1; i < failures; i++ {
		d *= 2
		if d >= dawarichBackoffMax {
			return dawarichBackoffMax
		}
	}
	if d > dawarichBackoffMax {
		return dawarichBackoffMax
	}
	return d
}

type dawarichTargetState struct {
	failures   int
	next       time.Time
	msg        string
	lastLogged time.Time
	suppressed int
}

// dawarichBackoff tracks the retry state of every Dawarich destination. The
// zero value is ready to use; now can be replaced in tests.
type dawarichBackoff struct {
	mu  sync.Mutex
	now func() time.Time
	st  map[string]*dawarichTargetState
}

func (b *dawarichBackoff) clock() time.Time {
	if b.now != nil {
		return b.now()
	}
	return time.Now()
}

// due reports whether the destination may be tried now.
func (b *dawarichBackoff) due(key string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := b.st[key]
	return s == nil || s.failures == 0 || !b.clock().Before(s.next)
}

// dawarichFailure is what the caller needs after recording a failure.
type dawarichFailure struct {
	Failures   int
	Next       time.Time
	Log        bool // write a log line this time
	Suppressed int  // identical failures not logged since the last line
}

// failure records one failed attempt. It asks for a log line on the first
// failure, when the message changes, and then at most every dawarichLogEvery.
func (b *dawarichBackoff) failure(key, msg string) dawarichFailure {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.st == nil {
		b.st = map[string]*dawarichTargetState{}
	}
	s := b.st[key]
	if s == nil {
		s = &dawarichTargetState{}
		b.st[key] = s
	}
	now := b.clock()
	s.failures++
	s.next = now.Add(dawarichBackoffDelay(s.failures))
	out := dawarichFailure{Failures: s.failures, Next: s.next}
	if s.failures == 1 || msg != s.msg || now.Sub(s.lastLogged) >= dawarichLogEvery {
		out.Log = true
		out.Suppressed = s.suppressed
		s.suppressed = 0
		s.lastLogged = now
	} else {
		s.suppressed++
	}
	s.msg = msg
	return out
}

// success clears the destination's failures and returns how many there were.
func (b *dawarichBackoff) success(key string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := b.st[key]
	if s == nil {
		return 0
	}
	n := s.failures
	delete(b.st, key)
	return n
}

// rewind sets a destination's failure count back to zero but keeps its last
// message and log timestamps, so the next failure counts as the first one
// (a two minute wait) without logging again for an unchanged message.
func (b *dawarichBackoff) rewind(key string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if s := b.st[key]; s != nil {
		s.failures = 0
	}
}

// snapshot returns the current failure count, next retry time and last error
// message of a destination (zero values when it is healthy).
func (b *dawarichBackoff) snapshot(key string) (failures int, next time.Time, msg string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if s := b.st[key]; s != nil && s.failures > 0 {
		return s.failures, s.next, s.msg
	}
	return 0, time.Time{}, ""
}

// reset forgets every destination, so the next tick tries them all.
func (b *dawarichBackoff) reset() {
	b.mu.Lock()
	b.st = nil
	b.mu.Unlock()
}
