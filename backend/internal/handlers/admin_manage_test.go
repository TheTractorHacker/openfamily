package handlers

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
)

// Admin share-link / invite / circle management. Needs TEST_DATABASE_URL.

func adminEnv(t *testing.T) *circleEnv {
	t.Helper()
	e := newCircleEnv(t)
	e.rt.Get("/api/admin/share-links", e.srv.AdminListShareLinks)
	e.rt.Delete("/api/admin/share-links/{id}", e.srv.AdminRevokeShareLink)
	e.rt.Get("/api/admin/circles", e.srv.AdminListCircles)
	e.rt.Patch("/api/admin/circles/{id}", e.srv.AdminUpdateCircle)
	e.rt.Get("/api/admin/invites", e.srv.AdminListInvites)
	e.rt.Delete("/api/admin/invites/{id}", e.srv.AdminRevokeInvite)
	return e
}

func TestAdminShareLinksListAndRevoke(t *testing.T) {
	e := adminEnv(t)
	ctx := context.Background()
	var live, expired string
	for i, exp := range []string{"1 hour", "-1 hour"} {
		var id string
		if err := e.pool.QueryRow(ctx, `
			INSERT INTO share_links (user_id, token_hash, label, expires_at)
			VALUES ($1, sha256($2::bytea), 'lbl', now() + $3::interval) RETURNING id`,
			e.ids["A"], []byte{byte(i), byte(time.Now().UnixNano())}, exp).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			live = id
		} else {
			expired = id
		}
	}
	_, _, raw := e.do("A", "GET", "/api/admin/share-links", nil)
	var list []adminShareLinkOut
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatal(err)
	}
	st := map[string]string{}
	for _, l := range list {
		st[l.ID] = l.Status
	}
	if st[live] != "active" || st[expired] != "expired" {
		t.Fatalf("statuses: %v", st)
	}
	e.mustCode("A", "DELETE", "/api/admin/share-links/"+expired, nil, 404)
	e.mustCode("A", "DELETE", "/api/admin/share-links/nope", nil, 404)
	e.mustCode("A", "DELETE", "/api/admin/share-links/"+live, nil, 200)
	e.mustCode("A", "DELETE", "/api/admin/share-links/"+live, nil, 404)
	_, _, raw = e.do("A", "GET", "/api/admin/share-links", nil)
	_ = json.Unmarshal(raw, &list)
	for _, l := range list {
		if l.ID == live && l.Status != "revoked" {
			t.Fatalf("link not revoked: %s", l.Status)
		}
	}
}

func TestAdminCirclesEndExtendAndInviteRevoke(t *testing.T) {
	e := adminEnv(t)
	trip := e.tempCircle("A", 24, "B")
	perm := e.createCircle("A", "Perm")

	find := func(id string) adminCircleOut {
		t.Helper()
		_, _, raw := e.do("A", "GET", "/api/admin/circles", nil)
		var list []adminCircleOut
		if err := json.Unmarshal(raw, &list); err != nil {
			t.Fatal(err)
		}
		for _, c := range list {
			if c.ID == id {
				return c
			}
		}
		t.Fatalf("circle %s not listed", id)
		return adminCircleOut{}
	}
	if c := find(trip); c.Status != "active" || c.Members != 2 || c.ExpiresAt == nil {
		t.Fatalf("trip: %+v", c)
	}
	if c := find(perm); c.Status != "permanent" {
		t.Fatalf("perm: %+v", c)
	}

	e.mustCode("A", "PATCH", "/api/admin/circles/"+perm, map[string]any{"end": true}, 409)
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{}, 400)
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"extend_hours": 0}, 400)
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"extend_hours": 721}, 400)
	before := *find(trip).ExpiresAt
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"extend_hours": 5}, 200)
	if got := find(trip).ExpiresAt.Sub(before); got < 4*time.Hour+50*time.Minute || got > 5*time.Hour+10*time.Minute {
		t.Fatalf("extended by %v", got)
	}

	// Lapsed within grace: extendable and revives members' access.
	e.lapse(trip, time.Hour)
	if c := find(trip); c.Status != "expired" {
		t.Fatalf("want expired: %+v", c)
	}
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"extend_hours": 2}, 200)
	if _, err := circles.New(e.pool).RequireMember(context.Background(), e.ids["B"], trip); err != nil {
		t.Fatalf("member lost access after extend: %v", err)
	}

	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"end": true}, 200)
	if c := find(trip); c.Status != "ended" {
		t.Fatalf("want ended: %+v", c)
	}
	if _, err := circles.New(e.pool).RequireMember(context.Background(), e.ids["B"], trip); err == nil {
		t.Fatal("ended circle must cut off members")
	}
	e.mustCode("A", "PATCH", "/api/admin/circles/"+trip, map[string]any{"extend_hours": 2}, 409)

	// Circle-only invites are listed and revocable by an admin.
	inv := e.mustCode("A", "POST", "/circles/"+perm+"/invites", map[string]any{}, 201)
	_, _, raw := e.do("A", "GET", "/api/admin/invites", nil)
	var invs []adminInvite
	if err := json.Unmarshal(raw, &invs); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, i := range invs {
		if i.ID == inv["id"] && i.CircleName != nil && *i.CircleName == "Perm" {
			found = true
		}
	}
	if !found {
		t.Fatalf("circle invite not listed: %s", raw)
	}
	e.mustCode("A", "DELETE", "/api/admin/invites/"+inv["id"].(string), nil, 200)
	e.mustCode("A", "DELETE", "/api/admin/invites/"+inv["id"].(string), nil, 404)
}
