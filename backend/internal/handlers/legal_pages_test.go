package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
)

func legalRouter() http.Handler {
	r := chi.NewRouter()
	s := &Server{}
	r.Get("/privacy", s.LegalPrivacy)
	r.Get("/terms", s.LegalTerms)
	return r
}

// The legal pages must be readable with no credentials at all (store review),
// must come from the embedded drafts, and must not be a way to inject markup.
func TestLegalPagesArePublicHTML(t *testing.T) {
	for path, want := range map[string]string{
		"/privacy": "Privacy Policy",
		"/terms":   "Terms of Use",
	} {
		w := httptest.NewRecorder()
		legalRouter().ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != 200 {
			t.Fatalf("%s: status %d", path, w.Code)
		}
		if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
			t.Fatalf("%s: content type %q", path, ct)
		}
		body := w.Body.String()
		if !strings.Contains(body, "<h1>") || !strings.Contains(body, want) {
			t.Fatalf("%s: missing heading %q in %.200s", path, want, body)
		}
		if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
			t.Fatalf("%s: no restrictive CSP", path)
		}
		if strings.Contains(body, "<script") {
			t.Fatalf("%s: script in legal page", path)
		}
	}
}

func TestLegalPrivacyStatesNoDeveloperCollection(t *testing.T) {
	w := httptest.NewRecorder()
	legalRouter().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/privacy", nil))
	for _, must := range []string{"no Orbitly cloud", "Delete my account", "Private"} {
		if !strings.Contains(w.Body.String(), must) {
			t.Fatalf("privacy page lost the statement %q", must)
		}
	}
}

func TestRenderLegalMarkdownEscapesAndLimitsLinks(t *testing.T) {
	body, title := renderLegalMarkdown("# T <b>\n\n[x](javascript:alert(1)) [y](https://example.com) [p](PRIVACY_POLICY.md) <script>alert(1)</script>\n\n- **a**\n- `b`\n", "fallback")
	if title != "T <b>" {
		t.Fatalf("title %q", title)
	}
	if strings.Contains(body, "<script") || strings.Contains(body, "javascript:") {
		t.Fatalf("unsafe output: %s", body)
	}
	for _, want := range []string{`<a href="https://example.com">y</a>`, `<a href="/privacy">p</a>`, "<ul>", "<strong>a</strong>", "<code>b</code>"} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %q in %s", want, body)
		}
	}
}
