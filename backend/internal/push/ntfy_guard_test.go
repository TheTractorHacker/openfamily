package push

import (
	"net/url"
	"testing"
)

func parseURL(raw string) (*url.URL, error) { return url.Parse(raw) }

func TestNtfyTopicRules(t *testing.T) {
	ConfigureNtfy("https://push.example.org", "")
	defer ConfigureNtfy("", "")
	cases := map[string]bool{
		"https://push.example.org/family":               false, // guessable word
		"https://push.example.org/alerts-alerts":        false, // letters only, one case
		"https://push.example.org/a/b":                  false, // not a single segment
		"https://push.example.org/":                     false,
		"https://push.example.org/up4x9K2mQ7vB1":        true, // ntfy-app style
		"https://push.example.org/orbitly-7f3a9c21d4e8": true,
		"https://ntfy.sh/shorty":                        false,
		"https://ntfy.sh/up4x9K2mQ7vB1":                 true,
	}
	for raw, wantOK := range cases {
		err := validateTopicOnly(t, raw)
		if (err == nil) != wantOK {
			t.Errorf("%s: ok=%v want %v (%v)", raw, err == nil, wantOK, err)
		}
	}
}

// validateTopicOnly runs just the topic rule (no DNS) for a URL.
func validateTopicOnly(t *testing.T, raw string) error {
	t.Helper()
	u, err := parseURL(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !ntfyGuarded(u.Hostname()) {
		return nil
	}
	return validateNtfyTopic(u)
}

func TestNtfyAuthTokenOnlyForConfiguredHost(t *testing.T) {
	ConfigureNtfy("https://push.example.org", "tk_secret")
	defer ConfigureNtfy("", "")
	if ntfyAuthFor("push.example.org") != "tk_secret" {
		t.Fatal("token must be sent to the configured host")
	}
	if ntfyAuthFor("other.example.org") != "" || ntfyAuthFor("ntfy.sh") != "" {
		t.Fatal("token must never go to another host")
	}
}
