package handlers

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// One-time "I'm here" check-ins to chosen circle members. Distinct from the
// family-wide alert check-in (alerts.go): the sender picks the recipients, who
// must each share a circle with the sender, and the check-in is stored for
// checkinRetention then no longer served. See docs/checkin-sharing.md.
const (
	checkinRetention     = 30 * 24 * time.Hour
	maxCheckinRecipients = 25
	maxCheckinList       = 100
	defaultCheckinList   = 30
)

type checkinRequest struct {
	RecipientIDs []string `json:"recipient_ids"`
	Note         string   `json:"note"`
	Lat          *float64 `json:"lat"`
	Lon          *float64 `json:"lon"`
}

type checkinJSON struct {
	ID         string    `json:"id"`
	UserID     string    `json:"user_id"`
	Name       string    `json:"name"`
	Lat        *float64  `json:"lat,omitempty"`
	Lon        *float64  `json:"lon,omitempty"`
	Note       string    `json:"note,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	Recipients []string  `json:"recipient_ids,omitempty"`
}

// PostCheckinTo records a check-in and delivers it (WS + push) to the chosen
// recipients only. Recipients that do not share a circle with the caller are
// rejected with a uniform 404 so membership is not probeable. A check-in is an
// explicit act, so it is sent even while sharing is paused.
func (s *Server) PostCheckinTo(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req checkinRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	note := strings.TrimSpace(req.Note)
	if utf8.RuneCountInString(note) > maxAlertNote {
		writeError(w, http.StatusBadRequest, "note is too long")
		return
	}
	if !validAlertCoord(req.Lat, -90, 90) || !validAlertCoord(req.Lon, -180, 180) || (req.Lat == nil) != (req.Lon == nil) {
		writeError(w, http.StatusBadRequest, "lat/lon out of range")
		return
	}
	seen := map[string]bool{}
	var ids []string
	for _, id := range req.RecipientIDs {
		id = strings.ToLower(strings.TrimSpace(id))
		if id == "" || id == strings.ToLower(claims.UserID) || seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		writeError(w, http.StatusBadRequest, "choose at least one recipient")
		return
	}
	if len(ids) > maxCheckinRecipients {
		writeError(w, http.StatusBadRequest, "too many recipients")
		return
	}
	ok, err := circles.New(s.Pool).CoMembers(r.Context(), claims.UserID, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to authorize recipients")
		return
	}
	for _, id := range ids {
		if !ok[id] {
			writeError(w, http.StatusNotFound, "member not found")
			return
		}
	}
	if s.AlertLimit != nil && !s.AlertLimit.Allow("checkinto:"+claims.UserID, 1, s.alertLimits().CheckInCooldown) {
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}

	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save check-in")
		return
	}
	defer tx.Rollback(r.Context())
	var c checkinJSON
	c.UserID, c.Lat, c.Lon, c.Note, c.Recipients = claims.UserID, req.Lat, req.Lon, note, ids
	if err := tx.QueryRow(r.Context(), `
		INSERT INTO checkins (user_id, lat, lon, note, expires_at)
		VALUES ($1, $2, $3, $4, now() + $5::interval)
		RETURNING id, created_at, expires_at`,
		claims.UserID, req.Lat, req.Lon, note, strconv.Itoa(int(checkinRetention/time.Second))+" seconds",
	).Scan(&c.ID, &c.CreatedAt, &c.ExpiresAt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save check-in")
		return
	}
	if _, err := tx.Exec(r.Context(), `
		INSERT INTO checkin_recipients (checkin_id, user_id)
		SELECT $1, unnest($2::uuid[])`, c.ID, ids); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save check-in")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save check-in")
		return
	}
	_ = s.Pool.QueryRow(r.Context(), `SELECT name FROM users WHERE id = $1`, claims.UserID).Scan(&c.Name)

	if familyID, err := s.familyIDForUser(r.Context(), claims.UserID); err == nil {
		s.logAudit(r.Context(), claims.UserID, familyID, "checkin.send",
			"checkin_id="+c.ID+" recipients="+strconv.Itoa(len(ids)), clientIP(r))
	}
	go s.purgeExpiredSharing()
	go s.fanOutCheckin(c, ids)
	writeJSON(w, http.StatusCreated, c)
}

// fanOutCheckin delivers a stored check-in to its recipients over the WS and
// push. The push never carries coordinates and, unless VERBOSE_PUSH, neither
// the sender's name nor the note.
func (s *Server) fanOutCheckin(c checkinJSON, recipients []string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if s.hub != nil {
		payload, err := json.Marshal(map[string]any{
			"type":       "checkin",
			"checkin_id": c.ID,
			"user_id":    c.UserID,
			"name":       c.Name,
			"lat":        c.Lat,
			"lon":        c.Lon,
			"note":       c.Note,
			"created_at": c.CreatedAt,
		})
		if err == nil {
			for _, uid := range recipients {
				s.hub.sendToUser(uid, payload)
			}
		}
	}
	if s.Push != nil {
		title, body := s.alertPushCopy(alertCheckIn, c.Name, c.Note)
		s.pushUsers(ctx, recipients, title, body)
	}
}

// pushUsers pushes one notification to every registered device of the given
// users (same transports as pushFamilyAlert, without delivery tracking).
func (s *Server) pushUsers(ctx context.Context, userIDs []string, title, body string) {
	rows, err := s.Pool.Query(ctx, `
		SELECT d.user_id, d.platform, d.push_token, d.unifiedpush_endpoint, d.id, d.push_transport
		FROM devices d
		WHERE d.user_id = ANY($1::uuid[])
		  AND ((d.platform = 'ios' AND d.push_token IS NOT NULL AND d.push_token <> '')
		       OR (d.platform = 'android' AND d.unifiedpush_endpoint IS NOT NULL AND d.unifiedpush_endpoint <> '')
		       OR (d.platform = 'android' AND d.push_transport = 'direct'))`, userIDs)
	if err != nil {
		slog.Error("checkin: list devices", "err", err)
		return
	}
	type dev struct{ uid, platform, token, endpoint, id, transport string }
	var devs []dev
	for rows.Next() {
		var d dev
		var token, endpoint *string
		if err := rows.Scan(&d.uid, &d.platform, &token, &endpoint, &d.id, &d.transport); err != nil {
			continue
		}
		d.token, d.endpoint = derefOrEmpty(token), derefOrEmpty(endpoint)
		devs = append(devs, d)
	}
	rows.Close()
	for _, d := range devs {
		n := push.Notification{Title: title, Body: body, Platform: d.platform, PushToken: d.token, UnifiedPushEndpoint: d.endpoint}
		if d.platform == "android" && d.transport == "direct" && s.Direct != nil {
			n = directNotification(n, d.id, d.uid, "", "")
		}
		if err := s.dispatchBest(ctx, n); err != nil {
			slog.Debug("checkin: push failed", "user_id", d.uid, "err", err)
		}
	}
}

// ListCheckins returns check-ins the caller received (default) or sent
// (?direction=sent), newest first. Expired check-ins are never served.
func (s *Server) ListCheckins(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	limit := defaultCheckinList
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > maxCheckinList {
			writeError(w, http.StatusBadRequest, "limit must be 1-"+strconv.Itoa(maxCheckinList))
			return
		}
		limit = n
	}
	var q string
	switch r.URL.Query().Get("direction") {
	case "", "received":
		q = `
			SELECT c.id, c.user_id, u.name, c.lat, c.lon, c.note, c.created_at, c.expires_at
			FROM checkin_recipients cr
			JOIN checkins c ON c.id = cr.checkin_id
			JOIN users u ON u.id = c.user_id
			WHERE cr.user_id = $1 AND c.expires_at > now()
			ORDER BY c.created_at DESC, c.id LIMIT $2`
	case "sent":
		q = `
			SELECT c.id, c.user_id, u.name, c.lat, c.lon, c.note, c.created_at, c.expires_at
			FROM checkins c JOIN users u ON u.id = c.user_id
			WHERE c.user_id = $1 AND c.expires_at > now()
			ORDER BY c.created_at DESC, c.id LIMIT $2`
	default:
		writeError(w, http.StatusBadRequest, "direction must be received or sent")
		return
	}
	rows, err := s.Pool.Query(r.Context(), q, claims.UserID, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load check-ins")
		return
	}
	defer rows.Close()
	out := []checkinJSON{}
	for rows.Next() {
		var c checkinJSON
		if err := rows.Scan(&c.ID, &c.UserID, &c.Name, &c.Lat, &c.Lon, &c.Note, &c.CreatedAt, &c.ExpiresAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load check-ins")
			return
		}
		out = append(out, c)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to load check-ins")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"checkins": out})
}

// purgeExpiredSharing garbage-collects expired rows. Reads already ignore
// them; this only bounds table size and enforces the retention window.
func (s *Server) purgeExpiredSharing() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, q := range []string{
		`DELETE FROM checkins WHERE expires_at <= now()`,
		`DELETE FROM live_shares WHERE expires_at <= now()`,
		`DELETE FROM sharing_pauses WHERE paused_until <= now()`,
		`DELETE FROM bubbles WHERE expires_at <= now()`,
	} {
		if _, err := s.Pool.Exec(ctx, q); err != nil {
			slog.Debug("purge expired sharing", "err", err)
		}
	}
}
