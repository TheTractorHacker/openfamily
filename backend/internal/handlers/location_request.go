package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

const (
	locationRequestCommandTTL = 30 * time.Second
	locationRequestCooldown   = 2 * time.Minute

	// A member whose devices have not reported within this window is
	// considered quiet enough to justify one automatic refresh attempt.
	staleLocationThreshold = 10 * time.Minute

	// Minimum spacing between automatic refresh attempts for the same member.
	// Deliberately much longer than the user-facing cooldown: this watchdog is
	// a background convenience, not a polling loop, and each attempt costs a
	// push notification plus a GPS fix on the target's phone.
	staleRequestCooldown = 15 * time.Minute
)

type locationRequestState struct {
	id        string
	createdAt time.Time
}

type locationRequestDecision struct {
	state      locationRequestState
	status     string
	retryAfter time.Duration
}

// locationRequestGate is deliberately in-memory: the cooldown is a battery
// protection, not authorization state. A server restart may permit one extra
// request, while normal operation coalesces concurrent viewers and rapid taps.
type locationRequestGate struct {
	mu       sync.Mutex
	byUser   map[string]locationRequestState
	cooldown time.Duration
	ttl      time.Duration
}

func newLocationRequestGate(cooldown time.Duration) *locationRequestGate {
	return &locationRequestGate{
		byUser:   make(map[string]locationRequestState),
		cooldown: cooldown,
		ttl:      locationRequestCommandTTL,
	}
}

func (g *locationRequestGate) reserve(targetID, requestID string, now time.Time) locationRequestDecision {
	g.mu.Lock()
	defer g.mu.Unlock()

	if previous, ok := g.byUser[targetID]; ok {
		age := now.Sub(previous.createdAt)
		if age >= 0 && age < g.cooldown {
			status := "cooldown"
			if age < g.ttl {
				status = "coalesced"
			}
			return locationRequestDecision{
				state:      previous,
				status:     status,
				retryAfter: g.cooldown - age,
			}
		}
	}

	state := locationRequestState{id: requestID, createdAt: now}
	g.byUser[targetID] = state
	return locationRequestDecision{state: state, status: "queued"}
}

func (g *locationRequestGate) release(targetID, requestID string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if current, ok := g.byUser[targetID]; ok && current.id == requestID {
		delete(g.byUser, targetID)
	}
}

type locationRequestCommand struct {
	Type        string    `json:"type"`
	RequestID   string    `json:"request_id"`
	RequestedAt time.Time `json:"requested_at"`
	ExpiresAt   time.Time `json:"expires_at"`
}

// RequestMemberLocation asks a family member's device (Android via UnifiedPush,
// iOS via a silent APNs command) for one fresh fix.
// The command contains no location or requester information and expires after
// 30 seconds. The app still enforces its own sharing and permission settings.
func (s *Server) RequestMemberLocation(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	targetID := strings.TrimSpace(chi.URLParam(r, "id"))
	if targetID == "" {
		writeError(w, http.StatusBadRequest, "member id required")
		return
	}

	var isFamilyMember bool
	err := s.Pool.QueryRow(r.Context(), `
		SELECT EXISTS (
			SELECT 1
			FROM users requester
			JOIN users target ON target.id = $2
			WHERE requester.id = $1
			  AND requester.family_id IS NOT NULL
			  AND target.family_id = requester.family_id
		)`, claims.UserID, targetID).Scan(&isFamilyMember)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify family member")
		return
	}
	if !isFamilyMember {
		writeError(w, http.StatusNotFound, "family member not found")
		return
	}

	endpoints, err := s.androidPushEndpoints(r.Context(), targetID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member devices")
		return
	}
	iosTokens, err := s.iosPushTokens(r.Context(), targetID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load member devices")
		return
	}
	directIDs := s.directDeviceIDs(r.Context(), targetID)
	if (len(endpoints) == 0 && len(iosTokens) == 0 && len(directIDs) == 0) || s.Push == nil {
		writeError(w, http.StatusConflict, "member has no reachable device")
		return
	}
	now := time.Now().UTC()
	requestID, err := newLocationRequestID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create location request")
		return
	}
	gate := s.locationRequests
	if gate == nil {
		gate = newLocationRequestGate(locationRequestCooldown)
		s.locationRequests = gate
	}
	decision := gate.reserve(targetID, requestID, now)
	if decision.status != "queued" {
		writeJSON(w, http.StatusAccepted, map[string]any{
			"status":              decision.status,
			"request_id":          decision.state.id,
			"retry_after_seconds": max(1, int(decision.retryAfter.Round(time.Second)/time.Second)),
		})
		return
	}

	body, command, err := encodeLocationRequestCommand(requestID, now)
	if err != nil {
		gate.release(targetID, requestID)
		writeError(w, http.StatusInternalServerError, "failed to encode location request")
		return
	}

	if !s.dispatchLocationRequest(r.Context(), body, targetID) {
		gate.release(targetID, requestID)
		writeError(w, http.StatusBadGateway, "could not reach member device")
		return
	}

	// Audit every request that actually woke a device (BSEC-013): the family's
	// admins can see who asked for whom. The pushed command itself stays free
	// of requester information.
	if familyID, err := s.familyIDForUser(r.Context(), claims.UserID); err == nil {
		s.logAudit(r.Context(), claims.UserID, familyID, "family.location_request",
			"requested a fresh location from member "+targetID, clientIP(r))
	}

	writeJSON(w, http.StatusAccepted, map[string]any{
		"status":     "queued",
		"request_id": requestID,
		"expires_at": command.ExpiresAt,
	})
}

func newLocationRequestID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func encodeLocationRequestCommand(requestID string, now time.Time) ([]byte, locationRequestCommand, error) {
	command := locationRequestCommand{
		Type:        "location_request",
		RequestID:   requestID,
		RequestedAt: now,
		ExpiresAt:   now.Add(locationRequestCommandTTL),
	}
	body, err := json.Marshal(command)
	return body, command, err
}

// androidPushEndpoints lists the registered UnifiedPush endpoints for a
// member's Android devices, newest-seen first.
func (s *Server) androidPushEndpoints(ctx context.Context, userID string) ([]string, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT unifiedpush_endpoint
		FROM devices
		WHERE user_id = $1
		  AND platform = 'android'
		  AND unifiedpush_endpoint IS NOT NULL
		  AND unifiedpush_endpoint <> ''
		ORDER BY last_seen DESC NULLS LAST, created_at DESC
		LIMIT 1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var endpoints []string
	for rows.Next() {
		var endpoint string
		if err := rows.Scan(&endpoint); err != nil {
			return nil, err
		}
		endpoints = append(endpoints, endpoint)
	}
	return endpoints, rows.Err()
}

// iosPushTokens lists the registered APNs device tokens for a member's iOS
// devices (mirrors [androidPushEndpoints]).
func (s *Server) iosPushTokens(ctx context.Context, userID string) ([]string, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT push_token
		FROM devices
		WHERE user_id = $1
		  AND platform = 'ios'
		  AND push_token IS NOT NULL
		  AND push_token <> ''
		ORDER BY last_seen DESC NULLS LAST, created_at DESC
		LIMIT 1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var tokens []string
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, err
		}
		tokens = append(tokens, token)
	}
	return tokens, rows.Err()
}

// dispatchLocationRequest delivers one location-refresh command to a member's
// devices: Android (UnifiedPush, message body = command JSON, unchanged wire
// shape) first, then iOS (silent content-available APNs payload that is
// executed in the background — never shown as an alert). Returns true when at
// least one transport accepted the request.
func (s *Server) dispatchLocationRequest(parent context.Context, body []byte, userID string) bool {
	// Built-in direct channel first: a live stream delivers immediately. A
	// device that is not connected still gets the command queued (short TTL),
	// and the other transports below are tried too.
	queuedDirect := false
	for _, id := range s.directDeviceIDs(parent, userID) {
		dispatchCtx, cancel := context.WithTimeout(parent, 12*time.Second)
		err := s.Push.Dispatch(dispatchCtx, directNotification(push.Notification{
			Title: "OpenFamily location refresh", Body: string(body), Silent: true, Platform: "android",
		}, id, userID, "", ""))
		cancel()
		if err == nil {
			queuedDirect = true
			if s.Direct.IsConnected(id) {
				return true
			}
		}
	}
	endpoints, err := s.androidPushEndpoints(parent, userID)
	if err != nil {
		slog.Warn("location request: load android endpoints", "err", err)
	}
	for _, endpoint := range endpoints {
		dispatchCtx, cancel := context.WithTimeout(parent, 12*time.Second)
		err := s.Push.Dispatch(dispatchCtx, push.Notification{
			Title:               "OpenFamily location refresh",
			Body:                string(body),
			Platform:            "android",
			UnifiedPushEndpoint: endpoint,
		})
		cancel()
		if err == nil {
			return true
		}
	}
	tokens, err := s.iosPushTokens(parent, userID)
	if err != nil {
		slog.Warn("location request: load ios tokens", "err", err)
	}
	for _, token := range tokens {
		dispatchCtx, cancel := context.WithTimeout(parent, 12*time.Second)
		err := s.Push.Dispatch(dispatchCtx, push.Notification{
			Title:     "OpenFamily location refresh",
			Body:      string(body),
			Silent:    true,
			Platform:  "ios",
			PushToken: token,
		})
		cancel()
		if err == nil {
			return true
		}
	}
	return queuedDirect
}

// staleRequestGate rate-limits automatic refresh attempts per member. Unlike
// [locationRequestGate] there is no request id or coalescing: it is purely a
// per-member cooldown with opportunistic pruning of expired entries.
type staleRequestGate struct {
	mu       sync.Mutex
	lastSent map[string]time.Time
	cooldown time.Duration
}

func newStaleRequestGate(cooldown time.Duration) *staleRequestGate {
	return &staleRequestGate{
		lastSent: make(map[string]time.Time),
		cooldown: cooldown,
	}
}

// reserve returns true if an automatic refresh may be sent for targetID now.
func (g *staleRequestGate) reserve(targetID string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()

	if last, ok := g.lastSent[targetID]; ok && now.Sub(last) < g.cooldown {
		return false
	}
	if len(g.lastSent) > 1024 {
		// Opportunistic pruning so long uptimes cannot grow the map without
		// bound; members that went quiet long ago re-qualify normally.
		for id, t := range g.lastSent {
			if now.Sub(t) >= g.cooldown {
				delete(g.lastSent, id)
			}
		}
	}
	g.lastSent[targetID] = now
	return true
}

// MaybeRequestStaleLocations inspects a freshly built family snapshot and asks
// quiet members' phones for one fresh fix each. This is what lets a viewer who
// simply opens the family map converge on current positions without tapping
// anything: stale pins trigger at most one push per member per watchdog
// cooldown, and the resulting fix arrives over the normal ingest path.
//
// Runs entirely in the background; failures are logged, never surfaced — the
// snapshot response must not depend on push delivery.
func (s *Server) MaybeRequestStaleLocations(familyID string, members []wsMember) {
	if s.Push == nil || s.Pool == nil {
		return
	}
	now := time.Now().UTC()
	watchdog := s.staleWatchdog
	if watchdog == nil {
		watchdog = newStaleRequestGate(staleRequestCooldown)
		s.staleWatchdog = watchdog
	}

	for _, m := range members {
		if m.LastSeenAt == nil || now.Sub(*m.LastSeenAt) < staleLocationThreshold {
			continue
		}
		target := m.ID
		if !watchdog.reserve(target, now) {
			continue
		}

		go func(target string) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			requestID, err := newLocationRequestID()
			if err != nil {
				return
			}
			body, _, err := encodeLocationRequestCommand(requestID, time.Now().UTC())
			if err != nil {
				return
			}
			if s.dispatchLocationRequest(ctx, body, target) {
				slog.Info("stale-member refresh requested",
					"family_id", familyID, "user_id", target)
				return
			}
			slog.Warn("stale-member refresh could not be delivered", "user_id", target)
		}(target)
	}
}
