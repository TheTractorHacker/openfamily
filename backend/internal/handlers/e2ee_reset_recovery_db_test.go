package handlers

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

// The server key across an owner key reset, the server-side half of "a family app repairs itself
// after a reset" (docs/design/E2EE.md "Server key across an owner reset"). Needs TEST_DATABASE_URL.

// fakeHost stands in for the built-in server device.
type fakeHost struct {
	mu         sync.Mutex
	dev        *tdev
	revoked    []string
	reattached []string
}

func newFakeHost(d *tdev) *fakeHost { return &fakeHost{dev: d} }

func (h *fakeHost) Info() e2eebridge.EmbeddedInfo {
	return e2eebridge.EmbeddedInfo{DeviceID: h.dev.id, Fingerprint: hex.EncodeToString(h.dev.fp), Registered: true, State: e2eebridge.StateRunning}
}
func (h *fakeHost) JoinRequestFor(string) (e2eebridge.JoinRequest, error) {
	return e2eebridge.JoinRequest{}, nil
}
func (h *fakeHost) Approve(context.Context, string, string, string) error { return nil }
func (h *fakeHost) NoteRevoked(id string) {
	h.mu.Lock()
	h.revoked = append(h.revoked, id)
	h.mu.Unlock()
}
func (h *fakeHost) Reattach(actor string, pub, sig []byte) error {
	h.mu.Lock()
	h.reattached = append(h.reattached, actor)
	h.mu.Unlock()
	return nil
}

func attachSig(t *testing.T, phone, server *tdev) string {
	t.Helper()
	lm, err := e2ee.LogActionMessage(e2ee.ActServerAttach, phone.uid, phone.id, "", server.id, 0, server.fp)
	if err != nil {
		t.Fatal(err)
	}
	return b64s(ed25519.Sign(phone.priv, lm))
}

// resetBody is the new owner phone's reset request, optionally asking to keep the server key.
func resetBody(t *testing.T, phone *tdev, keep *tdev, sig string) map[string]any {
	t.Helper()
	b := regBody(t, phone, "device", nil, e2ee.ActReset, true)
	b["caps"] = []string{"lanes2"}
	if keep != nil {
		b["keep_server"] = map[string]any{"device_id": keep.id, "log_signature": sig}
	}
	return b
}

// approveByAdmin approves the reset phone in the circle the way the owner-approval flow does.
func (e *srvEnv) approveByAdmin(d *tdev, approver *tdev) {
	e.t.Helper()
	e.sql(`INSERT INTO device_approvals (device_id, circle_id, approver_user_id, approver_device_id, approver_pub, signature)
		VALUES ($1,$2,$3,$4,$5,$6)`, d.id, e.circle, approver.uid, approver.id, approver.ed, make([]byte, 64))
}

func (e *srvEnv) serverActive(id string) bool {
	return e.count(`SELECT count(*) FROM device_keys WHERE device_id = $1 AND revoked_at IS NULL`, id) == 1
}

func (e *srvEnv) pinnedID() string {
	var id string
	_ = e.pool.QueryRow(context.Background(), `SELECT d.device_id::text FROM e2ee_server_device sd JOIN device_keys d ON d.device_id = sd.device_id
		WHERE d.revoked_at IS NULL`).Scan(&id)
	return id
}

// productionState builds what the production database held after the owner's reset (2026-11-10):
// policy signed by the owner's old phone, the owner's and another member's server prefs, the SK wrapped
// to the server key. B is "the other member", C a member who never chose.
func productionState(t *testing.T) (*srvEnv, *fakeHost) {
	e := newLaneEnv(t)
	host := newFakeHost(e.s)
	e.srv.ServerDevice = host
	e.route("POST", "/e2ee/server-device/replace", e.srv.E2EEServerReplace)
	e.enableAssist("required_server")
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	e.setLane("B", e.b, "server", 1, 200)
	return e, host
}

func (e *srvEnv) itemCode(user string, d *tdev, line e2ee.Line, seq int64) (string, string) {
	e.t.Helper()
	code, m, raw := e.do(user, "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": d.id,
		"items": []any{e.sealV2(d, line, 1, seq, "fix")}})
	if code != 200 && code != 201 {
		e.t.Fatalf("batch: %d %s", code, raw)
	}
	r := results(m)[0]
	s, _ := r["error"].(string)
	return r["status"].(string), s
}

func (e *srvEnv) memberOut(asUser, member string) (map[string]any, map[string]any) {
	e.t.Helper()
	st := e.mustCode(asUser, "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	for _, x := range st["members"].([]any) {
		if m := x.(map[string]any); m["user_id"] == e.ids[member] {
			return m, st
		}
	}
	e.t.Fatalf("member %s missing", member)
	return nil, nil
}

// THE production state, rebuilt: after the owner's reset the SAME server key is kept, the circle has no
// working policy until the owner's new phone signs one, and from then on the other member needs no action.
func TestProductionResetStateConvergesWithTheSameServerKey(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)

	e, host := productionState(t)
	if !e.serverActive(e.s.id) || e.pinnedID() != e.s.id {
		t.Fatal("fixture: server key not pinned")
	}
	if e.count(`SELECT e2ee_device_approved($1::uuid, $2::uuid)::int`, e.s.id, e.circle) != 1 {
		t.Fatal("fixture: the server key is not approved before the reset")
	}

	// The owner resets; the new phone signs "keep this server key".
	a2 := newTDev(t, e.ids["A"])
	body := resetBody(t, a2, e.s, attachSig(t, a2, e.s))
	resp := e.mustCode("A", "POST", "/e2ee/devices", body, 201)
	if resp["server_kept"] != true {
		t.Fatalf("the server key was not kept: %v", resp)
	}
	if e.serverActive(e.a.id) {
		t.Fatal("the old owner phone is still active")
	}
	if !e.serverActive(e.s.id) || e.pinnedID() != e.s.id {
		t.Fatal("the server key did not survive the reset or lost its pin")
	}
	if e.count(`SELECT count(*) FROM e2ee_server_attach WHERE server_device_id = $1 AND attached_by_device_id = $2`, e.s.id, a2.id) != 1 {
		t.Fatal("no attach row")
	}
	if len(host.reattached) != 1 || host.reattached[0] != a2.id || len(host.revoked) != 0 {
		t.Fatalf("the device was not told to re-anchor (reattached=%v revoked=%v)", host.reattached, host.revoked)
	}
	// The reset entry is directly followed by the attach entry.
	var resetSeq, attachSeq int
	_ = e.pool.QueryRow(context.Background(), `SELECT (SELECT max(seq) FROM e2ee_log WHERE action = 8 AND user_id = $1),
		(SELECT max(seq) FROM e2ee_log WHERE action = 13 AND user_id = $1)`, e.ids["A"]).Scan(&resetSeq, &attachSeq)
	if resetSeq == 0 || attachSeq != resetSeq+1 {
		t.Fatalf("log order: reset %d attach %d", resetSeq, attachSeq)
	}

	// Until the new phone is approved in the circle, the kept key is NOT approved there (it hangs on that phone now,
	// not on the revoked one that first approved it).
	if e.count(`SELECT e2ee_device_approved($1::uuid, $2::uuid)::int`, e.s.id, e.circle) != 0 {
		t.Fatal("the kept server key is approved through a revoked phone")
	}
	e.approveByAdmin(a2, e.b)
	if e.count(`SELECT e2ee_device_approved($1::uuid, $2::uuid)::int`, e.s.id, e.circle) != 1 {
		t.Fatal("the kept server key is not approved once the new phone is")
	}

	// The symptom of the production incident: the policy is signed by a revoked phone, so the server line
	// is closed. The phone line is NOT: nothing is dropped, nothing is refused as required_server.
	if st, why := e.itemCode("B", e.b, e.serverLine(), 1); st != "rejected" || why != "lane_not_server" {
		t.Fatalf("server line before the policy is signed again: %s %s", st, why)
	}
	if st, why := e.itemCode("B", e.b, e.phoneLine(), 2); st != "stored" {
		t.Fatalf("B's phone-line item was refused: %s %s", st, why)
	}
	mo, st := e.memberOut("B", "B")
	if st["policy_verified"] != false || mo["processing"] != "phone" || mo["catching_up"] != true {
		t.Fatalf("state before the repair: policy_verified=%v member=%v", st["policy_verified"], mo)
	}

	// The new owner phone signs the policy again (same generation: nothing changes for the others) and its own pref.
	e.declareLanes2("A", a2)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, true, "phone", "required_server", 1, a2), 200)
	e.setLane("A", a2, "server", 1, 200)

	// The other member did NOTHING: their pref still names the same server key and fingerprint and counts.
	if st, why := e.itemCode("B", e.b, e.serverLine(), 3); st != "stored" {
		t.Fatalf("B's server-line item after the owner's phone re-signed: %s %s", st, why)
	}
	mo, st = e.memberOut("A", "B")
	if st["policy_verified"] != true || mo["processing"] != "server" || mo["catching_up"] == true || mo["pref_stale"] == true {
		t.Fatalf("state after the repair: policy_verified=%v member=%v", st["policy_verified"], mo)
	}
	// C never chose: still on the phone line, said so in the state, and still relayed there.
	if mo, _ := e.memberOut("A", "C"); mo["catching_up"] != true || mo["processing"] != "phone" {
		t.Fatalf("C: %v", mo)
	}
	if st, why := e.itemCode("C", e.c, e.serverLine(), 4); st != "rejected" || why != "lane_not_server" {
		t.Fatalf("C's server line must stay closed until C's own phone signs: %s %s", st, why)
	}
	if st, why := e.itemCode("C", e.c, e.phoneLine(), 5); st != "stored" {
		t.Fatalf("C's phone-line item was refused: %s %s", st, why)
	}

	// The log, as the verifier sees it: the old phones stay retired, the server key is kept.
	entries, head := fetchLog(t, e, "B", "&server_attach=1")
	check, idx, err := e2ee.SyncLogFull(nil, func(after int64) ([]e2ee.LogEntry, e2ee.LogHead, error) {
		es, h := fetchLogAfter(t, e, "B", "&server_attach=1", after)
		return es, h, nil
	})
	if err != nil || !check.OK() {
		t.Fatalf("the log served to a new client does not verify: %v %v", err, check.Detail)
	}
	if idx.Revoked(e.s.id) || !idx.Revoked(e.a.id) {
		t.Fatalf("log verdict: server revoked=%v old phone revoked=%v", idx.Revoked(e.s.id), idx.Revoked(e.a.id))
	}
	if a, _, _, ok := idx.AttachVoucher(e.s.id); !ok || a != a2.id {
		t.Fatalf("attach voucher %q %v", a, ok)
	}
	_ = entries
	_ = head
	// A client that did not ask sees the attach entry redacted and the chain still verifies.
	check2, idx2, err := e2ee.SyncLogFull(nil, func(after int64) ([]e2ee.LogEntry, e2ee.LogHead, error) {
		es, h := fetchLogAfter(t, e, "B", "", after)
		return es, h, nil
	})
	if err != nil || !check2.OK() {
		t.Fatalf("the redacted log does not verify: %v %v", err, check2.Detail)
	}
	if _, _, _, ok := idx2.AttachVoucher(e.s.id); ok {
		t.Fatal("an app that did not ask for server-attach entries got one")
	}

	// No secret material anywhere.
	secrets := []string{b64s(a2.priv.Seed()), hex.EncodeToString(a2.priv.Seed()), b64s(a2.xsec), b64s(e.key), b64s(testSK), hex.EncodeToString(testSK),
		b64s(e.s.priv.Seed()), b64s(e.s.xsec)}
	out, _ := json.Marshal(resp)
	rows, _ := e.pool.Query(context.Background(), `SELECT action || ' ' || detail FROM audit_log WHERE user_id = $1`, e.ids["A"])
	var audit strings.Builder
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		audit.WriteString(s + "\n")
	}
	rows.Close()
	if !strings.Contains(audit.String(), "server key kept") {
		t.Fatalf("the audit does not say the key was kept: %s", audit.String())
	}
	logJSON, _ := json.Marshal(entries)
	for _, sct := range secrets {
		for name, hay := range map[string]string{"log output": buf.String(), "audit": audit.String(), "response": string(out), "key log": string(logJSON)} {
			if strings.Contains(hay, sct) {
				t.Fatalf("secret material %q… leaked into the %s", sct[:8], name)
			}
		}
	}
}

func fetchLogAfter(t *testing.T, e *srvEnv, user, q string, after int64) ([]e2ee.LogEntry, e2ee.LogHead) {
	t.Helper()
	m := e.mustCode(user, "GET", fmt.Sprintf("/e2ee/log?after=%d%s", after, q), nil, 200)
	raw, _ := json.Marshal(m["entries"])
	var es []e2ee.LogEntry
	if err := json.Unmarshal(raw, &es); err != nil {
		t.Fatal(err)
	}
	h := m["head"].(map[string]any)
	hh, _ := hex.DecodeString(h["hash"].(string))
	return es, e2ee.LogHead{Seq: int64(h["seq"].(float64)), Hash: hh}
}

func fetchLog(t *testing.T, e *srvEnv, user, q string) ([]e2ee.LogEntry, e2ee.LogHead) {
	t.Helper()
	return fetchLogAfter(t, e, user, q, 0)
}

// Without the attach (an old app, a refusing server) the reset behaves as it always did: every key is revoked,
// the server makes a new one, the other member's pref goes stale, and a new generation fixes it. Nothing is
// dropped on the way.
func TestProductionResetWithoutKeepStillConvergesAfterTheNewKeyIsApproved(t *testing.T) {
	e, host := productionState(t)
	a2 := newTDev(t, e.ids["A"])
	resp := e.mustCode("A", "POST", "/e2ee/devices", resetBody(t, a2, nil, ""), 201)
	if resp["server_kept"] != nil {
		t.Fatalf("kept without being asked: %v", resp)
	}
	if e.serverActive(e.s.id) || e.pinnedID() != "" {
		t.Fatal("the server key survived a plain reset")
	}
	if len(host.revoked) != 1 || host.revoked[0] != e.s.id || len(host.reattached) != 0 {
		t.Fatalf("host calls: revoked=%v reattached=%v", host.revoked, host.reattached)
	}
	if e.count(`SELECT count(*) FROM e2ee_server_attach`) != 0 {
		t.Fatal("an attach row without an attach")
	}
	// B's pref names a revoked key: the server line is closed, the phone line is not, and the state says why.
	if st, why := e.itemCode("B", e.b, e.serverLine(), 1); st != "rejected" || why != "lane_not_server" {
		t.Fatalf("%s %s", st, why)
	}
	if st, why := e.itemCode("B", e.b, e.phoneLine(), 2); st != "stored" {
		t.Fatalf("%s %s", st, why)
	}
	mo, _ := e.memberOut("B", "B")
	if mo["pref_stale"] != true || mo["catching_up"] != true {
		t.Fatalf("B should be shown as catching up with a stale pref: %v", mo)
	}

	// The new server key joins, the new owner phone approves it and rotates the generation; every phone signs again.
	s2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s2, "server", a2, e2ee.ActRegister, false), 201)
	e.approveByAdmin(a2, e.b)
	e.declareLanes2("A", a2)
	oldS := e.s
	e.s = s2
	e.pin()
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "required_server", 2, a2,
			mkSKWrap(t, e.circle, 2, a2, a2), mkSKWrap(t, e.circle, 2, a2, e.b), mkSKWrap(t, e.circle, 2, a2, e.c), mkSKWrap(t, e.circle, 2, a2, s2)), 200)
	e.setLane("A", a2, "server", 2, 200)
	if st, why := e.itemCode("B", e.b, e.serverLine(), 3); st != "rejected" {
		t.Fatalf("B's stale pref still counts for the new key: %s %s", st, why)
	}
	e.setLane("B", e.b, "server", 2, 200) // B's own phone, by itself
	if st, why := e.itemCode("B", e.b, e.serverLine(), 4); st != "stored" {
		t.Fatalf("B's server line after signing the new key: %s %s", st, why)
	}
	if mo, st := e.memberOut("A", "B"); st["policy_verified"] != true || mo["processing"] != "server" || mo["pref_stale"] == true {
		t.Fatalf("B after signing again: %v", mo)
	}
	_ = oldS
}

// An unapproved, foreign, unpinned or unsigned key can never be kept or become the server key.
func TestKeepServerIsRefusedForEveryWrongKey(t *testing.T) {
	type tc struct {
		name  string
		setup func(e *srvEnv, a2 *tdev) map[string]any
		host  bool
	}
	cases := []tc{
		{"signed by another key", func(e *srvEnv, a2 *tdev) map[string]any {
			rogue := newTDev(t, e.ids["A"])
			return resetBody(t, a2, e.s, attachSig(t, rogue, e.s))
		}, true},
		{"signed for another fingerprint", func(e *srvEnv, a2 *tdev) map[string]any {
			wrong := *e.s
			wrong.fp = bytes.Repeat([]byte{9}, 32)
			return resetBody(t, a2, e.s, attachSig(t, a2, &wrong))
		}, true},
		{"signed by the OLD phone", func(e *srvEnv, a2 *tdev) map[string]any {
			return resetBody(t, a2, e.s, attachSig(t, e.a, e.s))
		}, true},
		{"garbage signature", func(e *srvEnv, a2 *tdev) map[string]any {
			return resetBody(t, a2, e.s, b64s(make([]byte, 64)))
		}, true},
		{"missing signature", func(e *srvEnv, a2 *tdev) map[string]any {
			return resetBody(t, a2, e.s, "")
		}, true},
		{"separate server device (no built-in host)", func(e *srvEnv, a2 *tdev) map[string]any {
			return resetBody(t, a2, e.s, attachSig(t, a2, e.s))
		}, false},
		{"an id the built-in device does not own", func(e *srvEnv, a2 *tdev) map[string]any {
			e.srv.ServerDevice = newFakeHost(newTDev(t, e.ids["A"]))
			return resetBody(t, a2, e.s, attachSig(t, a2, e.s))
		}, true},
		{"a key that is not the pinned server key", func(e *srvEnv, a2 *tdev) map[string]any {
			s2 := newTDev(t, e.ids["A"])
			e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s2, "server", e.a, e2ee.ActRegister, false), 201)
			e.srv.ServerDevice = newFakeHost(s2)
			return resetBody(t, a2, s2, attachSig(t, a2, s2))
		}, true},
		{"a phone key of the same account", func(e *srvEnv, a2 *tdev) map[string]any {
			return resetBody(t, a2, e.a, attachSig(t, a2, e.a))
		}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, host := productionState(t)
			if !c.host {
				e.srv.ServerDevice = nil
			}
			a2 := newTDev(t, e.ids["A"])
			body := c.setup(e, a2)
			resp := e.mustCode("A", "POST", "/e2ee/devices", body, 201)
			if resp["server_kept"] != nil {
				t.Fatalf("kept: %v", resp)
			}
			if e.serverActive(e.s.id) || e.pinnedID() != "" {
				t.Fatal("the server key survived")
			}
			if e.count(`SELECT count(*) FROM e2ee_server_attach`) != 0 || e.count(`SELECT count(*) FROM e2ee_log WHERE action = 13 AND user_id = $1`, e.ids["A"]) != 0 {
				t.Fatal("an attach was recorded")
			}
			if len(host.reattached) != 0 {
				t.Fatal("the device was told to re-anchor")
			}
		})
	}
}

// Another user's reset can never keep (or touch) this account's server key; a normal cross-signed registration
// ignores the field.
func TestKeepServerOnlyForTheKeyOwnersOwnReset(t *testing.T) {
	e, host := productionState(t)
	b2 := newTDev(t, e.ids["B"])
	body := resetBody(t, b2, e.s, attachSig(t, b2, e.s))
	if resp := e.mustCode("B", "POST", "/e2ee/devices", body, 201); resp["server_kept"] != nil {
		t.Fatalf("%v", resp)
	}
	if !e.serverActive(e.s.id) || e.pinnedID() != e.s.id {
		t.Fatal("B's reset touched A's server key")
	}
	if e.count(`SELECT count(*) FROM e2ee_server_attach`) != 0 || len(host.reattached) != 0 || len(host.revoked) != 0 {
		t.Fatal("B's reset attached or revoked A's key")
	}
	// A cross-signed registration (not a reset) carrying keep_server changes nothing.
	a3 := newTDev(t, e.ids["A"])
	reg := regBody(t, a3, "device", e.a, e2ee.ActRegister, false)
	reg["caps"] = []string{"lanes2"}
	reg["keep_server"] = map[string]any{"device_id": e.s.id, "log_signature": attachSig(t, a3, e.s)}
	if resp := e.mustCode("A", "POST", "/e2ee/devices", reg, 201); resp["server_kept"] != nil {
		t.Fatalf("%v", resp)
	}
	if e.count(`SELECT count(*) FROM e2ee_server_attach`) != 0 || !e.serverActive(e.s.id) {
		t.Fatal("a plain registration attached the key")
	}
}

// "Replace the server key": the one deliberate way to change the key.
func TestReplaceServerKeyNeedsAPlatformAdminOwnerAndTheirPhoneSignature(t *testing.T) {
	e, host := productionState(t)
	sign := func(by *tdev) map[string]any {
		return simpleAction(t, e2ee.ActRevoke, by, "", 0, e.s.id, e.s.fp)
	}
	// Not a platform admin.
	e.mustCode("A", "POST", "/e2ee/server-device/replace", sign(e.a), 403)
	e.sql(`UPDATE users SET platform_admin = TRUE WHERE id = ANY($1)`, []string{e.ids["A"], e.ids["B"]})
	// A platform admin who does not own the key.
	e.mustCode("B", "POST", "/e2ee/server-device/replace", sign(e.b), 403)
	// Signed by someone else's phone, signed for another key, bad signature, a non-phone key.
	e.mustCode("A", "POST", "/e2ee/server-device/replace", sign(e.b), 400)
	other := simpleAction(t, e2ee.ActRevoke, e.a, "", 0, e.a.id, e.a.fp)
	e.mustCode("A", "POST", "/e2ee/server-device/replace", other, 400)
	bad := sign(e.a)
	bad["log_signature"] = b64s(make([]byte, 64))
	e.mustCode("A", "POST", "/e2ee/server-device/replace", bad, 400)
	if !e.serverActive(e.s.id) || len(host.revoked) != 0 {
		t.Fatal("a refused replace changed the server key")
	}
	// The owner's own active phone signs: revoked, the device is told, the log carries the signed revoke.
	e.mustCode("A", "POST", "/e2ee/server-device/replace", sign(e.a), 200)
	if e.serverActive(e.s.id) || len(host.revoked) != 1 || host.revoked[0] != e.s.id {
		t.Fatalf("replace did not revoke: revoked=%v", host.revoked)
	}
	if e.count(`SELECT count(*) FROM e2ee_log WHERE action = 3 AND subject_id = $1 AND actor_device_id = $2`, e.s.id, e.a.id) != 1 {
		t.Fatal("no signed revoke in the log")
	}
}

// Migration 000410 can be applied twice and rolled back; rolling back restores the old rule.
func TestServerKeyAcrossResetMigrationIdempotentAndDown(t *testing.T) {
	e := newLaneEnv(t)
	up, err := os.ReadFile("../db/migrations/000410_server_key_across_reset.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	down, err := os.ReadFile("../db/migrations/000410_server_key_across_reset.down.sql")
	if err != nil {
		t.Fatal(err)
	}
	e.sql(string(up))
	e.sql(string(up))
	e.sql(string(down))
	e.sql(string(down))
	e.sql(string(up))
	// After the up migration a phone-line item of a required_server circle is accepted by the database itself.
	e.enableAssist("required_server")
	if err := e.sqlErr(`INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at)
		VALUES ($1,$2,99,'fix',1,256,'\x00',now())`, e.circle, e.b.id); err != nil {
		t.Fatalf("the database still refuses phone-line items of a required_server circle: %v", err)
	}
	// ... and a chat item is still phone-line only.
	err = e.sqlErr(`INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at, key_line)
		VALUES ($1,$2,100,'chat',1,256,'\x00',now(),'server')`, e.circle, e.b.id)
	if err == nil {
		t.Fatal("a server-line chat item was inserted")
	}
}
