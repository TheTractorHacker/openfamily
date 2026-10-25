package main

import (
	"crypto/sha256"
	"encoding/base64"
	"regexp"
	"strings"
	"testing"

	web "github.com/TheTractorHacker/openfamily/backend/web"
)

// TestAdminCSPCoversInlineScripts pins the Content-Security-Policy to the
// embedded admin panel's inline scripts. The CSP allows only 'self' plus
// explicit hashes, so any rebuild that changes (or adds) an inline <script>
// in dist/index.html must come with an updated hash in adminSPACSP — this
// test fails loudly instead of shipping a policy that silently breaks the
// theme bootstrap or, worse, a page whose new inline script is not covered.
func TestAdminCSPCoversInlineScripts(t *testing.T) {
	index, err := web.Dist.ReadFile("dist/index.html")
	if err != nil {
		t.Fatalf("read embedded index.html: %v", err)
	}

	re := regexp.MustCompile(`(?s)<script>(.*?)</script>`)
	matches := re.FindAllSubmatch(index, -1)
	if len(matches) == 0 {
		t.Fatal("no inline scripts found in dist/index.html; if inline scripts were removed intentionally, update this test and adminSPACSP")
	}
	for i, m := range matches {
		sum := sha256.Sum256(m[1])
		want := "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
		if !strings.Contains(adminSPACSP, want) {
			t.Errorf("inline script #%d is not allowed by adminSPACSP.\nadd %s to the script-src directive", i, want)
		}
	}
}

func TestAdminCSPMapDirectives(t *testing.T) {
	csp := buildAdminCSP("")
	for _, want := range []string{
		"connect-src 'self' https://tiles.openfreemap.org;",
		"worker-src 'self' blob:;",
		"child-src blob:;",
		"img-src 'self' data: blob: https:;",
		"object-src 'none'",
		"frame-ancestors 'none'",
	} {
		if !strings.Contains(csp, want) {
			t.Errorf("CSP missing %q:\n%s", want, csp)
		}
	}
	if strings.Contains(csp, "unsafe-eval") || strings.Contains(csp, "script-src 'self' 'unsafe") {
		t.Errorf("script-src must stay strict: %s", csp)
	}
	custom := buildAdminCSP("https://maps.example.com/styles/x.json")
	if !strings.Contains(custom, "connect-src 'self' https://tiles.openfreemap.org https://maps.example.com;") {
		t.Errorf("custom style origin not added: %s", custom)
	}
	if strings.Contains(buildAdminCSP("http://insecure.example/s.json"), "insecure.example") {
		t.Error("non-https style origin must not be allowed")
	}
}
