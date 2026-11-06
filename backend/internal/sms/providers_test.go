package sms

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestNormalizeProvider(t *testing.T) {
	for in, want := range map[string]string{"": "twilio", " Twilio ": "twilio", "TELNYX": "telnyx", "plivo": "plivo", "SNS": "sns"} {
		if got, ok := NormalizeProvider(in); !ok || got != want {
			t.Errorf("NormalizeProvider(%q) = %q,%v want %q", in, got, ok, want)
		}
	}
	if _, ok := NormalizeProvider("carrier-pigeon"); ok {
		t.Fatal("unknown provider accepted")
	}
}

func TestProviderEnabledPerProvider(t *testing.T) {
	cases := []struct {
		name string
		cfg  Config
		want bool
	}{
		{"none", Config{}, false},
		{"twilio ok", Config{AccountSID: "a", AuthToken: "b", From: "+1"}, true},
		{"twilio missing from", Config{AccountSID: "a", AuthToken: "b"}, false},
		{"telnyx needs key+from only", Config{Provider: "telnyx", AuthToken: "k", From: "+1"}, true},
		{"telnyx no key", Config{Provider: "telnyx", From: "+1"}, false},
		{"plivo ok", Config{Provider: "plivo", AccountSID: "id", AuthToken: "t", From: "+1"}, true},
		{"sns needs region, from optional", Config{Provider: "sns", AccountSID: "ak", AuthToken: "sk", Region: "us-east-1"}, true},
		{"sns no region", Config{Provider: "sns", AccountSID: "ak", AuthToken: "sk"}, false},
		{"unknown", Config{Provider: "x", AccountSID: "a", AuthToken: "b", From: "c"}, false},
	}
	for _, c := range cases {
		if got := providerEnabled(c.cfg); got != c.want {
			t.Errorf("%s: enabled=%v want %v", c.name, got, c.want)
		}
		if got := New(c.cfg).Enabled(); got != c.want {
			t.Errorf("%s: New().Enabled()=%v want %v", c.name, got, c.want)
		}
	}
}

func TestSettingsMergeKeepsProviderFromEnv(t *testing.T) {
	env := Settings{Provider: "telnyx", Region: "r", AuthToken: "env", From: "+1"}
	got := Merge(env, Settings{Provider: "plivo", AuthToken: "stored"}, true)
	if got.Provider != "telnyx" || got.AuthToken != "stored" {
		t.Fatalf("merge = %+v", got)
	}
	if !got.Enabled() {
		t.Fatal("telnyx with stored key must be enabled")
	}
}

func TestTelnyxFake(t *testing.T) {
	var gotAuth string
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(202)
	}))
	defer srv.Close()
	d := &telnyx{apiKey: "KEY", from: "+15550001111", endpoint: srv.URL, client: srv.Client()}
	if err := d.Send(context.Background(), "+1 (555) 000-2222", "hi"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer KEY" || gotBody["to"] != "+15550002222" || gotBody["from"] != "+15550001111" || gotBody["text"] != "hi" {
		t.Fatalf("auth=%q body=%v", gotAuth, gotBody)
	}
	if err := d.Send(context.Background(), "garbage", "hi"); err == nil {
		t.Fatal("invalid phone must fail before any request")
	}
}

func TestPlivoFake(t *testing.T) {
	var path, user, pass string
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		user, pass, _ = r.BasicAuth()
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(202)
	}))
	defer srv.Close()
	d := &plivo{authID: "MAID", authToken: "tok", from: "+15550001111", baseURL: srv.URL, client: srv.Client()}
	if err := d.Send(context.Background(), "+15550002222", "yo"); err != nil {
		t.Fatal(err)
	}
	if path != "/v1/Account/MAID/Message/" || user != "MAID" || pass != "tok" || gotBody["dst"] != "+15550002222" || gotBody["src"] != "+15550001111" || gotBody["text"] != "yo" {
		t.Fatalf("path=%q user=%q body=%v", path, user, gotBody)
	}
}

func TestSNSFakeSignsRequest(t *testing.T) {
	var auth, date string
	var form url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, date = r.Header.Get("Authorization"), r.Header.Get("X-Amz-Date")
		b, _ := io.ReadAll(r.Body)
		form, _ = url.ParseQuery(string(b))
		w.WriteHeader(200)
	}))
	defer srv.Close()
	fixed := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	d := &snsSender{accessKey: "AKID", secretKey: "SECRET", region: "eu-west-1", senderID: "OpenFam",
		endpoint: srv.URL + "/", now: func() time.Time { return fixed }, client: srv.Client()}
	if err := d.Send(context.Background(), "+15550002222", "hello"); err != nil {
		t.Fatal(err)
	}
	if date != "20261106T120000Z" ||
		!strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential=AKID/20261106/eu-west-1/sns/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=") {
		t.Fatalf("date=%q auth=%q", date, auth)
	}
	if form.Get("Action") != "Publish" || form.Get("PhoneNumber") != "+15550002222" || form.Get("Message") != "hello" ||
		form.Get("MessageAttributes.entry.1.Value.StringValue") != "OpenFam" {
		t.Fatalf("form=%v", form)
	}
	// Signature is deterministic for a fixed clock and secret.
	first := auth
	_ = d.Send(context.Background(), "+15550002222", "hello")
	if auth != first {
		t.Fatal("SigV4 signature not deterministic")
	}
	// A different secret must change it.
	d.secretKey = "OTHER"
	_ = d.Send(context.Background(), "+15550002222", "hello")
	if auth == first {
		t.Fatal("signature ignores the secret")
	}
}

func TestProviderErrorSurfacesStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad key", 401)
	}))
	defer srv.Close()
	d := &telnyx{apiKey: "k", from: "+1", endpoint: srv.URL, client: srv.Client()}
	err := d.Send(context.Background(), "+15550002222", "x")
	if err == nil || !strings.Contains(err.Error(), "telnyx returned 401") {
		t.Fatalf("err=%v", err)
	}
}
