// Package errlog keeps the most recent warning/error log records in memory so
// the admin system-health page can show them without log access. It wraps a
// slog.Handler and forwards everything unchanged.
package errlog

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Entry is one retained log record. Attribute values are deliberately not
// kept: they can carry identifiers or request data; the message alone is what
// the health page needs.
type Entry struct {
	Time    time.Time `json:"time"`
	Level   string    `json:"level"`
	Message string    `json:"message"`
}

const maxMessage = 300

// Ring is a fixed-size, concurrency-safe buffer of the newest entries.
type Ring struct {
	mu   sync.Mutex
	size int
	buf  []Entry
}

// NewRing returns a ring that keeps the newest size entries.
func NewRing(size int) *Ring {
	if size < 1 {
		size = 1
	}
	return &Ring{size: size}
}

// Add appends an entry, dropping the oldest when full.
func (r *Ring) Add(e Entry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.buf) >= r.size {
		copy(r.buf, r.buf[1:])
		r.buf = r.buf[:len(r.buf)-1]
	}
	r.buf = append(r.buf, e)
}

// Recent returns up to n entries, newest first.
func (r *Ring) Recent(n int) []Entry {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Entry, 0, n)
	for i := len(r.buf) - 1; i >= 0 && len(out) < n; i-- {
		out = append(out, r.buf[i])
	}
	return out
}

// Default is the process-wide ring fed by Wrap.
var Default = NewRing(100)

type handler struct {
	slog.Handler
	ring *Ring
}

// Wrap returns a handler that records Warn and above into ring (Default when
// nil) and then delegates to next.
func Wrap(next slog.Handler, ring *Ring) slog.Handler {
	if ring == nil {
		ring = Default
	}
	return &handler{Handler: next, ring: ring}
}

func (h *handler) Handle(ctx context.Context, rec slog.Record) error {
	if rec.Level >= slog.LevelWarn {
		msg := rec.Message
		if len(msg) > maxMessage {
			msg = msg[:maxMessage]
		}
		h.ring.Add(Entry{Time: rec.Time, Level: rec.Level.String(), Message: msg})
	}
	return h.Handler.Handle(ctx, rec)
}

func (h *handler) WithAttrs(a []slog.Attr) slog.Handler {
	return &handler{Handler: h.Handler.WithAttrs(a), ring: h.ring}
}

func (h *handler) WithGroup(name string) slog.Handler {
	return &handler{Handler: h.Handler.WithGroup(name), ring: h.ring}
}
