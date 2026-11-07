package handlers

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

func chatEnv(t *testing.T) *circleEnv {
	t.Helper()
	e := newCircleEnv(t)
	e.rt.Get("/circles/{id}/chat", e.srv.ListChatMessages)
	e.rt.Post("/circles/{id}/chat", e.srv.SendChatMessage)
	e.rt.Post("/circles/{id}/chat/read", e.srv.MarkChatRead)
	e.rt.Post("/circles/{id}/chat/photo", e.srv.SendChatPhoto)
	e.rt.Get("/circles/{id}/chat/{msgId}/photo", e.srv.GetChatPhoto)
	e.rt.Get("/chat/unread", e.srv.ChatUnread)
	e.rt.Patch("/circles/{id}/chat/{msgId}", e.srv.EditChatMessage)
	e.rt.Delete("/circles/{id}/chat/{msgId}", e.srv.DeleteChatMessage)
	return e
}

func TestChatAuthorization(t *testing.T) {
	e := chatEnv(t)
	c := e.createCircle("A", "Chatters", "B") // A admin, B member; D outsider
	e.mustCode("A", "POST", "/circles/"+c+"/chat", map[string]string{"body": "hello"}, 201)

	for _, tc := range []struct {
		name, user, method, path string
		body                     any
		want                     int
	}{
		{"anon list", "", "GET", "/circles/" + c + "/chat", nil, 401},
		{"anon send", "", "POST", "/circles/" + c + "/chat", map[string]string{"body": "x"}, 401},
		{"outsider list", "D", "GET", "/circles/" + c + "/chat", nil, 404},
		{"outsider send", "D", "POST", "/circles/" + c + "/chat", map[string]string{"body": "x"}, 404},
		{"outsider read", "D", "POST", "/circles/" + c + "/chat/read", nil, 404},
		{"malformed id", "A", "GET", "/circles/nope/chat", nil, 404},
		{"member list", "B", "GET", "/circles/" + c + "/chat", nil, 200},
		{"member send", "B", "POST", "/circles/" + c + "/chat", map[string]string{"body": "hi"}, 201},
	} {
		if code, _, raw := e.do(tc.user, tc.method, tc.path, tc.body); code != tc.want {
			t.Errorf("%s: got %d want %d: %s", tc.name, code, tc.want, raw)
		}
	}
	// The outsider's rejected send stored nothing.
	var n int
	if err := e.pool.QueryRow(t.Context(), `SELECT count(*) FROM chat_messages WHERE circle_id=$1`, c).Scan(&n); err != nil || n != 2 {
		t.Fatalf("stored messages = %d, %v; want 2", n, err)
	}
	// A circle's chat is invisible from another circle the user belongs to.
	other := e.createCircle("D", "Other")
	_, m, _ := e.do("D", "GET", "/circles/"+other+"/chat", nil)
	if msgs, _ := m["messages"].([]any); len(msgs) != 0 {
		t.Fatalf("other circle leaked messages: %v", msgs)
	}
	// A removed member loses access immediately.
	e.mustCode("A", "DELETE", "/circles/"+c+"/members/"+e.ids["B"], nil, 200)
	e.mustCode("B", "GET", "/circles/"+c+"/chat", nil, 404)
	e.mustCode("B", "POST", "/circles/"+c+"/chat", map[string]string{"body": "x"}, 404)
}

func TestChatValidationAndLimits(t *testing.T) {
	e := chatEnv(t)
	c := e.createCircle("A", "Limits")
	path := "/circles/" + c + "/chat"
	e.mustCode("A", "POST", path, map[string]string{"body": "   "}, 400)
	e.mustCode("A", "POST", path, map[string]string{"body": strings.Repeat("é", maxChatBodyLen+1)}, 413)
	e.mustCode("A", "POST", path, map[string]string{"body": strings.Repeat("é", maxChatBodyLen)}, 201)
	e.mustCode("A", "GET", path+"?limit=0", nil, 400)
	e.mustCode("A", "GET", path+"?before=abc", nil, 400)

	e.srv.AuthLimit = sms.NewLimiter()
	for i := 0; i < chatSendPerMinute; i++ {
		e.mustCode("A", "POST", path, map[string]string{"body": fmt.Sprint("m", i)}, 201)
	}
	e.mustCode("A", "POST", path, map[string]string{"body": "one too many"}, 429)
	// The limit is per sender.
	inv := e.createCircle("C", "Other")
	e.mustCode("C", "POST", "/circles/"+inv+"/chat", map[string]string{"body": "fine"}, 201)
}

func TestChatPaginationAndUnread(t *testing.T) {
	e := chatEnv(t)
	c := e.createCircle("A", "Pages", "B")
	path := "/circles/" + c + "/chat"
	for i := 1; i <= 5; i++ {
		e.mustCode("A", "POST", path, map[string]string{"body": fmt.Sprint("msg", i)}, 201)
	}
	p1 := e.mustCode("B", "GET", path+"?limit=2", nil, 200)
	msgs := p1["messages"].([]any)
	if len(msgs) != 2 || msgs[0].(map[string]any)["body"] != "msg5" || msgs[1].(map[string]any)["body"] != "msg4" {
		t.Fatalf("page1 = %v", msgs)
	}
	cur := fmt.Sprint(int64(p1["next_before"].(float64)))
	p2 := e.mustCode("B", "GET", path+"?limit=2&before="+cur, nil, 200)
	msgs = p2["messages"].([]any)
	if len(msgs) != 2 || msgs[0].(map[string]any)["body"] != "msg3" {
		t.Fatalf("page2 = %v", msgs)
	}
	cur = fmt.Sprint(int64(p2["next_before"].(float64)))
	p3 := e.mustCode("B", "GET", path+"?limit=2&before="+cur, nil, 200)
	if len(p3["messages"].([]any)) != 1 || p3["next_before"] != nil {
		t.Fatalf("page3 = %v", p3)
	}

	// Unread: B has 5, A (the sender) has 0.
	if u := e.mustCode("B", "GET", "/chat/unread", nil, 200); int(u["circles"].(map[string]any)[c].(float64)) != 5 || int(u["total"].(float64)) != 5 {
		t.Fatalf("B unread = %v", u)
	}
	if u := e.mustCode("A", "GET", "/chat/unread", nil, 200); int(u["circles"].(map[string]any)[c].(float64)) != 0 {
		t.Fatalf("A unread = %v", u)
	}
	// Reading, including a bogus future seq, clamps to the newest message.
	e.mustCode("B", "POST", path+"/read", map[string]int64{"seq": 1 << 40}, 204)
	if u := e.mustCode("B", "GET", "/chat/unread", nil, 200); int(u["total"].(float64)) != 0 {
		t.Fatalf("B unread after read = %v", u)
	}
	e.mustCode("A", "POST", path, map[string]string{"body": "later"}, 201)
	if u := e.mustCode("B", "GET", "/chat/unread", nil, 200); int(u["total"].(float64)) != 1 {
		t.Fatalf("B unread after new = %v", u)
	}
}

func TestChatLiveFrameAndPush(t *testing.T) {
	e := chatEnv(t)
	fp := &fakePush{}
	e.srv.Push = fp
	c := e.createCircle("A", "Live", "B")
	other := e.createCircle("D", "Elsewhere")
	ctx := t.Context()
	if _, err := e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/b')`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/a')`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/d')`, e.ids["D"]); err != nil {
		t.Fatal(err)
	}
	inC, inOther := testWSClient(), testWSClient()
	e.srv.hub.registerCircles([]string{c}, e.ids["B"], inC)
	e.srv.hub.registerCircles([]string{other}, e.ids["D"], inOther)

	e.mustCode("A", "POST", "/circles/"+c+"/chat", map[string]string{"body": "secret plan at 51.5,-0.1"}, 201)

	select {
	case raw := <-inC.send:
		if !strings.Contains(string(raw), `"type":"chat"`) || !strings.Contains(string(raw), c) {
			t.Fatalf("frame = %s", raw)
		}
	case <-time.After(time.Second):
		t.Fatal("circle member got no live frame")
	}
	select {
	case raw := <-inOther.send:
		t.Fatalf("other circle received %s", raw)
	default:
	}

	// Push goes to the other member only, and without the text by default.
	deadline := time.Now().Add(3 * time.Second)
	for {
		fp.mu.Lock()
		n := len(fp.sent)
		fp.mu.Unlock()
		if n >= 1 || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	fp.mu.Lock()
	defer fp.mu.Unlock()
	if len(fp.sent) != 1 || fp.sent[0].UnifiedPushEndpoint != "https://ntfy.example/b" {
		t.Fatalf("push targets = %+v", fp.sent)
	}
	if got := fp.sent[0].Title + fp.sent[0].Body; strings.Contains(got, "secret") || strings.Contains(got, "51.5") {
		t.Fatalf("push leaked message text: %q", got)
	}
}

func TestChatEditDeleteIdempotencyCatchUp(t *testing.T) {
	e := chatEnv(t)
	c := e.createCircle("A", "V2", "B", "C") // A admin; B, C members; D outsider
	p := "/circles/" + c + "/chat"

	// Idempotent send: same client_id returns the same message, one row.
	_, first, _ := e.do("B", "POST", p, map[string]string{"body": "once", "client_id": "k1"})
	code, again, _ := e.do("B", "POST", p, map[string]string{"body": "once", "client_id": "k1"})
	if code != 200 || again["id"] != first["id"] {
		t.Fatalf("retry: code %d, %v vs %v", code, again["id"], first["id"])
	}
	var n int
	_ = e.pool.QueryRow(t.Context(), `SELECT count(*) FROM chat_messages WHERE circle_id=$1`, c).Scan(&n)
	if n != 1 {
		t.Fatalf("rows = %d, want 1", n)
	}
	// The same client_id from another sender is a different message.
	e.mustCode("C", "POST", p, map[string]string{"body": "other", "client_id": "k1"}, 201)
	e.mustCode("B", "POST", p, map[string]string{"body": "x", "client_id": strings.Repeat("a", 65)}, 400)

	id := first["id"].(string)
	seq := int64(first["seq"].(float64))

	// Edit: only the sender.
	e.mustCode("C", "PATCH", p+"/"+id, map[string]string{"body": "hijack"}, 404)
	e.mustCode("A", "PATCH", p+"/"+id, map[string]string{"body": "admin edit"}, 404)
	e.mustCode("D", "PATCH", p+"/"+id, map[string]string{"body": "x"}, 404)
	e.mustCode("B", "PATCH", p+"/"+id, map[string]string{"body": "  "}, 400)
	got := e.mustCode("B", "PATCH", p+"/"+id, map[string]string{"body": "twice"}, 200)
	if got["body"] != "twice" || got["edited_at"] == nil {
		t.Fatalf("edit result: %v", got)
	}

	// Catch-up: only messages newer than `after`, newest first.
	_, page, _ := e.do("A", "GET", p+"?after="+fmt.Sprint(seq), nil)
	msgs, _ := page["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["body"] != "other" {
		t.Fatalf("after page: %v", msgs)
	}
	e.mustCode("A", "GET", p+"?after=-1", nil, 400)

	// Delete: sender or admin; other members and outsiders get 404.
	e.mustCode("C", "DELETE", p+"/"+id, nil, 404)
	e.mustCode("D", "DELETE", p+"/"+id, nil, 404)
	e.mustCode("B", "DELETE", p+"/"+id, nil, 204)
	e.mustCode("B", "DELETE", p+"/"+id, nil, 404)
	_, other, _ := e.do("C", "GET", p, nil)
	om := other["messages"].([]any)
	oid := om[0].(map[string]any)["id"].(string)
	e.mustCode("A", "DELETE", p+"/"+oid, nil, 204) // admin moderation
	_, after, _ := e.do("A", "GET", p, nil)
	if l, _ := after["messages"].([]any); len(l) != 0 {
		t.Fatalf("messages left: %v", l)
	}
	// Unread no longer counts deleted messages.
	_, un, _ := e.do("A", "GET", "/chat/unread", nil)
	if un["total"].(float64) != 0 {
		t.Fatalf("unread after delete: %v", un)
	}
}
