package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Web access from any browser (docs/design/WEB_VIEWER_ANYWHERE.md). Needs TEST_DATABASE_URL.

type vvEnv struct {
	*circleEnv
	phone, web *tdev
	mu         sync.Mutex
	audits     []string
}

func newVVEnv(t *testing.T) *vvEnv {
	e := newE2EEEnv(t)
	e.route("GET", "/e2ee/viewer-vault", e.srv.E2EEViewerVaultStatus)
	e.route("POST", "/e2ee/viewer-vault/unlock", e.srv.E2EEViewerVaultUnlock)
	e.route("PUT", "/e2ee/viewer-vault", e.srv.E2EEViewerVaultPut)
	e.route("PUT", "/e2ee/viewer-vault/pin", e.srv.E2EEViewerVaultPin)
	e.route("DELETE", "/e2ee/viewer-vault", e.srv.E2EEViewerVaultDelete)
	e.route("GET", "/api/admin/settings/e2ee-viewer-vault", e.srv.AdminGetViewerVault)
	e.route("PUT", "/api/admin/settings/e2ee-viewer-vault", e.srv.AdminPutViewerVault)
	v := &vvEnv{circleEnv: e}
	e.srv.auditHook = func(_, _, a, _ string) { v.mu.Lock(); v.audits = append(v.audits, a); v.mu.Unlock() }
	e.srv.ViewerVault = ViewerVaultConfig{Pepper: bytes.Repeat([]byte{9}, 32)}
	ctx := context.Background()
	if err := e.srv.EnsureThemeSchema(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE users SET platform_admin = TRUE WHERE id = $1`, e.ids["A"]); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `UPDATE app_theme_settings SET e2ee_viewer_vault_enabled = TRUE WHERE id = 1`)
	})
	e.setPassword("A", "correct horse battery")
	e.setPassword("B", "correct horse battery")
	v.phone = newTDev(t, e.ids["A"])
	e.register("A", v.phone)
	v.web = newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, v.web, "web", v.phone, e2ee.ActRegister, false), 201)
	return v
}

func (v *vvEnv) count(action string) int {
	v.mu.Lock()
	defer v.mu.Unlock()
	n := 0
	for _, a := range v.audits {
		if a == action {
			n++
		}
	}
	return n
}

func (v *vvEnv) blobFor(uid, deviceID string) map[string]any {
	return map[string]any{
		"v": 1, "user_id": uid, "device_id": deviceID,
		"unlockers": []any{map[string]any{"kind": "passphrase", "kdf": "argon2id", "m": 65536, "t": 3, "p": 1, "pep": 1, "salt": "AAAA", "nonce": "BBBB", "wrapped": "CCCC"}},
		"nonce":     "DDDD", "sealed": "EEEE",
	}
}

func (v *vvEnv) unlock(user, browser string) map[string]any {
	v.t.Helper()
	return v.mustCode(user, "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "correct horse battery", "browser_id": browser}, 200)
}

func TestViewerVaultSetupUnlockAndPin(t *testing.T) {
	v := newVVEnv(t)
	st := v.mustCode("A", "GET", "/e2ee/viewer-vault", nil, 200)
	if st["available"] != true || st["exists"] != false {
		t.Fatalf("status before setup: %v", st)
	}
	// Wrong password: no pepper, no ticket.
	code, m, _ := v.do("A", "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "nope"})
	if code != 400 || m["pepper"] != nil || m["ticket"] != nil {
		t.Fatalf("wrong password released something: %d %v", code, m)
	}
	u := v.unlock("A", "browser-one-0123456789")
	ticket, _ := u["ticket"].(string)
	if ticket == "" || u["pepper"] == nil || u["blob"] != nil {
		t.Fatalf("first unlock: %v", u)
	}
	// Without a ticket, with someone else's account in the blob, or with a phone key: refused.
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"blob": v.blobFor(v.ids["A"], v.web.id)}, 403)
	t2 := v.unlock("A", "browser-one-0123456789")["ticket"].(string)
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": t2, "blob": v.blobFor(v.ids["B"], v.web.id)}, 400)
	t3 := v.unlock("A", "browser-one-0123456789")["ticket"].(string)
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": t3, "blob": v.blobFor(v.ids["A"], v.phone.id)}, 400)
	// Valid save; the ticket is single use.
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": ticket, "blob": v.blobFor(v.ids["A"], v.web.id)}, 200)
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": ticket, "blob": v.blobFor(v.ids["A"], v.web.id)}, 403)
	// Another user's ticket never works for A (B is not an admin, so B cannot even get one).
	v.mustCode("B", "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "correct horse battery"}, 404)

	st = v.mustCode("A", "GET", "/e2ee/viewer-vault", nil, 200)
	if st["exists"] != true || st["device_id"] != v.web.id || st["key_active"] != true || st["pepper_changed"] != false {
		t.Fatalf("status after setup: %v", st)
	}
	if _, has := st["blob"]; has {
		t.Fatal("status must never carry the blob")
	}

	// The blob comes back only after a step-up, unchanged.
	before := v.count("e2ee.viewer_vault_new_browser")
	got := v.unlock("A", "browser-one-0123456789")
	gb, _ := json.Marshal(got["blob"])
	wb, _ := json.Marshal(v.blobFor(v.ids["A"], v.web.id))
	var g1, w1 any
	_ = json.Unmarshal(gb, &g1)
	_ = json.Unmarshal(wb, &w1)
	gs, _ := json.Marshal(g1)
	ws, _ := json.Marshal(w1)
	if string(gs) != string(ws) {
		t.Fatalf("blob changed: %s vs %s", gs, ws)
	}
	// New-browser notice: once per browser.
	if v.count("e2ee.viewer_vault_new_browser") != before+1 {
		t.Fatalf("first unlock with a vault in this browser should be noted as new")
	}
	v.unlock("A", "browser-one-0123456789")
	if v.count("e2ee.viewer_vault_new_browser") != before+1 {
		t.Fatal("the same browser was reported as new twice")
	}
	v.unlock("A", "browser-two-0123456789")
	if v.count("e2ee.viewer_vault_new_browser") != before+2 {
		t.Fatal("a second browser was not reported")
	}

	// Pin: only grows.
	pin := func(seq int) map[string]any {
		return map[string]any{"pin": map[string]any{"v": 1, "seq": seq, "nonce": "n", "sealed": "s"}}
	}
	if r := v.mustCode("A", "PUT", "/e2ee/viewer-vault/pin", pin(5), 200); r["stored"] != true {
		t.Fatal("pin 5 not stored")
	}
	if r := v.mustCode("A", "PUT", "/e2ee/viewer-vault/pin", pin(3), 200); r["stored"] != false {
		t.Fatal("an older pin replaced a newer one")
	}
	if r := v.unlock("A", "browser-one-0123456789"); r["pin"].(map[string]any)["seq"] != float64(5) {
		t.Fatalf("pin not returned: %v", r["pin"])
	}
}

func TestViewerVaultRevokeAndSwitches(t *testing.T) {
	v := newVVEnv(t)
	ctx := context.Background()
	tk := v.unlock("A", "")["ticket"].(string)
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": tk, "blob": v.blobFor(v.ids["A"], v.web.id)}, 200)

	// Admin switch off: unlock and save are 404; status explains; delete still works later.
	v.mustCode("A", "PUT", "/api/admin/settings/e2ee-viewer-vault", map[string]any{"enabled": false}, 200)
	code, m, _ := v.do("A", "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "correct horse battery"})
	if code != 404 || m["code"] != "viewer_vault_off_in_settings" {
		t.Fatalf("switched off but unlock answered %d %v", code, m)
	}
	if st := v.mustCode("A", "GET", "/e2ee/viewer-vault", nil, 200); st["available"] != false || st["reason"] != "off_in_settings" {
		t.Fatalf("status when off: %v", st)
	}
	v.mustCode("A", "PUT", "/api/admin/settings/e2ee-viewer-vault", map[string]any{"enabled": true}, 200)

	// Operator hard switch.
	v.srv.ViewerVault.Off = true
	v.mustCode("A", "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "correct horse battery"}, 404)
	v.srv.ViewerVault.Off = false

	// A different pepper file: reported, never a silent "wrong passphrase".
	old := v.srv.ViewerVault.Pepper
	v.srv.ViewerVault.Pepper = bytes.Repeat([]byte{1}, 32)
	code, m, _ = v.do("A", "POST", "/e2ee/viewer-vault/unlock", map[string]any{"password": "correct horse battery"})
	if code != 409 || m["code"] != "viewer_vault_pepper_changed" {
		t.Fatalf("pepper change: %d %v", code, m)
	}
	v.srv.ViewerVault.Pepper = old

	// Pepper is per account.
	p1 := v.srv.pepperFor(v.ids["A"])
	p2 := v.srv.pepperFor(v.ids["B"])
	if bytes.Equal(p1, p2) {
		t.Fatal("pepper must differ per account")
	}

	// Revoking the web key (as from a phone) deletes the vault at once.
	v.mustCode("A", "DELETE", "/e2ee/devices/"+v.web.id, simpleAction(t, e2ee.ActRevoke, v.phone, "", 0, v.web.id, v.web.fp), 200)
	var n int
	_ = v.pool.QueryRow(ctx, `SELECT count(*) FROM e2ee_viewer_vaults WHERE user_id = $1`, v.ids["A"]).Scan(&n)
	if n != 0 {
		t.Fatal("revoking the web key left its vault behind")
	}
	if st := v.mustCode("A", "GET", "/e2ee/viewer-vault", nil, 200); st["exists"] != false {
		t.Fatalf("status after revoke: %v", st)
	}
	// A revoked key cannot be stored again.
	tk = v.unlock("A", "")["ticket"].(string)
	v.mustCode("A", "PUT", "/e2ee/viewer-vault", map[string]any{"ticket": tk, "blob": v.blobFor(v.ids["A"], v.web.id)}, 400)

	// Delete is idempotent and needs no step-up.
	if r := v.mustCode("A", "DELETE", "/e2ee/viewer-vault", nil, 200); r["deleted"] != false {
		t.Fatalf("delete of nothing: %v", r)
	}
	// Non-admins: status says why; nothing else is reachable.
	if st := v.mustCode("B", "GET", "/e2ee/viewer-vault", nil, 200); st["available"] != false || st["reason"] != "admins_only" {
		t.Fatalf("non-admin status: %v", st)
	}
	v.mustCode("B", "PUT", "/e2ee/viewer-vault/pin", map[string]any{"pin": map[string]any{"v": 1, "seq": 1, "nonce": "n", "sealed": "s"}}, 404)
}

func TestViewerVaultPepperFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sub", "viewer-vault-pepper")
	a, err := LoadViewerVaultPepper(p)
	if err != nil || len(a) != 32 {
		t.Fatalf("create: %v %d", err, len(a))
	}
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("pepper file mode: %v %v", err, fi.Mode())
	}
	b, err := LoadViewerVaultPepper(p)
	if err != nil || !bytes.Equal(a, b) {
		t.Fatal("pepper not stable across starts")
	}
	_ = os.WriteFile(p, []byte("short\n"), 0o600)
	if _, err := LoadViewerVaultPepper(p); err == nil || !strings.Contains(err.Error(), "32+") {
		t.Fatalf("bad pepper accepted: %v", err)
	}
	var tk viewerVaultTickets
	x := tk.issue("u1")
	if tk.take("u2", x) || tk.take("u1", x) {
		t.Fatal("a ticket must be bound to its user and consumed by any attempt")
	}
	y := tk.issue("u1")
	if !tk.take("u1", y) || tk.take("u1", y) {
		t.Fatal("ticket must work once")
	}
}
