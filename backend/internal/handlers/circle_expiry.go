package handlers

import (
	"context"
	"log/slog"
	"time"
)

// Temporary circles stop being served the instant expires_at passes (every
// read goes through live_circle_members / circleLiveSQL, so correctness needs
// no job). This loop only tidies up: it drops hub subscriptions of lapsed
// circles and deletes circles once their grace period is over.

// RunCirclePurge blocks until ctx is cancelled, purging on a timer.
func (s *Server) RunCirclePurge(ctx context.Context) {
	t := time.NewTicker(circlePurgeInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if _, err := s.PurgeTemporaryCircles(ctx); err != nil {
				slog.Warn("circle purge", "err", err)
			}
		}
	}
}

// PurgeTemporaryCircles unsubscribes lapsed circles from the websocket hub and
// deletes those past the grace period (members, invites, chat and check-in
// rows cascade). It returns how many circles were deleted. Circles that are
// primary for some user are never deleted here (temporary circles are never
// family-backed, so this is only a guard).
func (s *Server) PurgeTemporaryCircles(ctx context.Context) (int, error) {
	if s.hub != nil {
		rows, err := s.Pool.Query(ctx, `
			SELECT id::text FROM circles c
			WHERE c.expires_at IS NOT NULL AND NOT `+circleLiveSQL)
		if err != nil {
			return 0, err
		}
		var ids []string
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err == nil {
				ids = append(ids, id)
			}
		}
		rows.Close()
		for _, id := range ids {
			s.hub.unsubscribeCircle(id)
		}
	}
	grace := int64(tempCircleGrace / time.Second)
	tag, err := s.Pool.Exec(ctx, `
		DELETE FROM circles c
		WHERE c.expires_at IS NOT NULL
		  AND COALESCE(c.ended_at, c.expires_at) + make_interval(secs => $1) < now()
		  AND NOT EXISTS (SELECT 1 FROM families f WHERE f.id = c.id)`, grace)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// resubscribeCircle re-adds every member's live sockets to circleID.
func (s *Server) resubscribeCircle(ctx context.Context, circleID string) {
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1`, circleID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		if rows.Scan(&uid) == nil {
			s.hub.subscribeUser(uid, circleID)
		}
	}
}
