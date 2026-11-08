package handlers

import (
	"context"
	"log/slog"
	"time"
)

// Fleet health lists every device row a member ever signed in with. After a reinstall or a new
// phone the old rows stayed there for ever. This tidy-up hides (never deletes) a row that was not
// seen for a day once the same person has a NEWER row on the same platform that was active within
// the last day. A hidden row that reports again shows up again (the same rule as the manual
// "hide stale" action); history and push registrations are untouched.

const deviceTidyInterval = time.Hour

// RunDeviceTidy blocks until ctx is cancelled, tidying on a timer (and once shortly after start).
func (s *Server) RunDeviceTidy(ctx context.Context) {
	t := time.NewTimer(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := s.HideSupersededDevices(ctx); err != nil {
				slog.Warn("device tidy", "err", err)
			} else if n > 0 {
				slog.Info("device tidy: hid old sign-ins replaced by a newer device", "count", n)
			}
			t.Reset(deviceTidyInterval)
		}
	}
}

// HideSupersededDevices hides device rows older than a day that a newer, recently active row of the
// same user and platform has replaced. It returns how many rows were hidden.
func (s *Server) HideSupersededDevices(ctx context.Context) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `
		UPDATE devices d SET hidden_at = now()
		WHERE (d.hidden_at IS NULL OR d.last_seen > d.hidden_at)
		  AND COALESCE(d.last_seen, d.created_at) < now() - interval '1 day'
		  AND EXISTS (
		    SELECT 1 FROM devices n
		    WHERE n.user_id = d.user_id AND n.platform = d.platform AND n.id <> d.id
		      AND COALESCE(n.last_seen, n.created_at) > COALESCE(d.last_seen, d.created_at)
		      AND COALESCE(n.last_seen, n.created_at) > now() - interval '1 day')`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
