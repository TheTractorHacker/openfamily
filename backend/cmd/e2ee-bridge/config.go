package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"
)

// config comes from the bridge's own JSON file, never from the OpenFamily
// database (the server must not learn where the plaintext goes).
type config struct {
	// Mode is "" (Dawarich bridge, the default) or "server" (the OpenFamily
	// server's own device: decrypted positions go to Ingest, not to Dawarich).
	Mode        string             `json:"mode,omitempty"`
	Ingest      ingestCfg          `json:"ingest,omitempty"`
	Dawarich    dawarichCfg        `json:"dawarich"`
	Users       map[string]userCfg `json:"users"`
	Circles     []string           `json:"circles"`
	Since       string             `json:"since"`
	PollSeconds int                `json:"poll_seconds"`

	since time.Time
}

// ingestCfg is where the server device hands decrypted positions: the OpenFamily
// API, over the private network between the containers.
type ingestCfg struct {
	URL       string `json:"url"`
	TokenFile string `json:"token_file,omitempty"`

	token string
}

type dawarichCfg struct {
	BaseURL      string `json:"base_url"`
	LocalURL     string `json:"local_url"`
	APIKey       string `json:"api_key"`
	SendUnmapped bool   `json:"send_unmapped"`
}

type userCfg struct {
	APIKey string `json:"api_key"`
	Label  string `json:"label"`
}

func validateBaseURL(s, field string) error {
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%s must be an http(s) URL", field)
	}
	return nil
}

func loadConfig(path string, env func(string) string) (*config, error) {
	var c config
	if path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if fi, err := os.Stat(path); err == nil && fi.Mode().Perm()&0o077 != 0 {
			fmt.Fprintf(os.Stderr, "warning: %s is readable by other users and holds Dawarich API keys; chmod 600 it\n", path)
		}
		dec := json.NewDecoder(strings.NewReader(string(b)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&c); err != nil {
			return nil, fmt.Errorf("config: %w", err)
		}
	}
	if k := env("E2EE_BRIDGE_DAWARICH_KEY"); k != "" {
		c.Dawarich.APIKey = strings.TrimSpace(k)
	}
	switch c.Mode {
	case "":
	case "server":
		return finishServerConfig(&c, env)
	default:
		return nil, errors.New(`config: mode must be "" or "server"`)
	}
	if err := validateBaseURL(c.Dawarich.BaseURL, "dawarich.base_url"); err != nil {
		return nil, err
	}
	if c.Dawarich.LocalURL != "" {
		if err := validateBaseURL(c.Dawarich.LocalURL, "dawarich.local_url"); err != nil {
			return nil, err
		}
	}
	c.Dawarich.BaseURL = strings.TrimRight(c.Dawarich.BaseURL, "/")
	c.Dawarich.LocalURL = strings.TrimRight(c.Dawarich.LocalURL, "/")
	if c.Dawarich.APIKey == "" && len(c.Users) == 0 {
		return nil, errors.New("config: no Dawarich API key (dawarich.api_key, E2EE_BRIDGE_DAWARICH_KEY or users[].api_key)")
	}
	if c.Dawarich.SendUnmapped && c.Dawarich.APIKey == "" {
		return nil, errors.New("config: send_unmapped needs a main dawarich.api_key")
	}
	for id, u := range c.Users {
		if len(id) != 36 || u.APIKey == "" {
			return nil, fmt.Errorf("config: users[%q] needs a user id and an api_key", id)
		}
	}
	if c.Since != "" {
		t, err := time.Parse(time.RFC3339, c.Since)
		if err != nil {
			t, err = time.Parse("2006-01-02", c.Since)
		}
		if err != nil {
			return nil, errors.New("config: since must be RFC3339 or YYYY-MM-DD")
		}
		c.since = t.UTC()
	}
	if c.PollSeconds == 0 {
		c.PollSeconds = 30
	}
	if c.PollSeconds < 5 || c.PollSeconds > 3600 {
		return nil, errors.New("config: poll_seconds must be 5..3600")
	}
	return &c, nil
}

func (c *config) wantCircle(id string) bool {
	if len(c.Circles) == 0 {
		return true
	}
	for _, x := range c.Circles {
		if x == id {
			return true
		}
	}
	return false
}

// target says which Dawarich account a person's points go to.
type target struct {
	key     string
	label   string
	perUser bool // a dedicated per-person account (one person only)
}

func (c *config) targetFor(userID string) (target, bool) {
	if u, ok := c.Users[userID]; ok && u.APIKey != "" {
		l := u.Label
		if l == "" {
			l = userID[:8]
		}
		return target{key: u.APIKey, label: l, perUser: true}, true
	}
	if c.Dawarich.SendUnmapped && c.Dawarich.APIKey != "" {
		return target{key: c.Dawarich.APIKey, label: "main"}, true
	}
	return target{}, false
}

func (c *config) serverMode() bool { return c.Mode == "server" }

// finishServerConfig validates the server-device configuration. The ingest token
// is the same secret the OpenFamily server was given (E2EE_SERVER_INGEST_TOKEN);
// it comes from the environment or a file, never from the JSON itself.
func finishServerConfig(c *config, env func(string) string) (*config, error) {
	if err := validateBaseURL(c.Ingest.URL, "ingest.url"); err != nil {
		return nil, err
	}
	c.Ingest.URL = strings.TrimRight(c.Ingest.URL, "/")
	tok := strings.TrimSpace(env("E2EE_SERVER_INGEST_TOKEN"))
	if tok == "" && c.Ingest.TokenFile != "" {
		b, err := os.ReadFile(c.Ingest.TokenFile)
		if err != nil {
			return nil, fmt.Errorf("config: ingest.token_file: %w", err)
		}
		tok = strings.TrimSpace(string(b))
	}
	if len(tok) < 32 {
		return nil, errors.New("config: the ingest token (E2EE_SERVER_INGEST_TOKEN or ingest.token_file) must be at least 32 characters")
	}
	c.Ingest.token = tok
	if c.Since != "" {
		t, err := time.Parse(time.RFC3339, c.Since)
		if err != nil {
			t, err = time.Parse("2006-01-02", c.Since)
		}
		if err != nil {
			return nil, errors.New("config: since must be RFC3339 or YYYY-MM-DD")
		}
		c.since = t.UTC()
	}
	if c.PollSeconds == 0 {
		c.PollSeconds = 15
	}
	if c.PollSeconds < 5 || c.PollSeconds > 3600 {
		return nil, errors.New("config: poll_seconds must be 5..3600")
	}
	return c, nil
}
