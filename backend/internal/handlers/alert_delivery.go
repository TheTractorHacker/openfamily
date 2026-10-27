package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

// Delivery channels and states (see docs/safety.md).
const (
	chanPush = "push"
	chanWS   = "ws"
	chanSMS  = "sms"

	stQueued       = "queued"
	stSent         = "sent"
	stDelivered    = "delivered"
	stFailed       = "failed"
	stAcknowledged = "acknowledged"
)

// Stable, short error codes stored on a failed delivery. Provider response
// bodies (which can contain phone numbers) are never stored.
const (
	errCodeInvalidPhone    = "invalid_phone"
	errCodeProvider        = "provider_error"
	errCodeRejected        = "rejected_by_provider"
	errCodeSMSOff          = "sms_not_configured"
	errCodeRecipientCap    = "limit_recipients_per_alert"
	errCodeSenderDailyCap  = "limit_sender_sms_per_day"
	errCodeFamilyHourlyCap = "limit_family_sms_per_hour"
)

// recordDelivery upserts one (alert, recipient, channel) row. State never moves
// backwards: delivered/acknowledged are not overwritten by queued/sent/failed.
func (s *Server) recordDelivery(ctx context.Context, alertID, userID, contactID, label, channel, state, errCode string) {
	key := "u:" + userID
	var uid, cid any
	if userID != "" {
		uid = userID
	} else {
		key = "c:" + contactID
		cid = contactID
	}
	_, err := s.Pool.Exec(ctx, `
		INSERT INTO alert_deliveries (alert_id, recipient_key, recipient_user_id, contact_id, recipient_label,
		                              channel, state, error, sent_at, delivered_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8,
		        CASE WHEN $7 IN ('sent','delivered') THEN now() END,
		        CASE WHEN $7 = 'delivered' THEN now() END)
		ON CONFLICT (alert_id, recipient_key, channel) DO UPDATE SET
		    state = CASE
		        WHEN alert_deliveries.state = 'acknowledged' THEN alert_deliveries.state
		        WHEN alert_deliveries.state = 'delivered' AND EXCLUDED.state IN ('queued','sent','failed') THEN alert_deliveries.state
		        ELSE EXCLUDED.state END,
		    error = CASE WHEN EXCLUDED.state = 'failed' THEN EXCLUDED.error ELSE '' END,
		    sent_at = COALESCE(alert_deliveries.sent_at, EXCLUDED.sent_at),
		    delivered_at = COALESCE(alert_deliveries.delivered_at, EXCLUDED.delivered_at),
		    updated_at = now()`,
		alertID, key, uid, cid, label, channel, state, errCode)
	if err != nil {
		slog.Error("alert: record delivery", "channel", channel, "err", err)
	}
}

// --- hub helpers (kept out of hub.go) ---

// broadcastCollect is broadcast that also reports which users had the frame
// queued onto a live socket. Queued-on-socket is the strongest signal the
// server has; the recipient's explicit ack is the only proof of reading.
func (h *hub) broadcastCollect(familyID string, msg []byte) map[string]bool {
	h.mu.Lock()
	m := h.families[familyID]
	clients := make([]*wsClient, 0, len(m))
	for c := range m {
		clients = append(clients, c)
	}
	h.mu.Unlock()

	reached := map[string]bool{}
	for _, c := range clients {
		select {
		case c.send <- msg:
			if c.userID != "" {
				reached[c.userID] = true
			}
		default:
			h.unregister(familyID, c)
			c.close()
		}
	}
	return reached
}

// sendToUser queues msg on every live socket of one user and reports whether
// any accepted it.
func (h *hub) sendToUser(userID string, msg []byte) bool {
	h.mu.Lock()
	clients := make([]*wsClient, 0, len(h.familyUsers[userID]))
	for c := range h.familyUsers[userID] {
		clients = append(clients, c)
	}
	h.mu.Unlock()
	ok := false
	for _, c := range clients {
		select {
		case c.send <- msg:
			ok = true
		default:
		}
	}
	return ok
}

func (s *Server) broadcastAlert(ctx context.Context, a alertRow) {
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
		for uid := range s.hub.broadcastCollect(a.FamilyID, payload) {
			if uid != a.UserID {
				s.recordDelivery(ctx, a.ID, uid, "", "", chanWS, stDelivered, "")
			}
		}
	}
	s.hub.broadcastAdmin(payload)
}

// pushFamilyAlert pushes to every other family member's devices and, when
// alertID is set, records one push delivery per user: sent if any device's
// provider (ntfy/APNs) accepted it, failed if every device failed.
func (s *Server) pushFamilyAlert(ctx context.Context, familyID, senderID, alertID, title, body string) (sent, failed int) {
	return s.pushFamilyAlertFor(ctx, familyID, senderID, alertID, title, body, "")
}

// pushFamilyAlertFor is pushFamilyAlert for a mutable category (see
// notification_prefs.go); "" means the push always gets through.
func (s *Server) pushFamilyAlertFor(ctx context.Context, familyID, senderID, alertID, title, body, category string) (sent, failed int) {
	// category is "" for alerts that always get through (SOS, help); otherwise
	// people who muted it are skipped.
	muted := s.usersMuted(ctx, category)
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.name, d.platform, d.push_token, d.unifiedpush_endpoint, d.id, d.push_transport
		FROM devices d
		JOIN users u ON u.id = d.user_id
		WHERE u.family_id = $1 AND u.id <> $2
		  AND ((d.platform = 'ios' AND d.push_token IS NOT NULL AND d.push_token <> '')
		       OR (d.platform = 'android' AND d.unifiedpush_endpoint IS NOT NULL AND d.unifiedpush_endpoint <> '')
		       OR (d.platform = 'android' AND d.push_transport = 'direct'))`,
		familyID, senderID)
	if err != nil {
		slog.Error("alert: list devices", "err", err)
		return 0, 0
	}
	type dev struct {
		platform, token, endpoint, id string
		direct                        bool
	}
	type target struct {
		name string
		devs []dev
	}
	targets := map[string]*target{}
	var order []string
	for rows.Next() {
		var uid, name, platform string
		var token, endpoint *string
		var devID, transport string
		if err := rows.Scan(&uid, &name, &platform, &token, &endpoint, &devID, &transport); err != nil {
			continue
		}
		if muted[uid] {
			continue
		}
		t := targets[uid]
		if t == nil {
			t = &target{name: name}
			targets[uid] = t
			order = append(order, uid)
		}
		t.devs = append(t.devs, dev{platform, derefOrEmpty(token), derefOrEmpty(endpoint), devID,
			platform == "android" && transport == "direct" && s.Direct != nil})
	}
	rows.Close()

	for _, uid := range order {
		t := targets[uid]
		if alertID != "" {
			s.recordDelivery(ctx, alertID, uid, "", t.name, chanPush, stQueued, "")
		}
		ok, code := false, errCodeProvider
		// directOnly stays true while every accepted delivery is a direct
		// enqueue: that is "queued" until the device streams it (sent) and acks
		// it (delivered), which the stream handler records.
		directOnly := true
		for _, d := range t.devs {
			n := push.Notification{
				Title: title, Body: body, Platform: d.platform,
				PushToken: d.token, UnifiedPushEndpoint: d.endpoint,
			}
			if d.direct {
				n = directNotification(n, d.id, uid, alertID, "")
				if alertID != "" {
					n.DedupeID = "alert:" + alertID
				}
			}
			err := s.dispatchBest(ctx, n)
			if err == nil {
				ok = true
				if !d.direct || (d.endpoint != "" && !s.Direct.IsConnected(d.id)) {
					directOnly = false
				}
			} else if push.IsPermanent(err) {
				code = errCodeRejected
			}
		}
		if ok {
			sent++
		} else {
			failed++
		}
		if alertID != "" {
			if ok && directOnly {
				continue // stays queued; the stream records sent/delivered
			}
			if ok {
				s.recordDelivery(ctx, alertID, uid, "", t.name, chanPush, stSent, "")
			} else {
				s.recordDelivery(ctx, alertID, uid, "", t.name, chanPush, stFailed, code)
			}
		}
	}
	return sent, failed
}

// smsEmergencyContacts texts the sender's own, explicitly added emergency
// contacts (never family members' profile phones). Each contact gets a delivery
// row; contacts beyond the per-alert, per-sender daily or per-family hourly
// ceiling are recorded as failed with a limit code instead of being texted.
func (s *Server) smsEmergencyContacts(ctx context.Context, a alertRow, body string) (sent, failed int) {
	cfg := s.alertLimits()
	rows, err := s.Pool.Query(ctx, `
		SELECT id, name, phone FROM emergency_contacts WHERE user_id = $1 ORDER BY created_at, id`, a.UserID)
	if err != nil {
		slog.Error("alert: list contacts", "err", err)
		return 0, 0
	}
	type contact struct{ id, name, phone string }
	var contacts []contact
	for rows.Next() {
		var c contact
		if err := rows.Scan(&c.id, &c.name, &c.phone); err == nil {
			contacts = append(contacts, c)
		}
	}
	rows.Close()
	if len(contacts) == 0 {
		return 0, 0
	}

	senderLeft, familyLeft := cfg.SenderSMSPerDay, cfg.FamilySMSPerHour
	if s.SMSEnabled() {
		var sn, fn int
		_ = s.Pool.QueryRow(ctx, smsCountSQL("a.user_id = $1", "24 hours"), a.UserID).Scan(&sn)
		if a.FamilyID != "" {
			_ = s.Pool.QueryRow(ctx, smsCountSQL("a.family_id = $1", "1 hour"), a.FamilyID).Scan(&fn)
		}
		senderLeft -= sn
		familyLeft -= fn
	}

	for i, c := range contacts {
		switch {
		case !s.SMSEnabled():
			s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stFailed, errCodeSMSOff)
			failed++
			continue
		case i >= cfg.SMSMaxRecipients:
			s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stFailed, errCodeRecipientCap)
			failed++
			continue
		case senderLeft <= 0:
			s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stFailed, errCodeSenderDailyCap)
			failed++
			continue
		case familyLeft <= 0:
			s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stFailed, errCodeFamilyHourlyCap)
			failed++
			continue
		}
		senderLeft--
		familyLeft--
		s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stQueued, "")
		if err := s.sendSMS(ctx, c.phone, body); err != nil {
			code := errCodeProvider
			if errors.Is(err, sms.ErrInvalidPhone) {
				code = errCodeInvalidPhone
			}
			slog.Error("alert: sms contact", "code", code) // no provider body: it can contain the number
			s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stFailed, code)
			failed++
			continue
		}
		// The API accepted the message; a Twilio status callback is not wired,
		// so "sent" is as far as SMS state goes.
		s.recordDelivery(ctx, a.ID, "", c.id, c.name, chanSMS, stSent, "")
		sent++
	}
	return sent, failed
}

// smsCountSQL counts SMS attempts (those that really consumed provider quota,
// i.e. not refused by a limit) for the given alert owner scope and window.
func smsCountSQL(scope, window string) string {
	return `SELECT count(*) FROM alert_deliveries d JOIN alerts a ON a.id = d.alert_id
		WHERE d.channel = 'sms' AND ` + scope + ` AND d.created_at > now() - interval '` + window + `'
		  AND d.error NOT LIKE 'limit\_%' AND d.error <> 'sms_not_configured'`
}

// smsResolvedContacts sends the "marked themselves safe" follow-up only to
// contacts who actually received the original SMS.
func (s *Server) smsResolvedContacts(ctx context.Context, alertID, body string) {
	if !s.SMSEnabled() {
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT c.phone FROM alert_deliveries d JOIN emergency_contacts c ON c.id = d.contact_id
		WHERE d.alert_id = $1 AND d.channel = 'sms' AND d.state IN ('sent','delivered','acknowledged')`, alertID)
	if err != nil {
		slog.Error("alert: list notified contacts", "err", err)
		return
	}
	var phones []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil {
			phones = append(phones, p)
		}
	}
	rows.Close()
	for _, p := range phones {
		if err := s.sendSMS(ctx, p, body); err != nil {
			slog.Error("alert: sms resolved follow-up failed")
		}
	}
}

// --- read / ack endpoints ---

type deliveryJSON struct {
	RecipientUserID string     `json:"recipient_user_id,omitempty"`
	ContactID       string     `json:"contact_id,omitempty"`
	Recipient       string     `json:"recipient"`
	Channel         string     `json:"channel"`
	State           string     `json:"state"`
	Error           string     `json:"error,omitempty"`
	SentAt          *time.Time `json:"sent_at,omitempty"`
	DeliveredAt     *time.Time `json:"delivered_at,omitempty"`
	AcknowledgedAt  *time.Time `json:"acknowledged_at,omitempty"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type alertDetailJSON struct {
	alertJSON
	SenderName string         `json:"sender_name"`
	UserID     string         `json:"user_id"`
	ResolvedAt *time.Time     `json:"resolved_at,omitempty"`
	Deliveries []deliveryJSON `json:"deliveries"`
}

func (s *Server) loadAlertByID(ctx context.Context, id string) (alertRow, *time.Time, error) {
	var a alertRow
	var resolved *time.Time
	err := s.Pool.QueryRow(ctx, `
		SELECT a.id, a.user_id, COALESCE(a.family_id::text, ''), a.type, a.status, a.lat, a.lon, COALESCE(a.note, ''),
		       a.share_token, a.created_at, u.name, a.resolved_at
		FROM alerts a JOIN users u ON u.id = a.user_id
		WHERE a.id::text = $1`, id,
	).Scan(&a.ID, &a.UserID, &a.FamilyID, &a.Type, &a.Status, &a.Lat, &a.Lon, &a.Note, &a.ShareToken, &a.CreatedAt, &a.SenderName, &resolved)
	return a, resolved, err
}

// GetAlert returns an alert with per-recipient delivery state. Only the sender
// and admins of the sender's family may read it; anyone else gets 404.
func (s *Server) GetAlert(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	a, resolved, err := s.loadAlertByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "alert not found")
		return
	}
	if a.UserID != claims.UserID {
		var isAdmin bool
		err := s.Pool.QueryRow(r.Context(), `
			SELECT role = 'admin' AND family_id IS NOT NULL AND family_id::text = $2 FROM users WHERE id = $1`,
			claims.UserID, a.FamilyID).Scan(&isAdmin)
		if err != nil || !isAdmin || a.FamilyID == "" {
			writeError(w, http.StatusNotFound, "alert not found")
			return
		}
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT COALESCE(d.recipient_user_id::text, ''), COALESCE(d.contact_id::text, ''),
		       COALESCE(NULLIF(u.name, ''), d.recipient_label), d.channel, d.state, d.error,
		       d.sent_at, d.delivered_at, d.acknowledged_at, d.updated_at
		FROM alert_deliveries d LEFT JOIN users u ON u.id = d.recipient_user_id
		WHERE d.alert_id = $1
		ORDER BY d.created_at, d.channel, d.id`, a.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load deliveries")
		return
	}
	defer rows.Close()
	out := alertDetailJSON{
		alertJSON:  alertJSON{ID: a.ID, Type: a.Type, Status: a.Status, Lat: a.Lat, Lon: a.Lon, Note: a.Note, CreatedAt: a.CreatedAt, Message: alertNotifiedMessage},
		SenderName: a.SenderName, UserID: a.UserID, ResolvedAt: resolved, Deliveries: []deliveryJSON{},
	}
	for rows.Next() {
		var d deliveryJSON
		if err := rows.Scan(&d.RecipientUserID, &d.ContactID, &d.Recipient, &d.Channel, &d.State, &d.Error,
			&d.SentAt, &d.DeliveredAt, &d.AcknowledgedAt, &d.UpdatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read deliveries")
			return
		}
		out.Deliveries = append(out.Deliveries, d)
	}
	writeJSON(w, http.StatusOK, out)
}

// AckAlert lets a family member (not the sender) acknowledge an alert. It is
// idempotent: repeats return the original acknowledgement time and send
// nothing further. The first acknowledgement is pushed to the sender over the
// WebSocket hub.
func (s *Server) AckAlert(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	a, _, err := s.loadAlertByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil || a.FamilyID == "" {
		writeError(w, http.StatusNotFound, "alert not found")
		return
	}
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil || familyID != a.FamilyID {
		writeError(w, http.StatusNotFound, "alert not found")
		return
	}
	if a.UserID == claims.UserID {
		writeError(w, http.StatusBadRequest, "you cannot acknowledge your own alert")
		return
	}
	var name string
	_ = s.Pool.QueryRow(r.Context(), `SELECT name FROM users WHERE id = $1`, claims.UserID).Scan(&name)

	key := "u:" + claims.UserID
	var prior *time.Time
	_ = s.Pool.QueryRow(r.Context(), `
		SELECT min(acknowledged_at) FROM alert_deliveries WHERE alert_id = $1 AND recipient_key = $2`,
		a.ID, key).Scan(&prior)
	if prior == nil {
		// Make sure at least one row exists even when the recipient had no
		// push/WS delivery (e.g. they opened the app on their own), then
		// acknowledge every channel row for them.
		s.recordDelivery(r.Context(), a.ID, claims.UserID, "", name, chanWS, stQueued, "")
		var at time.Time
		if _, err := s.Pool.Exec(r.Context(), `
			UPDATE alert_deliveries SET state = 'acknowledged', acknowledged_at = COALESCE(acknowledged_at, now()), updated_at = now(), error = ''
			WHERE alert_id = $1 AND recipient_key = $2`, a.ID, key); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to acknowledge alert")
			return
		}
		if err := s.Pool.QueryRow(r.Context(), `
			SELECT min(acknowledged_at) FROM alert_deliveries WHERE alert_id = $1 AND recipient_key = $2`,
			a.ID, key).Scan(&at); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to acknowledge alert")
			return
		}
		prior = &at
		s.Direct.AckAlertForUser(r.Context(), a.ID, claims.UserID)
		if s.hub != nil {
			if payload, err := json.Marshal(map[string]any{
				"type": "alert_ack", "alert_id": a.ID, "user_id": claims.UserID, "name": name, "acknowledged_at": at,
			}); err == nil {
				s.hub.sendToUser(a.UserID, payload)
			}
		}
		s.logAudit(r.Context(), claims.UserID, familyID, "alert.ack", "alert_id="+a.ID, clientIP(r))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"alert_id": a.ID, "state": stAcknowledged, "acknowledged_at": prior,
	})
}

// RevokeAlertShare turns off the alert's public location link immediately.
func (s *Server) RevokeAlertShare(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	a, ok := s.loadOwnAlert(w, r, claims.UserID)
	if !ok {
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `
		UPDATE alerts SET share_revoked_at = COALESCE(share_revoked_at, now()) WHERE id = $1 AND user_id = $2`,
		a.ID, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke link")
		return
	}
	s.logAudit(r.Context(), claims.UserID, a.FamilyID, "alert.share_revoked", "alert_id="+a.ID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"alert_id": a.ID, "share_revoked": true})
}

type alertListItem struct {
	ID         string     `json:"id"`
	Type       string     `json:"type"`
	Status     string     `json:"status"`
	UserID     string     `json:"user_id"`
	SenderName string     `json:"sender_name"`
	Lat        *float64   `json:"lat,omitempty"`
	Lon        *float64   `json:"lon,omitempty"`
	Note       string     `json:"note,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
}

const (
	defaultAlertPage = 20
	maxAlertPage     = 100
)

// ListAlerts returns the caller's family emergency history, newest first.
// `before` is the id of the last alert of the previous page. Coordinates are
// included only while an alert is active.
func (s *Server) ListAlerts(w http.ResponseWriter, r *http.Request) {
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
	limit := defaultAlertPage
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > maxAlertPage {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("limit must be 1-%d", maxAlertPage))
			return
		}
		limit = n
	}
	var before any
	if v := r.URL.Query().Get("before"); v != "" {
		before = v
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT a.id, a.type, a.status, a.user_id, u.name, a.lat, a.lon, COALESCE(a.note, ''), a.created_at, a.resolved_at
		FROM alerts a JOIN users u ON u.id = a.user_id
		WHERE a.family_id = $1
		  AND ($2::text IS NULL OR (a.created_at, a.id) < (
		        SELECT b.created_at, b.id FROM alerts b WHERE b.id::text = $2 AND b.family_id = $1))
		ORDER BY a.created_at DESC, a.id DESC
		LIMIT $3`, familyID, before, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list alerts")
		return
	}
	defer rows.Close()
	items := []alertListItem{}
	for rows.Next() {
		var it alertListItem
		if err := rows.Scan(&it.ID, &it.Type, &it.Status, &it.UserID, &it.SenderName, &it.Lat, &it.Lon, &it.Note, &it.CreatedAt, &it.ResolvedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to read alerts")
			return
		}
		if it.Status != alertStatusActive {
			it.Lat, it.Lon = nil, nil
		}
		items = append(items, it)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, "failed to read alerts")
		return
	}
	next := ""
	if len(items) > limit {
		items = items[:limit]
		next = items[limit-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"alerts": items, "next_before": next})
}
