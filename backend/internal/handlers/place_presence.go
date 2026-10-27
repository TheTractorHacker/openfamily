package handlers

import (
	"context"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

// placePresence derives, per user, where they are relative to saved places
// from the geofence_events log (no extra state is stored). For each geofence
// the latest event decides inside/outside. A user inside at least one place is
// "at" the most recently entered one; otherwise their most recent exit gives
// "left". Users with no events, or whose place was deleted, are omitted.
func (s *Server) placePresence(ctx context.Context, userIDs []string) (map[string]*models.PlacePresence, error) {
	out := map[string]*models.PlacePresence{}
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT ON (user_id) user_id, place_id, name, state, ts FROM (
			SELECT l.user_id, l.place_id, p.name, l.ts,
			       CASE l.event_type WHEN 'enter' THEN 'at' ELSE 'left' END AS state
			FROM (
				SELECT DISTINCT ON (user_id, geofence_id)
				       user_id, geofence_id, place_id, event_type, ts
				FROM geofence_events
				WHERE user_id = ANY($1::uuid[]) AND place_id IS NOT NULL
				ORDER BY user_id, geofence_id, ts DESC
			) l
			JOIN places p ON p.id = l.place_id
		) x
		ORDER BY user_id, (state = 'at') DESC, ts DESC`, userIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			uid, placeID, name, state string
			ts                        time.Time
		)
		if err := rows.Scan(&uid, &placeID, &name, &state, &ts); err != nil {
			return nil, err
		}
		out[uid] = &models.PlacePresence{PlaceID: placeID, PlaceName: name, State: state, Since: ts}
	}
	return out, rows.Err()
}
