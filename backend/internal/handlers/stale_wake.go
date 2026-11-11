package handlers

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// Server-driven wake-up of a phone that stopped reporting.
//
// A phone whose tracking service Android ended stays silent until somebody opens the app. The server already
// notices (a family snapshot asks quiet members for one fix, see MaybeRequestStaleLocations) but only while a
// viewer happens to open the map. This worker does the same for sharing members' phones on a timer, so a phone that
// went quiet gets the existing "location request" push without anybody watching. The command is the same one a
// viewer's "refresh" sends; the app answers it with one fix, and its handler also asks the Android side to restart
// the tracking service if that is wanted and gone.
//
// Cost and safety rules, all of them on purpose:
//   - Android devices only. A suspended iPhone is normal and Apple throttles silent pushes.
//   - Only the user's NEWEST device of that platform (an old phone left in a drawer is never woken while a newer
//     one exists), and only that one device, never the user's other devices.
//   - Only a member who is sharing in at least one live circle and is not in a paused-sharing window.
//   - A device is asked at most once per staleWakeCooldown (15 minutes), claimed with one UPDATE so two server
//     processes or a restart cannot double it, and recorded on the device row (last_stale_wake_at,
//     stale_wake_count).
//   - After staleWakeMaxUnanswered asks in a row with no report in between, it stops until the device reports again
//     (a phone that is off, signed out or force-stopped cannot answer, and pushing it forever helps nobody).
//   - Nothing for a device quiet longer than staleWakeGiveUp.
//   - If many devices look quiet at once it is treated as a server or network outage and nothing is sent.
//   - At most staleWakeMaxPerTick asks per run.
const (
	staleWakeTick           = 5 * time.Minute
	staleWakeAfter          = 15 * time.Minute
	staleWakeCooldown       = 15 * time.Minute
	staleWakeGiveUp         = 24 * time.Hour
	staleWakeMaxUnanswered  = 8
	staleWakeMaxPerTick     = 50
	staleWakeOutageMin      = 5
	staleWakeParallel       = 8
	staleWakeDispatchBudget = 15 * time.Second
)

// staleWakeOutage reports whether so many of the active Android devices look quiet at once that the cause is
// probably the server or the network, not the phones. Nothing is sent then.
func staleWakeOutage(candidates, active int) bool {
	return candidates >= staleWakeOutageMin && candidates*2 >= active
}

type staleWakeDevice struct {
	id, userID, transport, endpoint string
}

// RunStaleWake blocks until ctx is cancelled.
func (s *Server) RunStaleWake(ctx context.Context) {
	t := time.NewTicker(staleWakeTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := s.RunStaleWakeOnce(ctx, time.Now().UTC())
			if err != nil {
				slog.Warn("stale wake", "err", err)
			} else if n > 0 {
				slog.Info("stale wake: asked quiet phones to report", "count", n)
			}
		}
	}
}

// staleWakeCandidates lists the devices to ask now, and how many Android devices are active at all (for the outage
// rule). now is passed in so tests use a fixed clock.
func (s *Server) staleWakeCandidates(ctx context.Context, now time.Time) ([]staleWakeDevice, int, error) {
	var active int
	if err := s.Pool.QueryRow(ctx, `
		SELECT count(*) FROM devices d
		WHERE d.platform = 'android' AND (d.hidden_at IS NULL OR d.last_seen > d.hidden_at)
		  AND d.last_seen > $1 AND (d.push_transport = 'direct' OR COALESCE(d.unifiedpush_endpoint, '') <> '')`,
		now.Add(-staleWakeGiveUp)).Scan(&active); err != nil {
		return nil, 0, err
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT d.id::text, d.user_id::text, d.push_transport, COALESCE(d.unifiedpush_endpoint, '')
		FROM devices d
		WHERE d.platform = 'android'
		  AND (d.hidden_at IS NULL OR d.last_seen > d.hidden_at)
		  AND d.last_seen < $1 AND d.last_seen > $2
		  AND (d.push_transport = 'direct' OR COALESCE(d.unifiedpush_endpoint, '') <> '')
		  AND (d.last_stale_wake_at IS NULL OR d.last_stale_wake_at < $3)
		  AND (d.last_stale_wake_at IS NULL OR d.last_seen > d.last_stale_wake_at OR d.stale_wake_count < $4)
		  AND d.id = (SELECT n.id FROM devices n
		              WHERE n.user_id = d.user_id AND n.platform = 'android'
		                AND (n.hidden_at IS NULL OR n.last_seen > n.hidden_at)
		              ORDER BY n.last_seen DESC NULLS LAST, n.created_at DESC LIMIT 1)
		  AND EXISTS (SELECT 1 FROM live_circle_members m WHERE m.user_id = d.user_id AND m.sharing_enabled)
		  AND NOT `+pausedExprSQL("d.user_id")+`
		ORDER BY d.last_seen DESC
		LIMIT $5`,
		now.Add(-staleWakeAfter), now.Add(-staleWakeGiveUp), now.Add(-staleWakeCooldown),
		staleWakeMaxUnanswered, staleWakeMaxPerTick)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []staleWakeDevice
	for rows.Next() {
		var d staleWakeDevice
		if err := rows.Scan(&d.id, &d.userID, &d.transport, &d.endpoint); err != nil {
			return nil, 0, err
		}
		out = append(out, d)
	}
	return out, active, rows.Err()
}

// claimStaleWake records the ask and reports whether this caller won it (false: another run asked within the
// cooldown, or the device reached the unanswered limit in the meantime).
func (s *Server) claimStaleWake(ctx context.Context, deviceID string, now time.Time) bool {
	tag, err := s.Pool.Exec(ctx, `
		UPDATE devices SET
		  stale_wake_count = CASE WHEN last_stale_wake_at IS NULL OR last_seen > last_stale_wake_at THEN 1 ELSE stale_wake_count + 1 END,
		  last_stale_wake_at = $2
		WHERE id = $1
		  AND (last_stale_wake_at IS NULL OR last_stale_wake_at < $3)
		  AND (last_stale_wake_at IS NULL OR last_seen > last_stale_wake_at OR stale_wake_count < $4)`,
		deviceID, now, now.Add(-staleWakeCooldown), staleWakeMaxUnanswered)
	return err == nil && tag.RowsAffected() == 1
}

// RunStaleWakeOnce asks every eligible quiet device to report and returns how many asks were sent. Safe to call
// repeatedly and concurrently.
func (s *Server) RunStaleWakeOnce(ctx context.Context, now time.Time) (int, error) {
	if s.Push == nil || s.Pool == nil {
		return 0, nil
	}
	cands, active, err := s.staleWakeCandidates(ctx, now)
	if err != nil {
		return 0, err
	}
	if len(cands) == 0 {
		return 0, nil
	}
	if staleWakeOutage(len(cands), active) {
		slog.Warn("stale wake: many phones quiet at once, treating as an outage", "quiet", len(cands), "active", active)
		return 0, nil
	}
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		sent int
		sem  = make(chan struct{}, staleWakeParallel)
	)
	for _, d := range cands {
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(d staleWakeDevice) {
			defer wg.Done()
			defer func() { <-sem }()
			if !s.claimStaleWake(ctx, d.id, now) {
				return
			}
			requestID, err := newLocationRequestID()
			if err != nil {
				return
			}
			body, _, err := encodeLocationRequestCommand(requestID, time.Now().UTC())
			if err != nil {
				return
			}
			dctx, cancel := context.WithTimeout(ctx, staleWakeDispatchBudget)
			defer cancel()
			ok := s.dispatchStaleWake(dctx, body, d)
			slog.Info("stale wake", "device_id", d.id, "user_id", d.userID, "delivered", ok)
			if ok {
				mu.Lock()
				sent++
				mu.Unlock()
			}
		}(d)
	}
	wg.Wait()
	return sent, nil
}

// dispatchStaleWake sends the location-request command to ONE device: its built-in direct stream (queued, short
// lifetime) and its UnifiedPush endpoint when it has them. Returns true when a transport accepted it. Tests replace
// it through staleWakeSend.
func (s *Server) dispatchStaleWake(ctx context.Context, body []byte, d staleWakeDevice) bool {
	if s.staleWakeSend != nil {
		return s.staleWakeSend(ctx, body, d)
	}
	ok := false
	if d.transport == "direct" && s.Direct != nil {
		if err := s.Push.Dispatch(ctx, directNotification(push.Notification{
			Title: "Orbitly location refresh", Body: string(body), Silent: true, Platform: "android",
		}, d.id, d.userID, "", "")); err == nil {
			ok = true
		}
	}
	if d.endpoint != "" {
		if err := s.Push.Dispatch(ctx, push.Notification{
			Title:               "Orbitly location refresh",
			Body:                string(body),
			Platform:            "android",
			UnifiedPushEndpoint: d.endpoint,
		}); err == nil {
			ok = true
		}
	}
	return ok
}
