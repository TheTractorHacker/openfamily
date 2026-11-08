package middleware

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func jsonHandler(body string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	})
}

func TestCompressGzipsLargeJSON(t *testing.T) {
	body := `[` + strings.Repeat(`{"name":"Alex","lat":51.5,"lon":-0.1},`, 100) + `{}]`
	h := Compress(jsonHandler(body))
	req := httptest.NewRequest("GET", "/family/members", nil)
	req.Header.Set("Accept-Encoding", "gzip, br")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("not compressed: %v", rec.Header())
	}
	if !strings.Contains(rec.Header().Get("Vary"), "Accept-Encoding") {
		t.Fatal("missing Vary")
	}
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(zr)
	if string(got) != body {
		t.Fatal("round trip mismatch")
	}
	if rec.Body.Len() >= len(body)/2 {
		t.Fatalf("expected real saving, %d vs %d", rec.Body.Len(), len(body))
	}
}

func TestCompressSkips(t *testing.T) {
	big := strings.Repeat("x", 4000)
	cases := map[string]func() (*http.Request, http.Handler){
		"no accept-encoding": func() (*http.Request, http.Handler) {
			return httptest.NewRequest("GET", "/a", nil), jsonHandler(big)
		},
		"gzip q=0": func() (*http.Request, http.Handler) {
			r := httptest.NewRequest("GET", "/a", nil)
			r.Header.Set("Accept-Encoding", "gzip;q=0")
			return r, jsonHandler(big)
		},
		"websocket path": func() (*http.Request, http.Handler) {
			r := httptest.NewRequest("GET", "/ws/stream", nil)
			r.Header.Set("Accept-Encoding", "gzip")
			return r, jsonHandler(big)
		},
		"image": func() (*http.Request, http.Handler) {
			r := httptest.NewRequest("GET", "/a", nil)
			r.Header.Set("Accept-Encoding", "gzip")
			return r, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "image/jpeg")
				_, _ = w.Write([]byte(big))
			})
		},
		"already encoded": func() (*http.Request, http.Handler) {
			r := httptest.NewRequest("GET", "/a", nil)
			r.Header.Set("Accept-Encoding", "gzip")
			return r, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Content-Encoding", "br")
				_, _ = w.Write([]byte(big))
			})
		},
		"tiny body": func() (*http.Request, http.Handler) {
			r := httptest.NewRequest("GET", "/a", nil)
			r.Header.Set("Accept-Encoding", "gzip")
			return r, jsonHandler(`{"ok":true}`)
		},
	}
	for name, mk := range cases {
		req, inner := mk()
		rec := httptest.NewRecorder()
		Compress(inner).ServeHTTP(rec, req)
		ce := rec.Header().Get("Content-Encoding")
		if ce == "gzip" {
			t.Errorf("%s: should not gzip", name)
		}
		if rec.Code != 200 || rec.Body.Len() == 0 {
			t.Errorf("%s: bad response %d len %d", name, rec.Code, rec.Body.Len())
		}
	}
}

func TestCompressKeepsStatusAndErrors(t *testing.T) {
	h := Compress(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"nope"}`))
	}))
	req := httptest.NewRequest("GET", "/a", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 404 || rec.Body.String() != `{"error":"nope"}` {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestETagRoundTrip(t *testing.T) {
	h := ETag(jsonHandler(`{"a":1}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	tag := rec.Header().Get("ETag")
	if rec.Code != 200 || !strings.HasPrefix(tag, `W/"`) || rec.Body.String() != `{"a":1}` {
		t.Fatalf("first: %d %q %q", rec.Code, tag, rec.Body.String())
	}
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("If-None-Match", tag)
	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req)
	if rec2.Code != 304 || rec2.Body.Len() != 0 || rec2.Header().Get("ETag") != tag {
		t.Fatalf("second: %d len=%d", rec2.Code, rec2.Body.Len())
	}
	// Changed body: validator no longer matches.
	rec3 := httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("If-None-Match", tag)
	ETag(jsonHandler(`{"a":2}`)).ServeHTTP(rec3, req)
	if rec3.Code != 200 || rec3.Body.String() != `{"a":2}` {
		t.Fatalf("third: %d", rec3.Code)
	}
	// Strong / list / star forms.
	for _, in := range []string{strings.TrimPrefix(tag, "W/"), `"zzz", ` + tag, "*"} {
		req = httptest.NewRequest("GET", "/x", nil)
		req.Header.Set("If-None-Match", in)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != 304 {
			t.Errorf("If-None-Match %q: %d", in, rr.Code)
		}
	}
}

func TestETagLeavesOtherResponsesAlone(t *testing.T) {
	// errors, non-JSON, POST, oversize
	errH := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"error":"x"}`))
	})
	rec := httptest.NewRecorder()
	ETag(errH).ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != 403 || rec.Header().Get("ETag") != "" || rec.Body.String() != `{"error":"x"}` {
		t.Fatalf("error path: %d %v", rec.Code, rec.Header())
	}
	img := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("jpegbytes"))
	})
	rec = httptest.NewRecorder()
	ETag(img).ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Header().Get("ETag") != "" || rec.Body.String() != "jpegbytes" {
		t.Fatal("image touched")
	}
	rec = httptest.NewRecorder()
	ETag(jsonHandler(`{}`)).ServeHTTP(rec, httptest.NewRequest("POST", "/x", bytes.NewReader(nil)))
	if rec.Header().Get("ETag") != "" {
		t.Fatal("POST got an ETag")
	}
	big := strings.Repeat("a", etagMaxBody+10)
	rec = httptest.NewRecorder()
	ETag(jsonHandler(big)).ServeHTTP(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Header().Get("ETag") != "" || rec.Body.Len() != len(big) {
		t.Fatal("oversize body mishandled")
	}
}

func TestETagWithCompress(t *testing.T) {
	body := `[` + strings.Repeat(`{"a":"bbbbbbbbbbbbbbbb"},`, 100) + `{}]`
	h := Compress(ETag(jsonHandler(body)))
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	tag := rec.Header().Get("ETag")
	if tag == "" || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("expected both: %v", rec.Header())
	}
	req = httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	req.Header.Set("If-None-Match", tag)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 304 || rec.Body.Len() != 0 {
		t.Fatalf("304 through gzip: %d len %d", rec.Code, rec.Body.Len())
	}
}
