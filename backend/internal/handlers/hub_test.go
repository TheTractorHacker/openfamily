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
