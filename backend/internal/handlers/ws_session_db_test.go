package handlers

import (
	"context"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

func TestWSSessionValidExpAndRevocation(t *testing.T) {
	fx := newAlertFixture(t)
	ctx := context.Background()
	var fam string
	if err := fx.pool.QueryRow(ctx, `
		INSERT INTO refresh_sessions (user_id, jti, family_id, expires_at) VALUES ($1, 'jti-ws-'||gen_random_uuid()::text, gen_random_uuid()::text, now() + interval '1 day')
		RETURNING family_id`, fx.a).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	c := &wsClient{userID: fx.a, sid: fam, exp: time.Now().Add(time.Minute)}
	if ok, err := fx.srv.wsSessionValid(ctx, c); err != nil || !ok {
		t.Fatalf("live session: %v %v", ok, err)
	}
	c.exp = time.Now().Add(-time.Second)
	if ok, _ := fx.srv.wsSessionValid(ctx, c); ok {
		t.Fatal("expired token still valid")
	}
	c.exp = time.Now().Add(time.Minute)
	if _, err := fx.pool.Exec(ctx, `UPDATE refresh_sessions SET revoked_at = now() WHERE family_id = $1`, fam); err != nil {
		t.Fatal(err)
	}
	if ok, _ := fx.srv.wsSessionValid(ctx, c); ok {
		t.Fatal("revoked session still valid")
	}
}

func TestShareLinksRevokedOnLogoutAll(t *testing.T) {
	fx := newAlertFixture(t)
	h := newShareLinkRouter(fx)
	ctx := context.Background()
	if code, _ := callJSON(t, h, "POST", "/share-links", fx.a, map[string]any{"minutes": 60}); code != 201 {
		t.Fatalf("create: %d", code)
	}
	if code, _ := callJSON(t, h, "POST", "/share-links", fx.b, map[string]any{"minutes": 60}); code != 201 {
		t.Fatalf("create b: %d", code)
	}
	rt := chi.NewRouter()
	rt.Post("/auth/logout-all", fx.srv.LogoutAll)
	if code, _ := callJSON(t, rt, "POST", "/auth/logout-all", fx.a, nil); code != 200 {
		t.Fatalf("logout-all: %d", code)
	}
	var activeA, activeB int
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM share_links WHERE user_id=$1 AND revoked_at IS NULL`, fx.a).Scan(&activeA)
	_ = fx.pool.QueryRow(ctx, `SELECT count(*) FROM share_links WHERE user_id=$1 AND revoked_at IS NULL`, fx.b).Scan(&activeB)
	if activeA != 0 || activeB != 1 {
		t.Fatalf("active a=%d b=%d", activeA, activeB)
	}
}
