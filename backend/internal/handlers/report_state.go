package handlers

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
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

// liveTouch remembers when devices.last_seen was last written per
// (user, owned device). Keys are only ever stored after the device was proven
// to belong to the user, and the map is reset at liveTouchLimit like
// versionRecorder, so client input cannot grow it without bound.
type liveTouchMap struct {
	mu sync.Mutex
	m  map[string]time.Time
}

const (
	liveTouchEvery = 10 * time.Minute
	liveTouchLimit = 50000
)

var liveTouch = &liveTouchMap{m: map[string]time.Time{}}

func (l *liveTouchMap) recent(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	t, ok := l.m[key]
	return ok && now.Sub(t) < liveTouchEvery
}

func (l *liveTouchMap) set(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.m) >= liveTouchLimit {
		l.m = map[string]time.Time{}
	}
	l.m[key] = now
}

// touchPrivateLiveness bumps devices.last_seen for the phone that just made a
// genuine, accepted end-to-end encrypted upload. Private circles upload under
// their own E2EE device ids, so without this the Fleet page and the "phone
// went silent" alert would see a working phone as quiet.
//
// Fail closed: it needs a valid X-Device-Id naming a device that belongs to the
// caller, and a platform header. There is no "most recent device" fallback, and
// polls/lists never call this, so a client that only reads cannot keep a dead
// phone looking alive. At most one write per device per 10 minutes; no
// coordinate or ciphertext is read or written.
func (s *Server) touchPrivateLiveness(r *http.Request, userID string) {
	if s == nil || s.Pool == nil || userID == "" {
		return
	}
	dev := middleware.DeviceIDHeader(r)
	if dev == "" || middleware.AppInfoFromContext(r.Context()).Platform == "" {
		return
	}
	key := userID + "|" + dev
	now := time.Now()
	if liveTouch.recent(key, now) {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	tag, err := s.Pool.Exec(ctx, `UPDATE devices SET last_seen = now() WHERE id = $1::uuid AND user_id = $2::uuid`, dev, userID)
	if err != nil {
		slog.Debug("private liveness", "err", err)
		return
	}
	if tag.RowsAffected() == 1 {
		liveTouch.set(key, now)
	}
}
