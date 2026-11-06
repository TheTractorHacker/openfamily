package sms

import (
	"errors"
	"net/url"
	"strings"
)

// Settings is the effective Twilio configuration used to send SMS.
// Environment values are the fallback; a saved admin row overrides any
// field that is non-empty.
type Settings struct {
	// Provider (SMS_PROVIDER) and Region (SMS_REGION, sns only) are
	// deployment settings: the admin screen edits credentials, not these.
	Provider      string
	Region        string
	AccountSID    string
	AuthToken     string
	From          string
	PublicBaseURL string
}

// ErrInvalidPublicBaseURL is returned when the share-link origin is not https.
var ErrInvalidPublicBaseURL = errors.New("public base URL must be an https origin, e.g. https://openfamily.example.com")

// Merge prefers non-empty stored fields over env. When no settings row
// exists, env is used as-is so existing TWILIO_* deploys keep working.
func Merge(env Settings, stored Settings, storedPresent bool) Settings {
	if !storedPresent {
		return env
	}
	out := env // Provider and Region always come from the environment
	if strings.TrimSpace(stored.AccountSID) != "" {
		out.AccountSID = stored.AccountSID
	}
	if stored.AuthToken != "" {
		out.AuthToken = stored.AuthToken
	}
	if strings.TrimSpace(stored.From) != "" {
		out.From = stored.From
	}
	if strings.TrimSpace(stored.PublicBaseURL) != "" {
		out.PublicBaseURL = stored.PublicBaseURL
	}
	return out
}

// Enabled is true when the selected provider has all the credentials it needs.
func (s Settings) Enabled() bool { return providerEnabled(s.Config()) }

// Config returns the dispatcher credentials.
func (s Settings) Config() Config {
	return Config{
		Provider:   s.Provider,
		Region:     s.Region,
		AccountSID: s.AccountSID,
		AuthToken:  s.AuthToken,
		From:       s.From,
	}
}

// NormalizePublicBaseURL trims a trailing slash and requires https when set.
// Empty input clears the value (returns "", nil).
func NormalizePublicBaseURL(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", nil
	}
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", ErrInvalidPublicBaseURL
	}
	return strings.TrimRight(s, "/"), nil
}
