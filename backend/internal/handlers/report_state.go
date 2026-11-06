package handlers

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Server-side liveness bookkeeping. Everything stored here is metadata the
// server already sees (that a phone talked to it, and when). It never holds a
// coordinate, which is what lets Private circles use it too.

const reportWriteEvery = time.Minute

// reportTracker throttles liveness writes: at most one row update per user per
// minute and one hour-bucket insert per user per UTC hour. The zero value works.
type reportTracker struct {
	mu   sync.Mutex
	last map[string]time.Time
	hour map[string]time.Time
}

// due reports whether a write should happen for user at now and records it.
func (t *reportTracker) due(user string, now time.Time) (row, hour bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.last == nil {
		t.last, t.hour = map[string]time.Time{}, map[string]time.Time{}
	}
	if l, ok := t.last[user]; !ok || now.Sub(l) >= reportWriteEvery {
		t.last[user] = now
		row = true
	}
	h := now.UTC().Truncate(time.Hour)
	if l, ok := t.hour[user]; !ok || !l.Equal(h) {
		t.hour[user] = h
		hour = true
	}
	return row, hour
}

// noteReport records that userID's phone talked to the server (a location,
// batch, heartbeat or encrypted-item upload). Best effort; never fails a request.
func (s *Server) noteReport(ctx context.Context, userID string, now time.Time) {
	if s == nil || s.Pool == nil || userID == "" {
		return
	}
	row, hour := s.reports.due(userID, now)
	if !row && !hour {
		return
	}
	ctx = context.WithoutCancel(ctx)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if row {
		if _, err := s.Pool.Exec(ctx, `
			INSERT INTO member_report_state (user_id, last_report_at) VALUES ($1, $2)
			ON CONFLICT (user_id) DO UPDATE SET last_report_at = GREATEST(member_report_state.last_report_at, EXCLUDED.last_report_at)`,
			userID, now); err != nil {
			slog.Debug("report state", "err", err)
		}
	}
	if hour {
		if _, err := s.Pool.Exec(ctx, `
			INSERT INTO member_report_hours (user_id, hour) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			userID, now.UTC().Truncate(time.Hour)); err != nil {
			slog.Debug("report hours", "err", err)
		}
	}
}

// noteWS records a successful live-stream (WebSocket) connect.
func (s *Server) noteWS(ctx context.Context, userID string) {
	if s == nil || s.Pool == nil || userID == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	// last_report_at is NOT NULL, but a socket alone is not a report: seed with
	// the epoch so a first-time row never reads as recent.
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO member_report_state (user_id, last_report_at, last_ws_at) VALUES ($1, 'epoch', now())
		ON CONFLICT (user_id) DO UPDATE SET last_ws_at = now()`, userID); err != nil {
		slog.Debug("ws state", "err", err)
	}
}

// notePushResult records whether a push to one device was accepted by its
// provider (ok) or failed.
func (s *Server) notePushResult(ctx context.Context, deviceID string, ok bool) {
	if s == nil || s.Pool == nil || deviceID == "" {
		return
	}
	col := "last_push_fail_at"
	if ok {
		col = "last_push_ok_at"
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if _, err := s.Pool.Exec(ctx, `UPDATE devices SET `+col+` = now() WHERE id = $1`, deviceID); err != nil {
		slog.Debug("push result", "err", err)
	}
}
