package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Temporary sharing: a pause of all location sharing, and live shares with one
// chosen person. Both expire server-side and expiry is enforced on read. The
// pause is honoured by every sharing decision in internal/circles (members
// snapshot, WS broadcast, presence, watch/live boost, trips); SOS is separate
// and always shares. See docs/checkin-sharing.md.
const (
	minSharingPause = time.Minute
	maxSharingPause = 30 * 24 * time.Hour
	maxLiveShare    = 24 * time.Hour
)

type pauseJSON struct {
	Paused      bool       `json:"paused"`
	PausedUntil *time.Time `json:"paused_until,omitempty"`
}

func (s *Server) currentPause(r *http.Request, userID string) (pauseJSON, error) {
	var until time.Time
	err := s.Pool.QueryRow(r.Context(),
		`SELECT paused_until FROM sharing_pauses WHERE user_id = $1 AND paused_until > now()`, userID).Scan(&until)
	if err == pgx.ErrNoRows {
		return pauseJSON{}, nil
	}
	if err != nil {
		return pauseJSON{}, err
	}
	return pauseJSON{Paused: true, PausedUntil: &until}, nil
}

// GetSharingPause reports whether the caller's sharing is currently paused.
func (s *Server) GetSharingPause(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	p, err := s.currentPause(r, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load pause")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// SetSharingPause pauses the caller's location sharing for a duration:
// {"minutes": n} or {"until": RFC3339} (1 minute to 30 days from now).
func (s *Server) SetSharingPause(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		Minutes *int       `json:"minutes"`
		Until   *time.Time `json:"until"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil || (req.Minutes == nil) == (req.Until == nil) {
		writeError(w, http.StatusBadRequest, "send exactly one of minutes or until")
		return
	}
	now := time.Now().UTC()
	var until time.Time
	if req.Minutes != nil {
		if *req.Minutes < 0 || *req.Minutes > int(maxSharingPause/time.Minute) {
			writeError(w, http.StatusBadRequest, "duration out of range")
			return
		}
		until = now.Add(time.Duration(*req.Minutes) * time.Minute)
	} else {
		until = req.Until.UTC()
	}
	if d := until.Sub(now); d < minSharingPause || d > maxSharingPause {
		writeError(w, http.StatusBadRequest, "pause must last between 1 minute and 30 days")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		INSERT INTO sharing_pauses (user_id, paused_until) VALUES ($1, $2)
		ON CONFLICT (user_id) DO UPDATE SET paused_until = EXCLUDED.paused_until, created_at = now()`,
		claims.UserID, until); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to pause sharing")
		return
	}
	s.auditSharing(r, claims.UserID, "sharing.pause", "paused until "+until.Format(time.RFC3339))
	s.notifySharingChange(claims.UserID, &until)
	writeJSON(w, http.StatusOK, pauseJSON{Paused: true, PausedUntil: &until})
}

// ClearSharingPause resumes sharing immediately.
func (s *Server) ClearSharingPause(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `DELETE FROM sharing_pauses WHERE user_id = $1`, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to resume sharing")
		return
	}
	s.auditSharing(r, claims.UserID, "sharing.resume", "resumed sharing")
	s.notifySharingChange(claims.UserID, nil)
	writeJSON(w, http.StatusOK, pauseJSON{})
}

func (s *Server) auditSharing(r *http.Request, userID, action, detail string) {
	if familyID, err := s.familyIDForUser(r.Context(), userID); err == nil {
		s.logAudit(r.Context(), userID, familyID, action, detail, clientIP(r))
	}
}

// notifySharingChange sends the same `sharing` frame SetCircleSharing does for
// each of the user's circles so open maps drop (or restore) the pin at once.
// Expiry of a pause sends no frame; clients re-fetch the snapshot.
func (s *Server) notifySharingChange(userID string, pausedUntil *time.Time) {
	if s.hub == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	own, sharing, err := circles.New(s.Pool).OwnAndSharingCircles(ctx, userID)
	if err != nil {
		return
	}
	on := map[string]bool{}
	for _, id := range sharing {
		on[id] = true
	}
	for _, id := range own {
		m := map[string]any{"type": "sharing", "circle_id": id, "user_id": userID, "enabled": on[id], "paused": pausedUntil != nil}
		if pausedUntil != nil {
			m["paused_until"] = pausedUntil
		}
		if b, err := json.Marshal(m); err == nil {
			s.hub.notifyCircleAware(id, b)
		}
	}
}

// ---- live shares -----------------------------------------------------------

type liveShareJSON struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"` // the other party
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`

	// Incoming shares only: the sharer's last known position. Omitted while
	// the sharer has sharing paused or has not reported yet.
	Paused     bool       `json:"paused,omitempty"`
	Lat        *float64   `json:"lat,omitempty"`
	Lon        *float64   `json:"lon,omitempty"`
	RecordedAt *time.Time `json:"recorded_at,omitempty"`
}

// CreateLiveShare shares the caller's live location with one circle member
// until now+minutes (1 minute to 24 hours). Re-sharing with the same person
// replaces the previous expiry.
func (s *Server) CreateLiveShare(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		ViewerID string `json:"viewer_id"`
		Minutes  int    `json:"minutes"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	viewer := strings.ToLower(strings.TrimSpace(req.ViewerID))
	if viewer == "" || viewer == strings.ToLower(claims.UserID) {
		writeError(w, http.StatusBadRequest, "viewer_id is required")
		return
	}
	if d := time.Duration(req.Minutes) * time.Minute; d < minSharingPause || d > maxLiveShare {
		writeError(w, http.StatusBadRequest, "minutes must be between 1 and 1440")
		return
	}
	ok, err := circles.New(s.Pool).CoMembers(r.Context(), claims.UserID, []string{viewer})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize share")
		return
	}
	if !ok[viewer] {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}
	out := liveShareJSON{UserID: viewer}
	if err := s.Pool.QueryRow(r.Context(), `
		WITH ins AS (
			INSERT INTO live_shares (owner_id, viewer_id, expires_at)
			VALUES ($1, $2, now() + make_interval(mins => $3::int))
			ON CONFLICT (owner_id, viewer_id) DO UPDATE
			   SET expires_at = EXCLUDED.expires_at, created_at = now()
			RETURNING id, created_at, expires_at)
		SELECT ins.id, ins.created_at, ins.expires_at, u.name FROM ins, users u WHERE u.id = $2`,
		claims.UserID, viewer, req.Minutes,
	).Scan(&out.ID, &out.CreatedAt, &out.ExpiresAt, &out.Name); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create share")
		return
	}
	s.auditSharing(r, claims.UserID, "liveshare.create", "live share "+out.ID+" until "+out.ExpiresAt.Format(time.RFC3339))
	go s.purgeExpiredSharing()
	writeJSON(w, http.StatusCreated, out)
}

// ListLiveShares returns the caller's unexpired outgoing shares and the
// unexpired shares others made with the caller (with the sharer's last known
// position, withheld while that sharer is paused).
func (s *Server) ListLiveShares(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	outgoing := []liveShareJSON{}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT ls.id, ls.viewer_id, u.name, ls.created_at, ls.expires_at
		FROM live_shares ls JOIN users u ON u.id = ls.viewer_id
		WHERE ls.owner_id = $1 AND ls.expires_at > now()
		ORDER BY ls.expires_at, ls.id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load shares")
		return
	}
	for rows.Next() {
		var l liveShareJSON
		if err := rows.Scan(&l.ID, &l.UserID, &l.Name, &l.CreatedAt, &l.ExpiresAt); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load shares")
			return
		}
		outgoing = append(outgoing, l)
	}
	rows.Close()

	incoming := []liveShareJSON{}
	// Membership is re-checked on every read: leaving the circle ends the share.
	rows, err = s.Pool.Query(r.Context(), `
		SELECT ls.id, ls.owner_id, u.name, ls.created_at, ls.expires_at,
		       `+pausedExprSQL("ls.owner_id")+`, mp.lat, mp.lon, mp.ts
		FROM live_shares ls
		JOIN users u ON u.id = ls.owner_id
		LEFT JOIN member_positions mp ON mp.user_id = ls.owner_id
		WHERE ls.viewer_id = $1 AND ls.expires_at > now()
		  AND EXISTS (SELECT 1 FROM live_circle_members a JOIN live_circle_members b ON b.circle_id = a.circle_id
		              WHERE a.user_id = ls.viewer_id AND b.user_id = ls.owner_id)
		ORDER BY ls.expires_at, ls.id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load shares")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var l liveShareJSON
		var lat, lon *float64
		var ts *time.Time
		if err := rows.Scan(&l.ID, &l.UserID, &l.Name, &l.CreatedAt, &l.ExpiresAt, &l.Paused, &lat, &lon, &ts); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load shares")
			return
		}
		if !l.Paused {
			l.Lat, l.Lon, l.RecordedAt = lat, lon, ts
		}
		incoming = append(incoming, l)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load shares")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"outgoing": outgoing, "incoming": incoming})
}

func pausedExprSQL(userCol string) string {
	return "EXISTS (SELECT 1 FROM sharing_pauses sp WHERE sp.user_id = " + userCol + " AND sp.paused_until > now())"
}

// DeleteLiveShare ends a share early. Either party may end it; anyone else
// gets a uniform 404.
func (s *Server) DeleteLiveShare(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "share not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `
		DELETE FROM live_shares WHERE id = $1 AND (owner_id = $2 OR viewer_id = $2)`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to end share")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "share not found")
		return
	}
	s.auditSharing(r, claims.UserID, "liveshare.end", "ended live share "+id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
