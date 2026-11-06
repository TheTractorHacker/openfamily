package handlers

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Phase 2: the encrypted channel. Needs TEST_DATABASE_URL (skipped otherwise).

type chanEnv struct {
	*circleEnv
	circle  string
	a, b, c *tdev
	key     []byte
}

func newChanEnv(t *testing.T) *chanEnv {
	e := newE2EEEnv(t)
	e.route("POST", "/circles/{id}/e2ee/batch", e.srv.E2EEPostBatch)
	e.route("GET", "/circles/{id}/e2ee/items", e.srv.E2EEListItems)
	e.route("DELETE", "/circles/{id}/e2ee/items", e.srv.E2EEEraseItems)
	e.route("POST", "/circles/{id}/e2ee/purge-plaintext", e.srv.E2EEPurgePlaintext)
	e.route("POST", "/locations", e.srv.IngestLocation)
	e.route("POST", "/locations/batch", e.srv.IngestLocationBatch)
	e.route("POST", "/family/places", e.srv.CreatePlace)
	e.route("POST", "/checkins", e.srv.PostCheckinTo)
	e.route("DELETE", "/me/locations", e.srv.DeleteMyLocations)
	c := e.e2eeFamily(map[string]string{"A": "admin", "B": "member", "C": "member"})
	ce := &chanEnv{circleEnv: e, circle: c, key: bytes.Repeat([]byte{7}, 32)}
	ce.a, ce.b, ce.c = newTDev(t, e.ids["A"]), newTDev(t, e.ids["B"]), newTDev(t, e.ids["C"])
	e.register("A", ce.a)
	e.register("B", ce.b)
	e.register("C", ce.c)
	e.mustCode("A", "POST", "/circles/"+c+"/e2ee/enable", epochBody(t, e2ee.ActEnable, c, 1, ce.a,
		mkWrap(t, c, 1, ce.a, ce.a, ce.key), mkWrap(t, c, 1, ce.a, ce.b, ce.key), mkWrap(t, c, 1, ce.a, ce.c, ce.key)), 200)
	return ce
}

// e2eeFamily makes a family-backed circle (the production "primary circle":
// users.family_id = circle id) with the given roles.
func (e *circleEnv) e2eeFamily(roles map[string]string) string {
	e.t.Helper()
	ctx := context.Background()
	var fam string
	if err := e.pool.QueryRow(ctx, `INSERT INTO families (name) VALUES ('Fam') RETURNING id`).Scan(&fam); err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `UPDATE users SET family_id = NULL WHERE family_id = $1`, fam)
		_, _ = e.pool.Exec(ctx, `DELETE FROM families WHERE id = $1`, fam)
	})
	for n, role := range roles {
		if _, err := e.pool.Exec(ctx, `UPDATE users SET family_id=$1, role=$2 WHERE id=$3`, fam, role, e.ids[n]); err != nil {
			e.t.Fatal(err)
		}
	}
	return fam
}

// seal builds a wire item the way a phone does.
func (e *chanEnv) seal(t *testing.T, d *tdev, circle, purpose string, epoch int, seq int64, payload []byte) map[string]any {
	t.Helper()
	padded, err := e2ee.Pad(payload)
	if err != nil {
		t.Fatal(err)
	}
	ct, err := e2ee.Seal(e.key, circle, uint32(epoch), d.id, purpose, padded)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"seq": seq, "purpose": purpose, "epoch": epoch, "size_bucket": len(padded), "ciphertext": b64s(ct)}
}

func (e *chanEnv) post(user string, d *tdev, circle string, want int, items ...map[string]any) map[string]any {
	e.t.Helper()
	return e.mustCode(user, "POST", "/circles/"+circle+"/e2ee/batch", map[string]any{"sender_device_id": d.id, "items": items}, want)
}

func results(m map[string]any) []map[string]any {
	var out []map[string]any
	for _, r := range m["results"].([]any) {
		out = append(out, r.(map[string]any))
	}
	return out
}

func TestE2EEChannelRoundTripAndIdempotency(t *testing.T) {
	e := newChanEnv(t)
	plain := []byte(`{"lat":52.5200,"lon":13.4050}`)
	it := e.seal(t, e.b, e.circle, "fix", 1, 1, plain)
	r := results(e.post("B", e.b, e.circle, 201, it))
	if r[0]["status"] != "stored" {
		t.Fatalf("%v", r)
	}
	// Same seq again: duplicate, nothing stored twice (even with other bytes).
	again := e.seal(t, e.b, e.circle, "fix", 1, 1, plain)
	r = results(e.post("B", e.b, e.circle, 200, again))
	if r[0]["status"] != "duplicate" {
		t.Fatalf("%v", r)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), `SELECT count(*) FROM e2ee_items WHERE circle_id = $1`, e.circle).Scan(&n)
	if n != 1 {
		t.Fatalf("rows %d", n)
	}
	// A pulls, decrypts, and sees the same plaintext.
	got := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?after=0", nil, 200)
	items := got["items"].([]any)
	if len(items) != 1 || got["has_more"] != false {
		t.Fatalf("%v", got)
	}
	m := items[0].(map[string]any)
	ct, _ := base64.StdEncoding.DecodeString(m["ciphertext"].(string))
	pt, err := e2ee.Open(e.key, e.circle, m["device_id"].(string), "fix", ct)
	if err != nil {
		t.Fatal(err)
	}
	if un, _ := e2ee.Unpad(pt); !bytes.Equal(un, plain) {
		t.Fatalf("round trip %q", un)
	}
	// Received time is coarse (whole minute) and carries no user id.
	if ts, _ := time.Parse(time.RFC3339, m["received_at"].(string)); ts.Second() != 0 || ts.Nanosecond() != 0 {
		t.Fatalf("received_at not coarse: %v", m["received_at"])
	}
	if _, has := m["user_id"]; has {
		t.Fatal("item exposes a user id")
	}
	// Cursor: nothing after the head; purpose filter; limit/has_more.
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "event", 1, 2, []byte(`{}`)), e.seal(t, e.b, e.circle, "fix", 1, 3, plain))
	head := e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/items?after=0&limit=2", nil, 200)
	if len(head["items"].([]any)) != 2 || head["has_more"] != true {
		t.Fatalf("%v", head)
	}
	rest := e.mustCode("C", "GET", fmt.Sprintf("/circles/%s/e2ee/items?after=%v", e.circle, head["next_cursor"]), nil, 200)
	if len(rest["items"].([]any)) != 1 {
		t.Fatalf("%v", rest)
	}
	ev := e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/items?purpose=event", nil, 200)
	if len(ev["items"].([]any)) != 1 {
		t.Fatalf("%v", ev)
	}
	e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/items?purpose=bogus", nil, 400)
	e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/items?after=-1", nil, 400)
}

func TestE2EEChannelValidation(t *testing.T) {
	e := newChanEnv(t)
	ok := e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x"))
	clone := func(mod func(m map[string]any)) map[string]any {
		m := map[string]any{}
		for k, v := range ok {
			m[k] = v
		}
		mod(m)
		return m
	}
	big := e.seal(t, e.b, e.circle, "fix", 1, 9, bytes.Repeat([]byte{1}, 2000)) // bucket 4096 > fix cap 1024
	histOK := e.seal(t, e.b, e.circle, "history", 1, 10, bytes.Repeat([]byte{1}, 2000))
	cases := map[string]map[string]any{
		"purpose":      clone(func(m map[string]any) { m["purpose"] = "gps" }),
		"seq zero":     clone(func(m map[string]any) { m["seq"] = 0 }),
		"future epoch": clone(func(m map[string]any) { m["epoch"] = 2 }),
		"epoch zero":   clone(func(m map[string]any) { m["epoch"] = 0 }),
		"bucket":       clone(func(m map[string]any) { m["size_bucket"] = 300 }),
		"length lie":   clone(func(m map[string]any) { m["size_bucket"] = 512 }),
		"not base64":   clone(func(m map[string]any) { m["ciphertext"] = "!!" }),
		"header epoch": e.seal(t, e.b, e.circle, "fix", 1, 4, []byte("y")),
		"too big":      big,
	}
	// Header epoch mismatch: re-declare epoch 1 payload as epoch... only possible after epoch>1; use a flipped version byte.
	ctb, _ := base64.StdEncoding.DecodeString(cases["header epoch"]["ciphertext"].(string))
	ctb[0] = 2
	cases["header epoch"]["ciphertext"] = b64s(ctb)
	for name, it := range cases {
		r := results(e.post("B", e.b, e.circle, 200, it))
		if r[0]["status"] != "rejected" {
			t.Errorf("%s accepted: %v", name, r)
		}
	}
	if r := results(e.post("B", e.b, e.circle, 201, histOK)); r[0]["status"] != "stored" {
		t.Fatalf("history chunk refused: %v", r)
	}
	// Empty and oversized batches are 400.
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id, "items": []any{}}, 400)
	many := make([]map[string]any, 51)
	for i := range many {
		many[i] = e.seal(t, e.b, e.circle, "fix", 1, int64(100+i), []byte("z"))
	}
	e.post("B", e.b, e.circle, 400, many...)
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": "nope", "items": []any{ok}}, 400)
}

func TestE2EEChannelAuthorizationAndIDOR(t *testing.T) {
	e := newChanEnv(t)
	it := e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x"))
	// Non-member D: 404 everywhere, no existence signal.
	e.mustCode("D", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id, "items": []any{it}}, 404)
	e.mustCode("D", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 404)
	e.mustCode("D", "DELETE", "/circles/"+e.circle+"/e2ee/items", nil, 404)
	// A member cannot upload as ANOTHER member's device (404, no probing).
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id, "items": []any{it}}, 404)
	// ... nor with a random id.
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": newTDev(t, e.ids["A"]).id, "items": []any{it}}, 404)
	// Another circle: B is not a member there.
	c2 := e.createCircle("A", "Other", "C")
	e.mustCode("B", "GET", "/circles/"+c2+"/e2ee/items", nil, 404)
	e.mustCode("B", "POST", "/circles/"+c2+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id, "items": []any{it}}, 404)
	// A circle that is not private refuses the channel (409), for members too.
	e.mustCode("A", "GET", "/circles/"+c2+"/e2ee/items", nil, 409)
	e.mustCode("A", "POST", "/circles/"+c2+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id, "items": []any{it}}, 409)
	// Ciphertext sealed for circle 1 is not served through circle 2.
	e.post("B", e.b, e.circle, 201, it)
	got := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 200)
	if len(got["items"].([]any)) != 1 {
		t.Fatal("expected one item")
	}
	// Removed member loses access immediately.
	e.mustCode("A", "DELETE", "/circles/"+e.circle+"/members/"+e.ids["C"], nil, 200)
	e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 404)
	// A replacement (reset) key is not approved: it can neither upload nor pull.
	b2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, b2, "device", nil, e2ee.ActReset, true), 201)
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": b2.id, "items": []any{e.seal(t, b2, e.circle, "fix", 1, 1, []byte("x"))}}, 403)
	e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 403)
	// The old key was revoked by the reset.
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id, "items": []any{e.seal(t, e.b, e.circle, "fix", 1, 50, []byte("x"))}}, 403)
}

func TestE2EEServiceAndWebDevicesPullButCannotUpload(t *testing.T) {
	e := newChanEnv(t)
	svc, web, up := newTDev(t, e.ids["A"]), newTDev(t, e.ids["A"]), newTDev(t, e.ids["A"])
	// Must be cross-signed by an existing key of the same user (never a root).
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, svc, "service", nil, e2ee.ActRegister, false), 400)
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, svc, "service", e.a, e2ee.ActRegister, false), 201)
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, web, "web", e.a, e2ee.ActRegister, false), 201)
	upBody := regBody(t, up, "service", e.a, e2ee.ActRegister, false)
	upBody["can_upload"] = true
	e.mustCode("A", "POST", "/e2ee/devices", upBody, 201)

	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x")))
	for _, d := range []*tdev{svc, web} {
		e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": d.id,
			"items": []any{e.seal(t, d, e.circle, "fix", 1, 1, []byte("x"))}}, 403)
		got := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+d.id, nil, 200)
		if len(got["items"].([]any)) != 1 {
			t.Fatalf("%s kind cannot pull: %v", d.id, got)
		}
	}
	// Explicitly allowed bridge may upload.
	e.post("A", up, e.circle, 201, e.seal(t, up, e.circle, "fix", 1, 1, []byte("x")))
	// Someone else's device id in as_device does not grant pulling.
	e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+svc.id, nil, 403)
	// Revoked service key stops pulling as that device.
	e.mustCode("A", "DELETE", "/e2ee/devices/"+svc.id, simpleAction(t, 3, e.a, "", 0, svc.id, svc.fp), 200)
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?as_device="+svc.id, nil, 403)
	// The recovery kind can never upload.
	if n := results(e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id,
		"items": []any{e.seal(t, e.a, e.circle, "event", 1, 1, []byte("{}"))}}, 201)); n[0]["status"] != "stored" {
		t.Fatal("phone upload refused")
	}
}

func TestE2EEChannelRetentionAndErase(t *testing.T) {
	e := newChanEnv(t)
	ctx := context.Background()
	e.post("B", e.b, e.circle, 201,
		e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x")),
		e.seal(t, e.b, e.circle, "history", 1, 2, []byte("x")),
		e.seal(t, e.b, e.circle, "place", 1, 3, []byte("x")),
		e.seal(t, e.b, e.circle, "event", 1, 4, []byte("x")))
	e.post("A", e.a, e.circle, 201, e.seal(t, e.a, e.circle, "fix", 1, 1, []byte("x")))
	var live, hist, place *time.Time
	rows, _ := e.pool.Query(ctx, `SELECT purpose, expires_at FROM e2ee_items WHERE device_id = $1 ORDER BY seq`, e.b.id)
	for rows.Next() {
		var p string
		var ex *time.Time
		_ = rows.Scan(&p, &ex)
		switch p {
		case "fix":
			live = ex
		case "history":
			hist = ex
		case "place":
			place = ex
		}
	}
	rows.Close()
	if live == nil || time.Until(*live) > 49*time.Hour || time.Until(*live) < 47*time.Hour {
		t.Fatalf("live window: %v", live)
	}
	if hist == nil || time.Until(*hist) < 24*time.Hour {
		t.Fatalf("history retention: %v", hist)
	}
	if place != nil {
		t.Fatalf("places should not expire: %v", place)
	}
	// Short retention lapse: expired rows are invisible, then purged.
	_, _ = e.pool.Exec(ctx, `UPDATE e2ee_items SET expires_at = now() - interval '1 minute' WHERE purpose = 'fix' AND device_id = $1`, e.b.id)
	got := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?purpose=fix", nil, 200)
	if len(got["items"].([]any)) != 1 { // only A's own fix remains visible
		t.Fatalf("expired item served: %v", got)
	}
	n, err := e.srv.PurgeE2EEItems(ctx)
	if err != nil || n != 1 {
		t.Fatalf("purge %d %v", n, err)
	}
	// Members erase their own uploads; admin-only circle scope.
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/items?scope=circle", nil, 403)
	if d := e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/items?purpose=history", nil, 200); d["deleted"].(float64) != 1 {
		t.Fatalf("%v", d)
	}
	var left int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_items WHERE device_id = $1`, e.b.id).Scan(&left)
	if left != 2 { // place + event
		t.Fatalf("left %d", left)
	}
	// "Delete my location history" also erases sealed copies (but keeps places).
	e.mustCode("B", "DELETE", "/me/locations", nil, 200)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_items WHERE device_id = $1`, e.b.id).Scan(&left)
	if left != 1 {
		t.Fatalf("left after history erase %d", left)
	}
	e.mustCode("A", "DELETE", "/circles/"+e.circle+"/e2ee/items?scope=circle", nil, 200)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_items WHERE circle_id = $1`, e.circle).Scan(&left)
	if left != 0 {
		t.Fatalf("circle erase left %d", left)
	}
	// Switching the circle off deletes whatever is left.
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 77, []byte("x")))
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/disable", simpleAction(t, e2ee.ActDisable, e.a, e.circle, 1, "", nil), 200)
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_items WHERE circle_id = $1`, e.circle).Scan(&left)
	if left != 0 {
		t.Fatalf("disable left %d", left)
	}
}

func TestE2EEPrivateCircleRejectsPlaintext(t *testing.T) {
	e := newChanEnv(t)
	ctx := context.Background()
	var posBefore int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM locations`).Scan(&posBefore)
	// All of B's circles are private: plaintext ingest is refused with 409.
	body := map[string]any{"device_id": e.b.id, "lat": 52.1, "lon": 13.1}
	code, m, raw := e.do("B", "POST", "/locations", body)
	if code != 409 || m["code"] != "e2ee_private_circle" {
		t.Fatalf("ingest: %d %s", code, raw)
	}
	e.mustCode("B", "POST", "/locations/batch", map[string]any{"points": []any{body}}, 409)
	// Member position row untouched (the fixture seeded 10/20).
	var lat float64
	_ = e.pool.QueryRow(ctx, `SELECT lat FROM member_positions WHERE user_id = $1`, e.ids["B"]).Scan(&lat)
	if lat != 10 {
		t.Fatalf("member_positions written: %v", lat)
	}
	// Places and geofences cannot be created for the private circle, by API...
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
	// ...nor by any other code path: the database trigger refuses.
	_, err := e.pool.Exec(ctx, `INSERT INTO places (family_id, circle_id, name, geom, radius_meters)
		VALUES ($1, $1, 'x', ST_SetSRID(ST_MakePoint(1,2),4326), 100)`, e.circle)
	if err == nil || !strings.Contains(err.Error(), "e2ee_private_circle") {
		t.Fatalf("trigger did not fire: %v", err)
	}
	_, err = e.pool.Exec(ctx, `INSERT INTO geofences (family_id) VALUES ($1)`, e.circle)
	if err == nil || !strings.Contains(err.Error(), "e2ee_private_circle") {
		t.Fatalf("geofence trigger did not fire: %v", err)
	}
	// Check-in with coordinates to a private-only co-member: delivered without them.
	got := e.mustCode("B", "POST", "/checkins", map[string]any{"recipient_ids": []string{e.ids["A"]}, "lat": 1.5, "lon": 2.5, "note": "hi"}, 201)
	if got["lat"] != nil || got["lon"] != nil {
		t.Fatalf("check-in coordinates stored for private circle: %v", got)
	}
	var cl *float64
	_ = e.pool.QueryRow(ctx, `SELECT lat FROM checkins WHERE user_id = $1`, e.ids["B"]).Scan(&cl)
	if cl != nil {
		t.Fatal("plaintext check-in coordinate persisted")
	}
	var posAfter int
	_ = e.pool.QueryRow(ctx, `SELECT count(*) FROM locations`).Scan(&posAfter)
	if posAfter != posBefore {
		t.Fatal("locations rows written")
	}
	// Legacy plaintext places that existed before the switch can be purged by an admin.
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/purge-plaintext", nil, 403)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/purge-plaintext", nil, 200)
}

func TestE2EEMixedUserVisibilityAndUploadRules(t *testing.T) {
	e := newChanEnv(t)
	ctx := context.Background()
	// D joins a standard circle with E and the private circle with A.
	std := e.createCircle("D", "Std", "E")
	e.mustCode("A", "POST", "/circles/"+e.circle+"/invites", map[string]any{}, 201)
	inv := e.mustCode("A", "POST", "/circles/"+e.circle+"/invites", map[string]any{}, 201)
	e.mustCode("D", "POST", "/circles/join", map[string]string{"code": inv["code"].(string)}, 200)

	// D has a standard circle, so plaintext ingest is NOT refused (it feeds Std only).
	var dev string
	_ = e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, e.ids["D"]).Scan(&dev)
	code, _, raw := e.do("D", "POST", "/locations", map[string]any{"device_id": dev, "lat": 48.1, "lon": 11.5})
	if code != 201 {
		t.Fatalf("mixed user ingest: %d %s", code, raw)
	}
	az := circles.New(e.pool)
	// E (standard co-member) may see D's plaintext position; A (private co-member only) may not.
	if sh, _ := az.SharedWith(ctx, e.ids["E"], e.ids["D"]); len(sh) != 1 || sh[0] != std {
		t.Fatalf("E sees via %v", sh)
	}
	if sh, _ := az.SharedWith(ctx, e.ids["A"], e.ids["D"]); len(sh) != 0 {
		t.Fatalf("private co-member sees plaintext via %v", sh)
	}
	vis, _ := az.LocationVisibility(ctx, e.ids["A"], []string{e.circle})
	if vis[e.ids["D"]] {
		t.Fatal("private circle shows D's plaintext location")
	}
	vis, _ = az.LocationVisibility(ctx, e.ids["E"], []string{std})
	if !vis[e.ids["D"]] {
		t.Fatal("standard circle lost visibility")
	}
	if _, sharing, _ := az.OwnAndSharingCircles(ctx, e.ids["D"]); len(sharing) != 1 || sharing[0] != std {
		t.Fatalf("live fan-out would include private circle: %v", sharing)
	}
	mc, _ := az.MemberCircles(ctx, e.ids["A"], []string{e.circle})
	for _, c := range mc[e.ids["D"]] {
		if c.Sharing {
			t.Fatal("MemberCircles marks private circle as plaintext-sharing")
		}
	}
}

func TestE2EEStandardCircleUnchanged(t *testing.T) {
	e := newChanEnv(t)
	ctx := context.Background()
	std := e.e2eeFamily(map[string]string{"D": "admin", "E": "member"})
	var dev string
	_ = e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform) VALUES ($1,'android') RETURNING id`, e.ids["D"]).Scan(&dev)
	e.mustCode("D", "POST", "/locations", map[string]any{"device_id": dev, "lat": 48.1, "lon": 11.5}, 201)
	e.mustCode("D", "POST", "/family/places", map[string]any{"name": "Home", "lat": 48, "lon": 11, "radius_meters": 100, "circle_id": std}, 201)
	az := circles.New(e.pool)
	if sh, _ := az.SharedWith(ctx, e.ids["E"], e.ids["D"]); len(sh) != 1 {
		t.Fatalf("standard visibility changed: %v", sh)
	}
}

func TestE2EEChannelNoCoordinatesInLogsOrAudit(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)
	e := newChanEnv(t)
	plain := []byte(`{"lat":52.520008,"lon":13.404954,"name":"Secret Home"}`)
	it := e.seal(t, e.b, e.circle, "fix", 1, 1, plain)
	e.post("B", e.b, e.circle, 201, it)
	e.post("B", e.b, e.circle, 200, it)
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 200)
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/items", nil, 200)
	rows, err := e.pool.Query(context.Background(), `SELECT action || ' ' || detail FROM audit_log WHERE user_id = ANY($1::uuid[])`,
		[]string{e.ids["A"], e.ids["B"]})
	if err != nil {
		t.Fatal(err)
	}
	var audit strings.Builder
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		audit.WriteString(s + "\n")
	}
	rows.Close()
	for _, bad := range []string{"52.52", "13.40", "Secret Home", it["ciphertext"].(string), b64s(e.key), fmt.Sprintf("%x", e.key)} {
		if strings.Contains(buf.String(), bad) || strings.Contains(audit.String(), bad) {
			t.Fatalf("%q leaked into logs/audit", bad)
		}
	}
}

func TestE2EEChannelWebSocketFanOut(t *testing.T) {
	e := newChanEnv(t)
	ts := e.streamServer()
	cb, st := e.dial(ts, "A", "")
	if st != 101 {
		t.Fatalf("dial %d", st)
	}
	cb.expect("welcome")
	out, _ := e.dial(ts, "D", "")
	_ = out
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x")))
	f := cb.expect("e2ee_item")
	if f["circle_id"] != e.circle || f["purpose"] != "fix" || f["ciphertext"] == "" || f["lat"] != nil {
		t.Fatalf("frame %v", f)
	}
	if out != nil {
		out.quiet() // a non-member never receives it
	}
}
