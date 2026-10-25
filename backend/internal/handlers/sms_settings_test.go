package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
)

func TestPrepareStoredSMSSettingsRequiresSIDAndFrom(t *testing.T) {
	_, err := prepareStoredSMSSettings(smsSettingsPutRequest{
		AuthToken: "tok",
		From:      "+15551234567",
	}, sms.Settings{}, false, sms.Settings{})
	if err == nil {
		t.Fatal("expected missing SID error")
	}

	_, err = prepareStoredSMSSettings(smsSettingsPutRequest{
		AccountSID: "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		AuthToken:  "tok",
	}, sms.Settings{}, false, sms.Settings{})
	if err == nil {
		t.Fatal("expected missing from error")
	}
}

func TestPrepareStoredSMSSettingsKeepsExistingToken(t *testing.T) {
	got, err := prepareStoredSMSSettings(smsSettingsPutRequest{
		AccountSID: "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		From:       "+1 (555) 123-4567",
	}, sms.Settings{AuthToken: "kept"}, true, sms.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	if got.AuthToken != "kept" {
		t.Fatalf("token=%q", got.AuthToken)
	}
	if got.From != "+15551234567" {
		t.Fatalf("from=%q", got.From)
	}
}

func TestPrepareStoredSMSSettingsRejectsHTTPBaseURL(t *testing.T) {
	_, err := prepareStoredSMSSettings(smsSettingsPutRequest{
		AccountSID:    "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		AuthToken:     "tok",
		From:          "+15551234567",
		PublicBaseURL: "http://insecure.example",
	}, sms.Settings{}, false, sms.Settings{})
	if err == nil {
		t.Fatal("expected invalid URL error")
	}
}

func TestSMSSettingsJSONNeverIncludesToken(t *testing.T) {
	body, err := json.Marshal(smsSettingsJSON(sms.Settings{
		AccountSID: "ACxxx",
		AuthToken:  "super-secret",
		From:       "+15551234567",
	}, true))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "super-secret") {
		t.Fatalf("token leaked: %s", body)
	}
	if !strings.Contains(string(body), `"auth_token_set":true`) {
		t.Fatalf("missing auth_token_set: %s", body)
	}
	if !strings.Contains(string(body), `"source":"settings"`) {
		t.Fatalf("missing source: %s", body)
	}
}

func TestAdminGetSMSSettingsUnauthenticated(t *testing.T) {
	srv := &Server{}
	req := httptest.NewRequest(http.MethodGet, "/api/admin/settings/sms", nil)
	w := httptest.NewRecorder()
	srv.AdminGetSMSSettings(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestSMSEnabledUsesDispatcher(t *testing.T) {
	srv := &Server{SMS: sms.New(sms.Config{})}
	if srv.SMSEnabled() {
		t.Fatal("empty dispatcher should be disabled")
	}
	srv.SMS = sms.New(sms.Config{AccountSID: "AC", AuthToken: "tok", From: "+15550001111"})
	if !srv.SMSEnabled() {
		t.Fatal("configured dispatcher should be enabled")
	}
}
