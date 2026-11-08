package handlers

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/compat"
)

func docsRouter() http.Handler {
	r := chi.NewRouter()
	r.Get("/api/docs/*", (&Server{}).DocsContent)
	return r
}

func docsGet(t *testing.T, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	docsRouter().ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

type docsManifest struct {
	Release    string `json:"release"`
	Categories []struct {
		ID   string `json:"id"`
		Icon string `json:"icon"`
		Docs []struct {
			Path    string `json:"path"`
			Title   string `json:"title"`
			Summary string `json:"summary"`
		} `json:"docs"`
	} `json:"categories"`
	Popular []string `json:"popular"`
}

func TestDocsManifestAndContent(t *testing.T) {
	w := docsGet(t, "/api/docs/manifest.json")
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("manifest: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	var m docsManifest
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, c := range m.Categories {
		for _, d := range c.Docs {
			n++
			if r := docsGet(t, "/api/docs/"+d.Path); r.Code != 200 || r.Body.Len() == 0 {
				t.Errorf("%s: %d", d.Path, r.Code)
			}
		}
	}
	if n < 20 {
		t.Fatalf("only %d docs in the manifest", n)
	}
	if r := docsGet(t, "/api/docs/CHANGELOG.md"); r.Code != 200 || !strings.Contains(r.Body.String(), "## "+m.Release) {
		t.Fatal("CHANGELOG.md is missing the manifest release section")
	}
	if r := docsGet(t, "/api/docs/user/getting-started.md"); r.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("nosniff missing")
	}
}

// Every page has a one-line summary (search results and the category cards use
// it), the popular list points at real pages, and drawings are served inert.
func TestDocsSummariesPopularAndDrawings(t *testing.T) {
	var m docsManifest
	if err := json.Unmarshal(docsGet(t, "/api/docs/manifest.json").Body.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{}
	for _, c := range m.Categories {
		for _, d := range c.Docs {
			known[d.Path] = true
			if len(d.Summary) < 20 || d.Title == "" {
				t.Errorf("%s: missing title or summary (%q)", d.Path, d.Summary)
			}
		}
	}
	if len(m.Popular) == 0 {
		t.Error("manifest has no popular pages")
	}
	for _, p := range m.Popular {
		if !known[p] {
			t.Errorf("popular page %s is not in the manifest", p)
		}
	}
	for _, want := range []string{"quick-start.md", "concepts.md", "glossary.md", "faq.md", "troubleshooting/index.md"} {
		if !known[want] {
			t.Errorf("%s missing from the manifest", want)
		}
	}
	w := docsGet(t, "/api/docs/images/concepts-processing.svg")
	if w.Code != 200 || w.Header().Get("Content-Type") != "image/svg+xml" {
		t.Fatalf("svg: %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Error("svg must carry a sandboxing Content-Security-Policy")
	}
}

func TestDocsRejectsOddPaths(t *testing.T) {
	for _, p := range []string{"/api/docs/", "/api/docs/..%2f..%2fgo.mod", "/api/docs/../x.md", "/api/docs/nope.md", "/api/docs/user", "/api/docs/x.svg", "/api/docs/x.html", "/api/docs/user/"} {
		if w := docsGet(t, p); w.Code != 404 {
			t.Errorf("%s: want 404, got %d", p, w.Code)
		}
	}
}

// The changelog must describe the newest release in compat.Releases: whoever
// adds a release line also has to write what changed (docs/CHANGELOG.md), then
// run scripts/docs-check.sh --fix to refresh the embedded copy.
func TestChangelogCoversLatestRelease(t *testing.T) {
	data, err := fs.ReadFile(docsFS, "CHANGELOG.md")
	if err != nil {
		t.Fatal(err)
	}
	latest := compat.Compute("", "").Latest
	want := "## v" + strings.TrimSuffix(latest.String(), ".0")
	if !strings.Contains(string(data), want+".") && !strings.Contains(string(data), want+" ") {
		t.Fatalf("docs/CHANGELOG.md has no section for release %s (compat.Releases): add it, then run scripts/docs-check.sh --fix", latest)
	}
}
