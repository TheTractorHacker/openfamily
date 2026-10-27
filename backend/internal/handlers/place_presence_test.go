package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/TheTractorHacker/openfamily/backend/internal/models"
)

func TestPlacePresenceJSONOmittedWhenNil(t *testing.T) {
	b, err := json.Marshal(wsMember{ID: "x"})
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if _, ok := m["place_presence"]; ok {
		t.Fatalf("place_presence should be omitted when nil: %s", b)
	}
	since := time.Date(2026, 1, 1, 15, 42, 0, 0, time.UTC)
	b, _ = json.Marshal(wsMember{ID: "x", PlacePresence: &models.PlacePresence{PlaceID: "p", PlaceName: "Home", State: "at", Since: since}})
	_ = json.Unmarshal(b, &m)
	pp, _ := m["place_presence"].(map[string]any)
	if pp["state"] != "at" || pp["place_name"] != "Home" || pp["since"] != "2026-01-01T15:42:00Z" {
		t.Fatalf("unexpected place_presence: %s", b)
	}
	// Redaction drops it with the rest of the location fields.
	wm := wsMember{PlacePresence: &models.PlacePresence{}}
	wm.redactLocation()
	if wm.PlacePresence != nil {
		t.Fatal("redactLocation must clear place_presence")
	}
}

func TestPlacePresenceDerivedFromEvents(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	mk := func(q string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, q, args...).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	tag := fmt.Sprint(time.Now().UnixNano())
	fam := mk(`INSERT INTO families (name) VALUES ('pp') RETURNING id`)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE family_id = $1`, fam)
		_, _ = pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam)
	})
	user := func(n string) string {
		return mk(`INSERT INTO users (email, name, password_hash, family_id, role) VALUES ($1,$2,'x',$3,'member') RETURNING id`,
			n+tag+"@example.com", n, fam)
	}
	u1, u2, u3 := user("one"), user("two"), user("three")
	home := mk(`INSERT INTO places (family_id, name, type) VALUES ($1,'Home','home') RETURNING id`, fam)
	work := mk(`INSERT INTO places (family_id, name, type) VALUES ($1,'Work','work') RETURNING id`, fam)
	gf := func(place string) string {
		return mk(`INSERT INTO geofences (family_id, place_id) VALUES ($1,$2) RETURNING id`, fam, place)
	}
	gHome, gWork := gf(home), gf(work)
	now := time.Now().UTC().Truncate(time.Second)
	ev := func(g, u, p, typ string, ago time.Duration) {
		if _, err := pool.Exec(ctx, `INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts) VALUES ($1,$2,$3,$4,$5)`,
			g, u, p, typ, now.Add(-ago)); err != nil {
			t.Fatal(err)
		}
	}
	// u1: entered home 3h ago, left 2h ago, entered work 1h ago -> at Work.
	ev(gHome, u1, home, "enter", 3*time.Hour)
	ev(gHome, u1, home, "exit", 2*time.Hour)
	ev(gWork, u1, work, "enter", time.Hour)
	// u2: entered work, then left it -> left Work, since the exit.
	ev(gWork, u2, work, "enter", 2*time.Hour)
	ev(gWork, u2, work, "exit", 25*time.Minute)
	// u3: no events.

	srv := &Server{Pool: pool, hub: newHub()}
	got, err := srv.placePresence(ctx, []string{u1, u2, u3})
	if err != nil {
		t.Fatal(err)
	}
	if p := got[u1]; p == nil || p.State != "at" || p.PlaceName != "Work" || !p.Since.Equal(now.Add(-time.Hour)) {
		t.Fatalf("u1: %+v", p)
	}
	if p := got[u2]; p == nil || p.State != "left" || p.PlaceName != "Work" || !p.Since.Equal(now.Add(-25*time.Minute)) {
		t.Fatalf("u2: %+v", p)
	}
	if got[u3] != nil {
		t.Fatalf("u3 should have no presence: %+v", got[u3])
	}

	// Overlapping places: leaving Work while still inside Home reports Home.
	ev(gHome, u2, home, "enter", 3*time.Hour)
	got, _ = srv.placePresence(ctx, []string{u2})
	if p := got[u2]; p == nil || p.State != "at" || p.PlaceName != "Home" {
		t.Fatalf("u2 overlap: %+v", p)
	}
}
