package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

func runCLI(t *testing.T, env map[string]string, stdin string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := realMain(context.Background(), args, func(k string) string { return env[k] }, strings.NewReader(stdin), &out, &errb)
	return code, out.String(), errb.String()
}

func TestEnrollRegisterStatusRevoke(t *testing.T) {
	aliceID := newUUIDv4()
	of := newFakeOF(t, newUUIDv4(), aliceID)
	phone := newTDev(t, aliceID, "device", nil)
	of.members = []*tmember{{user: aliceID, name: "Alice", devs: []*tdev{phone}}}
	dir := filepath.Join(t.TempDir(), "state")
	env := map[string]string{"E2EE_BRIDGE_PASSWORD": of.password, "E2EE_BRIDGE_STATE": dir}
	of.mu.Lock()
	of.userID = aliceID
	of.mu.Unlock()

	// Step 1.
	code, out, errs := runCLI(t, env, "", "enroll", "--server", of.srv.URL, "--email", "a@example.org", "--name", strings.Repeat("N", 60))
	if code != 0 {
		t.Fatalf("enroll step 1: %d %s", code, errs)
	}
	for _, want := range []string{"Fingerprint:", "Digits:", "REQUEST CODE"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output lacks %q:\n%s", want, out)
		}
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var reqCode string
	for i, l := range lines {
		if strings.HasPrefix(l, "REQUEST CODE") {
			reqCode = strings.TrimSpace(lines[i+2])
		}
	}
	raw, err := base64.URLEncoding.DecodeString(reqCode) // padded base64url
	if err != nil {
		t.Fatalf("request code is not padded base64url: %v", err)
	}
	var rc requestCode
	if err := json.Unmarshal(raw, &rc); err != nil {
		t.Fatal(err)
	}
	if rc.U != aliceID || rc.K != "service" || len(rc.N) != 40 || e2ee.CheckID(rc.D) != nil {
		t.Fatalf("request code %+v", rc)
	}
	ed, _ := base64.StdEncoding.DecodeString(rc.E)
	x, _ := base64.StdEncoding.DecodeString(rc.X)
	bsig, _ := base64.StdEncoding.DecodeString(rc.B)
	if err := e2ee.VerifyBinding(rc.U, rc.D, ed, x, bsig); err != nil {
		t.Fatalf("binding signature: %v", err)
	}
	fp, _ := e2ee.Fingerprint(ed, x)
	if !strings.Contains(out, e2ee.ShortFingerprint(fp)) || !strings.Contains(out, e2ee.DigitGroups(fp)) {
		t.Fatal("fingerprint/digits not shown")
	}
	// Files: 0600 in a 0700 dir, the password is not stored anywhere.
	di, _ := os.Stat(dir)
	if di.Mode().Perm() != 0o700 {
		t.Fatalf("dir %v", di.Mode().Perm())
	}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		fi, _ := e.Info()
		b, _ := os.ReadFile(filepath.Join(dir, e.Name()))
		if fi.Mode().Perm() != 0o600 || strings.Contains(string(b), of.password) {
			t.Fatalf("%s: mode %v or password stored", e.Name(), fi.Mode().Perm())
		}
	}
	// Step 1 again is idempotent: same key, same code.
	_, out2, _ := runCLI(t, env, "", "enroll")
	if !strings.Contains(out2, reqCode) {
		t.Fatal("second enroll produced a different request code")
	}

	// The phone approves.
	fpr := fp
	msg, _ := e2ee.LogActionMessage(e2ee.ActRegister, aliceID, phone.id, "", rc.D, 0, fpr)
	ap, _ := json.Marshal(approvalCode{A: phone.id, S: std(ed25519.Sign(phone.priv, msg))})
	apCode := base64.URLEncoding.EncodeToString(ap)

	// A wrong code is refused with a hint.
	bad := approvalCode{A: phone.id, S: std(make([]byte, 64))}
	bb, _ := json.Marshal(bad)
	if code, _, errs := runCLI(t, env, "", "enroll", "--approval", base64.URLEncoding.EncodeToString(bb)); code == 0 || !strings.Contains(errs, "does not match") {
		t.Fatalf("bad approval accepted: %d %s", code, errs)
	}
	if code, _, errs := runCLI(t, env, "", "enroll", "--approval", "!!!"); code == 0 {
		t.Fatalf("garbage approval accepted: %s", errs)
	}
	// Step 2 (unpadded input is tolerated too).
	code, out, errs = runCLI(t, env, "", "enroll", "--approval", strings.TrimRight(apCode, "="))
	if code != 0 {
		t.Fatalf("enroll step 2: %d %s", code, errs)
	}
	reg := of.registered[len(of.registered)-1]
	if reg["kind"] != "service" || reg["device_id"] != rc.D || reg["actor_device_id"] != phone.id || reg["reset"] != false || reg["can_upload"] != false ||
		reg["ed25519_pub"] != rc.E || reg["x25519_pub"] != rc.X || reg["signature"] != rc.B || reg["label"] == "" {
		t.Fatalf("registration body: %v", reg)
	}

	// status: no secrets.
	env["E2EE_BRIDGE_PASSWORD"] = ""
	code, out, _ = runCLI(t, env, "", "status")
	if code != 0 || !strings.Contains(out, rc.D) || !strings.Contains(out, "registered at") {
		t.Fatalf("status: %d\n%s", code, out)
	}
	idRaw, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	var f identityFile
	_ = json.Unmarshal(idRaw, &f)
	if f.ApprovedBy != phone.id || f.ApproverEdPub != std(phone.edPub) {
		t.Fatalf("approving phone not pinned: %q %q", f.ApprovedBy, f.ApproverEdPub)
	}
	var sec identitySecret
	_ = json.Unmarshal(f.Secret.Plain, &sec)
	var sess session
	st, _ := openStore(dir, nil)
	_ = st.readSecret(fileSession, &sess)
	for _, s := range []string{sec.Seed, sess.RefreshToken} {
		if s == "" || strings.Contains(out, s) {
			t.Fatal("status leaks a secret (or the secret is empty)")
		}
	}

	// revoke signs ActRevoke with the bridge's own key.
	code, out, errs = runCLI(t, env, "", "revoke")
	if code != 0 {
		t.Fatalf("revoke: %d %s", code, errs)
	}
	rv := of.revoked[len(of.revoked)-1]
	if rv["_id"] != rc.D || rv["actor_device_id"] != rc.D {
		t.Fatalf("revoke body %v", rv)
	}
	sig, _ := base64.StdEncoding.DecodeString(rv["log_signature"].(string))
	if err := e2ee.VerifyLogAction(ed, e2ee.ActRevoke, aliceID, rc.D, "", rc.D, 0, fp, sig); err != nil {
		t.Fatalf("revoke signature: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, fileKeys)); err == nil {
		t.Fatal("circle keys not wiped")
	}
	code, out, _ = runCLI(t, env, "", "status")
	if !strings.Contains(out, "REVOKED") {
		t.Fatalf("status after revoke:\n%s", out)
	}
	// A revoked bridge refuses to run.
	cfg := filepath.Join(t.TempDir(), "c.json")
	_ = os.WriteFile(cfg, []byte(`{"dawarich":{"base_url":"http://127.0.0.1:1","api_key":"k"}}`), 0o600)
	if code, _, _ := runCLI(t, env, "", "run", "--config", cfg, "--once"); code == 0 {
		t.Fatal("revoked bridge ran")
	}
	_ = hex.EncodeToString
}

func TestEnrollNeedsCredentialsAndPasswordFromStdin(t *testing.T) {
	aliceID := newUUIDv4()
	of := newFakeOF(t, newUUIDv4(), aliceID)
	dir := filepath.Join(t.TempDir(), "state")
	env := map[string]string{"E2EE_BRIDGE_STATE": dir}
	if code, _, _ := runCLI(t, env, "", "enroll", "--server", of.srv.URL); code == 0 {
		t.Fatal("enroll without --email must fail")
	}
	if code, _, errs := runCLI(t, env, of.password+"\n", "enroll", "--server", of.srv.URL, "--email", "a@example.org"); code != 0 {
		t.Fatalf("stdin password: %d %s", code, errs)
	}
	if code, _, _ := runCLI(t, env, "wrong\n", "enroll", "--server", of.srv.URL, "--email", "a@example.org"); code == 0 {
		t.Fatal("wrong password accepted")
	}
}

func TestHelpMentionsOffHostAndUsageErrors(t *testing.T) {
	code, out, _ := runCLI(t, nil, "", "--help")
	if code != 0 || !strings.Contains(out, "OFF the OpenFamily server host") {
		t.Fatalf("help: %d\n%s", code, out)
	}
	if code, _, _ := runCLI(t, nil, "", "bogus"); code != exitUsage {
		t.Fatalf("unknown command: %d", code)
	}
	if code, _, _ := runCLI(t, map[string]string{"E2EE_BRIDGE_STATE": t.TempDir() + "/x"}, "", "run"); code != exitUsage {
		t.Fatalf("run without config: %d", code)
	}
}

func TestConfigValidation(t *testing.T) {
	good := `{"dawarich":{"base_url":"https://d.example/","api_key":"k"},"users":{"` + newUUIDv4() + `":{"api_key":"u","label":"x"}},"since":"2025-01-02"}`
	p := filepath.Join(t.TempDir(), "c.json")
	_ = os.WriteFile(p, []byte(good), 0o600)
	c, err := loadConfig(p, func(string) string { return "" })
	if err != nil || c.Dawarich.BaseURL != "https://d.example" || c.since.IsZero() || c.PollSeconds != 30 {
		t.Fatalf("good config: %v %+v", err, c)
	}
	// The key may come from the environment.
	_ = os.WriteFile(p, []byte(`{"dawarich":{"base_url":"http://d"}}`), 0o600)
	if _, err := loadConfig(p, func(string) string { return "" }); err == nil {
		t.Fatal("config without any key accepted")
	}
	if c, err := loadConfig(p, func(k string) string {
		if k == "E2EE_BRIDGE_DAWARICH_KEY" {
			return "envkey\n"
		}
		return ""
	}); err != nil || c.Dawarich.APIKey != "envkey" {
		t.Fatalf("env key: %v", err)
	}
	for _, bad := range []string{`{"dawarich":{"base_url":"ftp://x","api_key":"k"}}`, `{"dawarich":{"base_url":"http://x","api_key":"k"},"bogus":1}`,
		`{"dawarich":{"base_url":"http://x","api_key":"k"},"since":"yesterday"}`, `{"dawarich":{"base_url":"http://x","api_key":"k"},"poll_seconds":1}`,
		`{"dawarich":{"base_url":"http://x","api_key":"k"},"users":{"short":{"api_key":"u"}}}`} {
		_ = os.WriteFile(p, []byte(bad), 0o600)
		if _, err := loadConfig(p, func(string) string { return "" }); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}
