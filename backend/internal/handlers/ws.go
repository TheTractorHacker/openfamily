package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/models"
)

// wsMember is a family member in the members snapshot, joined to their latest
// location (if any).
type wsMember struct {
	ID              string      `json:"id"`
	Name            string      `json:"name"`
	Email           *string     `json:"email"`
	Role            models.Role `json:"role"`
	HasAvatar       bool        `json:"has_avatar"`
	AvatarVersion   int64       `json:"avatar_version"`
	AvatarUpdatedAt *time.Time  `json:"avatar_updated_at"`
	Lat             *float64    `json:"lat"`
	Lon             *float64    `json:"lon"`
	TS              *time.Time  `json:"ts"`
	BatteryPct      *float64    `json:"battery_pct"`
	SpeedMPS        *float64    `json:"speed_mps"`
	MotionState     *string     `json:"motion_state"`
	AccuracyMeters  *float64    `json:"accuracy_meters"`
	// LastSeenAt is the most recent device heartbeat/ingest time across all of
	// the member's devices. It can be newer than TS (the last stored
	// position's timestamp) when the member is stationary and only heartbeats
	// are arriving; clients use it to keep "last seen" fresh without moving
	// the pin.
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
}

// wsLocation is a live location update broadcast to a family.
type wsLocation struct {
	Type           string    `json:"type"`
	UserID         string    `json:"user_id"`
	Lat            float64   `json:"lat"`
	Lon            float64   `json:"lon"`
	TS             time.Time `json:"ts"`
	LastSeenAt     time.Time `json:"last_seen_at"`
	BatteryPct     *float64  `json:"battery_pct"`
	SpeedMPS       *float64  `json:"speed_mps"`
	MotionState    *string   `json:"motion_state"`
	AccuracyMeters *float64  `json:"accuracy_meters"`
}

// wsPresence is a liveness announcement broadcast when a device reports but its
// position has not changed enough to store a new location row (stationary
// dedup), or when it sends a bare heartbeat. It lets family clients refresh the
// member's "last seen" freshness without moving their pin or growing the
// locations table.
type wsPresence struct {
	Type       string    `json:"type"`
	UserID     string    `json:"user_id"`
	TS         time.Time `json:"ts"`
	BatteryPct *float64  `json:"battery_pct,omitempty"`
}

// wsAvatarUpdate tells already-connected clients to fetch or clear a changed
// member photo. The bytes are deliberately not embedded in WebSocket frames.
type wsAvatarUpdate struct {
	Type            string     `json:"type"`
	UserID          string     `json:"user_id"`
	HasAvatar       bool       `json:"has_avatar"`
	AvatarVersion   int64      `json:"avatar_version"`
	AvatarUpdatedAt *time.Time `json:"avatar_updated_at"`
}

// Stream serves the live WebSocket stream at /ws/stream. It authenticates the
// caller, registers the connection in the family hub, sends a welcome frame
// and a members snapshot, then fans out live location updates to every
// connected member of the family.
func (s *Server) Stream(w http.ResponseWriter, r *http.Request) {
	// Authenticate via Bearer token in the Authorization header, or via the
	// Sec-WebSocket-Protocol header (browsers cannot set the Authorization
	// header on WebSocket upgrades, but can set a subprotocol). The token is
	// never carried in the URL query string, which would leak it into access
	// logs and referrer headers.
	token := bearerToken(r)
	subprotocol := ""
	if token == "" {
		token, subprotocol = websocketSubprotocolToken(r)
	}
	claims, err := s.TM.Parse(token, auth.AccessToken)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if !s.tokenVersionMatches(r.Context(), claims.UserID, claims.TokenVersion) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Resolve the caller's current family from the database (the JWT family
	// claim can go stale when a user joins or creates a family).
	familyID, err := s.familyIDForUser(r.Context(), claims.UserID)
	if err != nil {
		http.Error(w, "failed to load family", http.StatusInternalServerError)
		return
	}
	if familyID == "" {
		http.Error(w, "no family", http.StatusNotFound)
		return
	}

	opts := &websocket.AcceptOptions{
		// Restrict cross-origin connections to the configured origin (or none,
		// i.e. same-origin only) instead of allowing any origin.
		OriginPatterns: s.wsOriginPatterns(),
	}
	if subprotocol != "" {
		// Echo the subprotocol back so the client's handshake succeeds.
		opts.Subprotocols = []string{subprotocol}
	}
	conn, err := websocket.Accept(w, r, opts)
	if err != nil {
		slog.Warn("websocket accept failed", "err", err)
		return
	}

	ctx := r.Context()
	conn.SetReadLimit(4096)

	c := &wsClient{
		conn: conn,
		send: make(chan []byte, clientSendBuffer),
		done: make(chan struct{}),
	}
	s.hub.register(familyID, claims.UserID, c)
	go s.hub.watch(c, wsRevalidateInterval, func(ctx context.Context) (bool, error) {
		return s.familyStreamAuthorized(ctx, claims.UserID, claims.TokenVersion, familyID)
	})
	defer func() {
		s.hub.unregister(familyID, c)
		c.close()
	}()

	// Welcome frame confirms the authenticated identity.
	welcome, err := json.Marshal(map[string]string{"type": "welcome", "user_id": claims.UserID})
	if err != nil {
		return
	}
	if err := conn.Write(ctx, websocket.MessageText, welcome); err != nil {
		return
	}

	// Members snapshot: full family member list with each member's latest
	// location. Sent once, after welcome, before any live updates.
	members, err := s.familyMembersSnapshot(ctx, familyID, claims.UserID)
	if err != nil {
		slog.Warn("members snapshot failed", "err", err, "user_id", claims.UserID)
		return
	}
	snapshot, err := json.Marshal(map[string]any{"type": "members", "members": members})
	if err != nil {
		slog.Warn("members snapshot marshal failed", "err", err)
		return
	}
	if err := conn.Write(ctx, websocket.MessageText, snapshot); err != nil {
		return
	}

	// A viewer just looked at this family: opportunistically ask any member
	// whose devices have gone quiet for one fresh fix (rate-limited per member
	// inside MaybeRequestStaleLocations). Runs in the background; never blocks
	// or fails the stream.
	s.MaybeRequestStaleLocations(familyID, members)

	// Start the writer goroutine only after the welcome and snapshot frames
	// are written, so there is a single writer at any time (coder/websocket
	// permits one concurrent writer). Broadcasts queued in the meantime are
	// buffered and drained once the writer starts.
	go c.writeLoop(ctx)

	// Read loop: answer the client's app-level ping frames ("pongs") and
	// discard everything else, while keeping the connection alive. The client
	// pings on a fixed cadence both as a liveness probe and to feed its
	// inbound-activity watchdog — without a pong that watchdog tears down a
	// silently dead (half-open) socket and reconnects. Protocol-level pings
	// (including the ones writeLoop originates every 30s) are answered
	// automatically by coder/websocket and never surface here. On disconnect
	// or error the deferred cleanup unregisters the client and closes it.
	for {
		msgType, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if msgType != websocket.MessageText {
			continue
		}
		var frame struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &frame); err != nil || frame.Type != "ping" {
			continue
		}
		pong, err := json.Marshal(map[string]string{"type": "pong"})
		if err != nil {
			continue
		}
		// Queue through the single-writer send channel (coder/websocket
		// allows only one concurrent writer, and writeLoop owns the socket
		// writes). Never block: a full buffer already marks this client as a
		// slow consumer, and the client's watchdog interprets any silent gap
		// as a dead connection on its own.
		select {
		case c.send <- pong:
		default:
		}
	}
}

// familyStreamAuthorized re-checks, against the database, that the socket
// owner still exists, still holds the token version the socket was opened
// with (logout / password change bump it) and is still in the family the
// socket is registered under.
func (s *Server) familyStreamAuthorized(ctx context.Context, userID string, version int, familyID string) (bool, error) {
	var current int
	var fid *string
	err := s.Pool.QueryRow(ctx,
		`SELECT token_version, family_id FROM users WHERE id = $1`, userID,
	).Scan(&current, &fid)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return current == version && fid != nil && *fid == familyID, nil
}

// familyMembersSnapshot returns every member of the family joined to their
// last-known position (users -> member_positions). A member with no position
// has null lat/lon/ts. Children (role != admin/member) do not see any email
// addresses, matching ListMembers.
func (s *Server) familyMembersSnapshot(ctx context.Context, familyID, callerID string) ([]wsMember, error) {
	canManage, err := s.userCanManage(ctx, callerID)
	if err != nil {
		return nil, err
	}

	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, u.name, u.role,
		       u.avatar_data IS NOT NULL, u.avatar_version, u.avatar_updated_at,
		       mp.lat, mp.lon, mp.ts, mp.battery_pct, mp.speed_mps, mp.motion_state, mp.accuracy_meters,
		       d.last_seen
		FROM users u
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		LEFT JOIN (
			SELECT user_id, MAX(last_seen) AS last_seen
			FROM devices GROUP BY user_id
		) d ON d.user_id = u.id
		WHERE u.family_id = $1
		ORDER BY u.name`, familyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	members := []wsMember{}
	for rows.Next() {
		var (
			id, email, name string
			role            models.Role
			hasAvatar       bool
			avatarVersion   int64
			avatarUpdatedAt *time.Time
			lat, lon        *float64
			ts              *time.Time
			battery, speed  *float64
			motion          *string
			accuracy        *float64
			lastSeenAt      *time.Time
		)
		if err := rows.Scan(&id, &email, &name, &role, &hasAvatar, &avatarVersion, &avatarUpdatedAt,
			&lat, &lon, &ts, &battery, &speed, &motion, &accuracy, &lastSeenAt); err != nil {
			return nil, err
		}
		m := wsMember{
			ID:              id,
			Name:            name,
			Role:            role,
			HasAvatar:       hasAvatar,
			AvatarVersion:   avatarVersion,
			AvatarUpdatedAt: avatarUpdatedAt,
			Lat:             lat,
			Lon:             lon,
			TS:              ts,
			BatteryPct:      battery,
			SpeedMPS:        speed,
			MotionState:     motion,
			AccuracyMeters:  accuracy,
			LastSeenAt:      lastSeenAt,
		}
		// Redact email for non-manager (child) viewers, matching ListMembers.
		if canManage {
			m.Email = &email
		}
		members = append(members, m)
	}
	if rows.Err() != nil {
		return nil, rows.Err()
	}
	return members, nil
}

// broadcastLocation fans out a live location update to the owner's family AND
// to any connected platform admin clients (who see updates across ALL
// families). It resolves the family ID and broadcasts under a background
// context so a client disconnect cannot cancel the broadcast. Callers should
// invoke it in a goroutine so the ingest ack is not delayed.
func (s *Server) broadcastLocation(ownerID string, loc wsLocation) {
	// Skip the family lookup entirely when nobody is listening — neither family
	// nor admin clients — so idle ingests don't hit the database.
	if !s.hub.hasAny() && !s.hub.hasAdminClients() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	familyID, err := s.familyIDForUser(ctx, ownerID)
	if err != nil {
		slog.Warn("location broadcast: resolve family failed", "err", err, "user_id", ownerID)
		return
	}
	msg, err := json.Marshal(loc)
	if err != nil {
		slog.Warn("location broadcast: marshal failed", "err", err)
		return
	}
	// Family-scoped clients (unchanged behavior).
	if familyID != "" {
		s.hub.broadcast(familyID, msg)
	}
	// Platform admin clients see every live update regardless of family.
	s.hub.broadcastAdmin(msg)
}

// broadcastPresence fans out a liveness announcement (no position change) to
// the owner's family and to connected platform admin clients. Like
// broadcastLocation, it resolves the family under a background context so a
// client disconnect cannot cancel the broadcast; callers should invoke it in a
// goroutine.
func (s *Server) broadcastPresence(ownerID string, ts time.Time, batteryPct *float64) {
	// Nobody listening: skip the family lookup entirely, matching
	// broadcastLocation's idle fast path.
	if !s.hub.hasAny() && !s.hub.hasAdminClients() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	familyID, err := s.familyIDForUser(ctx, ownerID)
	if err != nil {
		slog.Warn("presence broadcast: resolve family failed", "err", err, "user_id", ownerID)
		return
	}
	msg, err := json.Marshal(wsPresence{
		Type:       "presence",
		UserID:     ownerID,
		TS:         ts,
		BatteryPct: batteryPct,
	})
	if err != nil {
		slog.Warn("presence broadcast: marshal failed", "err", err)
		return
	}
	if familyID != "" {
		s.hub.broadcast(familyID, msg)
	}
	s.hub.broadcastAdmin(msg)
}

// broadcastAvatarUpdate fans out profile-photo metadata to the photo owner's
// family and to platform admins. Each recipient fetches protected bytes via an
// authenticated HTTP endpoint; no image bytes or URLs travel over the stream.
func (s *Server) broadcastAvatarUpdate(familyID *string, userID string, hasAvatar bool, avatarVersion int64, avatarUpdatedAt *time.Time) {
	if !s.hub.hasAny() && !s.hub.hasAdminClients() {
		return
	}
	msg, err := json.Marshal(wsAvatarUpdate{
		Type:            "avatar",
		UserID:          userID,
		HasAvatar:       hasAvatar,
		AvatarVersion:   avatarVersion,
		AvatarUpdatedAt: avatarUpdatedAt,
	})
	if err != nil {
		slog.Warn("avatar broadcast: marshal failed", "err", err, "user_id", userID)
		return
	}
	if familyID != nil && *familyID != "" {
		s.hub.broadcast(*familyID, msg)
	}
	s.hub.broadcastAdmin(msg)
}

// wsOriginPatterns returns the WebSocket origin allow-list. When no origin is
// configured it returns nil, so the coder/websocket default applies (only
// same-origin requests are accepted); otherwise it allows the configured
// origin.
func (s *Server) wsOriginPatterns() []string {
	if s.AllowedOrigin == "" {
		return nil
	}
	return []string{s.AllowedOrigin}
}

// websocketSubprotocolToken extracts the access token carried in the
// Sec-WebSocket-Protocol header. It returns the token and the subprotocol to
// echo back to the client (empty when the header is absent).
func websocketSubprotocolToken(r *http.Request) (token, subprotocol string) {
	h := r.Header.Get("Sec-WebSocket-Protocol")
	if h == "" {
		return "", ""
	}
	// The client sends the token as the first subprotocol.
	parts := strings.Split(h, ",")
	if len(parts) == 0 {
		return "", ""
	}
	subprotocol = strings.TrimSpace(parts[0])
	return subprotocol, subprotocol
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && h[:7] == "Bearer " {
		return h[7:]
	}
	return ""
}
