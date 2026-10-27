package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Need TEST_DATABASE_URL (skipped otherwise), like alerts_db_test.go.

func newSharingRouter(fx *alertFixture) http.Handler {
	srv := fx.srv
	r := chi.NewRouter()
	r.Post("/checkins", srv.PostCheckinTo)
	r.Get("/checkins", srv.ListCheckins)
	r.Get("/sharing/pause", srv.GetSharingPause)
	r.Put("/sharing/pause", srv.SetSharingPause)
	r.Delete("/sharing/pause", srv.ClearSharingPause)
	r.Post("/live-shares", srv.CreateLiveShare)
	r.Get("/live-shares", srv.ListLiveShares)
	r.Delete("/live-shares/{id}", srv.DeleteLiveShare)
	r.Post("/alerts/sos", srv.PostSOS)
	r.Post("/locations/watch", srv.WatchMember)
	return r
}

func callJSON(t *testing.T, h http.Handler, method, path, uid string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rd)
	req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func TestCheckinToChosenRecipients(t *testing.T) {
	fx := newAlertFixture(t)
	h := newSharingRouter(fx)

	code, _ := callJSON(t, h, "POST", "/checkins", fx.a, map[string]any{"recipient_ids": []string{}})
	if code != 400 {
		t.Fatalf("empty recipients: %d", code)
	}
	// Outsider (other family) is a uniform 404.
	code, _ = callJSON(t, h, "POST", "/checkins", fx.a, map[string]any{"recipient_ids": []string{fx.b, fx.x}})
	if code != 404 {
		t.Fatalf("outsider recipient: %d", code)
	}
	code, _ = callJSON(t, h, "POST", "/checkins", fx.a, map[string]any{"recipient_ids": []string{fx.b}, "lat": 123.0, "lon": 1.0})
	if code != 400 {
		t.Fatalf("bad lat: %d", code)
	}
	code, c := callJSON(t, h, "POST", "/checkins", fx.a, map[string]any{
		"recipient_ids": []string{fx.b, fx.b}, "note": " here ", "lat": 51.5, "lon": -0.12})
	if code != 201 || c["note"] != "here" {
		t.Fatalf("send: %d %v", code, c)
	}
	// Rate limit (cooldown) applies per sender.
	if fx.srv.AlertLimit != nil {
		if code, _ = callJSON(t, h, "POST", "/checkins", fx.a, map[string]any{"recipient_ids": []string{fx.b}}); code != 429 {
			t.Fatalf("cooldown: %d", code)
		}
	}

	list := func(uid, q string) []any {
		code, out := callJSON(t, h, "GET", "/checkins"+q, uid, nil)
		if code != 200 {
			t.Fatalf("list %s: %d", uid, code)
		}
		l, _ := out["checkins"].([]any)
		return l
	}
	if l := list(fx.b, ""); len(l) != 1 || l[0].(map[string]any)["lat"] != 51.5 {
		t.Fatalf("recipient feed: %v", l)
	}
	if l := list(fx.c, ""); len(l) != 0 {
		t.Fatalf("non-recipient circle member must not see it: %v", l)
	}
	if l := list(fx.a, "?direction=sent"); len(l) != 1 {
		t.Fatalf("sent: %v", l)
	}
	if code, _ = callJSON(t, h, "GET", "/checkins?direction=x", fx.a, nil); code != 400 {
		t.Fatalf("bad direction: %d", code)
	}

	// Push went to the recipient only, with no coordinates.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		fx.push.mu.Lock()
		n := len(fx.push.sent)
		fx.push.mu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	fx.push.mu.Lock()
	if len(fx.push.sent) != 1 || fx.push.sent[0].UnifiedPushEndpoint != "https://ntfy.example/b" {
		t.Fatalf("push: %+v", fx.push.sent)
	}
	fx.push.mu.Unlock()

	// Expired check-ins are not served even before the purge runs.
	if _, err := fx.pool.Exec(context.Background(), `UPDATE checkins SET expires_at = now() - interval '1 second' WHERE user_id = $1`, fx.a); err != nil {
		t.Fatal(err)
	}
	if l := list(fx.b, ""); len(l) != 0 {
		t.Fatalf("expired check-in served: %v", l)
	}
}

func TestSharingPauseHonouredEverywhere(t *testing.T) {
	fx := newAlertFixture(t)
	h := newSharingRouter(fx)
	ctx := context.Background()
	az := circles.New(fx.pool)

	if _, err := fx.pool.Exec(ctx, `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 10, 20, now())`, fx.a); err != nil {
		t.Fatal(err)
	}
	if s, _ := az.SharedWith(ctx, fx.b, fx.a); len(s) == 0 {
		t.Fatal("precondition: b should see a")
	}

	for _, bad := range []map[string]any{{}, {"minutes": 0}, {"minutes": 99999999}, {"minutes": 5, "until": time.Now().Add(time.Hour)}} {
		if code, _ := callJSON(t, h, "PUT", "/sharing/pause", fx.a, bad); code != 400 {
			t.Fatalf("bad pause %v: %d", bad, code)
		}
	}
	code, p := callJSON(t, h, "PUT", "/sharing/pause", fx.a, map[string]any{"minutes": 60})
	if code != 200 || p["paused"] != true {
		t.Fatalf("pause: %d %v", code, p)
	}

	// Members snapshot decision, WS broadcast and presence inputs.
	if s, _ := az.SharedWith(ctx, fx.b, fx.a); len(s) != 0 {
		t.Fatalf("SharedWith while paused: %v", s)
	}
	if s, _ := az.SharingCircles(ctx, fx.a); len(s) != 0 {
		t.Fatalf("SharingCircles while paused: %v", s)
	}
	own, sharing, _ := az.OwnAndSharingCircles(ctx, fx.a)
	if len(own) == 0 || len(sharing) != 0 {
		t.Fatalf("OwnAndSharing: %v %v", own, sharing)
	}
	if vis, _ := az.LocationVisibility(ctx, fx.b, own); vis[fx.a] {
		t.Fatal("b sees paused a in snapshot")
	} else if !vis[fx.c] {
		t.Fatal("unpaused c must stay visible")
	}
	if mc, _ := az.MemberCircles(ctx, fx.b, own); len(mc[fx.a]) == 0 || mc[fx.a][0].Sharing {
		t.Fatalf("MemberCircles should list a as not sharing: %v", mc[fx.a])
	}
	// The owner still sees themselves.
	if vis, _ := az.LocationVisibility(ctx, fx.a, own); !vis[fx.a] {
		t.Fatal("owner must see self")
	}
	// Live boost / watch path.
	if code, _ := callJSON(t, h, "POST", "/locations/watch", fx.b, map[string]any{"user_id": fx.a}); code != 404 {
		t.Fatalf("watch of paused member: %d", code)
	}

	// SOS always shares, pause or not.
	code, sos := callJSON(t, h, "POST", "/alerts/sos", fx.a, map[string]any{"lat": 1.0, "lon": 2.0})
	if code != 201 || sos["lat"] != 1.0 {
		t.Fatalf("sos while paused: %d %v", code, sos)
	}

	// Expiry is enforced on read with no job involved.
	if _, err := fx.pool.Exec(ctx, `UPDATE sharing_pauses SET paused_until = now() - interval '1 second' WHERE user_id = $1`, fx.a); err != nil {
		t.Fatal(err)
	}
	if s, _ := az.SharedWith(ctx, fx.b, fx.a); len(s) == 0 {
		t.Fatal("pause must lapse on its own")
	}
	if _, g := callJSON(t, h, "GET", "/sharing/pause", fx.a, nil); g["paused"] == true {
		t.Fatalf("expired pause reported: %v", g)
	}

	// Explicit resume.
	callJSON(t, h, "PUT", "/sharing/pause", fx.a, map[string]any{"until": time.Now().Add(2 * time.Hour)})
	if s, _ := az.SharedWith(ctx, fx.b, fx.a); len(s) != 0 {
		t.Fatal("until-form pause not honoured")
	}
	callJSON(t, h, "DELETE", "/sharing/pause", fx.a, nil)
	if s, _ := az.SharedWith(ctx, fx.b, fx.a); len(s) == 0 {
		t.Fatal("resume not honoured")
	}
}

func TestLiveShareLifecycle(t *testing.T) {
	fx := newAlertFixture(t)
	h := newSharingRouter(fx)
	ctx := context.Background()
	if _, err := fx.pool.Exec(ctx, `INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 10, 20, now())`, fx.a); err != nil {
		t.Fatal(err)
	}

	if code, _ := callJSON(t, h, "POST", "/live-shares", fx.a, map[string]any{"viewer_id": fx.x, "minutes": 30}); code != 404 {
		t.Fatalf("outsider viewer: %d", code)
	}
	for _, m := range []int{0, 1441} {
		if code, _ := callJSON(t, h, "POST", "/live-shares", fx.a, map[string]any{"viewer_id": fx.b, "minutes": m}); code != 400 {
			t.Fatalf("minutes %d: %d", m, code)
		}
	}
	if code, _ := callJSON(t, h, "POST", "/live-shares", fx.a, map[string]any{"viewer_id": fx.a, "minutes": 5}); code != 400 {
		t.Fatalf("self share: %d", code)
	}
	code, sh := callJSON(t, h, "POST", "/live-shares", fx.a, map[string]any{"viewer_id": fx.b, "minutes": 30})
	if code != 201 {
		t.Fatalf("create: %d %v", code, sh)
	}
	id, _ := sh["id"].(string)

	incoming := func(uid string) []any {
		_, out := callJSON(t, h, "GET", "/live-shares", uid, nil)
		l, _ := out["incoming"].([]any)
		return l
	}
	if l := incoming(fx.b); len(l) != 1 || l[0].(map[string]any)["lat"] != 10.0 {
		t.Fatalf("viewer feed: %v", l)
	}
	if l := incoming(fx.c); len(l) != 0 {
		t.Fatalf("third party sees share: %v", l)
	}
	if _, out := callJSON(t, h, "GET", "/live-shares", fx.a, nil); len(out["outgoing"].([]any)) != 1 {
		t.Fatalf("outgoing: %v", out)
	}

	// A paused sharer's position is withheld.
	callJSON(t, h, "PUT", "/sharing/pause", fx.a, map[string]any{"minutes": 10})
	if l := incoming(fx.b); len(l) != 1 || l[0].(map[string]any)["lat"] != nil || l[0].(map[string]any)["paused"] != true {
		t.Fatalf("paused share must hide position: %v", l)
	}
	callJSON(t, h, "DELETE", "/sharing/pause", fx.a, nil)

	// Strangers cannot end it; either party can.
	if code, _ := callJSON(t, h, "DELETE", "/live-shares/"+id, fx.c, nil); code != 404 {
		t.Fatalf("stranger delete: %d", code)
	}

	// Expiry is enforced on read.
	if _, err := fx.pool.Exec(ctx, `UPDATE live_shares SET expires_at = now() - interval '1 second' WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if l := incoming(fx.b); len(l) != 0 {
		t.Fatalf("expired share served: %v", l)
	}
	if _, out := callJSON(t, h, "GET", "/live-shares", fx.a, nil); len(out["outgoing"].([]any)) != 0 {
		t.Fatalf("expired outgoing served: %v", out)
	}

	// Re-share revives, viewer can end it.
	_, sh = callJSON(t, h, "POST", "/live-shares", fx.a, map[string]any{"viewer_id": fx.b, "minutes": 5})
	if code, _ := callJSON(t, h, "DELETE", "/live-shares/"+sh["id"].(string), fx.b, nil); code != 200 {
		t.Fatalf("viewer end: %d", code)
	}
	if l := incoming(fx.b); len(l) != 0 {
		t.Fatalf("ended share served: %v", l)
	}
	if code, _ := callJSON(t, h, "DELETE", "/live-shares/not-a-uuid", fx.b, nil); code != 404 {
		t.Fatalf("bad id: %d", code)
	}
}
