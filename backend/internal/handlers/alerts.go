package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

const (
	alertCheckIn      = "check_in"
	alertHelp         = "help"
	alertSOS          = "sos"
	alertStatusActive = "active"
	maxAlertNote      = 280
)

// alertNotifiedMessage is returned to the sender. It states what the server
// actually did. OpenFamily never contacts emergency services.
const alertNotifiedMessage = "Your family has been notified. Emergency services were not contacted; call your local emergency number if you need them."

type alertRow struct {
	ID         string
	UserID     string
	FamilyID   string
	Type       string
	Status     string
	Lat        *float64
	Lon        *float64
	Note       string
	ShareToken string
	CreatedAt  time.Time
	SenderName string

	ShareExpiresAt *time.Time
	ShareRevokedAt *time.Time
}

type alertJSON struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Status    string    `json:"status"`
	Lat       *float64  `json:"lat,omitempty"`
	Lon       *float64  `json:"lon,omitempty"`
	Note      string    `json:"note,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	Message   string    `json:"message,omitempty"`
}

// PostCheckIn records a family check-in and fans it out (WS, push, SMS).
func (s *Server) PostCheckIn(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertCheckIn, false)
}

// PostHelp records a non-emergency help alert. Family only (no emergency contacts).
func (s *Server) PostHelp(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertHelp, false)
}

// PostSOS records an emergency SOS. Family plus the sender's emergency contacts.
func (s *Server) PostSOS(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertSOS, true)
}

func (s *Server) loadOwnAlert(w http.ResponseWriter, r *http.Request, userID string) (alertRow, bool) {
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "alert id required")
		return alertRow{}, false
	}
	var a alertRow
	err := s.Pool.QueryRow(r.Context(), `
		SELECT a.id, a.user_id, COALESCE(a.family_id::text, ''), a.type, a.status, a.lat, a.lon, COALESCE(a.note, ''),
		       a.share_token, a.created_at, u.name
		FROM alerts a JOIN users u ON u.id = a.user_id
		WHERE a.id = $1 AND a.user_id = $2`, id, userID,
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt, &a.SenderName)
	if err != nil {
		writeError(w, http.StatusNotFound, "alert not found")
		return alertRow{}, false
	}
	return a, true
}

// ResolveAlert marks the caller's alert resolved and sends an "I'm safe" follow-up.
func (s *Server) ResolveAlert(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	a, ok := s.loadOwnAlert(w, r, claims.UserID)
	if !ok {
		return
	}
	if a.Status != alertStatusActive {
		writeJSON(w, http.StatusOK, alertJSON{ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt})
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE alerts SET status = 'resolved', resolved_at = now() WHERE id = $1 AND user_id = $2`,
		a.ID, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to resolve alert")
		return
	}
	a.Status = "resolved"
	go s.fanOutResolved(a)
	writeJSON(w, http.StatusOK, alertJSON{ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt})
}

// validAlertCoord accepts an absent value or a finite one within [min, max].
func validAlertCoord(v *float64, min, max float64) bool {
	if v == nil {
		return true
	}
	return !math.IsNaN(*v) && !math.IsInf(*v, 0) && *v >= min && *v <= max
}

type alertRequest struct {
	Note string   `json:"note"`
	Lat  *float64 `json:"lat"`
	Lon  *float64 `json:"lon"`
}

// decodeAlertRequest parses and validates an alert body: note length, and
// client-supplied coordinates must be finite and in range (BSEC-010). It
// returns a client-facing message, or "" when the request is acceptable.
func decodeAlertRequest(r *http.Request) (req alertRequest, note, errMsg string) {
	if r.Body != nil && r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			return req, "", "invalid request body"
		}
	}
	note = strings.TrimSpace(req.Note)
	if utf8.RuneCountInString(note) > maxAlertNote {
		return req, "", "note is too long"
	}
	if !validAlertCoord(req.Lat, -90, 90) || !validAlertCoord(req.Lon, -180, 180) {
		return req, "", "lat/lon out of range"
	}
	return req, note, ""
}

func (s *Server) postAlert(w http.ResponseWriter, r *http.Request, typ string, includeContacts bool) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load family")
		return
	}
	if familyID == "" {
		writeError(w, http.StatusNotFound, "no family")
		return
	}
	cfg := s.alertLimits()
	window := cfg.CheckInCooldown
	if typ == alertSOS {
		window = cfg.SOSCooldown
	}
	if s.AlertLimit != nil && !s.AlertLimit.Allow("alert:"+typ+":"+claims.UserID, 1, window) {
		if typ == alertSOS {
			writeError(w, http.StatusTooManyRequests,
				"your family was already notified of an SOS a moment ago; wait a couple of minutes before sending another")
			return
		}
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	// Family-wide ceiling for check-in/help. SOS is never blocked by it: the
	// family push/WebSocket fan-out always happens, only SMS is capped.
	if typ != alertSOS && cfg.FamilyMaxPerHour > 0 {
		var n int
		if err := s.Pool.QueryRow(r.Context(), `
			SELECT count(*) FROM alerts
			WHERE family_id = $1 AND type <> 'sos' AND created_at > now() - interval '1 hour'`,
			familyID).Scan(&n); err == nil && n >= cfg.FamilyMaxPerHour {
			writeError(w, http.StatusTooManyRequests, "your family has sent too many check-ins or help requests in the last hour")
			return
		}
	}

	req, note, errMsg := decodeAlertRequest(r)
	if errMsg != "" {
		writeError(w, http.StatusBadRequest, errMsg)
		return
	}

	lat, lon := req.Lat, req.Lon
	if lat == nil || lon == nil {
		var lastLat, lastLon float64
		err := s.Pool.QueryRow(r.Context(),
			`SELECT lat, lon FROM member_positions WHERE user_id = $1`, claims.UserID,
		).Scan(&lastLat, &lastLon)
		if err != nil && err != pgx.ErrNoRows {
			writeError(w, http.StatusInternalServerError, "failed to load location")
			return
		}
		if err == nil {
			lat, lon = &lastLat, &lastLon
		}
	}

	token, err := newShareToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create alert")
		return
	}

	var a alertRow
	err = s.Pool.QueryRow(r.Context(), `
		INSERT INTO alerts (user_id, family_id, type, status, lat, lon, note, share_token, share_expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		RETURNING id, user_id, family_id, type, status, lat, lon, note, share_token, created_at`,
		claims.UserID, familyID, typ, alertStatusActive, lat, lon, note, token, time.Now().Add(cfg.ShareTTL),
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create alert")
		return
	}
	_ = s.Pool.QueryRow(r.Context(), `SELECT name FROM users WHERE id = $1`, claims.UserID).Scan(&a.SenderName)

	s.logAudit(r.Context(), claims.UserID, familyID, "alert."+typ, "alert_id="+a.ID, clientIP(r))
	go s.fanOutAlert(a, includeContacts)

	writeJSON(w, http.StatusCreated, alertJSON{
		ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt,
		Message: alertNotifiedMessage,
	})
}

func (s *Server) fanOutAlert(a alertRow, includeContacts bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	title, body := s.alertPushCopy(a.Type, a.SenderName, a.Note)
	s.broadcastAlert(ctx, a)

	var pushSent, pushFailed int
	if s.Push != nil && a.FamilyID != "" {
		pushSent, pushFailed = s.pushFamilyAlert(ctx, a.FamilyID, a.UserID, a.ID, title, body)
	}

	var smsSent, smsFailed int
	if includeContacts || s.alertLimits().SMSOnCheckIn {
		loc := s.shareURL(a.ShareToken)
		smsBody := alertSMSBody(firstName(a.SenderName), a.Type, loc)
		smsSent, smsFailed = s.smsEmergencyContacts(ctx, a, smsBody)
	}
	s.logAudit(ctx, a.UserID, a.FamilyID, "alert.fanout",
		fmt.Sprintf("alert_id=%s push_sent=%d push_failed=%d sms_sent=%d sms_failed=%d",
			a.ID, pushSent, pushFailed, smsSent, smsFailed), "")
}

func (s *Server) fanOutResolved(a alertRow) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	name := firstName(a.SenderName)
	if s.hub != nil {
		payload, err := json.Marshal(map[string]any{
			"type":       "alert",
			"alert_type": a.Type,
			"alert_id":   a.ID,
			"status":     "resolved",
			"user_id":    a.UserID,
			"name":       a.SenderName,
		})
		if err == nil {
			if a.FamilyID != "" {
				s.hub.broadcast(a.FamilyID, payload)
			}
			s.hub.broadcastAdmin(payload)
		}
	}
	if s.Push != nil && a.FamilyID != "" {
		title := s.pushName(a.SenderName) + " is safe"
		s.pushFamilyAlert(ctx, a.FamilyID, a.UserID, "", title, title)
	}
	// Only contacts who actually received the original SMS hear the follow-up.
	s.smsResolvedContacts(ctx, a.ID, name+" marked themselves safe.")
}

func (s *Server) shareURL(token string) string {
	base := strings.TrimRight(s.publicBaseURL(), "/")
	if !strings.HasPrefix(strings.ToLower(base), "https://") {
		return ""
	}
	return base + "/alerts/share/" + token
}

// shareCSP allows nothing but inline styles: the page runs no script and loads
// no third-party resources (the map is an outbound link the viewer may click).
const shareCSP = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

func setShareHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Security-Policy", shareCSP)
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Robots-Tag", "noindex, nofollow, noarchive")
	h.Set("Cache-Control", "no-store")
}

// ShareAlert is the public, unauthenticated share page for SMS links.
func (s *Server) ShareAlert(w http.ResponseWriter, r *http.Request) {
	setShareHeaders(w)
	if s.AuthLimit != nil && !s.AuthLimit.Allow(authIPKey("share", clientIP(r)), sharePerIP, shareWindow) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	token := chi.URLParam(r, "token")
	if len(token) != shareTokenLen {
		http.NotFound(w, r)
		return
	}
	var a alertRow
	err := s.Pool.QueryRow(r.Context(), `
		SELECT a.id, a.user_id, COALESCE(a.family_id::text, ''), a.type, a.status, a.lat, a.lon, COALESCE(a.note, ''),
		       a.share_token, a.created_at, u.name, a.share_expires_at, a.share_revoked_at
		FROM alerts a JOIN users u ON u.id = a.user_id
		WHERE a.share_token = $1`, token,
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt, &a.SenderName,
		&a.ShareExpiresAt, &a.ShareRevokedAt)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch shareState(a, time.Now()) {
	case shareRevoked:
		http.Error(w, "this link was turned off by the sender", http.StatusGone)
		return
	case shareExpiredState:
		http.Error(w, "this link has expired", http.StatusGone)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(sharePageHTML(a)))
}

func newShareToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func firstName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "A family member"
	}
	if i := strings.IndexByte(name, ' '); i > 0 {
		return name[:i]
	}
	return name
}

const (
	shareOK = iota
	shareExpiredState
	shareRevoked
)

// shareTokenLen is the hex length of a share token (16 random bytes = 128 bits).
const shareTokenLen = 32

// shareState reports whether a share link may still be served. Rows from before
// the expiry column existed fall back to the 24 h lifetime they had.
func shareState(a alertRow, now time.Time) int {
	if a.ShareRevokedAt != nil {
		return shareRevoked
	}
	exp := a.CreatedAt.Add(24 * time.Hour)
	if a.ShareExpiresAt != nil {
		exp = *a.ShareExpiresAt
	}
	if !now.Before(exp) {
		return shareExpiredState
	}
	return shareOK
}

func alertCopy(typ, name, note string) (title, body string) {
	switch typ {
	case alertHelp:
		title = name + " needs help"
	case alertSOS:
		title = name + " sent SOS"
	default:
		title = name + " checked in"
	}
	body = title
	if note != "" {
		body = title + ": " + note
	}
	return title, body
}

// pushName is the sender name allowed in a push payload: the push provider
// (ntfy/APNs) only learns who it was when VERBOSE_PUSH is on (BSEC-022).
func (s *Server) pushName(senderName string) string {
	if s.VerbosePush {
		return firstName(senderName)
	}
	return "A family member"
}

// alertPushCopy builds the push title/body. Without VERBOSE_PUSH it carries
// neither the sender name nor the free-text note. It never carries coordinates.
func (s *Server) alertPushCopy(typ, senderName, note string) (title, body string) {
	if !s.VerbosePush {
		note = ""
	}
	return alertCopy(typ, s.pushName(senderName), note)
}

// alertSMSBody is the text sent to an emergency contact. It never contains raw
// coordinates: location travels only behind the short-lived share link, and is
// omitted when no https PUBLIC_BASE_URL is configured.
func alertSMSBody(name, typ, shareURL string) string {
	action := "checked in"
	switch typ {
	case alertHelp:
		action = "needs help"
	case alertSOS:
		action = "sent an SOS"
	}
	msg := fmt.Sprintf("%s %s via OpenFamily and their family was notified. Emergency services have NOT been contacted.", name, action)
	if shareURL != "" {
		msg += " Location (temporary link): " + shareURL
	}
	return msg
}

// sharePageHTML renders the public share page. It contains no script and no
// third-party resources. Coordinates and the map link are shown only while the
// alert is active: once resolved the page no longer reveals where the sender
// was.
func sharePageHTML(a alertRow) string {
	title, _ := alertCopy(a.Type, firstName(a.SenderName), a.Note)
	when := a.CreatedAt.UTC().Format(time.RFC3339)
	var locHTML string
	switch {
	case a.Status != alertStatusActive:
		locHTML = `<p>This alert has been resolved. Location sharing has ended.</p>`
	case a.Lat != nil && a.Lon != nil:
		// %.5f cannot carry markup; the URL holds only the two numbers.
		locHTML = fmt.Sprintf(
			`<p>Last known location: %.5f, %.5f</p>
<p><a href="https://www.openstreetmap.org/?mlat=%.5f&amp;mlon=%.5f#map=16/%.5f/%.5f" rel="noreferrer noopener">Open in OpenStreetMap</a></p>`,
			*a.Lat, *a.Lon, *a.Lat, *a.Lon, *a.Lat, *a.Lon)
	}
	return fmt.Sprintf(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow">
<title>%s</title>
<style>body{font-family:system-ui,sans-serif;margin:24px;color:#111;max-width:40rem}</style>
</head><body>
<h1>%s</h1>
<p>%s</p>
<p>%s</p>
%s
</body></html>`, html.EscapeString(title), html.EscapeString(title), html.EscapeString(when), html.EscapeString(a.Status), locHTML)
}
