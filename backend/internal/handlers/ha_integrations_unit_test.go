package handlers

import (
	"net/netip"
	"testing"
)

func parseAddrForTest(s string) (netip.Addr, error) { return netip.ParseAddr(s) }

// Shared with integrations/home_assistant/tests/test_webhook_auth.py so the server's
// signing and the Home Assistant verifier cannot drift apart.
func TestHAWebhookSignatureVector(t *testing.T) {
	got := HAWebhookSignature("secret", 1700000000, []byte(`{"a":1}`))
	if got != "v1=49f24e537407743fa4a0242bb63b94b9a47ee99cbbe071ccd8a22550ae411686" {
		t.Fatalf("signature vector changed: %s", got)
	}
}

func TestHAParseWebhookURL(t *testing.T) {
	for _, bad := range []string{"", "ftp://x", "http://", "http://u:p@h/x", "http://h/x#f", "http://h:99999/x", "javascript:alert(1)", "//h/x"} {
		if _, err := haParseWebhookURL(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if _, err := haParseWebhookURL("https://hooks.nabu.casa/abc"); err != nil {
		t.Error(err)
	}
	if got := haMaskURL("http://ha.local:8123/api/webhook/abcdef1234"); got != "http://ha.local:8123/…1234" {
		t.Errorf("mask: %q", got)
	}
}
