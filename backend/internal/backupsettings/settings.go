// Package backupsettings holds the backup configuration that an admin can edit
// in the web UI: the settings model, validation, the network policy for S3
// endpoints, envelope encryption of the S3 credentials, and the database
// access shared by the API (writes) and the backup service (reads). It has no
// heavy dependencies so the API can import it; the S3 client lives in
// internal/backup, which only the backup service uses.
package backupsettings

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strings"
	"time"

	"filippo.io/age"
)

// Settings is the non-secret, UI-editable configuration.
type Settings struct {
	S3Enabled     bool     `json:"s3_enabled"`
	Endpoint      string   `json:"endpoint"`
	Region        string   `json:"region"`
	Bucket        string   `json:"bucket"`
	Prefix        string   `json:"prefix"`
	PathStyle     bool     `json:"path_style"`
	StorageClass  string   `json:"storage_class"`
	Insecure      bool     `json:"insecure"`
	AllowPrivate  bool     `json:"allow_private"`
	LocalEnabled  bool     `json:"local_enabled"`
	AgeRecipients []string `json:"age_recipients"`
	Schedule      string   `json:"schedule"`
	Timezone      string   `json:"timezone"`
	KeepDaily     int      `json:"keep_daily"`
	KeepWeekly    int      `json:"keep_weekly"`
	KeepMonthly   int      `json:"keep_monthly"`
	StaleHours    int      `json:"stale_hours"`
	// AccessKeyHint is the last 4 characters of the stored access key id. It is
	// maintained by the server, never taken from a client.
	AccessKeyHint string `json:"access_key_hint,omitempty"`
}

// Credentials are the write-only S3 credentials.
type Credentials struct {
	AccessKeyID string `json:"access_key_id"`
	SecretKey   string `json:"secret_access_key"`
}

// Defaults are used for every field neither the environment nor the UI set.
func Defaults() Settings {
	return Settings{Prefix: "openfamily", Schedule: "15 3 * * *", Timezone: "UTC",
		KeepDaily: 7, KeepWeekly: 4, KeepMonthly: 6, StaleHours: 36, AgeRecipients: []string{}}
}

// Field links a UI field to the environment variables that pin it.
type Field struct {
	Name string
	Env  []string
}

// Fields lists every editable field. A field is "pinned" (read-only in the UI)
// when any of its environment variables is non-empty.
var Fields = []Field{
	{"s3_enabled", []string{"BACKUP_S3_BUCKET"}},
	{"endpoint", []string{"BACKUP_S3_ENDPOINT"}},
	{"region", []string{"BACKUP_S3_REGION"}},
	{"bucket", []string{"BACKUP_S3_BUCKET"}},
	{"prefix", []string{"BACKUP_S3_PREFIX"}},
	{"path_style", []string{"BACKUP_S3_PATH_STYLE"}},
	{"storage_class", []string{"BACKUP_S3_STORAGE_CLASS"}},
	{"insecure", []string{"BACKUP_S3_INSECURE"}},
	{"allow_private", []string{"BACKUP_S3_ALLOW_PRIVATE"}},
	{"credentials", []string{"BACKUP_S3_ACCESS_KEY_ID", "BACKUP_S3_ACCESS_KEY_ID_FILE", "BACKUP_S3_SECRET_ACCESS_KEY", "BACKUP_S3_SECRET_ACCESS_KEY_FILE"}},
	{"local_enabled", []string{"BACKUP_LOCAL_DIR"}},
	{"age_recipients", []string{"BACKUP_AGE_RECIPIENT", "BACKUP_AGE_RECIPIENTS_FILE", "BACKUP_AGE_PASSPHRASE_FILE"}},
	{"schedule", []string{"BACKUP_SCHEDULE"}},
	{"timezone", []string{"BACKUP_TZ"}},
	{"keep_daily", []string{"BACKUP_KEEP_DAILY"}},
	{"keep_weekly", []string{"BACKUP_KEEP_WEEKLY"}},
	{"keep_monthly", []string{"BACKUP_KEEP_MONTHLY"}},
	{"stale_hours", []string{"BACKUP_STALE_HOURS"}},
}

// PublicEnvVars are the pinning variables whose VALUES are non-secret and may
// be shown in the UI (everything except credentials and secret file paths).
var PublicEnvVars = []string{
	"BACKUP_S3_BUCKET", "BACKUP_S3_ENDPOINT", "BACKUP_S3_REGION", "BACKUP_S3_PREFIX", "BACKUP_S3_PATH_STYLE",
	"BACKUP_S3_STORAGE_CLASS", "BACKUP_S3_INSECURE", "BACKUP_S3_ALLOW_PRIVATE", "BACKUP_LOCAL_DIR", "BACKUP_AGE_RECIPIENT",
	"BACKUP_SCHEDULE", "BACKUP_TZ", "BACKUP_KEEP_DAILY", "BACKUP_KEEP_WEEKLY", "BACKUP_KEEP_MONTHLY", "BACKUP_STALE_HOURS",
	"BACKUP_ALLOW_UNENCRYPTED",
}

// Overlay converts UI settings into the BACKUP_* variables the service's
// environment loader understands. Real environment variables win over these.
func Overlay(s Settings, c *Credentials) map[string]string {
	m := map[string]string{}
	b := func(v bool) string {
		if v {
			return "true"
		}
		return "false"
	}
	if s.S3Enabled && s.Bucket != "" {
		m["BACKUP_S3_BUCKET"] = s.Bucket
		m["BACKUP_S3_ENDPOINT"] = s.Endpoint
		m["BACKUP_S3_REGION"] = s.Region
		m["BACKUP_S3_PREFIX"] = s.Prefix
		m["BACKUP_S3_PATH_STYLE"] = b(s.PathStyle)
		m["BACKUP_S3_STORAGE_CLASS"] = s.StorageClass
		m["BACKUP_S3_INSECURE"] = b(s.Insecure)
		m["BACKUP_S3_ALLOW_PRIVATE"] = b(s.AllowPrivate)
		if c != nil {
			m["BACKUP_S3_ACCESS_KEY_ID"] = c.AccessKeyID
			m["BACKUP_S3_SECRET_ACCESS_KEY"] = c.SecretKey
		}
	}
	if s.LocalEnabled {
		m["BACKUP_LOCAL_DIR"] = "/backups"
	}
	if len(s.AgeRecipients) > 0 {
		m["BACKUP_AGE_RECIPIENT"] = strings.Join(s.AgeRecipients, ",")
	}
	m["BACKUP_SCHEDULE"] = s.Schedule
	m["BACKUP_TZ"] = s.Timezone
	m["BACKUP_KEEP_DAILY"] = fmt.Sprint(s.KeepDaily)
	m["BACKUP_KEEP_WEEKLY"] = fmt.Sprint(s.KeepWeekly)
	m["BACKUP_KEEP_MONTHLY"] = fmt.Sprint(s.KeepMonthly)
	return m
}

var (
	bucketRe = regexp.MustCompile(`^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$`)
	regionRe = regexp.MustCompile(`^[A-Za-z0-9._\-]{0,64}$`)
	prefixRe = regexp.MustCompile(`^[A-Za-z0-9._\-/]{0,200}$`)
	classRe  = regexp.MustCompile(`^[A-Z0-9_]{0,32}$`)
	keyIDRe  = regexp.MustCompile(`^[A-Za-z0-9/+=._\-]{4,128}$`)
)

// ValidateRecipients checks age public keys; a private key gets a pointed error
// that never echoes the value.
func ValidateRecipients(rs []string) error {
	if len(rs) > 5 {
		return errors.New("at most 5 public keys")
	}
	for _, r := range rs {
		if strings.HasPrefix(strings.TrimSpace(r), "AGE-SECRET-KEY-") {
			return errors.New("that is a PRIVATE key (AGE-SECRET-KEY-...). Never paste it here: keep it off the server and enter only the public key (age1...)")
		}
		if _, err := age.ParseX25519Recipient(strings.TrimSpace(r)); err != nil {
			return errors.New("not a valid age public key (expected age1...)")
		}
	}
	return nil
}

// ValidateEndpoint enforces TLS (unless insecure) and the address policy for
// literal IPs and well-known metadata names. Hostnames are re-checked at
// connection time by the backup service (GuardedDialControl).
func ValidateEndpoint(ep string, insecure, allowPrivate bool) error {
	if ep == "" {
		return nil // AWS S3
	}
	host := ep
	secure := true
	if strings.Contains(ep, "://") {
		u, err := url.Parse(ep)
		if err != nil || u.Host == "" {
			return errors.New("not a valid URL")
		}
		if u.User != nil {
			return errors.New("must not contain credentials")
		}
		if u.Path != "" && u.Path != "/" || u.RawQuery != "" || u.Fragment != "" {
			return errors.New("must be a host (optionally with scheme and port), without a path")
		}
		switch u.Scheme {
		case "https":
		case "http":
			secure = false
		default:
			return errors.New("scheme must be https")
		}
		host = u.Host
		if !secure && !insecure {
			return errors.New("plain http is refused: use https, or enable \"Allow plain HTTP\" for a MinIO on your own network")
		}
	} else if strings.ContainsAny(host, "/@?#\\ ") {
		return errors.New("must be a host name or URL")
	}
	h := host
	if hh, _, err := net.SplitHostPort(host); err == nil {
		h = hh
	}
	h = strings.Trim(h, "[]")
	if h == "" {
		return errors.New("missing host")
	}
	return CheckHost(h, allowPrivate)
}

// ValidateSettings validates every field and returns per-field messages.
func ValidateSettings(s *Settings) map[string]string {
	e := map[string]string{}
	if s.S3Enabled {
		if s.Bucket == "" {
			e["bucket"] = "required when S3 is enabled"
		} else if !bucketRe.MatchString(s.Bucket) {
			e["bucket"] = "3-63 characters: lowercase letters, digits, dots and dashes"
		}
		if err := ValidateEndpoint(s.Endpoint, s.Insecure, s.AllowPrivate); err != nil {
			e["endpoint"] = err.Error()
		}
		if !regionRe.MatchString(s.Region) {
			e["region"] = "letters, digits, dots and dashes only"
		}
		if !prefixRe.MatchString(s.Prefix) || strings.Contains(s.Prefix, "..") || strings.Contains(s.Prefix, "//") {
			e["prefix"] = "letters, digits, . _ - and / only"
		}
		if !classRe.MatchString(s.StorageClass) {
			e["storage_class"] = "upper-case letters, digits and underscores (e.g. STANDARD_IA)"
		}
	}
	if err := ValidateRecipients(s.AgeRecipients); err != nil {
		e["age_recipients"] = err.Error()
	}
	if _, err := ParseCron(s.Schedule); err != nil {
		e["schedule"] = err.Error()
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil || s.Timezone == "" {
		e["timezone"] = "not a valid IANA time zone (e.g. Europe/Berlin)"
	}
	for name, v := range map[string]int{"keep_daily": s.KeepDaily, "keep_weekly": s.KeepWeekly, "keep_monthly": s.KeepMonthly} {
		if v < 0 || v > 3650 {
			e[name] = "0 to 3650"
		}
	}
	if s.StaleHours < 1 || s.StaleHours > 8760 {
		e["stale_hours"] = "1 to 8760"
	}
	return e
}

// ValidateCredentials checks the shape of the credentials without echoing them.
func ValidateCredentials(c Credentials) map[string]string {
	e := map[string]string{}
	if !keyIDRe.MatchString(c.AccessKeyID) {
		e["access_key_id"] = "4-128 characters, letters, digits and / + = . _ -"
	}
	if len(c.SecretKey) < 8 || len(c.SecretKey) > 256 || strings.ContainsAny(c.SecretKey, "\r\n\x00") {
		e["secret_access_key"] = "8-256 characters, no line breaks"
	}
	return e
}

// Hint returns the last four characters of an access key id.
func Hint(id string) string {
	if len(id) <= 4 {
		return ""
	}
	return "…" + id[len(id)-4:]
}
