package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Bubbles: a temporary, per-person geofence (docs/bubbles.md). The creator is
// alerted when the subject leaves a circle drawn around where the subject was
// when it was created, and optionally when they come back.
//
// Privacy rules:
//   - creator and subject must share a circle in which the subject currently
//     shares their location (circles.SharedWith: sharing on, not paused);
//   - the centre is the subject's last server-side position, never a client
//     supplied one, and it must be fresh;
//   - the subject is told a Bubble exists (push + the about_me list: who and
//     until when) but never receives coordinates, and the circle is returned
//     only to its creator;
//   - while the subject pauses sharing, or stops sharing with the creator,
//     the Bubble is not evaluated and produces no alert.
const (
	minBubbleRadius    = 50
	maxBubbleRadius    = 5000
	minBubbleDuration  = 15 * time.Minute
	maxBubbleDuration  = 24 * time.Hour
	maxActiveBubbles   = 10
	bubblePositionMax  = 30 * time.Minute // oldest subject position a Bubble may be centred on
	bubbleReenterRatio = 0.9              // hysteresis: re-enter only inside 90% of the radius
)

type bubbleJSON struct {
	ID            string    `json:"id"`
	SubjectID     string    `json:"subject_id"`
	SubjectName   string    `json:"subject_name"`
	Lat           float64   `json:"lat"`
	Lon           float64   `json:"lon"`
	RadiusM       int       `json:"radius_m"`
	NotifyReenter bool      `json:"notify_reenter"`
	Inside        bool      `json:"inside"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

// bubbleAboutMeJSON is what a subject sees: no coordinates, no radius.
type bubbleAboutMeJSON struct {
	ID          string    `json:"id"`
	CreatorID   string    `json:"creator_id"`
	CreatorName string    `json:"creator_name"`
	ExpiresAt   time.Time `json:"expires_at"`
}

// CreateBubble draws a Bubble around the subject's current position.
// {"subject_id", "radius_m", "duration_minutes", "notify_reenter"}.
func (s *Server) CreateBubble(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req struct {
		SubjectID       string `json:"subject_id"`
		RadiusM         int    `json:"radius_m"`
		DurationMinutes int    `json:"duration_minutes"`
		NotifyReenter   bool   `json:"notify_reenter"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	subject := strings.ToLower(strings.TrimSpace(req.SubjectID))
	if !circles.ValidID(subject) || subject == strings.ToLower(claims.UserID) {
		writeError(w, http.StatusBadRequest, "subject_id is required")
		return
	}
	if req.RadiusM < minBubbleRadius || req.RadiusM > maxBubbleRadius {
		writeError(w, http.StatusBadRequest, "radius_m must be between 50 and 5000")
		return
	}
	d := time.Duration(req.DurationMinutes) * time.Minute
	if d < minBubbleDuration || d > maxBubbleDuration {
		writeError(w, http.StatusBadRequest, "duration_minutes must be between 15 and 1440")
		return
	}
	ctx := r.Context()
	// Uniform 404 for non-members, and for members who are paused or not
	// sharing with the caller, so neither can be probed.
	shared, err := circles.New(s.Pool).SharedWith(ctx, claims.UserID, subject)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize bubble")
		return
	}
	if len(shared) == 0 {
		writeError(w, http.StatusNotFound, "member not found")
		return
	}

	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	defer tx.Rollback(ctx)
	// Serialise a creator's creates so the active cap cannot be raced past.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('bubbles:' || $1))`, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	var lat, lon float64
	var ts time.Time
	err = tx.QueryRow(ctx, `SELECT lat, lon, ts FROM member_positions WHERE user_id = $1`, subject).Scan(&lat, &lon, &ts)
	if err == pgx.ErrNoRows || (err == nil && time.Since(ts) > bubblePositionMax) {
		writeError(w, http.StatusConflict, "no recent location for this member")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	// One Bubble per (creator, subject): a new one replaces the old.
	if _, err := tx.Exec(ctx, `DELETE FROM bubbles WHERE creator_id = $1 AND subject_id = $2`, claims.UserID, subject); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	var active int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM bubbles WHERE creator_id = $1 AND expires_at > now()`, claims.UserID).Scan(&active); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	if active >= maxActiveBubbles {
		writeError(w, http.StatusTooManyRequests, "too many active bubbles")
		return
	}
	var b bubbleJSON
	var creatorName string
	err = tx.QueryRow(ctx, `
		WITH ins AS (
			INSERT INTO bubbles (circle_id, creator_id, subject_id, lat, lon, radius_m, notify_reenter, expires_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, now() + make_interval(mins => $8::int))
			RETURNING id, lat, lon, radius_m, notify_reenter, last_inside, created_at, expires_at)
		SELECT ins.id, ins.lat, ins.lon, ins.radius_m, ins.notify_reenter, ins.last_inside, ins.created_at, ins.expires_at,
		       su.name, cu.name
		FROM ins, users su, users cu WHERE su.id = $3 AND cu.id = $2`,
		shared[0], claims.UserID, subject, lat, lon, req.RadiusM, req.NotifyReenter, req.DurationMinutes,
	).Scan(&b.ID, &b.Lat, &b.Lon, &b.RadiusM, &b.NotifyReenter, &b.Inside, &b.CreatedAt, &b.ExpiresAt, &b.SubjectName, &creatorName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	b.SubjectID = subject
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create bubble")
		return
	}
	s.auditSharing(r, claims.UserID, "bubble.create", fmt.Sprintf("bubble %s subject %s until %s", b.ID, subject, b.ExpiresAt.Format(time.RFC3339)))
	go s.purgeExpiredSharing()
	go s.notifyBubbleSubject(subject, creatorName, b.ExpiresAt)
	writeJSON(w, http.StatusCreated, b)
}

// ListBubbles returns the caller's active Bubbles ("bubbles", with geometry)
// and the active Bubbles around the caller ("about_me", without geometry).
// Expired rows are never served.
func (s *Server) ListBubbles(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	out := []bubbleJSON{}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT b.id, b.subject_id, u.name, b.lat, b.lon, b.radius_m, b.notify_reenter, b.last_inside, b.created_at, b.expires_at
		FROM bubbles b JOIN users u ON u.id = b.subject_id
		WHERE b.creator_id = $1 AND b.expires_at > now()
		ORDER BY b.expires_at, b.id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load bubbles")
		return
	}
	for rows.Next() {
		var b bubbleJSON
		if err := rows.Scan(&b.ID, &b.SubjectID, &b.SubjectName, &b.Lat, &b.Lon, &b.RadiusM, &b.NotifyReenter, &b.Inside, &b.CreatedAt, &b.ExpiresAt); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load bubbles")
			return
		}
		out = append(out, b)
	}
	rows.Close()

	about := []bubbleAboutMeJSON{}
	rows, err = s.Pool.Query(r.Context(), `
		SELECT b.id, b.creator_id, u.name, b.expires_at
		FROM bubbles b JOIN users u ON u.id = b.creator_id
		WHERE b.subject_id = $1 AND b.expires_at > now()
		ORDER BY b.expires_at, b.id`, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load bubbles")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var a bubbleAboutMeJSON
		if err := rows.Scan(&a.ID, &a.CreatorID, &a.CreatorName, &a.ExpiresAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load bubbles")
			return
		}
		about = append(about, a)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load bubbles")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"bubbles": out, "about_me": about})
}

// DeleteBubble cancels a Bubble. Only its creator may; anyone else gets a
// uniform 404.
func (s *Server) DeleteBubble(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	id := chi.URLParam(r, "id")
	if !circles.ValidID(id) {
		writeError(w, http.StatusNotFound, "bubble not found")
		return
	}
	tag, err := s.Pool.Exec(r.Context(), `DELETE FROM bubbles WHERE id = $1 AND creator_id = $2`, id, claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to cancel bubble")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "bubble not found")
		return
	}
	s.auditSharing(r, claims.UserID, "bubble.cancel", "cancelled bubble "+id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// notifyBubbleSubject tells the subject a Bubble was created around them. The
// push never carries coordinates; the creator's name only with VERBOSE_PUSH.
func (s *Server) notifyBubbleSubject(subjectID, creatorName string, until time.Time) {
	if s.Push == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Local time in the zone the subject set for quiet hours, else UTC.
	loc, label := time.UTC, " UTC"
	var tz string
	if err := s.Pool.QueryRow(ctx, `SELECT tz FROM member_notification_prefs WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 1`, subjectID).Scan(&tz); err == nil {
		if l, err := time.LoadLocation(tz); err == nil {
			loc, label = l, ""
		}
	}
	title := s.pushName(creatorName) + " created a Bubble around you"
	body := title + " until " + until.In(loc).Format("15:04") + label
	s.pushUsers(ctx, []string{subjectID}, title, body)
}

// haversineM is the great-circle distance in metres.
func haversineM(lat1, lon1, lat2, lon2 float64) float64 {
	const earthR = 6371008.8
	rad := math.Pi / 180
	dLat, dLon := (lat2-lat1)*rad, (lon2-lon1)*rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * earthR * math.Asin(math.Min(1, math.Sqrt(a)))
}

// bubbleInside applies the hysteresis: leaving is crossing the radius, coming
// back is crossing 90% of it, so a fix jittering on the edge does not flap.
func bubbleInside(wasInside bool, dist float64, radius int) bool {
	if wasInside {
		return dist <= float64(radius)
	}
	return dist <= float64(radius)*bubbleReenterRatio
}

// evaluateBubbles runs from evaluateGeofences (ingest and the reconcile loop)
// for every stored point. A transition is claimed with a conditional UPDATE, so
// concurrent evaluations of the same point alert once. It is idempotent: the
// reconcile loop re-evaluating the latest point produces no transition.
func (s *Server) evaluateBubbles(ctx context.Context, subjectID string, lon, lat float64, ts time.Time) {
	rows, err := s.Pool.Query(ctx, `
		SELECT id, creator_id, lat, lon, radius_m, last_inside, notify_reenter
		FROM bubbles WHERE subject_id = $1 AND expires_at > now() AND created_at <= $2`, subjectID, ts)
	if err != nil {
		slog.Error("bubble: query", "subject_id", subjectID, "err", err)
		return
	}
	type cand struct {
		id, creator       string
		lat, lon          float64
		radius            int
		wasInside, reentr bool
	}
	var cs []cand
	for rows.Next() {
		var c cand
		if err := rows.Scan(&c.id, &c.creator, &c.lat, &c.lon, &c.radius, &c.wasInside, &c.reentr); err != nil {
			rows.Close()
			slog.Error("bubble: scan", "err", err)
			return
		}
		cs = append(cs, c)
	}
	rows.Close()
	for _, c := range cs {
		// A paused subject, or one no longer sharing with the creator, is not
		// evaluated at all: no state change, no alert.
		shared, err := circles.New(s.Pool).SharedWith(ctx, c.creator, subjectID)
		if err != nil || len(shared) == 0 {
			continue
		}
		inside := bubbleInside(c.wasInside, haversineM(c.lat, c.lon, lat, lon), c.radius)
		if inside == c.wasInside {
			continue
		}
		tag, err := s.Pool.Exec(ctx, `
			UPDATE bubbles SET last_inside = $2, last_event_at = now()
			WHERE id = $1 AND last_inside = $3 AND expires_at > now()`, c.id, inside, c.wasInside)
		if err != nil || tag.RowsAffected() == 0 {
			continue // lost the race (already alerted) or expired
		}
		if inside && !c.reentr {
			continue // state tracked so a later leave alerts, but no entry alert
		}
		s.alertBubble(ctx, c.id, c.creator, subjectID, inside)
	}
}

// alertBubble delivers a transition to the creator: a WebSocket frame (live) and
// a push through the shared push pipeline. Neither carries coordinates.
func (s *Server) alertBubble(ctx context.Context, bubbleID, creatorID, subjectID string, entered bool) {
	var name string
	if err := s.Pool.QueryRow(ctx, `SELECT name FROM users WHERE id = $1`, subjectID).Scan(&name); err != nil {
		return
	}
	event := "left"
	if entered {
		event = "entered"
	}
	if s.hub != nil {
		if b, err := json.Marshal(map[string]any{
			"type": "bubble", "event": event, "bubble_id": bubbleID,
			"user_id": subjectID, "name": name, "at": time.Now().UTC(),
		}); err == nil {
			s.hub.sendToUser(creatorID, b)
		}
	}
	if s.Push != nil {
		title := s.pushName(name) + " " + event + " their Bubble"
		s.pushUsers(ctx, []string{creatorID}, title, title)
	}
}

// purgeExpiredBubbles deletes expired Bubbles. Reads already ignore them; this
// bounds the table. Called from the geofence reconcile loop and on create.
func (s *Server) purgeExpiredBubbles(ctx context.Context) {
	if _, err := s.Pool.Exec(ctx, `DELETE FROM bubbles WHERE expires_at <= now()`); err != nil {
		slog.Debug("purge expired bubbles", "err", err)
	}
}
