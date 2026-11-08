package handlers

import (
	"context"
	"testing"
)

// Old sign-ins replaced by a newer device on the same platform are hidden from Fleet health after a
// day; the newest row, a recently active older row, another platform and another user stay.
func TestHideSupersededDevices(t *testing.T) {
	e := newCircleEnv(t)
	ctx := context.Background()
	add := func(user, platform, ago string) string {
		var id string
		if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name, last_seen, created_at)
			VALUES ($1, $2, 'x', now() - $3::interval, now() - $3::interval) RETURNING id::text`, e.ids[user], platform, ago).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	oldA := add("A", "android", "10 days")
	midA := add("A", "android", "3 days")
	newA := add("A", "android", "1 hour")
	oldIOS := add("A", "ios", "10 days")
	lonely := add("B", "android", "20 days") // B has no newer device: kept
	hidden := func(id string) bool {
		var h bool
		if err := e.pool.QueryRow(ctx, `SELECT hidden_at IS NOT NULL FROM devices WHERE id = $1`, id).Scan(&h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	n, err := e.srv.HideSupersededDevices(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 || !hidden(oldA) || !hidden(midA) {
		t.Fatalf("old android rows should be hidden (n=%d)", n)
	}
	if hidden(newA) || hidden(oldIOS) || hidden(lonely) {
		t.Fatal("newest row, other platform and a lone device must stay")
	}
	if n, _ := e.srv.HideSupersededDevices(ctx); n != 0 {
		t.Fatalf("second run should hide nothing, hid %d", n)
	}
}
