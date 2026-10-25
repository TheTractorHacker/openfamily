package sms

import (
	"sync"
	"time"
)

const (
	// maxLimiterKeys bounds memory regardless of how many distinct keys
	// (attacker-chosen emails, addresses) are presented.
	maxLimiterKeys = 100_000
	// sweepInterval is how often expired keys are collected.
	sweepInterval = time.Minute
)

type entry struct {
	hits   []time.Time
	window time.Duration
}

// Limiter is a small in-memory sliding-window limiter (e.g. 1 SOS per 2
// minutes per user, login attempts per address). Keys whose hits have all aged
// out are evicted by a periodic sweep, and the key count is hard-capped, so
// memory stays bounded. It is not shared across API replicas and resets on
// restart.
type Limiter struct {
	mu        sync.Mutex
	hits      map[string]*entry
	lastSweep time.Time
	now       func() time.Time // injectable for tests
}

// NewLimiter builds an empty limiter.
func NewLimiter() *Limiter {
	return &Limiter{hits: map[string]*entry{}, now: time.Now, lastSweep: time.Now()}
}

// Len reports how many keys are currently tracked (for tests/metrics).
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.hits)
}

// prune drops hits older than the window and returns the survivors.
func (e *entry) prune(now time.Time) {
	cutoff := now.Add(-e.window)
	kept := e.hits[:0]
	for _, ts := range e.hits {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	e.hits = kept
}

// sweepLocked evicts expired keys and, if still over the cap, arbitrary keys
// (Go map order is random) until under it.
func (l *Limiter) sweepLocked(now time.Time) {
	l.lastSweep = now
	for k, e := range l.hits {
		e.prune(now)
		if len(e.hits) == 0 {
			delete(l.hits, k)
		}
	}
	for k := range l.hits {
		if len(l.hits) <= maxLimiterKeys*9/10 {
			break
		}
		delete(l.hits, k)
	}
}

func (l *Limiter) maybeSweepLocked(now time.Time) {
	if now.Sub(l.lastSweep) >= sweepInterval || len(l.hits) >= maxLimiterKeys {
		l.sweepLocked(now)
	}
}

// Allow records a hit when fewer than max events occurred in window.
func (l *Limiter) Allow(key string, max int, window time.Duration) bool {
	if l == nil || max <= 0 {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.maybeSweepLocked(now)
	e := l.hits[key]
	if e == nil {
		e = &entry{}
		l.hits[key] = e
	}
	e.window = window
	e.prune(now)
	if len(e.hits) >= max {
		return false
	}
	e.hits = append(e.hits, now)
	return true
}

// Exceeded reports whether key already has max or more events in window,
// without recording anything.
func (l *Limiter) Exceeded(key string, max int, window time.Duration) bool {
	if l == nil {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.hits[key]
	if e == nil {
		return false
	}
	e.window = window
	e.prune(l.now())
	return len(e.hits) >= max
}

// Record unconditionally adds an event for key (used to count only failures).
func (l *Limiter) Record(key string, window time.Duration) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.maybeSweepLocked(now)
	e := l.hits[key]
	if e == nil {
		e = &entry{}
		l.hits[key] = e
	}
	e.window = window
	e.prune(now)
	e.hits = append(e.hits, now)
}

// Reset forgets key (e.g. after a successful login).
func (l *Limiter) Reset(key string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	delete(l.hits, key)
	l.mu.Unlock()
}
