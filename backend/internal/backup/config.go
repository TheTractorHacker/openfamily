// Package backup implements Orbitly's scheduled, encrypted backups: a
// streaming pg_dump piped through age encryption, written to a local directory
// and/or any S3-compatible bucket, with a SHA-256 manifest, retention pruning
// and run records in the database. It is used only by cmd/backup (the optional
// `backup` compose service); the API server never imports it, so S3
// credentials and the dump tools never live in the API container.
package backup

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
)

// S3Config describes one S3-compatible destination. Secrets live only here and
// are never returned by Summary().
type S3Config struct {
	Endpoint     string // host[:port] or https://host[:port]; empty = AWS S3
	Region       string
	Bucket       string
	Prefix       string // no leading/trailing slash
	AccessKeyID  string
	SecretKey    string
	PathStyle    bool
	StorageClass string
	Insecure     bool // allow plain HTTP (local MinIO only)
	AllowPrivate bool // allow loopback/RFC1918 endpoints (link-local is always refused)
}

// Retention is the keep-N-daily/M-weekly/K-monthly policy. All zero keeps
// everything (pruning disabled).
type Retention struct {
	Daily, Weekly, Monthly int
	DryRun                 bool
}

// Config is the full backup service configuration.
type Config struct {
	S3               *S3Config
	LocalDir         string
	Recipients       []string // age X25519 public keys
	PassphraseFile   string   // alternative to Recipients (age scrypt)
	AllowUnencrypted bool
	Schedule         string
	Location         *time.Location
	Retention        Retention
	DatabaseURL      string
	WorkDir          string
	RunOnStart       bool
	// RunOnFirstStart takes a backup at start-up only when none has ever
	// succeeded (BACKUP_RUN_ON_START=first, the compose default), so a fresh
	// install has a backup within minutes instead of at the first 03:15.
	RunOnFirstStart bool
	Version         string

	// EnvPublic / EnvSecrets describe which settings the real environment pins
	// (values only for non-secret ones). Filled by ResolveConfig.
	EnvPublic  map[string]string
	EnvSecrets []string
}

// Summary is the non-secret view shown in the admin panel.
type Summary struct {
	Destinations []DestinationSummary `json:"destinations"`
	Encryption   string               `json:"encryption"` // age-x25519 | age-scrypt | none
	Schedule     string               `json:"schedule"`
	Timezone     string               `json:"timezone"`
	Retention    RetentionSummary     `json:"retention"`
	// Env lists the non-secret settings pinned by the service environment
	// (read-only in the UI); EnvSecrets only names pinned secrets, never values.
	Env        map[string]string `json:"env"`
	EnvSecrets []string          `json:"env_secrets"`
	// SettingsError is set when the saved UI settings could not be applied (the
	// previous configuration stays active). Scrubbed of secrets.
	SettingsError string `json:"settings_error,omitempty"`
	// SettingsUpdatedAt is the UI settings version this service is running.
	SettingsUpdatedAt *time.Time `json:"settings_updated_at,omitempty"`
}

type DestinationSummary struct {
	Kind   string `json:"kind"`   // local | s3
	Target string `json:"target"` // path, or s3://bucket/prefix (endpoint host only, no keys)
}

type RetentionSummary struct {
	Daily   int  `json:"daily"`
	Weekly  int  `json:"weekly"`
	Monthly int  `json:"monthly"`
	DryRun  bool `json:"dry_run"`
}

func readFileTrim(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// secretEnv returns NAME, or the trimmed contents of the file named by
// NAME_FILE (Docker/Compose secrets). The file wins if both are set.
func secretEnv(getenv func(string) string, name string) (string, error) {
	if f := getenv(name + "_FILE"); f != "" {
		v, err := readFileTrim(f)
		if err != nil {
			return "", fmt.Errorf("%s_FILE: cannot read file", name)
		}
		return v, nil
	}
	return strings.TrimSpace(getenv(name)), nil
}

func envBool(getenv func(string) string, name string, def bool) bool {
	v := strings.ToLower(strings.TrimSpace(getenv(name)))
	if v == "" {
		return def
	}
	return v == "1" || v == "true" || v == "yes" || v == "on"
}

func envInt(getenv func(string) string, name string, def int) (int, error) {
	v := strings.TrimSpace(getenv(name))
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > 3650 {
		return 0, fmt.Errorf("%s must be an integer between 0 and 3650", name)
	}
	return n, nil
}

// LoadConfig reads the BACKUP_* environment. It validates everything that can
// be checked offline and never includes a secret value in an error.
func LoadConfig(getenv func(string) string) (*Config, error) {
	c := &Config{
		LocalDir:         strings.TrimSpace(getenv("BACKUP_LOCAL_DIR")),
		AllowUnencrypted: envBool(getenv, "BACKUP_ALLOW_UNENCRYPTED", false),
		Schedule:         strings.TrimSpace(getenv("BACKUP_SCHEDULE")),
		DatabaseURL:      getenv("DATABASE_URL"),
		WorkDir:          strings.TrimSpace(getenv("BACKUP_WORK_DIR")),
		Version:          getenv("GIT_COMMIT"),
	}
	switch strings.ToLower(strings.TrimSpace(getenv("BACKUP_RUN_ON_START"))) {
	case "first", "first-run", "once":
		c.RunOnFirstStart = true
	default:
		c.RunOnStart = envBool(getenv, "BACKUP_RUN_ON_START", false)
	}
	if c.Schedule == "" {
		c.Schedule = "15 3 * * *"
	}
	if c.WorkDir == "" {
		c.WorkDir = os.TempDir()
	}
	tz := strings.TrimSpace(getenv("BACKUP_TZ"))
	if tz == "" {
		tz = strings.TrimSpace(getenv("TZ"))
	}
	if tz == "" {
		tz = "UTC"
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return nil, fmt.Errorf("BACKUP_TZ %q is not a valid time zone", tz)
	}
	c.Location = loc
	if _, err := ParseCron(c.Schedule); err != nil {
		return nil, fmt.Errorf("BACKUP_SCHEDULE: %w", err)
	}

	var e error
	if c.Retention.Daily, e = envInt(getenv, "BACKUP_KEEP_DAILY", 7); e != nil {
		return nil, e
	}
	if c.Retention.Weekly, e = envInt(getenv, "BACKUP_KEEP_WEEKLY", 4); e != nil {
		return nil, e
	}
	if c.Retention.Monthly, e = envInt(getenv, "BACKUP_KEEP_MONTHLY", 6); e != nil {
		return nil, e
	}
	c.Retention.DryRun = envBool(getenv, "BACKUP_RETENTION_DRY_RUN", false)

	// Encryption: age recipients (public keys) or a passphrase file.
	recips := getenv("BACKUP_AGE_RECIPIENT")
	if f := getenv("BACKUP_AGE_RECIPIENTS_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, errors.New("BACKUP_AGE_RECIPIENTS_FILE: cannot read file")
		}
		recips += "\n" + string(b)
	}
	for _, r := range strings.FieldsFunc(recips, func(r rune) bool { return r == ',' || r == '\n' || r == ' ' || r == '\t' || r == '\r' }) {
		if strings.HasPrefix(r, "#") {
			continue
		}
		c.Recipients = append(c.Recipients, r)
	}
	c.PassphraseFile = strings.TrimSpace(getenv("BACKUP_AGE_PASSPHRASE_FILE"))
	if len(c.Recipients) > 0 && c.PassphraseFile != "" {
		return nil, errors.New("set either BACKUP_AGE_RECIPIENT(S) or BACKUP_AGE_PASSPHRASE_FILE, not both")
	}
	if _, _, err := newEncryptor(c); err != nil {
		return nil, err
	}

	// S3.
	if bucket := strings.TrimSpace(getenv("BACKUP_S3_BUCKET")); bucket != "" {
		s := &S3Config{
			Endpoint:     strings.TrimSpace(getenv("BACKUP_S3_ENDPOINT")),
			Region:       strings.TrimSpace(getenv("BACKUP_S3_REGION")),
			Bucket:       bucket,
			Prefix:       strings.Trim(strings.TrimSpace(prefixOrDefault(getenv("BACKUP_S3_PREFIX"))), "/"),
			PathStyle:    envBool(getenv, "BACKUP_S3_PATH_STYLE", false),
			StorageClass: strings.TrimSpace(getenv("BACKUP_S3_STORAGE_CLASS")),
			Insecure:     envBool(getenv, "BACKUP_S3_INSECURE", false),
			// Operator-supplied (environment) endpoints may be on the LAN; the UI sets this explicitly.
			AllowPrivate: envBool(getenv, "BACKUP_S3_ALLOW_PRIVATE", true),
		}
		if s.AccessKeyID, e = secretEnv(getenv, "BACKUP_S3_ACCESS_KEY_ID"); e != nil {
			return nil, e
		}
		if s.SecretKey, e = secretEnv(getenv, "BACKUP_S3_SECRET_ACCESS_KEY"); e != nil {
			return nil, e
		}
		if s.AccessKeyID == "" || s.SecretKey == "" {
			return nil, errors.New("BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY (or their _FILE variants) are required when BACKUP_S3_BUCKET is set")
		}
		host, _, err := s.hostAndTLS()
		if err != nil {
			return nil, err
		}
		h := host
		if hh, _, e := net.SplitHostPort(host); e == nil {
			h = hh
		}
		if err := backupsettings.CheckHost(strings.Trim(h, "[]"), s.AllowPrivate); err != nil {
			return nil, fmt.Errorf("BACKUP_S3_ENDPOINT: %w", err)
		}
		if !c.encrypted() && !c.AllowUnencrypted {
			return nil, errors.New("refusing to upload an unencrypted database dump to S3: set BACKUP_AGE_RECIPIENT (recommended) or BACKUP_AGE_PASSPHRASE_FILE, or BACKUP_ALLOW_UNENCRYPTED=true")
		}
		c.S3 = s
	}
	return c, nil
}

func (c *Config) encrypted() bool { return len(c.Recipients) > 0 || c.PassphraseFile != "" }

// HasDestination reports whether anything is configured to receive backups.
func (c *Config) HasDestination() bool { return c.S3 != nil || c.LocalDir != "" }

// hostAndTLS normalises the endpoint and enforces TLS unless Insecure is set.
func (s *S3Config) hostAndTLS() (host string, secure bool, err error) {
	ep := s.Endpoint
	if ep == "" {
		return "s3.amazonaws.com", true, nil
	}
	secure = true
	explicitHTTPS := false
	if strings.Contains(ep, "://") {
		u, perr := url.Parse(ep)
		if perr != nil || u.Host == "" {
			return "", false, errors.New("BACKUP_S3_ENDPOINT is not a valid URL")
		}
		if u.User != nil {
			return "", false, errors.New("BACKUP_S3_ENDPOINT must not contain credentials")
		}
		if u.Path != "" && u.Path != "/" {
			return "", false, errors.New("BACKUP_S3_ENDPOINT must be a host (optionally with scheme and port), without a path")
		}
		switch u.Scheme {
		case "https":
			explicitHTTPS = true
		case "http":
			secure = false
		default:
			return "", false, errors.New("BACKUP_S3_ENDPOINT scheme must be https (or http with BACKUP_S3_INSECURE=true)")
		}
		ep = u.Host
	}
	switch {
	case explicitHTTPS:
		// An explicit https:// is never downgraded by the insecure flag.
	case s.Insecure:
		secure = false
	case !secure:
		return "", false, errors.New("BACKUP_S3_ENDPOINT uses plain http; TLS is required unless BACKUP_S3_INSECURE=true (local MinIO only)")
	}
	return ep, secure, nil
}

// Summary returns the non-secret description used by the admin panel.
func (c *Config) Summary() Summary {
	s := Summary{Schedule: c.Schedule, Timezone: c.Location.String(), Destinations: []DestinationSummary{}}
	if c.LocalDir != "" {
		s.Destinations = append(s.Destinations, DestinationSummary{Kind: "local", Target: c.LocalDir})
	}
	if c.S3 != nil {
		host := c.S3.Endpoint
		if host == "" {
			host = "AWS S3"
		}
		if i := strings.Index(host, "://"); i >= 0 {
			host = host[i+3:]
		}
		t := "s3://" + c.S3.Bucket
		if c.S3.Prefix != "" {
			t += "/" + c.S3.Prefix
		}
		s.Destinations = append(s.Destinations, DestinationSummary{Kind: "s3", Target: t + " @ " + host})
	}
	_, mode, _ := newEncryptor(c)
	s.Encryption = mode
	s.Env, s.EnvSecrets = c.EnvPublic, c.EnvSecrets
	if s.Env == nil {
		s.Env = map[string]string{}
	}
	if s.EnvSecrets == nil {
		s.EnvSecrets = []string{}
	}
	s.Retention = RetentionSummary{Daily: c.Retention.Daily, Weekly: c.Retention.Weekly, Monthly: c.Retention.Monthly, DryRun: c.Retention.DryRun}
	return s
}

// secrets lists every sensitive literal so errors can be scrubbed.
func (c *Config) secrets() []string {
	var out []string
	if c.S3 != nil {
		out = append(out, c.S3.SecretKey, c.S3.AccessKeyID)
	}
	return out
}

// DatabaseSecrets returns literals to scrub from database error text.
func (c *Config) DatabaseSecrets() []string { return append(c.secrets(), dbPassword(c.DatabaseURL)) }

func dbPassword(u string) string {
	if p, err := url.Parse(u); err == nil && p.User != nil {
		pw, _ := p.User.Password()
		return pw
	}
	return ""
}

func prefixOrDefault(p string) string {
	if strings.TrimSpace(p) == "" {
		return "openfamily"
	}
	return p
}
