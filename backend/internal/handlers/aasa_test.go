package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

func aasaReq(s *Server) *httptest.ResponseRecorder {
	r := chi.NewRouter()
	r.Get("/.well-known/apple-app-site-association", s.AppleAppSiteAssociation)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/.well-known/apple-app-site-association", nil))
	return rec
}

func TestAASAServedWhenConfigured(t *testing.T) {
	rec := aasaReq(&Server{IOSTeamID: "ABCDE12345", IOSBundleID: "app.openfamily"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content type %q", ct)
	}
	var doc struct {
		Applinks struct {
			Details []struct {
				AppIDs     []string `json:"appIDs"`
				Components []struct {
					Path string `json:"/"`
				} `json:"components"`
			} `json:"details"`
		} `json:"applinks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	d := doc.Applinks.Details
	if len(d) != 1 || len(d[0].AppIDs) != 1 || d[0].AppIDs[0] != "ABCDE12345.app.openfamily" {
		t.Fatalf("unexpected appIDs: %s", rec.Body.String())
	}
	if len(d[0].Components) != 1 || d[0].Components[0].Path != "/join/*" {
		t.Fatalf("unexpected components: %s", rec.Body.String())
	}
}

func TestAASADefaultsBundleID(t *testing.T) {
	rec := aasaReq(&Server{IOSTeamID: "ABCDE12345"})
	if rec.Code != http.StatusOK || !json.Valid(rec.Body.Bytes()) {
		t.Fatalf("status %d", rec.Code)
	}
	if want := "ABCDE12345.app.openfamily"; !strings.Contains(rec.Body.String(), want) {
		t.Errorf("missing %s in %s", want, rec.Body.String())
	}
}

func TestAASANotFoundWhenUnconfiguredOrInvalid(t *testing.T) {
	for name, s := range map[string]*Server{
		"empty":     {},
		"short":     {IOSTeamID: "ABC"},
		"lowercase": {IOSTeamID: "abcde12345"},
		"bad":       {IOSTeamID: "ABCDE12345", IOSBundleID: `x"y`},
	} {
		if rec := aasaReq(s); rec.Code != http.StatusNotFound {
			t.Errorf("%s: status %d, want 404", name, rec.Code)
		}
	}
}
