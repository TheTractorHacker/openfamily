package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

const (
	maxTwilioSIDLen   = 64
	maxTwilioTokenLen = 128
	smsSourceSettings = "settings"
	smsSourceEnv      = "environment"
)

type smsSettingsResponse struct {
	Configured    bool   `json:"configured"`
	AccountSID    string `json:"account_sid"`
	AuthTokenSet  bool   `json:"auth_token_set"`
	From          string `json:"from"`
	PublicBaseURL string `json:"public_base_url"`
	Source        string `json:"source"`
}

type smsSettingsPutRequest struct {
	AccountSID    string `json:"account_sid"`
	AuthToken     string `json:"auth_token"`
	From          string `json:"from"`
	PublicBaseURL string `json:"public_base_url"`
}

// LoadSMSSettings applies env credentials, then any saved admin row, and
// rebuilds the SMS dispatcher. Called at startup and after settings changes.
func (s *Server) LoadSMSSettings(ctx context.Context) error {
	stored, present, err := s.readSMSSettings(ctx)
	if err != nil {
		return err
	}
	s.applySMSSettings(sms.Merge(s.SMSEnv, stored, present))
	return nil
}

func (s *Server) SMSEnabled() bool {
	s.smsMu.RLock()
	defer s.smsMu.RUnlock()
	return s.SMS != nil && s.SMS.Enabled()
}

func (s *Server) sendSMS(ctx context.Context, to, body string) error {
	s.smsMu.RLock()
	defer s.smsMu.RUnlock()
	if s.SMS == nil || !s.SMS.Enabled() {
		return nil
	}
	return s.SMS.Send(ctx, to, body)
}

func (s *Server) publicBaseURL() string {
	s.smsMu.RLock()
	defer s.smsMu.RUnlock()
	return s.PublicBaseURL
}

func (s *Server) applySMSSettings(effective sms.Settings) {
	s.smsMu.Lock()
	defer s.smsMu.Unlock()
	s.SMS = sms.New(effective.Config())
	s.PublicBaseURL = effective.PublicBaseURL
}

func (s *Server) effectiveSMSSettings(ctx context.Context) (sms.Settings, bool, error) {
	stored, present, err := s.readSMSSettings(ctx)
	if err != nil {
		return sms.Settings{}, false, err
	}
	return sms.Merge(s.SMSEnv, stored, present), present, nil
}

func (s *Server) readSMSSettings(ctx context.Context) (sms.Settings, bool, error) {
	var row sms.Settings
	err := s.Pool.QueryRow(ctx, `
		SELECT account_sid, auth_token, from_number, public_base_url
		FROM sms_settings WHERE id = 1`).Scan(
		&row.AccountSID, &row.AuthToken, &row.From, &row.PublicBaseURL,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return sms.Settings{}, false, nil
	}
	if err != nil {
		return sms.Settings{}, false, err
	}
	return row, true, nil
}

func smsSettingsJSON(effective sms.Settings, fromSettings bool) smsSettingsResponse {
	source := smsSourceEnv
	if fromSettings {
		source = smsSourceSettings
	}
	return smsSettingsResponse{
		Configured:    effective.Enabled(),
		AccountSID:    effective.AccountSID,
		AuthTokenSet:  strings.TrimSpace(effective.AuthToken) != "",
		From:          effective.From,
		PublicBaseURL: effective.PublicBaseURL,
		Source:        source,
	}
}

func prepareStoredSMSSettings(req smsSettingsPutRequest, existing sms.Settings, existingOK bool, env sms.Settings) (sms.Settings, error) {
	sid := strings.TrimSpace(req.AccountSID)
	token := strings.TrimSpace(req.AuthToken)
	if sid == "" {
		return sms.Settings{}, errors.New("account SID is required")
	}
	if len(sid) > maxTwilioSIDLen {
		return sms.Settings{}, errors.New("account SID is too long")
	}
	if len(token) > maxTwilioTokenLen {
		return sms.Settings{}, errors.New("auth token is too long")
	}
	from, err := sms.NormalizeE164(req.From)
	if err != nil {
		return sms.Settings{}, err
	}
	if from == "" {
		return sms.Settings{}, errors.New("from number is required")
	}
	base, err := sms.NormalizePublicBaseURL(req.PublicBaseURL)
	if err != nil {
		return sms.Settings{}, err
	}
	if token == "" {
		switch {
		case existingOK && existing.AuthToken != "":
			token = existing.AuthToken
		case env.AuthToken != "":
			token = env.AuthToken
		default:
			return sms.Settings{}, errors.New("auth token is required")
		}
	}
	return sms.Settings{
		AccountSID:    sid,
		AuthToken:     token,
		From:          from,
		PublicBaseURL: base,
	}, nil
}

// AdminGetSMSSettings returns the effective Twilio configuration without
// the auth token. Requires platform admin.
func (s *Server) AdminGetSMSSettings(w http.ResponseWriter, r *http.Request) {
	if middleware.ClaimsFromContext(r.Context()) == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	effective, fromSettings, err := s.effectiveSMSSettings(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load SMS settings")
		return
	}
	writeJSON(w, http.StatusOK, smsSettingsJSON(effective, fromSettings))
}

// AdminPutSMSSettings saves Twilio credentials and enables SMS immediately.
func (s *Server) AdminPutSMSSettings(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	var req smsSettingsPutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	existing, existingOK, err := s.readSMSSettings(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load SMS settings")
		return
	}
	stored, err := prepareStoredSMSSettings(req, existing, existingOK, s.SMSEnv)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	_, err = s.Pool.Exec(r.Context(), `
		INSERT INTO sms_settings (id, account_sid, auth_token, from_number, public_base_url, updated_at)
		VALUES (1, $1, $2, $3, $4, now())
		ON CONFLICT (id) DO UPDATE SET
			account_sid = EXCLUDED.account_sid,
			auth_token = EXCLUDED.auth_token,
			from_number = EXCLUDED.from_number,
			public_base_url = EXCLUDED.public_base_url,
			updated_at = now()`,
		stored.AccountSID, stored.AuthToken, stored.From, stored.PublicBaseURL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save SMS settings")
		return
	}
	if err := s.LoadSMSSettings(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to apply SMS settings")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "sms.settings_updated", "updated Twilio SMS settings", clientIP(r))
	writeJSON(w, http.StatusOK, smsSettingsJSON(sms.Merge(s.SMSEnv, stored, true), true))
}

// AdminDeleteSMSSettings removes the saved row so environment values apply again.
func (s *Server) AdminDeleteSMSSettings(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if _, err := s.Pool.Exec(r.Context(), `DELETE FROM sms_settings WHERE id = 1`); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to clear SMS settings")
		return
	}
	if err := s.LoadSMSSettings(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to apply SMS settings")
		return
	}
	s.logAudit(r.Context(), claims.UserID, "", "sms.settings_cleared", "cleared saved Twilio SMS settings", clientIP(r))
	effective, _, err := s.effectiveSMSSettings(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load SMS settings")
		return
	}
	writeJSON(w, http.StatusOK, smsSettingsJSON(effective, false))
}
