package handlers

import (
	"context"
	"encoding/json"
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
	familyID string // first circle at registration (legacy field)
	// circles is the set of circle ids this socket is subscribed to. Guarded
	// by hub.mu.
	circles map[string]struct{}
	// aware is set once the client opted in to circle-labelled frames (by
	// connecting with ?circle_id= or sending a subscribe frame). Legacy
	// clients stay unaware and receive one unlabelled copy per update.
	aware bool
	// filter is the one circle an aware client subscribed to; "" means all of
	// its circles. Guarded by hub.mu.
	filter string
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

// register adds a client subscribed to a single circle (a legacy family).
func (h *hub) register(familyID, userID string, c *wsClient) {
	h.registerCircles([]string{familyID}, userID, c)
}

// registerCircles adds a client subscribed to every circle in circleIDs and
// records the authenticated user it belongs to. Admin clients use the separate
// registerAdmin path and are never included in familyUsers.
func (h *hub) registerCircles(circleIDs []string, userID string, c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c.userID = userID
	c.circles = make(map[string]struct{}, len(circleIDs))
	for i, id := range circleIDs {
		if i == 0 {
			c.familyID = id
		}
		h.addCircleLocked(id, c)
	}
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

func (h *hub) addCircleLocked(circleID string, c *wsClient) {
	m := h.families[circleID]
	if m == nil {
		m = make(map[*wsClient]struct{})
		h.families[circleID] = m
	}
	m[c] = struct{}{}
	if c.circles == nil {
		c.circles = make(map[string]struct{})
	}
	c.circles[circleID] = struct{}{}
}

func (h *hub) removeCircleLocked(circleID string, c *wsClient) {
	if m := h.families[circleID]; m != nil {
		delete(m, c)
		if len(m) == 0 {
			delete(h.families, circleID)
		}
	}
	delete(c.circles, circleID)
	if c.aware {
		if c.filter == circleID {
			c.filter = "" // the subscribed circle is gone; fall back to all
		}
		notice, _ := json.Marshal(map[string]string{"type": "circle_removed", "circle_id": circleID})
		select {
		case c.send <- notice:
		default:
		}
	}
}

// unregister removes a client from every circle it is subscribed to.
func (h *hub) unregister(familyID string, c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.unregisterFamilyClientLocked(familyID, c)
}

// unregisterFamilyClientLocked drops the whole client (all circles and the
// per-user index). familyID is kept for call-site compatibility.
func (h *hub) unregisterFamilyClientLocked(familyID string, c *wsClient) {
	h.removeCircleLocked(familyID, c)
	for id := range c.circles {
		h.removeCircleLocked(id, c)
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

// subscribeUser adds circleID to every live socket of userID (the user just
// joined or created that circle).
func (h *hub) subscribeUser(userID, circleID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.familyUsers[userID] {
		h.addCircleLocked(circleID, c)
	}
}

// unsubscribeUser removes circleID from every live socket of userID, effective
// immediately (the user was removed, left, or the circle was deleted). A socket
// left with no circle is closed.
func (h *hub) unsubscribeUser(userID, circleID string) {
	h.mu.Lock()
	var dead []*wsClient
	for c := range h.familyUsers[userID] {
		h.removeCircleLocked(circleID, c)
		if len(c.circles) == 0 {
			dead = append(dead, c)
		}
	}
	for _, c := range dead {
		h.unregisterFamilyClientLocked(circleID, c)
	}
	h.mu.Unlock()
	for _, c := range dead {
		c.close()
	}
}

// unsubscribeCircle removes circleID from every socket (circle deleted).
func (h *hub) unsubscribeCircle(circleID string) {
	h.mu.Lock()
	var dead []*wsClient
	for c := range h.families[circleID] {
		h.removeCircleLocked(circleID, c)
		if len(c.circles) == 0 {
			dead = append(dead, c)
		}
	}
	for _, c := range dead {
		h.unregisterFamilyClientLocked(circleID, c)
	}
	h.mu.Unlock()
	for _, c := range dead {
		c.close()
	}
}

// syncUserCircles makes the subscriptions of one socket equal to circleIDs
// (self-healing backstop run by the periodic revalidation).
func (h *hub) syncUserCircles(c *wsClient, circleIDs []string) {
	want := make(map[string]struct{}, len(circleIDs))
	for _, id := range circleIDs {
		want[id] = struct{}{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if c.userID != "" {
		if _, live := h.familyUsers[c.userID][c]; !live {
			return // already dropped; do not resurrect
		}
	}
	for id := range c.circles {
		if _, ok := want[id]; !ok {
			h.removeCircleLocked(id, c)
		}
	}
	for id := range want {
		if _, ok := c.circles[id]; !ok {
			h.addCircleLocked(id, c)
		}
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
	var clients []*wsClient
	for c := range h.families[familyID] {
		clients = append(clients, c)
	}
	var dead []*wsClient
	for _, c := range clients {
		h.removeCircleLocked(familyID, c)
		if len(c.circles) == 0 {
			dead = append(dead, c)
		}
	}
	for _, c := range dead {
		h.unregisterFamilyClientLocked(familyID, c)
	}
	h.mu.Unlock()
	for _, c := range dead {
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

// broadcastCircles enqueues msg once to every client subscribed to any circle
// in circleIDs, plus every client of alsoUser (the subject always sees their
// own updates). A client in several of the circles gets one copy. Slow clients
// are dropped like in broadcast.
func (h *hub) broadcastCircles(circleIDs []string, alsoUser string, msg []byte) {
	h.mu.Lock()
	seen := make(map[*wsClient]struct{})
	for _, id := range circleIDs {
		for c := range h.families[id] {
			seen[c] = struct{}{}
		}
	}
	if alsoUser != "" {
		for c := range h.familyUsers[alsoUser] {
			seen[c] = struct{}{}
		}
	}
	clients := make([]*wsClient, 0, len(seen))
	for c := range seen {
		clients = append(clients, c)
	}
	h.mu.Unlock()

	for _, c := range clients {
		select {
		case c.send <- msg:
		default:
			h.unregister(c.familyID, c)
			c.close()
		}
	}
}

// setSubscription opts c in to circle-labelled frames and narrows it to
// circleID ("" = all its circles). The caller must already have verified
// membership against the database; a circle the hub did not yet know is added.
// It reports false when the client is no longer registered.
func (h *hub) setSubscription(c *wsClient, circleID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c.userID != "" {
		if _, live := h.familyUsers[c.userID][c]; !live {
			return false
		}
	}
	if circleID != "" {
		if _, ok := c.circles[circleID]; !ok {
			h.addCircleLocked(circleID, c)
		}
	}
	c.aware = true
	c.filter = circleID
	return true
}

// broadcastLabelled delivers one subject update. shared are the circles the
// subject currently shares in; own are all of the subject's circles (they
// always see themselves). frame(circleID) returns the circle-labelled frame
// and legacy the unlabelled one. A legacy client gets one copy; an aware client
// gets one frame per matching circle, so it can filter per circle.
func (h *hub) broadcastLabelled(shared, own []string, ownerID string, legacy []byte, frame func(circleID string) []byte) {
	type delivery struct {
		c    *wsClient
		msgs [][]byte
	}
	cache := map[string][]byte{}
	labelled := func(id string) []byte {
		if b, ok := cache[id]; ok {
			return b
		}
		b := frame(id)
		cache[id] = b
		return b
	}
	h.mu.Lock()
	byClient := map[*wsClient]*delivery{}
	add := func(c *wsClient, msg []byte) {
		d := byClient[c]
		if d == nil {
			d = &delivery{c: c}
			byClient[c] = d
		}
		d.msgs = append(d.msgs, msg)
	}
	for _, id := range shared {
		for c := range h.families[id] {
			if ownerID != "" && c.userID == ownerID {
				continue // handled below
			}
			if !c.aware {
				if byClient[c] == nil {
					add(c, legacy)
				}
				continue
			}
			if c.filter == "" || c.filter == id {
				add(c, labelled(id))
			}
		}
	}
	if ownerID != "" {
		for c := range h.familyUsers[ownerID] {
			if !c.aware {
				add(c, legacy)
				continue
			}
			for _, id := range own {
				if _, in := c.circles[id]; in && (c.filter == "" || c.filter == id) {
					add(c, labelled(id))
				}
			}
		}
	}
	h.mu.Unlock()

	for _, d := range byClient {
		for _, msg := range d.msgs {
			select {
			case d.c.send <- msg:
			default:
				h.unregister(d.c.familyID, d.c)
				d.c.close()
			}
		}
	}
}

// notifyCircleAware sends msg to every aware client subscribed to circleID
// (directly or via "all"). Legacy clients are not sent new frame types.
func (h *hub) notifyCircleAware(circleID string, msg []byte) {
	h.mu.Lock()
	var clients []*wsClient
	for c := range h.families[circleID] {
		if c.aware && (c.filter == "" || c.filter == circleID) {
			clients = append(clients, c)
		}
	}
	h.mu.Unlock()
	for _, c := range clients {
		select {
		case c.send <- msg:
		default:
		}
	}
}
