package handlers

import (
	"context"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// clientSendBuffer is the number of outbound frames buffered per connection
// before the client is considered too slow and dropped.
const clientSendBuffer = 64

// wsClient is a single connected WebSocket client. Outbound frames are queued
// on send and written by a dedicated goroutine so a slow consumer cannot block
// location ingest.
type wsClient struct {
	conn     *websocket.Conn
	send     chan []byte
	done     chan struct{}
	once     sync.Once
	userID   string
	familyID string
}

// close signals the writer goroutine to stop and closes the connection. It is
// idempotent so both the read loop and a slow-client drop can call it.
func (c *wsClient) close() {
	c.once.Do(func() {
		close(c.done)
		if c.conn != nil {
			_ = c.conn.CloseNow()
		}
	})
}

// writeLoop drains the send channel and writes frames to the connection. It
// exits when the client is closed or a write fails.
//
// It also runs the heartbeat: a periodic ping detects a half-open connection
// (phone killed / signal lost with no FIN), which would otherwise leave the
// read loop blocked forever and hold a hub slot + send buffer indefinitely. A
// dead peer never answers the ping, so Ping times out and we close the
// connection, which unblocks the read loop and triggers the deferred
// unregister. Ping is a write, so it lives here alongside Write to respect
// coder/websocket's single-writer rule.
func (c *wsClient) writeLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case msg := <-c.send:
			if err := c.conn.Write(ctx, websocket.MessageText, msg); err != nil {
				c.close()
				return
			}
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.conn.Ping(pingCtx)
			cancel()
			if err != nil {
				c.close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// hub tracks connected WebSocket clients per family, plus the set of platform
// admin clients that receive live updates across ALL families.
type hub struct {
	mu          sync.Mutex
	families    map[string]map[*wsClient]struct{}
	familyUsers map[string]map[*wsClient]struct{}
	admins      map[*wsClient]struct{}
}

func newHub() *hub {
	return &hub{
		families:    make(map[string]map[*wsClient]struct{}),
		familyUsers: make(map[string]map[*wsClient]struct{}),
		admins:      make(map[*wsClient]struct{}),
	}
}

// register adds a family-scoped client and records the authenticated user it
// belongs to. Admin clients use the separate registerAdmin path and are never
// included in familyUsers.
func (h *hub) register(familyID, userID string, c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c.familyID = familyID
	c.userID = userID
	m := h.families[familyID]
	if m == nil {
		m = make(map[*wsClient]struct{})
		h.families[familyID] = m
	}
	m[c] = struct{}{}
	if userID == "" {
		return
	}
	userClients := h.familyUsers[userID]
	if userClients == nil {
		userClients = make(map[*wsClient]struct{})
		h.familyUsers[userID] = userClients
	}
	userClients[c] = struct{}{}
}

// unregister removes a client from a family.
func (h *hub) unregister(familyID string, c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.unregisterFamilyClientLocked(familyID, c)
}

func (h *hub) unregisterFamilyClientLocked(familyID string, c *wsClient) {
	m := h.families[familyID]
	if m != nil {
		delete(m, c)
		if len(m) == 0 {
			delete(h.families, familyID)
		}
	}
	if c.userID == "" {
		return
	}
	userClients := h.familyUsers[c.userID]
	if userClients == nil {
		return
	}
	delete(userClients, c)
	if len(userClients) == 0 {
		delete(h.familyUsers, c.userID)
	}
}

// disconnectFamilyUser closes every family-scoped socket for userID. It
// intentionally leaves platform-admin sockets alone: those streams are global
// and remain valid when the admin moves between families. Removing clients
// from the hub before closing them prevents a just-moved user from receiving
// another old-family broadcast while the close unblocks its read loop.
func (h *hub) disconnectFamilyUser(userID string) {
	h.mu.Lock()
	userClients := h.familyUsers[userID]
	clients := make([]*wsClient, 0, len(userClients))
	for c := range userClients {
		clients = append(clients, c)
	}
	for _, c := range clients {
		h.unregisterFamilyClientLocked(c.familyID, c)
	}
	h.mu.Unlock()

	for _, c := range clients {
		c.close()
	}
}

// disconnectUser closes every socket (family-scoped and platform-admin) that
// belongs to userID. Used when the account itself is no longer trustworthy:
// logout, password change or reset, deletion.
func (h *hub) disconnectUser(userID string) {
	h.disconnectFamilyUser(userID)
	h.disconnectAdminUser(userID)
}

// disconnectAdminUser closes every platform-admin socket for userID (admin
// demoted, logged out, password reset, deleted).
func (h *hub) disconnectAdminUser(userID string) {
	h.mu.Lock()
	var clients []*wsClient
	for c := range h.admins {
		if c.userID == userID {
			clients = append(clients, c)
		}
	}
	for _, c := range clients {
		delete(h.admins, c)
	}
	h.mu.Unlock()
	for _, c := range clients {
		c.close()
	}
}

// disconnectFamily closes every family-scoped socket registered under
// familyID (family deleted).
func (h *hub) disconnectFamily(familyID string) {
	h.mu.Lock()
	clients := make([]*wsClient, 0, len(h.families[familyID]))
	for c := range h.families[familyID] {
		clients = append(clients, c)
	}
	for _, c := range clients {
		h.unregisterFamilyClientLocked(familyID, c)
	}
	h.mu.Unlock()
	for _, c := range clients {
		c.close()
	}
}

// wsRevalidateInterval is how often an open stream re-checks that its owner is
// still authorized. A variable so tests can shorten it.
var wsRevalidateInterval = 30 * time.Second

// watch re-validates a connected client every interval until it closes. When
// check reports false the client is removed from the hub (so no further
// fan-out reaches it) and its socket is closed. A check error is treated as
// transient: the socket stays open and the next tick retries.
func (h *hub) watch(c *wsClient, interval time.Duration, check func(context.Context) (bool, error)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			ok, err := check(ctx)
			cancel()
			if err != nil || ok {
				continue
			}
			h.mu.Lock()
			h.unregisterFamilyClientLocked(c.familyID, c)
			delete(h.admins, c)
			h.mu.Unlock()
			c.close()
			return
		}
	}
}

// dropUserSockets closes all live streams of a user. Safe on a Server built
// without a hub (unit tests).
func (s *Server) dropUserSockets(userID string) {
	if s.hub != nil {
		s.hub.disconnectUser(userID)
	}
}

// hasAny reports whether any client is connected to any family. It lets
// callers skip a database lookup when there is nobody to notify.
func (h *hub) hasAny() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.families) > 0
}

// hasAdminClients reports whether any platform admin client is connected. It
// lets broadcastLocation skip the family lookup + broadcast when no admin is
// watching, mirroring the hasAny fast path.
func (h *hub) hasAdminClients() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.admins) > 0
}

// registerAdmin adds a client to the platform admin set (receives every live
// update across all families).
func (h *hub) registerAdmin(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.admins[c] = struct{}{}
}

// unregisterAdmin removes a client from the platform admin set.
func (h *hub) unregisterAdmin(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.admins, c)
}

// broadcastAdmin enqueues msg to every connected platform admin client without
// blocking. A client whose send buffer is full is dropped and unregistered so a
// slow consumer cannot stall location ingest.
func (h *hub) broadcastAdmin(msg []byte) {
	h.mu.Lock()
	clients := make([]*wsClient, 0, len(h.admins))
	for c := range h.admins {
		clients = append(clients, c)
	}
	h.mu.Unlock()

	for _, c := range clients {
		select {
		case c.send <- msg:
		default:
			h.unregisterAdmin(c)
			c.close()
		}
	}
}

// broadcast enqueues msg to every client in the family without blocking. A
// client whose send buffer is full is dropped and unregistered so a slow
// consumer cannot stall location ingest.
func (h *hub) broadcast(familyID string, msg []byte) {
	h.mu.Lock()
	m := h.families[familyID]
	clients := make([]*wsClient, 0, len(m))
	for c := range m {
		clients = append(clients, c)
	}
	h.mu.Unlock()

	for _, c := range clients {
		select {
		case c.send <- msg:
		default:
			h.unregister(familyID, c)
			c.close()
		}
	}
}
