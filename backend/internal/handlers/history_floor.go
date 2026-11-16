package handlers

import (
	"context"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
)

// A person who joins a circle reads other members' location history, trips and
// driving events only from their own join time onward. Without this, joining a
// circle (or being invited to one) would open up to the full retention window
// (90 days) of everyone's past movements. The floor is per circle: when two
// people share several circles, the earliest join time among the circles that
// actually let the viewer see the member applies. A user's own data is never
// limited.

// historyFloorSQL is the earliest join time of the viewer among the given
// circles (the viewer's membership rows).
const historyFloorSQL = `
	SELECT min(joined_at) FROM live_circle_members
	WHERE user_id = $1 AND circle_id = ANY($2::uuid[])`

// historyFloorIn returns the viewer's history floor over circleIDs. The zero
// time means "no floor" (no circle given: callers that reach here have already
// passed the sharing check).
func (s *Server) historyFloorIn(ctx context.Context, viewerID string, circleIDs []string) (time.Time, error) {
	if len(circleIDs) == 0 {
		return time.Time{}, nil
	}
	var floor *time.Time
	if err := s.Pool.QueryRow(ctx, historyFloorSQL, viewerID, circleIDs).Scan(&floor); err != nil {
		return time.Time{}, err
	}
	if floor == nil {
		return time.Time{}, nil
	}
	return *floor, nil
}

// historyFloorFor returns the floor for viewerID reading subjectID. It is the
// zero time for the viewer's own data.
func (s *Server) historyFloorFor(ctx context.Context, viewerID, subjectID string) (time.Time, error) {
	if viewerID == subjectID {
		return time.Time{}, nil
	}
	shared, err := circles.New(s.Pool).SharedWith(ctx, viewerID, subjectID)
	if err != nil {
		return time.Time{}, err
	}
	return s.historyFloorIn(ctx, viewerID, shared)
}

// clampFrom raises from to floor when the floor is later.
func clampFrom(from, floor time.Time) time.Time {
	if !floor.IsZero() && from.Before(floor) {
		return floor
	}
	return from
}

// tripVisibleSinceJoin reports whether a trip of subject that started at
// startedAt may be read by viewer (own trips always; others only when the trip
// started at or after the viewer joined the circle that lets them see it). A
// lookup failure hides the trip.
func (s *Server) tripVisibleSinceJoin(ctx context.Context, viewerID, subjectID string, startedAt time.Time) bool {
	if viewerID == subjectID {
		return true
	}
	floor, err := s.historyFloorFor(ctx, viewerID, subjectID)
	if err != nil {
		return false
	}
	return floor.IsZero() || !startedAt.Before(floor)
}
