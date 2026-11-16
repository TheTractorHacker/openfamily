package handlers

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestHubDisconnectFamilyUserClosesOnlyFamilySockets(t *testing.T) {
	h := newHub()
	first := testWSClient()
	second := testWSClient()
	otherUser := testWSClient()
	admin := testWSClient()

	// Multiple app instances can be connected at once. Use two family IDs to
	// prove every tracked family socket for the moved user is removed, while an
	// unrelated family member and a platform-admin stream stay connected.
	h.register("family-old", "moved-user", first)
	h.register("family-new", "moved-user", second)
	h.register("family-old", "other-user", otherUser)
	h.registerAdmin(admin)

	h.disconnectFamilyUser("moved-user")

	if !wsClientClosed(first) || !wsClientClosed(second) {
		t.Fatal("moved user's family sockets were not closed")
	}
	if wsClientClosed(otherUser) {
		t.Fatal("other user's family socket was closed")
	}
	if wsClientClosed(admin) {
		t.Fatal("platform-admin socket was closed")
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.familyUsers["moved-user"]; ok {
		t.Fatal("moved user remains in the family user index")
	}
	if _, ok := h.families["family-new"]; ok {
		t.Fatal("empty family socket set was not removed")
	}
	if _, ok := h.families["family-old"][otherUser]; !ok {
		t.Fatal("other user's family socket was removed from the hub")
	}
	if _, ok := h.admins[admin]; !ok {
		t.Fatal("platform-admin socket was removed from the hub")
	}
}

func testWSClient() *wsClient {
	return &wsClient{
		send: make(chan []byte, clientSendBuffer),
		done: make(chan struct{}),
	}
}

func wsClientClosed(c *wsClient) bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

func TestHubDisconnectUserClosesFamilyAndAdminSockets(t *testing.T) {
	h := newHub()
	famSock := testWSClient()
	adminSock := testWSClient()
	otherAdmin := testWSClient()
	adminSock.userID = "admin-1"
	otherAdmin.userID = "admin-2"

	h.register("fam", "admin-1", famSock)
	h.registerAdmin(adminSock)
	h.registerAdmin(otherAdmin)

	h.disconnectUser("admin-1")

	if !wsClientClosed(famSock) || !wsClientClosed(adminSock) {
		t.Fatal("user's sockets were not all closed")
	}
	if wsClientClosed(otherAdmin) {
		t.Fatal("another admin's socket was closed")
	}
	// No further fan-out may reach the dropped sockets.
	h.broadcastAdmin([]byte("x"))
	h.broadcast("fam", []byte("x"))
	if len(adminSock.send) != 0 || len(famSock.send) != 0 {
		t.Fatal("dropped sockets still received fan-out")
	}
	if len(otherAdmin.send) != 1 {
		t.Fatal("remaining admin did not receive fan-out")
	}
}

func TestHubDisconnectFamilyClosesEveryMember(t *testing.T) {
	h := newHub()
	a, b, other := testWSClient(), testWSClient(), testWSClient()
	h.register("gone", "u1", a)
	h.register("gone", "u2", b)
	h.register("kept", "u3", other)
	h.disconnectFamily("gone")
	if !wsClientClosed(a) || !wsClientClosed(b) || wsClientClosed(other) {
		t.Fatal("wrong set of sockets closed")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.families["gone"]) != 0 || len(h.familyUsers["u1"]) != 0 {
		t.Fatal("closed sockets remain indexed")
	}
}

func waitClosed(t *testing.T, c *wsClient) {
	t.Helper()
	select {
	case <-c.done:
	case <-time.After(2 * time.Second):
		t.Fatal("socket not closed within 2s")
	}
}

// A membership/credential change detected by the periodic check closes the
// socket and removes it from fan-out.
func TestHubWatchClosesFamilySocketWhenRevoked(t *testing.T) {
	h := newHub()
	c := testWSClient()
	h.register("fam", "u1", c)
	var authorized atomic.Bool
	authorized.Store(true)
	go h.watch(c, 10*time.Millisecond, func(context.Context) (bool, error) {
		return authorized.Load(), nil
	})
	time.Sleep(40 * time.Millisecond)
	if wsClientClosed(c) {
		t.Fatal("socket closed while still authorized")
	}
	authorized.Store(false)
	waitClosed(t, c)
	h.broadcast("fam", []byte("x"))
	if len(c.send) != 0 {
		t.Fatal("revoked socket still received fan-out")
	}
}

func TestHubWatchClosesAdminSocketWhenDemoted(t *testing.T) {
	h := newHub()
	c := testWSClient()
	h.registerAdmin(c)
	go h.watch(c, 10*time.Millisecond, func(context.Context) (bool, error) { return false, nil })
	waitClosed(t, c)
	h.broadcastAdmin([]byte("x"))
	if len(c.send) != 0 {
		t.Fatal("demoted admin socket still received fan-out")
	}
}

// Transient check errors (database blip) must not drop healthy sockets.
func TestHubWatchKeepsSocketOnCheckError(t *testing.T) {
	h := newHub()
	c := testWSClient()
	h.register("fam", "u1", c)
	go h.watch(c, 5*time.Millisecond, func(context.Context) (bool, error) {
		return false, errors.New("db down")
	})
	time.Sleep(50 * time.Millisecond)
	if wsClientClosed(c) {
		t.Fatal("socket closed on transient error")
	}
	c.close()
}

func TestHubCapUserSocketsClosesOldest(t *testing.T) {
	h := newHub()
	base := time.Now()
	var cs []*wsClient
	for i := 0; i < 5; i++ {
		c := testWSClient()
		c.since = base.Add(time.Duration(i) * time.Second)
		h.register("fam", "u1", c)
		cs = append(cs, c)
	}
	other := testWSClient()
	h.register("fam", "u2", other)
	h.capUserSockets("u1", 3)
	if !wsClientClosed(cs[0]) || !wsClientClosed(cs[1]) {
		t.Fatal("oldest sockets not closed")
	}
	if wsClientClosed(cs[2]) || wsClientClosed(cs[3]) || wsClientClosed(cs[4]) || wsClientClosed(other) {
		t.Fatal("newer or foreign sockets closed")
	}
}

func TestHubDisconnectSessionOnlyThatSid(t *testing.T) {
	h := newHub()
	a, b, admin, other := testWSClient(), testWSClient(), testWSClient(), testWSClient()
	a.sid, b.sid, admin.sid, other.sid = "s1", "s2", "s1", "s1"
	h.register("fam", "u1", a)
	h.register("fam", "u1", b)
	admin.userID = "u1"
	h.registerAdmin(admin)
	h.register("fam", "u2", other)
	h.disconnectSession("u1", "s1")
	if !wsClientClosed(a) || !wsClientClosed(admin) {
		t.Fatal("session sockets not closed")
	}
	if wsClientClosed(b) || wsClientClosed(other) {
		t.Fatal("other session/user socket closed")
	}
}

func TestSubscribeLimiter(t *testing.T) {
	var l subscribeLimiter
	now := time.Now()
	if w, _ := l.allow(now); w != 0 {
		t.Fatal("first frame must pass")
	}
	// A quick second frame is delayed to the next slot, not dropped.
	w, abuse := l.allow(now.Add(100 * time.Millisecond))
	if abuse || w <= 0 || w > subscribeMinInterval {
		t.Fatalf("second frame wait=%v abuse=%v, want delayed", w, abuse)
	}
	for i := 0; i < subscribeMaxStrikes; i++ {
		_, abuse = l.allow(now.Add(110 * time.Millisecond))
	}
	if !abuse {
		t.Fatal("flood did not trigger close")
	}
	if w, a := l.allow(now.Add(20 * time.Second)); w != 0 || a {
		t.Fatal("frame after quiet interval must pass")
	}
}
