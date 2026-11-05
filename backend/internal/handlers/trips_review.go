package handlers

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/trips"
)

// Review of detected events by the person they are about: "I was a
// passenger" for a whole drive and "false alarm" for one phone-use event.
// Only the owner may do either (anyone else gets 404, like every other
// trip lookup). Both remove the events from every report, score and weekly
// summary because those read trip_events_effective.

// tripEventsView returns the events the caller may see for trip, and whether
// the owner marked the drive as a passenger drive. The owner also gets their
// dismissed phone-use events (flagged) so a mistaken dismissal can be undone.
func (s *Server) tripEventsView(ctx context.Context, st *trips.Store, viewerID string, trip trips.Row) ([]trips.EventRow, bool) {
	passenger, _ := st.IsPassenger(ctx, trip.UserID, trip.StartedAt)
	owner := viewerID == trip.UserID && !passenger
	ev, err := st.EventsFor(ctx, trip.ID, owner)
	if err != nil {
		return []trips.EventRow{}, passenger
	}
	return ev, passenger
}

// SetTripPassenger marks or unmarks a drive as "I was a passenger".
// PUT /trips/{id}/passenger {"passenger": true|false}
func (s *Server) SetTripPassenger(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Passenger *bool `json:"passenger"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Passenger == nil {
		writeError(w, http.StatusBadRequest, "passenger (true or false) is required")
		return
	}
	trip, err := s.tripStore().Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil || trip.UserID != claims.UserID {
		// Missing, malformed, someone else's: all the same answer.
		writeError(w, http.StatusNotFound, "trip not found")
		return
	}
	if *req.Passenger {
		_, err = s.Pool.Exec(r.Context(), `INSERT INTO trip_passenger_marks (user_id, started_at) VALUES ($1::uuid, $2)
			ON CONFLICT (user_id, started_at) DO NOTHING`, claims.UserID, trip.StartedAt)
	} else {
		_, err = s.Pool.Exec(r.Context(), `DELETE FROM trip_passenger_marks WHERE user_id = $1::uuid AND started_at = $2`,
			claims.UserID, trip.StartedAt)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "driving.passenger", "trip passenger mark changed", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"trip_id": trip.ID, "passenger": *req.Passenger})
}

// SetEventDismissed marks one phone-use event as a false alarm (or restores
// it). PATCH /trips/events/{eventId} {"dismissed": true|false}
func (s *Server) SetEventDismissed(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Dismissed *bool `json:"dismissed"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Dismissed == nil {
		writeError(w, http.StatusBadRequest, "dismissed (true or false) is required")
		return
	}
	// Ownership and kind are part of the WHERE: another user's event, a GPS
	// event (recomputed from the track, so a mark would not stick) and a
	// malformed id all match nothing.
	tag, err := s.Pool.Exec(r.Context(), `
		UPDATE trip_events SET dismissed_at = CASE WHEN $3::boolean THEN COALESCE(dismissed_at, now()) ELSE NULL END
		WHERE id::text = $1 AND user_id = $2::uuid AND source = 'sensor' AND kind = 'phone_use'`,
		chi.URLParam(r, "eventId"), claims.UserID, *req.Dismissed)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "event not found")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "driving.event_dismiss", "phone use event review changed", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"dismissed": *req.Dismissed})
}
