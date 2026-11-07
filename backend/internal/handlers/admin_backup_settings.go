package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/backupsettings"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
)

// Backup settings editable from the admin UI.
//
// Secrecy model: the S3 access key id and secret are accepted by PUT (and, for
// a one-off test, by POST test-s3), sealed with AES-256-GCM under a key derived
// from BACKUP_SETTINGS_KEY / JWT_SECRET, and stored in backup_settings. They
// are never returned by any endpoint (GET only reports "set" and the last four
// characters of the key id), never written to the audit log (only field names)
// and never put in error text. The backup service reads and decrypts them with
// the same key. Anyone holding both the database and the server environment can
// decrypt them: use a bucket key scoped to the backup prefix.

const backupSettingsPerHour = 20

type backupAgentInfo struct {
	Env           map[string]string `json:"env"`
	EnvSecrets    []string          `json:"env_secrets"`
	SettingsError string            `json:"settings_error"`
}

type backupSettingsCreds struct {
	AccessKeySet  bool   `json:"access_key_set"`
	AccessKeyHint string `json:"access_key_hint"`
	SecretSet     bool   `json:"secret_set"`
	Source        string `json:"source"` // env | ui | none
	Pinned        bool   `json:"pinned"`
	Unreadable    bool   `json:"unreadable"`
}

type backupSettingsOut struct {
	Values         backupsettings.Settings `json:"values"`
	Sources        map[string]string       `json:"sources"`
	Pinned         []string                `json:"pinned"`
	Credentials    backupSettingsCreds     `json:"credentials"`
	UpdatedAt      *time.Time              `json:"updated_at"`
	AgentReporting bool                    `json:"agent_reporting"`
	SettingsError  string                  `json:"settings_error,omitempty"`
	KeyConfigured  bool                    `json:"key_configured"`
}

type backupSettingsIn struct {
	Settings         backupsettings.Settings `json:"settings"`
	AccessKeyID      string                  `json:"access_key_id"`
	SecretAccessKey  string                  `json:"secret_access_key"`
	ClearCredentials bool                    `json:"clear_credentials"`
}

func (s *Server) readBackupAgentInfo(r *http.Request) (info backupAgentInfo, reporting bool) {
	var raw json.RawMessage
	var hb time.Time
	if err := s.Pool.QueryRow(r.Context(), `SELECT heartbeat_at, config FROM backup_agent WHERE id = 1`).Scan(&hb, &raw); err != nil {
		return
	}
	_ = json.Unmarshal(raw, &info)
	return info, time.Since(hb) < backupAgentAlive
}

func envBoolStr(v string) bool {
	v = strings.ToLower(strings.TrimSpace(v))
	return v == "1" || v == "true" || v == "yes" || v == "on"
}

// applyEnv overwrites the pinned fields of st with what the service's
// environment says.
func applyEnv(st *backupsettings.Settings, env map[string]string) {
	if v := env["BACKUP_S3_BUCKET"]; v != "" {
		st.S3Enabled, st.Bucket = true, v
	}
	set := func(k string, f func(string)) {
		if v := env[k]; v != "" {
			f(v)
		}
	}
	set("BACKUP_S3_ENDPOINT", func(v string) { st.Endpoint = v })
	set("BACKUP_S3_REGION", func(v string) { st.Region = v })
	set("BACKUP_S3_PREFIX", func(v string) { st.Prefix = v })
	set("BACKUP_S3_PATH_STYLE", func(v string) { st.PathStyle = envBoolStr(v) })
	set("BACKUP_S3_STORAGE_CLASS", func(v string) { st.StorageClass = v })
	set("BACKUP_S3_INSECURE", func(v string) { st.Insecure = envBoolStr(v) })
	set("BACKUP_S3_ALLOW_PRIVATE", func(v string) { st.AllowPrivate = envBoolStr(v) })
	set("BACKUP_LOCAL_DIR", func(string) { st.LocalEnabled = true })
	set("BACKUP_AGE_RECIPIENT", func(v string) {
		st.AgeRecipients = nil
		for _, x := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' }) {
			st.AgeRecipients = append(st.AgeRecipients, x)
		}
	})
	set("BACKUP_SCHEDULE", func(v string) { st.Schedule = v })
	set("BACKUP_TZ", func(v string) { st.Timezone = v })
	atoi := func(dst *int) func(string) {
		return func(v string) {
			if n, err := strconv.Atoi(v); err == nil {
				*dst = n
			}
		}
	}
	set("BACKUP_KEEP_DAILY", atoi(&st.KeepDaily))
	set("BACKUP_KEEP_WEEKLY", atoi(&st.KeepWeekly))
	set("BACKUP_KEEP_MONTHLY", atoi(&st.KeepMonthly))
	set("BACKUP_STALE_HOURS", atoi(&st.StaleHours))
}

// pinnedFields maps field name -> true when the environment sets it.
func (s *Server) pinnedFields(info backupAgentInfo) map[string]bool {
	set := map[string]bool{}
	for k := range info.Env {
		set[k] = true
	}
	for _, k := range info.EnvSecrets {
		set[k] = true
	}
	if s.BackupStaleHours > 0 {
		set["BACKUP_STALE_HOURS"] = true
	}
	pins := map[string]bool{}
	for _, f := range backupsettings.Fields {
		for _, e := range f.Env {
			if set[e] {
				pins[f.Name] = true
			}
		}
	}
	return pins
}

func (s *Server) staleEnvValue(env map[string]string) map[string]string {
	if s.BackupStaleHours > 0 {
		out := map[string]string{}
		for k, v := range env {
			out[k] = v
		}
		out["BACKUP_STALE_HOURS"] = strconv.Itoa(s.BackupStaleHours)
		return out
	}
	return env
}

// AdminGetBackupSettings returns the effective configuration with the source
// of every field. Secrets are never included.
// GET /api/admin/backups/settings
func (s *Server) AdminGetBackupSettings(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	st, err := backupsettings.Load(r.Context(), s.Pool, nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backup settings")
		return
	}
	info, reporting := s.readBackupAgentInfo(r)
	env := s.staleEnvValue(info.Env)
	pins := s.pinnedFields(info)

	out := backupSettingsOut{Values: st.Settings, Sources: map[string]string{}, Pinned: []string{}, AgentReporting: reporting,
		SettingsError: info.SettingsError, KeyConfigured: s.BackupSettingsKey != nil}
	if st.Exists {
		t := st.UpdatedAt
		out.UpdatedAt = &t
	}
	applyEnv(&out.Values, env)
	for _, f := range backupsettings.Fields {
		src := "default"
		if st.Exists {
			src = "ui"
		}
		if pins[f.Name] {
			src = "env"
			out.Pinned = append(out.Pinned, f.Name)
		}
		out.Sources[f.Name] = src
	}
	sort.Strings(out.Pinned)
	// Never expose anything but presence and a hint.
	out.Values.AccessKeyHint = ""
	c := backupSettingsCreds{Source: "none"}
	if st.HasCreds {
		c.AccessKeySet, c.SecretSet, c.Source = true, true, "ui"
		c.AccessKeyHint = st.Settings.AccessKeyHint
		if s.BackupSettingsKey != nil {
			var blobErr error
			if full, e := backupsettings.Load(r.Context(), s.Pool, s.BackupSettingsKey); e == nil {
				blobErr = full.CredsErr
			}
			c.Unreadable = blobErr != nil
		}
	}
	if pins["credentials"] {
		c.AccessKeySet, c.SecretSet, c.Source, c.Pinned, c.AccessKeyHint = true, true, "env", true, ""
	}
	out.Credentials = c
	writeJSON(w, http.StatusOK, out)
}

type settingsProblem struct {
	status int
	fields map[string]string
	msg    string
}

// prepareBackupSettings validates a submitted form against the environment
// pins and returns the settings to store (pinned fields keep their previous UI
// value) plus the effective settings used for validation.
func (s *Server) prepareBackupSettings(r *http.Request, in *backupSettingsIn, prev *backupsettings.Stored) (store backupsettings.Settings, effective backupsettings.Settings, creds *backupsettings.Credentials, prob *settingsProblem) {
	info, _ := s.readBackupAgentInfo(r)
	env := s.staleEnvValue(info.Env)
	pins := s.pinnedFields(info)

	// Normalise.
	in.Settings.AccessKeyHint = ""
	in.Settings.Endpoint = strings.TrimSpace(in.Settings.Endpoint)
	in.Settings.Bucket = strings.TrimSpace(in.Settings.Bucket)
	in.Settings.Prefix = strings.Trim(strings.TrimSpace(in.Settings.Prefix), "/")
	in.Settings.Region = strings.TrimSpace(in.Settings.Region)
	in.Settings.StorageClass = strings.TrimSpace(in.Settings.StorageClass)
	in.Settings.Timezone = strings.TrimSpace(in.Settings.Timezone)
	in.Settings.Schedule = strings.Join(strings.Fields(in.Settings.Schedule), " ")
	if in.Settings.AgeRecipients == nil {
		in.Settings.AgeRecipients = []string{}
	}
	for i := range in.Settings.AgeRecipients {
		in.Settings.AgeRecipients[i] = strings.TrimSpace(in.Settings.AgeRecipients[i])
	}

	// A pinned field cannot be changed from the UI.
	envView := backupsettings.Defaults()
	applyEnv(&envView, env)
	cur := prev.Settings
	cur.AccessKeyHint = ""
	effective = in.Settings
	store = in.Settings
	store.AccessKeyHint = prev.Settings.AccessKeyHint
	forced := map[string]string{}
	check := func(name string, differs bool, restore func()) {
		if !pins[name] {
			return
		}
		if differs {
			forced[name] = "set by the server environment; change it in .env, not here"
		}
		restore()
	}
	e, i, p := &effective, &in.Settings, &store
	for _, f := range []struct {
		name string
		diff bool
		fix  func()
	}{
		{"s3_enabled", i.S3Enabled != envView.S3Enabled, func() { e.S3Enabled = envView.S3Enabled; p.S3Enabled = cur.S3Enabled }},
		{"endpoint", i.Endpoint != envView.Endpoint, func() { e.Endpoint = envView.Endpoint; p.Endpoint = cur.Endpoint }},
		{"region", i.Region != envView.Region, func() { e.Region = envView.Region; p.Region = cur.Region }},
		{"bucket", i.Bucket != envView.Bucket, func() { e.Bucket = envView.Bucket; p.Bucket = cur.Bucket }},
		{"prefix", i.Prefix != envView.Prefix, func() { e.Prefix = envView.Prefix; p.Prefix = cur.Prefix }},
		{"path_style", i.PathStyle != envView.PathStyle, func() { e.PathStyle = envView.PathStyle; p.PathStyle = cur.PathStyle }},
		{"storage_class", i.StorageClass != envView.StorageClass, func() { e.StorageClass = envView.StorageClass; p.StorageClass = cur.StorageClass }},
		{"insecure", i.Insecure != envView.Insecure, func() { e.Insecure = envView.Insecure; p.Insecure = cur.Insecure }},
		{"allow_private", i.AllowPrivate != envView.AllowPrivate, func() { e.AllowPrivate = envView.AllowPrivate; p.AllowPrivate = cur.AllowPrivate }},
		{"local_enabled", i.LocalEnabled != envView.LocalEnabled, func() { e.LocalEnabled = envView.LocalEnabled; p.LocalEnabled = cur.LocalEnabled }},
		{"age_recipients", strings.Join(i.AgeRecipients, ",") != strings.Join(envView.AgeRecipients, ","), func() { e.AgeRecipients = envView.AgeRecipients; p.AgeRecipients = cur.AgeRecipients }},
		{"schedule", i.Schedule != envView.Schedule, func() { e.Schedule = envView.Schedule; p.Schedule = cur.Schedule }},
		{"timezone", i.Timezone != envView.Timezone, func() { e.Timezone = envView.Timezone; p.Timezone = cur.Timezone }},
		{"keep_daily", i.KeepDaily != envView.KeepDaily, func() { e.KeepDaily = envView.KeepDaily; p.KeepDaily = cur.KeepDaily }},
		{"keep_weekly", i.KeepWeekly != envView.KeepWeekly, func() { e.KeepWeekly = envView.KeepWeekly; p.KeepWeekly = cur.KeepWeekly }},
		{"keep_monthly", i.KeepMonthly != envView.KeepMonthly, func() { e.KeepMonthly = envView.KeepMonthly; p.KeepMonthly = cur.KeepMonthly }},
		{"stale_hours", i.StaleHours != envView.StaleHours, func() { e.StaleHours = envView.StaleHours; p.StaleHours = cur.StaleHours }},
	} {
		check(f.name, f.diff, f.fix)
	}
	if pins["credentials"] && (in.AccessKeyID != "" || in.SecretAccessKey != "" || in.ClearCredentials) {
		forced["credentials"] = "set by the server environment; change it in .env, not here"
	}
	if len(forced) > 0 {
		return store, effective, nil, &settingsProblem{status: http.StatusBadRequest, fields: forced, msg: "some fields are pinned by the server environment"}
	}

	errs := backupsettings.ValidateSettings(&effective)
	if in.AccessKeyID != "" || in.SecretAccessKey != "" {
		c := backupsettings.Credentials{AccessKeyID: strings.TrimSpace(in.AccessKeyID), SecretKey: in.SecretAccessKey}
		for k, v := range backupsettings.ValidateCredentials(c) {
			errs[k] = v
		}
		creds = &c
	}
	if effective.S3Enabled {
		hasCreds := pins["credentials"] || (prev.HasCreds && !in.ClearCredentials) || creds != nil
		if !hasCreds {
			errs["access_key_id"] = "S3 needs an access key; enter the key id and secret"
		}
		hasEnc := len(effective.AgeRecipients) > 0
		for _, k := range info.EnvSecrets {
			if k == "BACKUP_AGE_PASSPHRASE_FILE" || k == "BACKUP_AGE_RECIPIENTS_FILE" {
				hasEnc = true
			}
		}
		if !hasEnc && !envBoolStr(env["BACKUP_ALLOW_UNENCRYPTED"]) {
			if _, bad := errs["age_recipients"]; !bad {
				errs["age_recipients"] = "S3 backups must be encrypted: add your age public key (use Generate key pair)"
			}
		}
	}
	if len(errs) > 0 {
		return store, effective, nil, &settingsProblem{status: http.StatusBadRequest, fields: errs, msg: "invalid settings"}
	}
	return store, effective, creds, nil
}

func writeSettingsProblem(w http.ResponseWriter, p *settingsProblem) {
	writeJSON(w, p.status, map[string]any{"error": p.msg, "fields": p.fields})
}

// changedBackupFields lists the names (never values) of fields that differ.
func changedBackupFields(a, b backupsettings.Settings) []string {
	a.AccessKeyHint, b.AccessKeyHint = "", ""
	ja, jb := map[string]any{}, map[string]any{}
	ra, _ := json.Marshal(a)
	rb, _ := json.Marshal(b)
	_ = json.Unmarshal(ra, &ja)
	_ = json.Unmarshal(rb, &jb)
	var out []string
	for k := range jb {
		if fmt.Sprint(ja[k]) != fmt.Sprint(jb[k]) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func decodeBackupSettingsBody(w http.ResponseWriter, r *http.Request) (*backupSettingsIn, bool) {
	var in backupSettingsIn
	in.Settings = backupsettings.Defaults()
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return nil, false
	}
	return &in, true
}

// AdminPutBackupSettings validates and saves the settings. The backup service
// picks them up within seconds without a restart.
// PUT /api/admin/backups/settings
func (s *Server) AdminPutBackupSettings(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !s.backupLimiter().Allow("backup:settings:"+claims.UserID, backupSettingsPerHour, backupRateWindow) {
		w.Header().Set("Retry-After", "3600")
		writeError(w, http.StatusTooManyRequests, "too many changes; try again later")
		return
	}
	if s.BackupSettingsKey == nil {
		writeError(w, http.StatusServiceUnavailable, "no settings key is available (set BACKUP_SETTINGS_KEY or JWT_SECRET)")
		return
	}
	in, ok := decodeBackupSettingsBody(w, r)
	if !ok {
		return
	}
	prev, err := backupsettings.Load(r.Context(), s.Pool, nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backup settings")
		return
	}
	store, _, creds, prob := s.prepareBackupSettings(r, in, prev)
	if prob != nil {
		writeSettingsProblem(w, prob)
		return
	}
	if err := backupsettings.Save(r.Context(), s.Pool, s.BackupSettingsKey, store, creds, in.ClearCredentials, claims.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save backup settings")
		return
	}
	changed := changedBackupFields(prev.Settings, store)
	if creds != nil {
		changed = append(changed, "credentials(replaced)")
	} else if in.ClearCredentials {
		changed = append(changed, "credentials(cleared)")
	}
	detail := "no changes"
	if len(changed) > 0 {
		detail = "changed: " + strings.Join(changed, ", ")
	}
	s.logAudit(r.Context(), claims.UserID, "", "admin.backup.settings", detail, clientIP(r))
	s.AdminGetBackupSettings(w, r)
}

// sealTestPayload validates the unsaved form carried by a test request and
// returns it sealed for the backup service.
func (s *Server) sealTestPayload(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	if s.BackupSettingsKey == nil {
		writeError(w, http.StatusServiceUnavailable, "no settings key is available (set BACKUP_SETTINGS_KEY or JWT_SECRET)")
		return nil, false
	}
	in, ok := decodeBackupSettingsBody(w, r)
	if !ok {
		return nil, false
	}
	prev, err := backupsettings.Load(r.Context(), s.Pool, nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read backup settings")
		return nil, false
	}
	_, effective, creds, prob := s.prepareBackupSettings(r, in, prev)
	if prob != nil {
		writeSettingsProblem(w, prob)
		return nil, false
	}
	if !effective.S3Enabled {
		writeError(w, http.StatusBadRequest, "enable S3 first")
		return nil, false
	}
	raw, _ := json.Marshal(struct {
		Settings    backupsettings.Settings     `json:"settings"`
		Credentials *backupsettings.Credentials `json:"credentials,omitempty"`
	}{effective, creds})
	blob, err := backupsettings.SealPayload(s.BackupSettingsKey, raw)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to queue the test")
		return nil, false
	}
	return blob, true
}
