package handlers

import (
	"bytes"
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Encrypted chat (docs/design/E2EE_CHAT.md). Needs TEST_DATABASE_URL.

func addChatRoutes(e *circleEnv) {
	e.route("GET", "/circles/{id}/chat", e.srv.ListChatMessages)
	e.route("POST", "/circles/{id}/chat", e.srv.SendChatMessage)
	e.route("POST", "/circles/{id}/chat/read", e.srv.MarkChatRead)
	e.route("POST", "/circles/{id}/chat/photo", e.srv.SendChatPhoto)
	e.route("GET", "/chat/unread", e.srv.ChatUnread)
	e.route("PATCH", "/circles/{id}/chat/{msgId}", e.srv.EditChatMessage)
	e.route("DELETE", "/circles/{id}/chat/history", e.srv.DeleteChatPlaintextHistory)
	e.route("DELETE", "/circles/{id}/chat/{msgId}", e.srv.DeleteChatMessage)
	e.route("POST", "/circles/{id}/e2ee/blobs", e.srv.E2EEPostBlob)
	e.route("GET", "/circles/{id}/e2ee/blobs/{blobId}", e.srv.E2EEGetBlob)
}

func TestChatNeverOnServerLineEvenInServerLane(t *testing.T) {
	e := readyLanes(t) // A and B are in lane server, C has no pref
	// A server-line chat item from a lane-server author is refused by the handler ...
	bad := e.sealV2(e.a, e.serverLine(), 1, 1, "chat")
	rs := results(e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id, "items": []any{bad}}, 200))
	if rs[0]["status"] != "rejected" || rs[0]["error"] != "chat_phone_only" {
		t.Fatalf("server-line chat: %v", rs)
	}
	// ... and by the database even if the handler were bypassed.
	err := e.sqlErr(`INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at, key_line)
		VALUES ($1,$2,77,'chat',1,256,'\x00',now(),'server')`, e.circle, e.a.id)
	if err == nil || !strings.Contains(err.Error(), "chat_phone_only") {
		t.Fatalf("DB accepted server-line chat: %v", err)
	}
	// The same author's phone-line chat is relayed.
	ok := e.sealV2(e.a, e.phoneLine(), 1, 2, "chat")
	if r := results(e.post("A", e.a, e.circle, 201, ok)); r[0]["status"] != "stored" {
		t.Fatalf("%v", r)
	}
	// The server key (sidecar) never receives chat, whatever it asks for.
	for _, q := range []string{"?key_line=server&as_device=", "?key_line=all&as_device=", "?key_line=phone&as_device=", "?purpose=chat&key_line=all&as_device="} {
		got := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items"+q+e.s.id, nil, 200)
		for _, it := range got["items"].([]any) {
			if it.(map[string]any)["purpose"] == "chat" {
				t.Fatalf("server key was served chat with %q", q)
			}
		}
	}
	// A phone sees it.
	if n := len(e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items?purpose=chat", nil, 200)["items"].([]any)); n != 1 {
		t.Fatalf("phone pull: %d", n)
	}
	// Leaving the server lane ends server copies, never chat (it was never one).
	e.setLane("A", e.a, "phone", 0, 200)
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND purpose = 'chat'`, e.circle) != 1 {
		t.Fatal("chat item vanished with the lane")
	}
}

func TestChatRelayedInRequiredServerCircle(t *testing.T) {
	e := newLaneEnv(t)
	e.enableAssist("required_server")
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	// C never consented to the server lane: fixes are refused, chat is not.
	if r := results(e.mustCode("C", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.c.id,
		"items": []any{e.sealV2(e.c, e.phoneLine(), 1, 1, "fix")}}, 200)); r[0]["error"] != "required_server" {
		t.Fatalf("%v", r)
	}
	if r := results(e.post("C", e.c, e.circle, 201, e.sealV2(e.c, e.phoneLine(), 1, 2, "chat"))); r[0]["status"] != "stored" {
		t.Fatalf("chat blocked in a required_server circle: %v", r)
	}
}

func TestPlaintextChatRefusedInPrivateCircle(t *testing.T) {
	e := newChanEnv(t)
	addChatRoutes(e.circleEnv)
	// History written before the circle turned private.
	e.sql2(`ALTER TABLE chat_messages DISABLE TRIGGER trg_chat_plaintext_guard`)
	e.sql2(`INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1,$2,'old plaintext hello')`, e.circle, e.ids["B"])
	e.sql2(`ALTER TABLE chat_messages ENABLE TRIGGER trg_chat_plaintext_guard`)

	code, m, _ := e.do("B", "POST", "/circles/"+e.circle+"/chat", map[string]string{"body": "secret", "client_id": "c1"})
	if code != 409 || m["code"] != "chat_encrypted" {
		t.Fatalf("send: %d %v", code, m)
	}
	if code, m, _ = e.do("B", "PATCH", "/circles/"+e.circle+"/chat/00000000-0000-0000-0000-000000000000", map[string]string{"body": "x"}); code != 409 || m["code"] != "chat_encrypted" {
		t.Fatalf("edit: %d %v", code, m)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/circles/"+e.circle+"/chat/photo", bytes.NewReader([]byte{0xff, 0xd8}))
	req.Header.Set("X-Test-User", e.ids["B"])
	req.Header.Set("Content-Type", "image/jpeg")
	e.rt.ServeHTTP(rec, req)
	if rec.Code != 409 || !strings.Contains(rec.Body.String(), "chat_encrypted") {
		t.Fatalf("photo: %d %s", rec.Code, rec.Body.String())
	}
	// The DB backstop refuses a plaintext row even from a rogue writer.
	if err := e.sqlErr(`INSERT INTO chat_messages (circle_id, sender_id, body) VALUES ($1,$2,'sneaky')`, e.circle, e.ids["B"]); err == nil || !strings.Contains(err.Error(), "e2ee_chat_encrypted") {
		t.Fatalf("db accepted plaintext chat: %v", err)
	}
	if e.count(`SELECT count(*) FROM chat_messages WHERE body IN ('secret','sneaky')`) != 0 {
		t.Fatal("plaintext stored")
	}
	// Old history stays readable, flagged encrypted so the app marks it.
	got := e.mustCode("A", "GET", "/circles/"+e.circle+"/chat", nil, 200)
	if got["encrypted"] != true || len(got["messages"].([]any)) != 1 {
		t.Fatalf("history: %v", got)
	}
	// Only an admin may delete the old plaintext history.
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/chat/history", nil, 403)
	if d := e.mustCode("A", "DELETE", "/circles/"+e.circle+"/chat/history", nil, 200); d["deleted"].(float64) != 1 {
		t.Fatalf("%v", d)
	}
	if e.count(`SELECT count(*) FROM chat_messages WHERE circle_id = $1`, e.circle) != 0 {
		t.Fatal("history not deleted")
	}
	// A normal circle keeps plaintext chat unchanged.
	std := e.createCircle("A", "Std", "B")
	e.mustCode("B", "POST", "/circles/"+std+"/chat", map[string]string{"body": "hello standard"}, 201)
	if g := e.mustCode("A", "GET", "/circles/"+std+"/chat", nil, 200); g["encrypted"] != false || len(g["messages"].([]any)) != 1 {
		t.Fatalf("%v", g)
	}
}

func (e *chanEnv) sql2(q string, args ...any) {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(), q, args...); err != nil {
		e.t.Fatalf("%s: %v", q, err)
	}
}
func (e *chanEnv) sqlErr(q string, args ...any) error {
	_, err := e.pool.Exec(context.Background(), q, args...)
	return err
}
func (e *chanEnv) count(q string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), q, args...).Scan(&n); err != nil {
		e.t.Fatalf("%s: %v", q, err)
	}
	return n
}

func TestEncryptedChatUnreadFromMetadata(t *testing.T) {
	e := newChanEnv(t)
	addChatRoutes(e.circleEnv)
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "chat", 1, 1, []byte("opaque1")), e.seal(t, e.b, e.circle, "chat", 1, 2, []byte("opaque2")))
	e.post("A", e.a, e.circle, 201, e.seal(t, e.a, e.circle, "chat", 1, 1, []byte("mine")))
	unread := func(u string) float64 {
		m := e.mustCode(u, "GET", "/chat/unread", nil, 200)
		c, _ := m["circles"].(map[string]any)
		v, _ := c[e.circle].(float64)
		return v
	}
	if unread("A") != 2 || unread("B") != 1 {
		t.Fatalf("unread A=%v B=%v", unread("A"), unread("B"))
	}
	var last int64
	_ = e.pool.QueryRow(context.Background(), `SELECT max(id) FROM e2ee_items WHERE circle_id = $1 AND purpose='chat'`, e.circle).Scan(&last)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/chat/read", map[string]any{"item_id": last + 1000}, 204) // clamped
	if unread("A") != 0 {
		t.Fatalf("A after read: %v", unread("A"))
	}
	// The read cursor never moves back.
	e.mustCode("A", "POST", "/circles/"+e.circle+"/chat/read", map[string]any{"item_id": 1}, 204)
	if unread("A") != 0 {
		t.Fatal("cursor moved back")
	}
}

func TestEncryptedChatRetentionConfigurable(t *testing.T) {
	e := newChanEnv(t)
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "chat", 1, 1, []byte("x")), e.seal(t, e.b, e.circle, "fix", 1, 2, []byte("x")))
	ttl := func(p string) time.Duration {
		var d time.Duration
		var exp, rec time.Time
		_ = e.pool.QueryRow(context.Background(), `SELECT expires_at, now() FROM e2ee_items WHERE circle_id=$1 AND purpose=$2`, e.circle, p).Scan(&exp, &rec)
		d = exp.Sub(rec)
		return d
	}
	if d := ttl("chat"); d < 29*24*time.Hour || d > 31*24*time.Hour {
		t.Fatalf("default chat ttl %v", d)
	}
	if ttl("chat") <= ttl("fix") {
		t.Fatal("chat must outlive live location")
	}
	t.Setenv("E2EE_CHAT_TTL_DAYS", "3")
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "chat", 1, 3, []byte("y")))
	var exp, now time.Time
	_ = e.pool.QueryRow(context.Background(), `SELECT expires_at, now() FROM e2ee_items WHERE circle_id=$1 AND seq=3`, e.circle).Scan(&exp, &now)
	if d := exp.Sub(now); d < 71*time.Hour || d > 73*time.Hour {
		t.Fatalf("configured ttl %v", d)
	}
}

func TestEncryptedBlobMembersOnlyAndOpaque(t *testing.T) {
	e := newChanEnv(t)
	addChatRoutes(e.circleEnv)
	raw := func(user, method, path string, body []byte) (int, []byte) {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if user != "" {
			req.Header.Set("X-Test-User", e.ids[user])
		}
		e.rt.ServeHTTP(rec, req)
		return rec.Code, rec.Body.Bytes()
	}
	blob := bytes.Repeat([]byte{0xAB}, 5000)
	code, out := raw("B", "POST", "/circles/"+e.circle+"/e2ee/blobs", blob)
	if code != 201 {
		t.Fatalf("%d %s", code, out)
	}
	id := strings.Split(strings.Split(string(out), `"id":"`)[1], `"`)[0]
	if code, got := raw("A", "GET", "/circles/"+e.circle+"/e2ee/blobs/"+id, nil); code != 200 || !bytes.Equal(got, blob) {
		t.Fatalf("member read %d", code)
	}
	if code, _ := raw("D", "GET", "/circles/"+e.circle+"/e2ee/blobs/"+id, nil); code != 404 {
		t.Fatalf("outsider read %d", code)
	}
	if code, _ := raw("D", "POST", "/circles/"+e.circle+"/e2ee/blobs", blob); code != 404 {
		t.Fatalf("outsider upload %d", code)
	}
	if code, _ := raw("B", "POST", "/circles/"+e.circle+"/e2ee/blobs", bytes.Repeat([]byte{1}, 7<<20)); code != 413 {
		t.Fatalf("oversize %d", code)
	}
	// A blob id from one circle is not served through another circle.
	std := e.createCircle("A", "Std", "B")
	if code, _ := raw("B", "GET", "/circles/"+std+"/e2ee/blobs/"+id, nil); code != 404 {
		t.Fatalf("cross-circle blob %d", code)
	}
	// Plain circles do not take sealed blobs.
	if code, _ := raw("B", "POST", "/circles/"+std+"/e2ee/blobs", blob); code != 409 {
		t.Fatalf("plain circle blob %d", code)
	}
}
