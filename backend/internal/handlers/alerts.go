package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/middleware"
	"github.com/wheresfrank/openfamily/backend/internal/push"
)

const (
	alertCheckIn      = "check_in"
	alertHelp         = "help"
	alertSOS          = "sos"
	alertStatusActive = "active"
	shareTTL          = 24 * time.Hour
	maxAlertNote      = 280
	checkInRateWindow = time.Minute
	sosRateWindow     = 2 * time.Minute
)

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
}

type alertJSON struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Status    string    `json:"status"`
	Lat       *float64  `json:"lat,omitempty"`
	Lon       *float64  `json:"lon,omitempty"`
	Note      string    `json:"note,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// PostCheckIn records a family check-in and fans it out (WS, push, SMS).
func (s *Server) PostCheckIn(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertCheckIn, false, checkInRateWindow)
}

// PostHelp records a non-emergency help alert. Family only (no emergency contacts).
func (s *Server) PostHelp(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertHelp, false, checkInRateWindow)
}

// PostSOS records an emergency SOS. Family plus the sender's emergency contacts.
func (s *Server) PostSOS(w http.ResponseWriter, r *http.Request) {
	s.postAlert(w, r, alertSOS, true, sosRateWindow)
}

// GetAlert returns one of the caller's alerts. The SOS screen uses this to
// drop a stale "SOS sent" state when the row is gone or already resolved.
func (s *Server) GetAlert(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	a, ok := s.loadOwnAlert(w, r, claims.UserID)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, alertJSON{
		ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt,
	})
}

func (s *Server) loadOwnAlert(w http.ResponseWriter, r *http.Request, userID string) (alertRow, bool) {
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "alert id required")
		return alertRow{}, false
	}
	var a alertRow
	err := s.Pool.QueryRow(r.Context(), `
		SELECT a.id, a.user_id, COALESCE(a.family_id, ''), a.type, a.status, a.lat, a.lon, COALESCE(a.note, ''),
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

func (s *Server) postAlert(w http.ResponseWriter, r *http.Request, typ string, includeContacts bool, window time.Duration) {
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
	if s.AlertLimit != nil && !s.AlertLimit.Allow("alert:"+typ+":"+claims.UserID, 1, window) {
		if typ == alertSOS {
			writeError(w, http.StatusTooManyRequests,
				"an SOS was already sent recently; wait a couple of minutes")
			return
		}
		writeError(w, http.StatusTooManyRequests, "too many requests")
		return
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
		INSERT INTO alerts (user_id, family_id, type, status, lat, lon, note, share_token)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, user_id, family_id, type, status, lat, lon, note, share_token, created_at`,
		claims.UserID, familyID, typ, alertStatusActive, lat, lon, note, token,
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create alert")
		return
	}
	_ = s.Pool.QueryRow(r.Context(), `SELECT name FROM users WHERE id = $1`, claims.UserID).Scan(&a.SenderName)

	go s.fanOutAlert(a, includeContacts)

	writeJSON(w, http.StatusCreated, alertJSON{
		ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt,
	})
}

func (s *Server) fanOutAlert(a alertRow, includeContacts bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	title, body := alertCopy(a.Type, firstName(a.SenderName), a.Note)
	s.broadcastAlert(a)

	if s.Push != nil && a.FamilyID != "" {
		s.pushFamilyAlert(ctx, a.FamilyID, a.UserID, title, body)
	}

	loc := alertLocationText(s.shareURL(a.ShareToken), a.Lat, a.Lon)
	smsBody := alertSMSBody(firstName(a.SenderName), a.Type, loc)
	s.smsFamily(ctx, a.FamilyID, a.UserID, smsBody)
	if includeContacts {
		s.smsEmergencyContacts(ctx, a.UserID, smsBody)
	}
}

func (s *Server) fanOutResolved(a alertRow) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	name := firstName(a.SenderName)
	title := name + " is safe"
	body := title
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
		s.pushFamilyAlert(ctx, a.FamilyID, a.UserID, title, body)
	}
	smsBody := name + " is safe."
	s.smsFamily(ctx, a.FamilyID, a.UserID, smsBody)
	if a.Type == alertSOS {
		s.smsEmergencyContacts(ctx, a.UserID, smsBody)
	}
}

func (s *Server) broadcastAlert(a alertRow) {
	if s.hub == nil {
		return
	}
	payload, err := json.Marshal(map[string]any{
		"type":       "alert",
		"alert_type": a.Type,
		"alert_id":   a.ID,
		"user_id":    a.UserID,
		"name":       a.SenderName,
		"lat":        a.Lat,
		"lon":        a.Lon,
		"note":       a.Note,
		"created_at": a.CreatedAt,
	})
	if err != nil {
		return
	}
	if a.FamilyID != "" {
		s.hub.broadcast(a.FamilyID, payload)
	}
	s.hub.broadcastAdmin(payload)
}

func (s *Server) pushFamilyAlert(ctx context.Context, familyID, senderID, title, body string) {
	rows, err := s.Pool.Query(ctx, `
		SELECT d.platform, d.push_token, d.unifiedpush_endpoint
		FROM devices d
		JOIN users u ON u.id = d.user_id
		WHERE u.family_id = $1 AND u.id <> $2
		  AND ((d.platform = 'ios' AND d.push_token IS NOT NULL AND d.push_token <> '')
		       OR (d.platform = 'android' AND d.unifiedpush_endpoint IS NOT NULL AND d.unifiedpush_endpoint <> ''))`,
		familyID, senderID)
	if err != nil {
		slog.Error("alert: list devices", "err", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var platform string
		var token, endpoint *string
		if err := rows.Scan(&platform, &token, &endpoint); err != nil {
			continue
		}
		n := push.Notification{
			Title:               title,
			Body:                body,
			Platform:            platform,
			PushToken:           derefOrEmpty(token),
			UnifiedPushEndpoint: derefOrEmpty(endpoint),
		}
		_ = s.dispatchWithRetry(ctx, n)
	}
}

func (s *Server) smsFamily(ctx context.Context, familyID, senderID, body string) {
	if !s.SMSEnabled() || familyID == "" {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT phone FROM users
		WHERE family_id = $1 AND id <> $2 AND phone IS NOT NULL AND phone <> ''`,
		familyID, senderID)
	if err != nil {
		slog.Error("alert: list family phones", "err", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var phone string
		if err := rows.Scan(&phone); err != nil {
			continue
		}
		if err := s.sendSMS(ctx, phone, body); err != nil {
			slog.Error("alert: sms family", "err", err)
		}
	}
}

func (s *Server) smsEmergencyContacts(ctx context.Context, senderID, body string) {
	if !s.SMSEnabled() {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT phone FROM emergency_contacts WHERE user_id = $1`, senderID)
	if err != nil {
		slog.Error("alert: list contacts", "err", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var phone string
		if err := rows.Scan(&phone); err != nil {
			continue
		}
		if err := s.sendSMS(ctx, phone, body); err != nil {
			slog.Error("alert: sms contact", "err", err)
		}
	}
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
	if token == "" {
		http.NotFound(w, r)
		return
	}
	var a alertRow
	err := s.Pool.QueryRow(r.Context(), `
		SELECT a.id, a.user_id, COALESCE(a.family_id, ''), a.type, a.status, a.lat, a.lon, COALESCE(a.note, ''),
		       a.share_token, a.created_at, u.name
		FROM alerts a JOIN users u ON u.id = a.user_id
		WHERE a.share_token = $1`, token,
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt, &a.SenderName)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if shareExpired(a.CreatedAt, time.Now()) {
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

func shareExpired(created, now time.Time) bool {
	return now.Sub(created) > shareTTL
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

func alertSMSBody(name, typ, loc string) string {
	action := "checked in"
	switch typ {
	case alertHelp:
		action = "needs help"
	case alertSOS:
		action = "sent SOS"
	}
	if loc == "" {
		return fmt.Sprintf("%s %s.", name, action)
	}
	return fmt.Sprintf("%s %s. %s", name, action, loc)
}

func alertLocationText(shareURL string, lat, lon *float64) string {
	if shareURL != "" {
		return shareURL
	}
	if lat != nil && lon != nil {
		return fmt.Sprintf("%.5f, %.5f", *lat, *lon)
	}
	return ""
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
