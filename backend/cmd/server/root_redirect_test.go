package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
)

func TestRootRedirect(t *testing.T) {
	r := chi.NewRouter()
	r.Get("/", rootRedirect)
	r.Get("/admin/", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	for _, c := range []struct {
		method, path string
		status       int
		loc          string
	}{
		{"GET", "/", http.StatusFound, "/admin/"},
		{"GET", "/admin/", http.StatusTeapot, ""},
		{"POST", "/", http.StatusMethodNotAllowed, ""},
		{"GET", "/nope", http.StatusNotFound, ""},
	} {
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, httptest.NewRequest(c.method, c.path, nil))
		if rec.Code != c.status || rec.Header().Get("Location") != c.loc {
			t.Errorf("%s %s: %d loc=%q", c.method, c.path, rec.Code, rec.Header().Get("Location"))
		}
	}
}
