package push

import (
	"errors"
	"net/url"
	"strings"
	"sync"
)

// ntfy topics are the only secret on an open ntfy server: whoever knows the
// topic name can read every notification posted to it and publish fake ones.
// Two server-side controls follow:
//
//  1. On a guarded ntfy host (the configured NTFY_BASE_URL, and the public
//     ntfy.sh) a registered endpoint must be a single path segment that looks
//     like a random topic (>= 12 characters, mixed, not a word), so a
//     predictable name such as "family" or "alerts" is refused.
//  2. NTFY_AUTH_TOKEN, when set, is sent as a bearer token on every publish to
//     the configured host, so the ntfy server can run with deny-all access
//     and still accept the API server (see docs/push.md).
var (
	ntfyMu    sync.RWMutex
	ntfyHost  string
	ntfyToken string
)

// ConfigureNtfy records the configured ntfy origin and optional publish token.
func ConfigureNtfy(baseURL, authToken string) {
	host := ""
	if u, err := url.Parse(strings.TrimSpace(baseURL)); err == nil {
		host = strings.ToLower(u.Hostname())
	}
	ntfyMu.Lock()
	ntfyHost, ntfyToken = host, strings.TrimSpace(authToken)
	ntfyMu.Unlock()
}

func ntfyGuarded(host string) bool {
	host = strings.ToLower(host)
	ntfyMu.RLock()
	defer ntfyMu.RUnlock()
	return host == "ntfy.sh" || (ntfyHost != "" && host == ntfyHost)
}

// ntfyAuthFor returns the bearer token to publish to host, or "".
func ntfyAuthFor(host string) string {
	ntfyMu.RLock()
	defer ntfyMu.RUnlock()
	if ntfyToken != "" && ntfyHost != "" && strings.EqualFold(host, ntfyHost) {
		return ntfyToken
	}
	return ""
}

var errWeakTopic = errors.New("push: ntfy topic is too guessable (use a random topic of at least 12 characters)")

// validateNtfyTopic accepts only a single-segment, random-looking topic.
func validateNtfyTopic(u *url.URL) error {
	topic := strings.Trim(u.Path, "/")
	if topic == "" || strings.Contains(topic, "/") || u.RawQuery != "" {
		return errWeakTopic
	}
	if len(topic) < 12 || len(topic) > 64 {
		return errWeakTopic
	}
	distinct := map[rune]struct{}{}
	digits, letters := 0, 0
	for _, c := range topic {
		distinct[c] = struct{}{}
		switch {
		case c >= '0' && c <= '9':
			digits++
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			letters++
		case c == '-' || c == '_':
		default:
			return errWeakTopic
		}
	}
	// A dictionary-style name is letters only and repeats little; random
	// topics (the ntfy app's "up" + 12 random characters) mix digits or cases.
	if len(distinct) < 8 {
		return errWeakTopic
	}
	if digits == 0 && !hasMixedCase(topic) {
		return errWeakTopic
	}
	return nil
}

func hasMixedCase(s string) bool {
	lower, upper := false, false
	for _, c := range s {
		if c >= 'a' && c <= 'z' {
			lower = true
		}
		if c >= 'A' && c <= 'Z' {
			upper = true
		}
	}
	return lower && upper
}
