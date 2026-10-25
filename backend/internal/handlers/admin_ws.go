package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/wheresfrank/openfamily/backend/internal/auth"
	"github.com/wheresfrank/openfamily/backend/internal/models"
)

// adminWsMember is a family member in the platform-admin members snapshot,
// joined to their latest location and tagged with family_id + family_name so
// the admin map can render every group at once. It embeds the family-stream
// wsMember shape and adds the family tags.
type adminWsMember struct {
	wsMember
	FamilyID   *string `json:"family_id,omitempty"`
	FamilyName *string `json:"family_name,omitempty"`
}

// AdminStream serves the platform-admin live WebSocket stream at /api/admin/ws.
// Unlike the family-scoped /ws/stream, an admin client receives live location
// updates across ALL families.
//
// Authentication mirrors /ws/stream exactly: the access token is read from the
// Authorization Bearer header, or — for browsers that cannot set that header on
// a WebSocket upgrade — from the Sec-WebSocket-Protocol subprotocol. The token
// is never carried in the query string. The platform-admin gate is then checked
// against the database (platform_admin = TRUE).
//
// This route is registered at the top level (like /ws/stream) rather than under
// the RequireAuth/RequirePlatformAdmin HTTP middleware, because the middleware
// cannot see the subprotocol carrier — the same reason /ws/stream authenticates
// manually. The handler enforces both checks itself, so the privilege boundary
// is equivalent to "behind RequireAuth + RequirePlatformAdmin".
func (s *Server) AdminStream(w http.ResponseWriter, r *http.Request) {
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

	// Platform admin gate (re-read from the DB, never trust the JWT).
	var platformAdmin bool
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT platform_admin FROM users WHERE id = $1`, claims.UserID,
	).Scan(&platformAdmin); err != nil {
		http.Error(w, "failed to verify platform admin", http.StatusInternalServerError)
		return
	}
	if !platformAdmin {
		http.Error(w, "platform admin required", http.StatusForbidden)
		return
	}

	opts := &websocket.AcceptOptions{OriginPatterns: s.wsOriginPatterns()}
	if subprotocol != "" {
		// Echo the subprotocol back so the client's handshake succeeds.
		opts.Subprotocols = []string{subprotocol}
	}
	conn, err := websocket.Accept(w, r, opts)
	if err != nil {
		slog.Warn("admin websocket accept failed", "err", err)
		return
	}

	ctx := r.Context()
	conn.SetReadLimit(4096)

	c := &wsClient{
		conn: conn,
		send: make(chan []byte, clientSendBuffer),
		done: make(chan struct{}),
	}
	c.userID = claims.UserID
	s.auditAdminView(r.Context(), claims.UserID, "", "opened live location stream for all families", clientIP(r))
	s.hub.registerAdmin(c)
	go s.hub.watch(c, wsRevalidateInterval, func(ctx context.Context) (bool, error) {
		return s.adminStreamAuthorized(ctx, claims.UserID, claims.TokenVersion)
	})
	defer func() {
		s.hub.unregisterAdmin(c)
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

	// All-members snapshot: every member across all families, each tagged with
	// family_id + family_name + last-known location. Sent once, after welcome,
	// before any live updates. Reuses the same users -> member_positions JOIN
	// shape as AdminListMembers.
	members, err := s.adminMembersSnapshot(ctx)
	if err != nil {
		slog.Warn("admin members snapshot failed", "err", err, "user_id", claims.UserID)
		return
	}
	snapshot, err := json.Marshal(map[string]any{"type": "members", "members": members})
	if err != nil {
		slog.Warn("admin members snapshot marshal failed", "err", err)
		return
	}
	if err := conn.Write(ctx, websocket.MessageText, snapshot); err != nil {
		return
	}

	// Writer goroutine (heartbeat + drain), started only after the welcome and
	// snapshot frames so there is a single writer at any time.
	go c.writeLoop(ctx)

	// Read loop: discard inbound frames but keep the connection alive. On
	// disconnect or error the deferred cleanup unregisters the client and
	// closes it.
	for {
		if _, _, err := conn.Read(ctx); err != nil {
			return
		}
	}
}

// adminStreamAuthorized re-checks, against the database, that the admin
// socket owner still exists, still holds the token version the socket was
// opened with, and is still a platform admin.
func (s *Server) adminStreamAuthorized(ctx context.Context, userID string, version int) (bool, error) {
	var current int
	var platformAdmin bool
	err := s.Pool.QueryRow(ctx,
		`SELECT token_version, platform_admin FROM users WHERE id = $1`, userID,
	).Scan(&current, &platformAdmin)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return current == version && platformAdmin, nil
}

// adminMembersSnapshot returns every member across every family, each joined to
// their last-known position (users -> member_positions), their most recent
// device heartbeat/ingest time (devices.last_seen, exposed as last_seen_at so
// clients keep "last seen" fresh while only heartbeats arrive), and tagged with
// family_id + family_name. A member with no position has null lat/lon/ts; a
// member with no family has null family_id/family_name. Unlike the
// family-scoped snapshot, emails are NOT redacted (platform admin sees all),
// matching AdminListMembers.
func (s *Server) adminMembersSnapshot(ctx context.Context) ([]adminWsMember, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, u.name, u.role,
		       u.avatar_data IS NOT NULL, u.avatar_version, u.avatar_updated_at,
		       mp.lat, mp.lon, mp.ts, mp.battery_pct, mp.speed_mps, mp.motion_state, mp.accuracy_meters,
		       d.last_seen,
		       u.family_id, f.name
		FROM users u
		LEFT JOIN member_positions mp ON mp.user_id = u.id
		LEFT JOIN (
			SELECT user_id, MAX(last_seen) AS last_seen
			FROM devices GROUP BY user_id
		) d ON d.user_id = u.id
		LEFT JOIN families f ON f.id = u.family_id
		ORDER BY f.name NULLS LAST, u.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	members := []adminWsMember{}
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
			familyID        *string
			familyName      *string
		)
		if err := rows.Scan(&id, &email, &name, &role, &hasAvatar, &avatarVersion, &avatarUpdatedAt,
			&lat, &lon, &ts, &battery, &speed, &motion, &accuracy, &lastSeenAt, &familyID, &familyName); err != nil {
			return nil, err
		}
		m := adminWsMember{
			wsMember: wsMember{
				ID:              id,
				Name:            name,
				Email:           &email, // platform admin sees all emails
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
			},
			FamilyID:   familyID,
			FamilyName: familyName,
		}
		members = append(members, m)
	}
	if rows.Err() != nil {
		return nil, rows.Err()
	}
	return members, nil
}
