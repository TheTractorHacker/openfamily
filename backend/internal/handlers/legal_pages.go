package handlers

import (
	"html"
	"io/fs"
	"net/http"
	"regexp"
	"strings"
)

// Public legal pages: GET /privacy and GET /terms.
//
// Store reviewers (Apple, Google) and new members must be able to read the
// privacy policy and terms of the server they are about to use WITHOUT an
// account, so these two routes are unauthenticated. The text is the drafts in
// docs/legal/ (embedded with the rest of the docs bundle); there is no
// database access, no cookie and no user input in the page. Edit the markdown,
// run scripts/docs-check.sh --fix, rebuild: every server then shows its own
// copy.
var legalPages = map[string]struct{ file, fallback string }{
	"privacy": {"legal/PRIVACY_POLICY.md", "Privacy policy"},
	"terms":   {"legal/TERMS.md", "Terms of use"},
}

// LegalPrivacy serves GET /privacy.
func (s *Server) LegalPrivacy(w http.ResponseWriter, r *http.Request) { serveLegal(w, "privacy") }

// LegalTerms serves GET /terms.
func (s *Server) LegalTerms(w http.ResponseWriter, r *http.Request) { serveLegal(w, "terms") }

func serveLegal(w http.ResponseWriter, which string) {
	p := legalPages[which]
	src, err := fs.ReadFile(docsFS, p.file)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	body, title := renderLegalMarkdown(string(src), p.fallback)
	_, _ = w.Write([]byte(`<!doctype html><html lang="en"><head><meta charset="utf-8">` +
		`<meta name="viewport" content="width=device-width,initial-scale=1">` +
		`<title>` + html.EscapeString(title) + `</title><style>` +
		`body{font:16px/1.55 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:46rem;margin:0 auto;padding:1.25rem;color:#1b1b22;background:#fff}` +
		`h1{font-size:1.7rem}h2{font-size:1.25rem;margin-top:2rem}a{color:#5b3fd0}` +
		`blockquote{margin:1rem 0;padding:.6rem 1rem;border-left:4px solid #d9a400;background:#fff8e1}` +
		`table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:.4rem;text-align:left;vertical-align:top}` +
		`code{background:#f1f1f5;padding:0 .25rem;border-radius:3px}` +
		`@media(prefers-color-scheme:dark){body{background:#121218;color:#eaeaf0}a{color:#b8a6ff}code{background:#26262f}blockquote{background:#2a2410}td,th{border-color:#444}}` +
		`</style></head><body>` + body + `<p><a href="/privacy">Privacy policy</a> | <a href="/terms">Terms of use</a></p></body></html>`))
}

var (
	reBold   = regexp.MustCompile(`\*\*(.+?)\*\*`)
	reCode   = regexp.MustCompile("`([^`]+)`")
	reLink   = regexp.MustCompile(`\[([^\]]+)\]\(([^)\s]+)\)`)
	reOrdNum = regexp.MustCompile(`^\d+\.\s+`)
)

// legalInline escapes the text and then applies the few inline rules the
// legal drafts use. Link targets are limited to https URLs and the two legal
// pages themselves, so the markdown can never produce a script or javascript:
// link.
func legalInline(s string) string {
	s = html.EscapeString(s)
	s = reCode.ReplaceAllString(s, "<code>$1</code>")
	s = reBold.ReplaceAllString(s, "<strong>$1</strong>")
	return reLink.ReplaceAllStringFunc(s, func(m string) string {
		g := reLink.FindStringSubmatch(m)
		target := ""
		switch {
		case g[2] == "PRIVACY_POLICY.md" || g[2] == "privacy":
			target = "/privacy"
		case g[2] == "TERMS.md" || g[2] == "terms":
			target = "/terms"
		case strings.HasPrefix(g[2], "https://"):
			target = g[2]
		default:
			return g[1]
		}
		return `<a href="` + target + `">` + g[1] + `</a>`
	})
}

// renderLegalMarkdown converts the small markdown subset used in docs/legal
// (headings, paragraphs, bullet/numbered lists, block quotes, pipe tables,
// bold, code, links) to HTML. It returns the body and the first heading.
func renderLegalMarkdown(src, fallbackTitle string) (string, string) {
	var b strings.Builder
	title := fallbackTitle
	lines := strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n")
	var para []string
	list := ""
	flushPara := func() {
		if len(para) > 0 {
			b.WriteString("<p>" + legalInline(strings.Join(para, " ")) + "</p>\n")
			para = nil
		}
	}
	closeList := func() {
		if list != "" {
			b.WriteString("</" + list + ">\n")
			list = ""
		}
	}
	for i := 0; i < len(lines); i++ {
		ln := strings.TrimRight(lines[i], " \t")
		t := strings.TrimSpace(ln)
		switch {
		case t == "":
			flushPara()
			closeList()
		case strings.HasPrefix(t, "#"):
			flushPara()
			closeList()
			lvl := len(t) - len(strings.TrimLeft(t, "#"))
			if lvl > 4 {
				lvl = 4
			}
			text := strings.TrimSpace(t[lvl:])
			if lvl == 1 && title == fallbackTitle {
				title = text
			}
			b.WriteString("<h" + string(rune('0'+lvl)) + ">" + legalInline(text) + "</h" + string(rune('0'+lvl)) + ">\n")
		case strings.HasPrefix(t, ">"):
			flushPara()
			closeList()
			var q []string
			for ; i < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i]), ">"); i++ {
				q = append(q, strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(lines[i]), ">")))
			}
			i--
			b.WriteString("<blockquote>" + legalInline(strings.Join(q, " ")) + "</blockquote>\n")
		case strings.HasPrefix(t, "|"):
			flushPara()
			closeList()
			var rows [][]string
			for ; i < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i]), "|"); i++ {
				row := strings.Trim(strings.TrimSpace(lines[i]), "|")
				if strings.Trim(row, "-| :") == "" {
					continue
				}
				var cells []string
				for _, c := range strings.Split(row, "|") {
					cells = append(cells, strings.TrimSpace(c))
				}
				rows = append(rows, cells)
			}
			i--
			b.WriteString("<table>\n")
			for ri, row := range rows {
				tag := "td"
				if ri == 0 {
					tag = "th"
				}
				b.WriteString("<tr>")
				for _, c := range row {
					b.WriteString("<" + tag + ">" + legalInline(c) + "</" + tag + ">")
				}
				b.WriteString("</tr>\n")
			}
			b.WriteString("</table>\n")
		case strings.HasPrefix(t, "- ") || strings.HasPrefix(t, "* ") || reOrdNum.MatchString(t):
			flushPara()
			kind := "ul"
			item := ""
			if reOrdNum.MatchString(t) {
				kind = "ol"
				item = reOrdNum.ReplaceAllString(t, "")
			} else {
				item = t[2:]
			}
			if list != kind {
				closeList()
				b.WriteString("<" + kind + ">\n")
				list = kind
			}
			// Continuation lines (indented) belong to the same item.
			for i+1 < len(lines) && strings.HasPrefix(lines[i+1], "  ") && strings.TrimSpace(lines[i+1]) != "" &&
				!strings.HasPrefix(strings.TrimSpace(lines[i+1]), "- ") {
				i++
				item += " " + strings.TrimSpace(lines[i])
			}
			b.WriteString("<li>" + legalInline(item) + "</li>\n")
		default:
			closeList()
			para = append(para, t)
		}
	}
	flushPara()
	closeList()
	return b.String(), title
}
