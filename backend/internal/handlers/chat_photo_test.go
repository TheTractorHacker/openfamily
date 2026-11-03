package handlers

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func (e *circleEnv) rawReq(user, method, path, ct string, body []byte) (int, []byte, string) {
	e.t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	if user != "" {
		req.Header.Set("X-Test-User", e.ids[user])
	}
	rec := httptest.NewRecorder()
	e.rt.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes(), rec.Header().Get("Content-Type")
}

func testJPEG(t *testing.T) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 40, 30))
	for x := 0; x < 40; x++ {
		for y := 0; y < 30; y++ {
			img.Set(x, y, color.RGBA{200, uint8(x * 5), 10, 255})
		}
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestChatPhotoAndSeen(t *testing.T) {
	e := chatEnv(t)
	fp := &fakePush{}
	e.srv.Push = fp
	e.srv.VerbosePush = true
	c := e.createCircle("A", "Pics", "B")
	other := e.createCircle("D", "Elsewhere")
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO devices (user_id, platform, unifiedpush_endpoint) VALUES ($1,'android','https://ntfy.example/b')`, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	path := "/circles/" + c + "/chat"

	// Validation.
	if code, _, _ := e.rawReq("A", "POST", path+"/photo", "text/plain", []byte("x")); code != 415 {
		t.Fatalf("bad type = %d", code)
	}
	if code, _, _ := e.rawReq("A", "POST", path+"/photo", "image/jpeg", []byte("not a jpeg")); code != 400 {
		t.Fatalf("garbage = %d", code)
	}
	if code, _, _ := e.rawReq("D", "POST", path+"/photo", "image/jpeg", testJPEG(t)); code != 404 {
		t.Fatalf("outsider upload = %d", code)
	}
	if code, _, _ := e.rawReq("", "POST", path+"/photo", "image/jpeg", testJPEG(t)); code != 401 {
		t.Fatalf("anon upload = %d", code)
	}

	code, raw, _ := e.rawReq("A", "POST", path+"/photo", "image/jpeg", testJPEG(t))
	if code != 201 || !strings.Contains(string(raw), `"has_image":true`) {
		t.Fatalf("upload = %d %s", code, raw)
	}
	msgs := e.mustCode("B", "GET", path, nil, 200)["messages"].([]any)
	id := msgs[0].(map[string]any)["id"].(string)
	if msgs[0].(map[string]any)["has_image"] != true {
		t.Fatalf("list = %v", msgs[0])
	}

	// Members read it; outsiders and other circles cannot.
	code, data, ct := e.rawReq("B", "GET", path+"/"+id+"/photo", "", nil)
	if code != 200 || ct != "image/jpeg" || len(data) == 0 {
		t.Fatalf("member read = %d %s", code, ct)
	}
	if code, _, _ := e.rawReq("D", "GET", path+"/"+id+"/photo", "", nil); code != 404 {
		t.Fatalf("outsider read = %d", code)
	}
	if code, _, _ := e.rawReq("D", "GET", "/circles/"+other+"/chat/"+id+"/photo", "", nil); code != 404 {
		t.Fatalf("cross-circle read = %d", code)
	}
	if code, _, _ := e.rawReq("", "GET", path+"/"+id+"/photo", "", nil); code != 401 {
		t.Fatalf("anon read = %d", code)
	}

	// Photo push names the sender (VERBOSE_PUSH on).
	fp.mu.Lock()
	n := len(fp.sent)
	fp.mu.Unlock()
	for i := 0; n < 1 && i < 150; i++ {
		fp.mu.Lock()
		n = len(fp.sent)
		fp.mu.Unlock()
		if n < 1 {
			e.t.Log()
			sleepMs(20)
		}
	}
	fp.mu.Lock()
	if len(fp.sent) != 1 || !strings.Contains(fp.sent[0].Title, "sent a photo") {
		t.Fatalf("push = %+v", fp.sent)
	}
	fp.mu.Unlock()

	// Seen: B reads, then readers list carries B's marker.
	e.mustCode("B", "POST", path+"/read", nil, 204)
	rd := e.mustCode("A", "GET", path, nil, 200)["readers"].([]any)
	found := false
	for _, x := range rd {
		if x.(map[string]any)["user_id"] == e.ids["B"] && x.(map[string]any)["last_seq"].(float64) > 0 {
			found = true
		}
	}
	if !found {
		t.Fatalf("readers = %v", rd)
	}
}

func sleepMs(n int) { time.Sleep(time.Duration(n) * time.Millisecond) }
