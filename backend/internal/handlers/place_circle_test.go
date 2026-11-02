package handlers

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/push"
)

// Per-circle places: visibility, validation and alert recipients. Needs
// TEST_DATABASE_URL (skipped otherwise).

type stubPush struct{}

func (stubPush) Dispatch(context.Context, push.Notification) error { return nil }

// placeCircleEnv: family F with A (admin), B, C (members); circle X = A + B.
func newPlaceCircleEnv(t *testing.T) (*circleEnv, string, string) {
	t.Helper()
	e := newCircleEnv(t)
	ctx := context.Background()
	e.rt.Get("/family/places", e.srv.ListPlaces)
	e.rt.Post("/family/places", e.srv.CreatePlace)
	e.rt.Patch("/family/places/{id}", e.srv.UpdatePlace)
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('plc-circle') RETURNING id`).Scan(&fam); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM families WHERE id = $1`, fam)
	})
	for n, role := range map[string]string{"A": "admin", "B": "member", "C": "member"} {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id = $1, role = $2 WHERE id = $3`, fam, role, e.ids[n]); err != nil {
			t.Fatal(err)
		}
	}
	x := e.createCircle("A", "Extended", "B")
	return e, fam, x
}

func (e *circleEnv) placeNames(user string) map[string]bool {
	e.t.Helper()
	_, _, raw := e.do(user, "GET", "/family/places", nil)
	out := map[string]bool{}
	var list []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		e.t.Fatalf("%s: %v", raw, err)
	}
	for _, p := range list {
		out[p.Name] = true
	}
	return out
}

func TestCirclePlaceVisibilityAndValidation(t *testing.T) {
	e, _, x := newPlaceCircleEnv(t)
	body := func(name string, lat float64, circle any) map[string]any {
		return map[string]any{"name": name, "lat": lat, "lon": -75.0, "radius_meters": 200.0, "circle_id": circle}
	}
	// C is not a member of circle X, so cannot scope a place to it.
	e.mustCode("C", "POST", "/family/places", body("Nope", 40.0, x), 400)
	e.mustCode("A", "POST", "/family/places", body("Bad", 40.0, "not-a-uuid"), 400)

	cabin := e.mustCode("A", "POST", "/family/places", body("Cabin", 41.0, x), 201)
	if cabin["circle_id"] != x || cabin["circle_name"] != "Extended" {
		t.Fatalf("circle fields missing: %v", cabin)
	}
	e.mustCode("A", "POST", "/family/places", body("Home", 42.0, nil), 201)

	if got := e.placeNames("A"); !got["Cabin"] || !got["Home"] {
		t.Fatalf("A should see both: %v", got)
	}
	if got := e.placeNames("B"); !got["Cabin"] || !got["Home"] {
		t.Fatalf("B (circle member) should see both: %v", got)
	}
	if got := e.placeNames("C"); got["Cabin"] || !got["Home"] {
		t.Fatalf("C must see only the family-wide place: %v", got)
	}
	// A non-member cannot touch a circle place by id either.
	e.mustCode("C", "PATCH", "/family/places/"+cabin["id"].(string), map[string]any{"name": "x"}, 404)

	// Making it family-wide reveals it; scoping back hides it again.
	e.mustCode("A", "PATCH", "/family/places/"+cabin["id"].(string), map[string]any{"circle_id": nil}, 200)
	if !e.placeNames("C")["Cabin"] {
		t.Fatal("family-wide place should be visible to C")
	}
	got := e.mustCode("A", "PATCH", "/family/places/"+cabin["id"].(string), map[string]any{"circle_id": x}, 200)
	if got["circle_id"] != x || e.placeNames("C")["Cabin"] {
		t.Fatalf("re-scoping failed: %v", got)
	}
}

func TestCirclePlaceAlertRecipients(t *testing.T) {
	e, fam, x := newPlaceCircleEnv(t)
	ctx := context.Background()
	srv := &Server{Pool: e.pool, Push: stubPush{}}
	for _, n := range []string{"B", "C"} {
		if _, err := e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1, 'android', 'https://up.example/x')`, e.ids[n]); err != nil {
			t.Fatal(err)
		}
	}
	recipients := func(circle any) map[string]bool {
		t.Helper()
		var placeID, gfID, evID string
		if err := e.pool.QueryRow(ctx, `
			INSERT INTO places (family_id, name, geom, radius_meters, circle_id)
			VALUES ($1, 'p', ST_SetSRID(ST_MakePoint(-75, 40), 4326), 200, $2) RETURNING id`, fam, circle).Scan(&placeID); err != nil {
			t.Fatal(err)
		}
		if err := e.pool.QueryRow(ctx, `INSERT INTO geofences (family_id, place_id) VALUES ($1, $2) RETURNING id`, fam, placeID).Scan(&gfID); err != nil {
			t.Fatal(err)
		}
		tx, err := e.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if err := tx.QueryRow(ctx, `
			INSERT INTO geofence_events (geofence_id, user_id, place_id, event_type, ts)
			VALUES ($1, $2, $3, 'enter', now()) RETURNING id`, gfID, e.ids["A"], placeID).Scan(&evID); err != nil {
			t.Fatal(err)
		}
		if err := srv.createEventDeviceRows(ctx, tx, evID, e.ids["A"], fam, "enter"); err != nil {
			t.Fatal(err)
		}
		rows, err := tx.Query(ctx, `SELECT dev.user_id::text FROM geofence_event_devices d JOIN devices dev ON dev.id = d.device_id WHERE d.event_id = $1`, evID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]bool{}
		for rows.Next() {
			var u string
			_ = rows.Scan(&u)
			out[u] = true
		}
		return out
	}
	if got := recipients(nil); !got[e.ids["B"]] || !got[e.ids["C"]] {
		t.Fatalf("family-wide place must alert B and C: %v", got)
	}
	if got := recipients(x); !got[e.ids["B"]] || got[e.ids["C"]] {
		t.Fatalf("circle place must alert B only: %v", got)
	}
}
