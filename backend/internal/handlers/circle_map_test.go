package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
)

// Circle-aware map/stream tests: per-circle delivery over a real WebSocket,
// subscribe frames, sharing off, removal and bad ids. Need TEST_DATABASE_URL.

// wsConn reads in a background goroutine: coder/websocket closes the
// connection when a Read context expires, so timed reads must not use it.
type wsConn struct {
	t      *testing.T
	c      *websocket.Conn
	frames chan map[string]any
}

func (e *circleEnv) streamServer() *httptest.Server {
	e.srv.TM = auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour)
	ts := httptest.NewServer(http.HandlerFunc(e.srv.Stream))
	e.t.Cleanup(ts.Close)
	return ts
}

// dial opens /ws/stream as user; query is appended verbatim (e.g. "circle_id=x").
func (e *circleEnv) dial(ts *httptest.Server, user, query string) (*wsConn, int) {
	e.t.Helper()
	tok, err := e.srv.TM.IssueAccess(e.ids[user], "", 0)
	if err != nil {
		e.t.Fatal(err)
	}
	url := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/stream"
	if query != "" {
		url += "?" + query
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + tok}},
	})
	if err != nil {
		if resp != nil {
			return nil, resp.StatusCode
		}
		e.t.Fatalf("dial %s: %v", user, err)
	}
	e.t.Cleanup(func() { _ = conn.CloseNow() })
	w := &wsConn{t: e.t, c: conn, frames: make(chan map[string]any, 256)}
	go func() {
		defer close(w.frames)
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				return
			}
			var m map[string]any
			_ = json.Unmarshal(data, &m)
			w.frames <- m
		}
	}()
	return w, 101
}

func (w *wsConn) next(d time.Duration) (map[string]any, bool) {
	select {
	case m, ok := <-w.frames:
		return m, ok && m != nil
	case <-time.After(d):
		return nil, false
	}
}

// expect reads frames until one of type typ arrives.
func (w *wsConn) expect(typ string) map[string]any {
	w.t.Helper()
	for i := 0; i < 20; i++ {
		m, ok := w.next(3 * time.Second)
		if !ok {
			w.t.Fatalf("timed out waiting for %q frame", typ)
		}
		if m["type"] == typ {
			return m
		}
	}
	w.t.Fatalf("no %q frame", typ)
	return nil
}

// quiet asserts no frame arrives within a short window.
func (w *wsConn) quiet() {
	w.t.Helper()
	if m, ok := w.next(300 * time.Millisecond); ok {
		w.t.Fatalf("unexpected frame: %v", m)
	}
}

func (w *wsConn) send(v any) {
	b, _ := json.Marshal(v)
	if err := w.c.Write(context.Background(), websocket.MessageText, b); err != nil {
		w.t.Fatal(err)
	}
}

func memberNames(m map[string]any) map[string]bool {
	out := map[string]bool{}
	for _, x := range m["members"].([]any) {
		out[x.(map[string]any)["name"].(string)] = x.(map[string]any)["lat"] != nil
	}
	return out
}

func (e *circleEnv) loc(user string) {
	e.srv.broadcastLocation(e.ids[user], wsLocation{Type: "location", UserID: e.ids[user], TS: time.Now()})
}

func TestStreamPerCircleDeliveryAndSubscribe(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping() // A:{1} B:{1,2} C:{2}
	ts := e.streamServer()

	// Unknown, malformed and foreign circle ids are a plain 404.
	for _, q := range []string{
		"circle_id=" + c2,                                  // A is not in c2
		"circle_id=00000000-0000-4000-8000-000000000000",   // unknown
		"circle_id=not-a-uuid", "circle_id=%27%3B%20drop%20table--", // malformed
	} {
		if _, code := e.dial(ts, "A", q); code != 404 {
			t.Fatalf("%q: got %d want 404", q, code)
		}
	}

	legacyA, _ := e.dial(ts, "A", "")
	legacyA.expect("welcome")
	snapA := legacyA.expect("members")
	if _, hasCircle := snapA["circle_id"]; hasCircle {
		t.Fatal("legacy snapshot must not carry circle_id")
	}
	if n := memberNames(snapA); len(n) != 2 || !n["UserA"] || !n["UserB"] {
		t.Fatalf("legacy A snapshot: %v", n)
	}

	bAll, _ := e.dial(ts, "B", "circle_id=all")
	bAll.expect("welcome")
	if s := bAll.expect("members"); s["circle_id"] != "all" || len(memberNames(s)) != 3 {
		t.Fatalf("B all snapshot: %v", s)
	}
	cOne, _ := e.dial(ts, "C", "circle_id="+c2)
	cOne.expect("welcome")
	if s := cOne.expect("members"); s["circle_id"] != c2 || len(memberNames(s)) != 2 {
		t.Fatalf("C c2 snapshot: %v", s)
	}

	// B updates: the legacy viewer gets one unlabelled copy, C (c2 only) one
	// frame labelled c2, B itself (all) one per own circle.
	e.loc("B")
	if f := legacyA.expect("location"); f["circle_id"] != nil {
		t.Fatalf("legacy frame labelled: %v", f)
	}
	legacyA.quiet()
	if f := cOne.expect("location"); f["circle_id"] != c2 {
		t.Fatalf("C frame: %v", f)
	}
	cOne.quiet()
	seen := map[any]bool{}
	seen[bAll.expect("location")["circle_id"]] = true
	seen[bAll.expect("location")["circle_id"]] = true
	if !seen[c1] || !seen[c2] {
		t.Fatalf("B own frames: %v", seen)
	}

	// A's update never reaches C; B (all) gets exactly the c1 label.
	e.loc("A")
	legacyA.expect("location")
	if f := bAll.expect("location"); f["circle_id"] != c1 {
		t.Fatalf("A->B frame: %v", f)
	}
	cOne.quiet()

	// B narrows to c1: only c1 snapshot (A,B), then C's update is not delivered.
	bAll.send(map[string]string{"type": "subscribe", "circle_id": c1})
	if a := bAll.expect("subscribed"); a["circle_id"] != c1 {
		t.Fatalf("ack: %v", a)
	}
	if n := memberNames(bAll.expect("members")); len(n) != 2 || n["UserC"] {
		t.Fatalf("c1 snapshot: %v", n)
	}
	e.loc("C")
	cOne.expect("location")
	bAll.quiet()

	// Bad subscribe requests: error frame, subscription unchanged.
	for _, id := range []string{"nope", "00000000-0000-4000-8000-000000000000"} {
		bAll.send(map[string]string{"type": "subscribe", "circle_id": id})
		if m := bAll.expect("error"); m["code"] != "circle_not_found" {
			t.Fatalf("error frame: %v", m)
		}
	}
	cOne.send(map[string]string{"type": "subscribe", "circle_id": c1}) // C is not in c1
	cOne.expect("error")
	e.loc("A")
	bAll.expect("location")
	legacyA.expect("location") // A always sees itself

	// Sharing off in c1: A's legacy socket stops receiving B; aware sockets in
	// c1 are told; c2 delivery is unaffected.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	if f := bAll.expect("sharing"); f["enabled"] != false || f["circle_id"] != c1 {
		t.Fatalf("sharing frame: %v", f)
	}
	e.loc("B")
	legacyA.quiet()
	if f := cOne.expect("location"); f["circle_id"] != c2 {
		t.Fatalf("c2 still delivered: %v", f)
	}
	bAll.expect("location") // B still sees itself in c1

	// Snapshot scoped to c1 hides B's location from A but lists B.
	aSub, _ := e.dial(ts, "A", "circle_id="+c1)
	aSub.expect("welcome")
	if n := memberNames(aSub.expect("members")); n["UserB"] || !n["UserA"] {
		t.Fatalf("c1 snapshot after sharing off: %v", n)
	}

	// Removal: A removes B from c1. B's subscription to c1 is dropped, the
	// socket stays open (still in c2) and is told; A's c1 socket sees no more B.
	e.mustCode("A", "DELETE", "/circles/"+c1+"/members/"+e.ids["B"], nil, 200)
	if m := bAll.expect("circle_removed"); m["circle_id"] != c1 {
		t.Fatalf("removed frame: %v", m)
	}
	e.mustCode("B", "PUT", "/circles/"+c2+"/sharing", map[string]bool{"enabled": true}, 200)
	e.loc("B")
	cOne.expect("location")
	aSub.quiet()
	// Removing B from its last circle closes the socket.
	e.mustCode("C", "DELETE", "/circles/"+c2+"/members/"+e.ids["B"], nil, 200)
	for i := 0; i < 10; i++ {
		if _, ok := bAll.next(2 * time.Second); !ok {
			return
		}
	}
	t.Fatal("B socket not closed after last circle removal")
}

func TestListMembersCircleFilter(t *testing.T) {
	e := newCircleEnv(t)
	c1, c2 := e.overlapping()
	names := func(user, q string) map[string]map[string]any {
		_, _, raw := e.do(user, "GET", "/family/members"+q, nil)
		var list []map[string]any
		if err := json.Unmarshal(raw, &list); err != nil {
			t.Fatalf("%s %q: %s", user, q, raw)
		}
		out := map[string]map[string]any{}
		for _, m := range list {
			out[m["name"].(string)] = m
		}
		return out
	}
	// B in both circles: filter by each, and all.
	if n := names("B", "?circle_id="+c1); len(n) != 2 || n["UserC"] != nil {
		t.Fatalf("c1: %v", n)
	}
	if n := names("B", "?circle_id="+c2); len(n) != 2 || n["UserA"] != nil {
		t.Fatalf("c2: %v", n)
	}
	n := names("B", "?circle_id=all")
	if len(n) != 3 {
		t.Fatalf("all: %v", n)
	}
	if ids, _ := n["UserB"]["circle_ids"].([]any); len(ids) != 2 {
		t.Fatalf("B circle_ids: %v", n["UserB"])
	}
	if ids, _ := n["UserA"]["circle_ids"].([]any); len(ids) != 1 || ids[0] != c1 {
		t.Fatalf("A circle_ids: %v", n["UserA"])
	}
	// Outsider / malformed / unknown -> 404.
	for _, q := range []string{c2, "bad", "00000000-0000-4000-8000-000000000000"} {
		if code, _, _ := e.do("A", "GET", "/family/members?circle_id="+q, nil); code != 404 {
			t.Fatalf("%q: got %d", q, code)
		}
	}
	if code, _, _ := e.do("D", "GET", "/family/members?circle_id=all", nil); code != 404 {
		t.Fatalf("D all: %d", code)
	}
	// Sharing off in c1 only: A sees B without location in c1; in all, C still has it.
	e.mustCode("B", "PUT", "/circles/"+c1+"/sharing", map[string]bool{"enabled": false}, 200)
	if n := names("A", "?circle_id="+c1); n["UserB"]["lat"] != nil {
		t.Fatalf("location leaked: %v", n["UserB"])
	}
	// A co-member sees B as shared only in c2 (a viewer sees themselves as
	// sharing everywhere). A shares no circle with B but c1, where B is off.
	if sh, _ := names("A", "?circle_id=all")["UserB"]["sharing_circle_ids"].([]any); len(sh) != 0 {
		t.Fatalf("A must see B sharing nowhere: %v", sh)
	}
	sh, _ := names("C", "?circle_id=all")["UserB"]["sharing_circle_ids"].([]any)
	if len(sh) != 1 || sh[0] != c2 {
		t.Fatalf("C sharing_circle_ids: %v", sh)
	}
}
