package handlers

// Built-in "direct" push channel: server side of the stream the app keeps open
// (see internal/push/direct.go for the queueing design and docs/push.md).

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

const (
	pushStreamConnectsPerUser = 30 // connect attempts per window, per user
	pushStreamConnectWindow   = time.Minute
	pushAckBatchMax           = 50
	pushStreamBatch           = 20
	pushWriteTimeout          = 15 * time.Second
)

// Stream timing. Variables so tests can shrink them.
var (
	// pushHeartbeatInterval keeps NATs and proxies from dropping an idle
	// connection. Long on purpose: each heartbeat wakes the phone's radio.
	pushHeartbeatInterval = 55 * time.Second
	// pushRevalidateInterval is how often the server rechecks credentials.
	// It is server-side work only, nothing is sent to the phone.
	pushRevalidateInterval = 20 * time.Second
)

// validatePushTransport checks a requested push_transport value.
func (s *Server) validatePushTransport(platform, transport string) string {
	switch transport {
	case "":
		return ""
	case "direct":
		if platform != "android" {
			return "push_transport direct is only available on android"
		}
		if s.Direct == nil {
			return "direct push is disabled on this server"
		}
		return ""
	}
	return "push_transport must be empty or direct"
}

// dispatchBest delivers n over the best transport for the device. A direct
// notification is always queued (so it survives a dropped connection) and,
// when the device has no live stream and also registered a UnifiedPush
// endpoint, additionally sent there as a fallback. The app dedupes on the
// shared alert id. Returns nil when at least one transport accepted it.
func (s *Server) dispatchBest(ctx context.Context, n push.Notification) error {
	if !n.Direct {
		return s.dispatchWithRetry(ctx, n)
	}
	err := s.dispatchWithRetry(ctx, n)
	if n.UnifiedPushEndpoint != "" && !s.Direct.IsConnected(n.DeviceID) {
		up := n
		up.Direct = false
		if e2 := s.dispatchWithRetry(ctx, up); e2 == nil {
			err = nil
		} else if err != nil && !push.IsPermanent(e2) {
			err = e2
		}
	}
	return err
}

// directNotification adapts n for a device that declared the direct transport.
func directNotification(n push.Notification, deviceID, userID, alertID, dedupeID string) push.Notification {
	n.Direct = true
	n.DeviceID = deviceID
	n.UserID = userID
	n.AlertID = alertID
	n.DedupeID = dedupeID
	return n
}

// directDeviceIDs lists a user's android devices on the direct transport.
func (s *Server) directDeviceIDs(ctx context.Context, userID string) []string {
	if s.Direct == nil {
		return nil
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT id FROM devices
		WHERE user_id = $1 AND platform = 'android' AND push_transport = 'direct'
		ORDER BY last_seen DESC NULLS LAST, created_at DESC`, userID)
	if err != nil {
		slog.Warn("direct push: list devices", "err", err)
		return nil
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return ids
}

// RunPushJanitor expires stale outbox rows until ctx ends, recording a failed
// delivery for alert-linked events that were never delivered.
func (s *Server) RunPushJanitor(ctx context.Context) {
	if s.Direct == nil {
		return
	}
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		s.expirePushOutbox(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) expirePushOutbox(ctx context.Context) {
	evs, err := s.Direct.ExpireDue(ctx)
	if err != nil {
		slog.Warn("direct push: expire", "err", err)
		return
	}
	for _, e := range evs {
		if e.AlertID != "" {
			s.recordDelivery(ctx, e.AlertID, e.UserID, "", "", chanPush, stFailed, "expired")
		}
	}
}

// pushIdentity resolves who is calling a push endpoint and which device. A
// device key pins the device; a bearer token must name it with ?device_id=
// (stream) or "device_id" (ack) and own it.
func (s *Server) pushDevice(w http.ResponseWriter, r *http.Request, named string) (userID, deviceID string, ok bool) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", "", false
	}
	deviceID = middleware.DeviceIDFromContext(r.Context())
	if deviceID == "" {
		deviceID = named
	}
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return "", "", false
	}
	var owner string
	err := s.Pool.QueryRow(r.Context(), `SELECT user_id FROM devices WHERE id::text = $1`, deviceID).Scan(&owner)
	if err != nil || owner != claims.UserID {
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusInternalServerError, "failed to load device")
			return "", "", false
		}
		writeError(w, http.StatusNotFound, "device not found")
		return "", "", false
	}
	return claims.UserID, deviceID, true
}

// pushCredentialValid re-checks, mid-stream, that the credentials the stream
// was opened with are still good: device exists, token version unchanged
// (bearer) or ingest key still present, matching and unexpired (device key).
func (s *Server) pushCredentialValid(ctx context.Context, userID, deviceID string, bearerVersion *int, bearerExp *time.Time, presentedKey string) bool {
	var version int
	var keyHash *string
	var keyExp *time.Time
	err := s.Pool.QueryRow(ctx, `
		SELECT u.token_version, d.ingest_key_hash, d.ingest_key_expires_at
		FROM devices d JOIN users u ON u.id = d.user_id
		WHERE d.id::text = $1 AND d.user_id::text = $2`, deviceID, userID).Scan(&version, &keyHash, &keyExp)
	if err != nil {
		// A transient DB error must not drop a healthy stream; "no rows" does.
		return !errors.Is(err, pgx.ErrNoRows)
	}
	now := time.Now()
	if bearerVersion != nil {
		if version != *bearerVersion || (bearerExp != nil && !now.Before(*bearerExp)) {
			return false
		}
		return true
	}
	if keyHash == nil || (keyExp != nil && !now.Before(*keyExp)) {
		return false
	}
	cand := middleware.EncodeIngestKeyHash(middleware.HashDeviceIngestKey(presentedKey))
	return subtle.ConstantTimeCompare([]byte(*keyHash), []byte(cand)) == 1
}

// PushStream serves GET /push/stream: a Server-Sent Events stream of the
// device's queued push events. Auth: device ingest key (X-Device-Key) or a
// bearer token plus ?device_id=. Frames:
//
//	event: hello   one at start, with heartbeat/keepalive hints
//	event: push    {"v":1,"id":...,"kind":...,"title":...,...}; the app acks the id
//	: hb           comment heartbeat
//	event: bye     the server is closing (revoked / replaced / token expired)
func (s *Server) PushStream(w http.ResponseWriter, r *http.Request) {
	if s.Direct == nil {
		writeError(w, http.StatusNotFound, "direct push is disabled")
		return
	}
	userID, deviceID, ok := s.pushDevice(w, r, r.URL.Query().Get("device_id"))
	if !ok {
		return
	}
	if !s.allowKey(w, "pushstream:user:"+userID, pushStreamConnectsPerUser, pushStreamConnectWindow) {
		return
	}
	rc := http.NewResponseController(w)
	if _, ok := w.(http.Flusher); !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	// Remember how this stream authenticated, to revalidate it later.
	claims := middleware.ClaimsFromContext(r.Context())
	var bearerVersion *int
	var bearerExp *time.Time
	var presentedKey string
	if middleware.DeviceIDFromContext(r.Context()) == "" {
		v := claims.TokenVersion
		bearerVersion = &v
		if claims.ExpiresAt != nil {
			t := claims.ExpiresAt.Time
			bearerExp = &t
		}
	} else if _, k, ok := middleware.ParseDeviceKeyHeader(r.Header.Get(middleware.DeviceKeyHeader)); ok {
		presentedKey = k
	}

	conn, err := s.Direct.Connect(userID, deviceID)
	if err != nil {
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, "too many direct push connections")
		return
	}
	defer conn.Close()

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	_ = rc.SetReadDeadline(time.Time{})

	write := func(frame string) bool {
		_ = rc.SetWriteDeadline(time.Now().Add(pushWriteTimeout))
		if _, err := fmt.Fprint(w, frame); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	hello, _ := json.Marshal(map[string]any{
		"device_id":      deviceID,
		"heartbeat_secs": int(pushHeartbeatInterval / time.Second),
	})
	if !write("retry: 5000\nevent: hello\ndata: " + string(hello) + "\n\n") {
		return
	}

	ctx := r.Context()
	s.Direct.TouchSeen(ctx, deviceID)
	s.expirePushOutbox(ctx)

	sentOnConn := map[string]bool{}
	flush := func() bool {
		for {
			evs, err := s.Direct.Pending(ctx, deviceID, pushStreamBatch+len(sentOnConn))
			if err != nil {
				slog.Warn("direct push: pending", "err", err)
				return true
			}
			progressed := false
			for _, e := range evs {
				if sentOnConn[e.DedupeID] {
					continue
				}
				if !write("id: " + e.DedupeID + "\nevent: push\ndata: " + string(e.Payload) + "\n\n") {
					return false
				}
				sentOnConn[e.DedupeID] = true
				progressed = true
				_ = s.Direct.MarkSent(ctx, e.ID)
				if e.AlertID != "" {
					s.recordDelivery(ctx, e.AlertID, e.UserID, "", "", chanPush, stSent, "")
				}
			}
			if !progressed {
				return true
			}
			if len(sentOnConn) > 500 {
				sentOnConn = map[string]bool{}
			}
		}
	}
	if !flush() {
		return
	}

	hb := time.NewTicker(pushHeartbeatInterval)
	defer hb.Stop()
	rv := time.NewTicker(pushRevalidateInterval)
	defer rv.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-conn.Done():
			reason := "closed"
			if conn.Replaced() {
				reason = "replaced"
			}
			write("event: bye\ndata: {\"reason\":\"" + reason + "\"}\n\n")
			return
		case <-conn.Wake():
			if !flush() {
				return
			}
		case <-hb.C:
			if !write(": hb\n\n") {
				return
			}
			s.Direct.TouchSeen(ctx, deviceID)
		case <-rv.C:
			if !s.pushCredentialValid(ctx, userID, deviceID, bearerVersion, bearerExp, presentedKey) {
				write("event: bye\ndata: {\"reason\":\"revoked\"}\n\n")
				return
			}
		}
	}
}

// AckPush handles POST /push/ack {"device_id":..., "ids":[...]}: the device
// confirms it received (and showed) events. Delivery state becomes "delivered";
// the existing /alerts/{id}/ack still records that a person read it.
func (s *Server) AckPush(w http.ResponseWriter, r *http.Request) {
	if s.Direct == nil {
		writeError(w, http.StatusNotFound, "direct push is disabled")
		return
	}
	var req struct {
		DeviceID string   `json:"device_id"`
		IDs      []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.IDs) == 0 || len(req.IDs) > pushAckBatchMax {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("ids must contain 1-%d entries", pushAckBatchMax))
		return
	}
	for _, id := range req.IDs {
		if id == "" || len(id) > 100 || strings.ContainsAny(id, " \n") {
			writeError(w, http.StatusBadRequest, "invalid id")
			return
		}
	}
	_, deviceID, ok := s.pushDevice(w, r, req.DeviceID)
	if !ok {
		return
	}
	evs, err := s.Direct.Ack(r.Context(), deviceID, req.IDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to acknowledge")
		return
	}
	for _, e := range evs {
		if e.AlertID != "" {
			s.recordDelivery(r.Context(), e.AlertID, e.UserID, "", "", chanPush, stDelivered, "")
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// withDirectTransport upgrades a geofence notification for a device that
// declared the direct transport (queued in its outbox, with the UnifiedPush
// endpoint, if any, kept as a fallback). The dedupe id ties re-dispatches of
// the same event to the same outbox row.
func (s *Server) withDirectTransport(n push.Notification, ok bool, transport, deviceID, recipientID, eventID string) (push.Notification, bool) {
	if s.Direct == nil || transport != "direct" || n.Platform != "android" {
		return n, ok
	}
	return directNotification(n, deviceID, recipientID, "", "geofence:"+eventID), true
}
