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
