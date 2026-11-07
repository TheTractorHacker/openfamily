package backup

import (
	"regexp"
	"strings"
)

var ageSecretRe = regexp.MustCompile(`AGE-SECRET-KEY-[A-Z0-9]+`)

// Scrub removes secrets from text that may be logged, stored in backup_runs or
// returned by the API: every configured secret literal, any age private key,
// and anything shaped like a password in a URL. The result is capped at 500
// bytes.
func Scrub(s string, secrets []string) string {
	for _, sec := range secrets {
		if len(sec) >= 4 {
			s = strings.ReplaceAll(s, sec, "***")
		}
	}
	s = ageSecretRe.ReplaceAllString(s, "***")
	s = urlPassRe.ReplaceAllString(s, "$1***@")
	s = strings.TrimSpace(s)
	if len(s) > 500 {
		s = s[:500] + "..."
	}
	return s
}

var urlPassRe = regexp.MustCompile(`(://[^/\s:@]*:)[^/\s@]+@`)
