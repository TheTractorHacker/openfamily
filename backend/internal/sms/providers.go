package sms

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Provider names accepted in Config.Provider / SMS_PROVIDER. The empty string
// means Twilio, so existing TWILIO_* deployments keep working.
const (
	ProviderTwilio = "twilio"
	ProviderTelnyx = "telnyx"
	ProviderPlivo  = "plivo"
	ProviderSNS    = "sns"
)

// NormalizeProvider lower-cases and defaults the provider name. The second
// result is false for an unknown provider.
func NormalizeProvider(p string) (string, bool) {
	switch p = strings.ToLower(strings.TrimSpace(p)); p {
	case "", ProviderTwilio:
		return ProviderTwilio, true
	case ProviderTelnyx, ProviderPlivo, ProviderSNS:
		return p, true
	}
	return p, false
}

// Credentials map onto Config as follows:
//
//	twilio  AccountSID = Account SID, AuthToken = auth token, From = number / messaging service
//	telnyx  AuthToken  = API key (v2),                         From = number or messaging profile sender
//	plivo   AccountSID = Auth ID,     AuthToken = Auth Token,  From = source number / sender id
//	sns     AccountSID = access key,  AuthToken = secret key,  Region = AWS region, From = optional sender id
func providerEnabled(c Config) bool {
	p, ok := NormalizeProvider(c.Provider)
	if !ok {
		return false
	}
	has := func(s string) bool { return strings.TrimSpace(s) != "" }
	switch p {
	case ProviderTelnyx:
		return has(c.AuthToken) && has(c.From)
	case ProviderSNS:
		return has(c.AccountSID) && has(c.AuthToken) && has(c.Region)
	default: // twilio, plivo
		return has(c.AccountSID) && has(c.AuthToken) && has(c.From)
	}
}

// sendHTTP runs req and turns a non-2xx answer into an error naming the
// provider (the response body is truncated; it never contains our secrets).
func sendHTTP(client *http.Client, name string, req *http.Request) error {
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("sms: %s returned %d: %s", name, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func normalizeTo(to string) (string, error) {
	n, err := NormalizeE164(to)
	if err != nil {
		return "", err
	}
	if n == "" {
		return "", ErrInvalidPhone
	}
	return n, nil
}

// ---- Telnyx (https://developers.telnyx.com/api/messaging/send-message)

type telnyx struct {
	apiKey, from string
	endpoint     string
	client       *http.Client
}

func (t *telnyx) Enabled() bool { return true }

func (t *telnyx) Send(ctx context.Context, to, body string) error {
	to, err := normalizeTo(to)
	if err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]string{"from": t.from, "to": to, "text": body})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+t.apiKey)
	req.Header.Set("Content-Type", "application/json")
	return sendHTTP(t.client, "telnyx", req)
}

// ---- Plivo (https://www.plivo.com/docs/sms/api/message#send-a-message)

type plivo struct {
	authID, authToken, from string
	baseURL                 string
	client                  *http.Client
}

func (p *plivo) Enabled() bool { return true }

func (p *plivo) Send(ctx context.Context, to, body string) error {
	to, err := normalizeTo(to)
	if err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]string{"src": p.from, "dst": to, "text": body})
	endpoint := fmt.Sprintf("%s/v1/Account/%s/Message/", p.baseURL, url.PathEscape(p.authID))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.SetBasicAuth(p.authID, p.authToken)
	req.Header.Set("Content-Type", "application/json")
	return sendHTTP(p.client, "plivo", req)
}

// ---- Amazon SNS (Publish to a phone number, AWS Signature V4)

type snsSender struct {
	accessKey, secretKey, region, senderID string
	endpoint                               string
	now                                    func() time.Time
	client                                 *http.Client
}

func (s *snsSender) Enabled() bool { return true }

func (s *snsSender) Send(ctx context.Context, to, body string) error {
	to, err := normalizeTo(to)
	if err != nil {
		return err
	}
	form := url.Values{
		"Action":      {"Publish"},
		"Version":     {"2010-03-31"},
		"PhoneNumber": {to},
		"Message":     {body},
	}
	if s.senderID != "" {
		form.Set("MessageAttributes.entry.1.Name", "AWS.SNS.SMS.SenderID")
		form.Set("MessageAttributes.entry.1.Value.DataType", "String")
		form.Set("MessageAttributes.entry.1.Value.StringValue", s.senderID)
	}
	payload := form.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.endpoint, strings.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
	s.sign(req, payload)
	return sendHTTP(s.client, "sns", req)
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// sign adds AWS Signature Version 4 headers for service "sns".
func (s *snsSender) sign(req *http.Request, payload string) {
	now := s.now().UTC()
	amzDate := now.Format("20060102T150405Z")
	day := now.Format("20060102")
	host := req.URL.Host
	req.Header.Set("X-Amz-Date", amzDate)
	sum := sha256.Sum256([]byte(payload))
	payloadHash := hex.EncodeToString(sum[:])
	path := req.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	canonical := strings.Join([]string{
		req.Method, path, "",
		"content-type:" + req.Header.Get("Content-Type") + "\nhost:" + host + "\nx-amz-date:" + amzDate + "\n",
		"content-type;host;x-amz-date",
		payloadHash,
	}, "\n")
	scope := day + "/" + s.region + "/sns/aws4_request"
	csum := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(csum[:])
	k := hmacSHA256([]byte("AWS4"+s.secretKey), day)
	k = hmacSHA256(k, s.region)
	k = hmacSHA256(k, "sns")
	k = hmacSHA256(k, "aws4_request")
	sig := hex.EncodeToString(hmacSHA256(k, toSign))
	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=content-type;host;x-amz-date, Signature=%s",
		s.accessKey, scope, sig))
}

// newProvider builds the non-Twilio dispatchers.
func newProvider(cfg Config) Dispatcher {
	client := &http.Client{Timeout: 10 * time.Second}
	switch p, _ := NormalizeProvider(cfg.Provider); p {
	case ProviderTelnyx:
		return &telnyx{apiKey: strings.TrimSpace(cfg.AuthToken), from: strings.TrimSpace(cfg.From),
			endpoint: "https://api.telnyx.com/v2/messages", client: client}
	case ProviderPlivo:
		return &plivo{authID: strings.TrimSpace(cfg.AccountSID), authToken: cfg.AuthToken, from: strings.TrimSpace(cfg.From),
			baseURL: "https://api.plivo.com", client: client}
	case ProviderSNS:
		region := strings.TrimSpace(cfg.Region)
		return &snsSender{accessKey: strings.TrimSpace(cfg.AccountSID), secretKey: cfg.AuthToken, region: region,
			senderID: strings.TrimSpace(cfg.From), endpoint: "https://sns." + region + ".amazonaws.com/",
			now: time.Now, client: client}
	}
	return Noop{}
}
