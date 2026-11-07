package handlers

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// Per-member processing lanes (docs/design/PRIVACY_PROCESSING.md section 13,
// server tests). Needs TEST_DATABASE_URL.

const zeroUUID = "00000000-0000-0000-0000-000000000000"

var testSK = bytes.Repeat([]byte{0x5a}, 32)

func mkSKWrap(t *testing.T, circle string, gen int, wrapper, rcpt *tdev) map[string]any {
	t.Helper()
	aad, err := e2ee.WrapAADLine(circle, e2ee.LineServer, uint32(gen), rcpt.id, wrapper.id)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := e2ee.Wrap(testSK, rcpt.x, aad)
	if err != nil {
		t.Fatal(err)
	}
	sm, err := e2ee.WrapSigMessageLine(circle, e2ee.LineServer, uint32(gen), rcpt.id, wrapper.id, blob)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"recipient_device_id": rcpt.id, "wrapper_device_id": wrapper.id,
		"wrapped_key": b64s(blob), "signature": b64s(ed25519.Sign(wrapper.priv, sm))}
}

func randBytes(n int) []byte { b := make([]byte, n); _, _ = rand.Read(b); return b }

// policyBody builds a signed processing_policy request from an admin phone.
func policyBody(t *testing.T, circle string, assist bool, def, optOut string, gen int, actor *tdev, wraps ...map[string]any) map[string]any {
	t.Helper()
	dl, err := e2ee.ParseLine(def)
	if err != nil {
		t.Fatal(err)
	}
	oo, err := e2ee.ParseMemberOptOut(optOut)
	if err != nil {
		t.Fatal(err)
	}
	commit, err := e2ee.KeyCommitmentLine(testSK, circle, e2ee.LineServer, uint32(gen))
	if err != nil {
		t.Fatal(err)
	}
	nonce := randBytes(16)
	msg, err := e2ee.ProcessingPolicyMessage(circle, actor.uid, assist, dl, oo, uint32(gen), commit, nonce)
	if err != nil {
		t.Fatal(err)
	}
	lm, err := e2ee.LogActionMessage(e2ee.ActProcessingPolicy, actor.uid, actor.id, circle, "", uint32(gen), e2ee.ProcessingRef(msg))
	if err != nil {
		t.Fatal(err)
	}
	b := map[string]any{"server_assist": assist, "default_for_new": def, "member_opt_out": optOut, "sk_gen": gen,
		"commitment": b64s(commit), "nonce": b64s(nonce), "signature": b64s(ed25519.Sign(actor.priv, msg)),
		"actor_device_id": actor.id, "log_signature": b64s(ed25519.Sign(actor.priv, lm))}
	if len(wraps) > 0 {
		b["wraps"] = wraps
	}
	return b
}

// prefBody builds a signed processing_pref request from a member's phone.
func (e *srvEnv) prefBody(member *tdev, lane string, gen int) map[string]any {
	e.t.Helper()
	l, err := e2ee.ParseLine(lane)
	if err != nil {
		e.t.Fatal(err)
	}
	sdev, fp, subject := zeroUUID, make([]byte, 32), ""
	if l == e2ee.LineServer {
		sdev, fp, subject = e.s.id, e.s.fp, e.s.id
	}
	nonce := randBytes(16)
	msg, err := e2ee.ProcessingPrefMessage(e.circle, member.uid, l, uint32(gen), sdev, fp, nonce)
	if err != nil {
		e.t.Fatal(err)
	}
	lm, err := e2ee.LogActionMessage(e2ee.ActProcessingPref, member.uid, member.id, e.circle, subject, uint32(gen), e2ee.ProcessingRef(msg))
	if err != nil {
		e.t.Fatal(err)
	}
	return map[string]any{"lane": lane, "sk_gen": gen, "server_device_id": sdev, "server_fingerprint": b64s(fp), "nonce": b64s(nonce),
		"approver_device_id": member.id, "signature": b64s(ed25519.Sign(member.priv, msg)), "log_signature": b64s(ed25519.Sign(member.priv, lm))}
}

func (e *srvEnv) setLane(user string, d *tdev, lane string, gen, want int) map[string]any {
	e.t.Helper()
	return e.mustCode(user, "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(d, lane, gen), want)
}

func (e *srvEnv) declareLanes2(user string, d *tdev) {
	e.t.Helper()
	e.mustCode(user, "PUT", "/e2ee/devices/"+d.id+"/caps", map[string]any{"caps": []string{"lanes2", "bogus"}}, 200)
}

// laneEnv: a NON-legacy circle, server key pinned, every phone declared lanes2.
func newLaneEnv(t *testing.T) *srvEnv {
	e := newSrvEnvOpt(t, false)
	e.pin()
	e.declareLanes2("A", e.a)
	e.declareLanes2("B", e.b)
	e.declareLanes2("C", e.c)
	return e
}

func (e *srvEnv) enableAssist(optOut string) {
	e.t.Helper()
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(e.t, e.circle, true, "phone", optOut, 1, e.a, mkSKWrap(e.t, e.circle, 1, e.a, e.a), mkSKWrap(e.t, e.circle, 1, e.a, e.b), mkSKWrap(e.t, e.circle, 1, e.a, e.c)), 200)
}

func (e *srvEnv) wrapSKToServer(gen, want int) map[string]any {
	e.t.Helper()
	return e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"key_line": "server", "epoch": gen,
		"wraps": []any{mkSKWrap(e.t, e.circle, gen, e.a, e.s)}}, want)
}

func (e *srvEnv) sql(q string, args ...any) {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(), q, args...); err != nil {
		e.t.Fatalf("%s: %v", q, err)
	}
}

func (e *srvEnv) sqlErr(q string, args ...any) error {
	_, err := e.pool.Exec(context.Background(), q, args...)
	return err
}

func (e *srvEnv) count(q string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), q, args...).Scan(&n); err != nil {
		e.t.Fatalf("%s: %v", q, err)
	}
	return n
}

func (e *srvEnv) sealV2(d *tdev, line e2ee.Line, gen int, seq int64, purpose string) map[string]any {
	e.t.Helper()
	key := e.key
	if line == e2ee.LineServer {
		key = testSK
	}
	var nonce [24]byte
	copy(nonce[:], randBytes(24))
	ct, err := e2ee.SealItemV2(key, e.circle, line, uint32(gen), d.id, d.priv, purpose, uint64(seq), uint64(time.Now().UnixMilli()),
		[]byte(`{"lat":41.8781,"lon":-87.6298}`), nonce)
	if err != nil {
		e.t.Fatal(err)
	}
	return map[string]any{"seq": seq, "purpose": purpose, "epoch": gen, "size_bucket": len(ct) - 46, "ciphertext": b64s(ct), "key_line": line.String()}
}

// readyLanes: assist on, SK wrapped to the server, A and B server lane, C no pref.
func readyLanes(t *testing.T) *srvEnv {
	e := newLaneEnv(t)
	e.enableAssist("allowed")
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	e.setLane("B", e.b, "server", 1, 200)
	if got := e.count(`SELECT count(*) FROM (SELECT 1 WHERE e2ee_server_assist($1::uuid)) x`, e.circle); got != 1 {
		t.Fatal("server assistance is not in effect after policy, wrap and lane choices")
	}
	return e
}

// -------------------------------------------------------------- migration

func TestLanesMigrationIdempotentAndDown(t *testing.T) {
	e := newLaneEnv(t)
	up, err := os.ReadFile("../db/migrations/000220_processing_lanes.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	down, err := os.ReadFile("../db/migrations/000220_processing_lanes.down.sql")
	if err != nil {
		t.Fatal(err)
	}
	e.enableAssist("allowed")
	e.setLane("A", e.a, "server", 1, 200)
	before := e.count(`SELECT count(*) FROM e2ee_processing_pref`)
	// Running the up migration again changes nothing and does not fail.
	for i := 0; i < 2; i++ {
		if _, err := e.pool.Exec(context.Background(), string(up)); err != nil {
			t.Fatalf("up migration is not idempotent (run %d): %v", i+2, err)
		}
	}
	if after := e.count(`SELECT count(*) FROM e2ee_processing_pref`); after != before {
		t.Fatalf("prefs changed by re-running the migration: %d -> %d", before, after)
	}
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND server_assist AND e2ee_server_gen = 1`, e.circle) != 1 {
		t.Fatal("policy state changed by re-running the migration")
	}
	// The down migration REFUSES while lanes data exists (it would delete it silently).
	tx, err := e.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(context.Background(), string(down)); err == nil || !strings.Contains(err.Error(), "refusing to drop processing lanes") {
		t.Fatalf("down migration with lanes data: %v", err)
	}
	_ = tx.Rollback(context.Background())
	// After the data is gone it applies cleanly and restores the old schema (rolled back here).
	tx, err = e.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	for _, q := range []string{
		`UPDATE circles SET member_opt_out = 'allowed' WHERE member_opt_out <> 'allowed'`,
		`UPDATE circles SET server_assist = FALSE, server_legacy_epoch_max = 0 WHERE server_assist OR server_legacy_epoch_max > 0`,
		`DELETE FROM e2ee_processing_pref`,
		`DELETE FROM circle_key_wraps WHERE key_line = 'server'`,
		`DELETE FROM e2ee_items WHERE key_line = 'server'`,
	} {
		if _, err := tx.Exec(context.Background(), q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if _, err := tx.Exec(context.Background(), string(down)); err != nil {
		t.Fatalf("down migration: %v", err)
	}
	var n int
	if err := tx.QueryRow(context.Background(), `SELECT count(*) FROM information_schema.columns WHERE table_name = 'e2ee_items' AND column_name = 'key_line'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("key_line survived the down migration: %d %v", n, err)
	}
}

// -------------------------------------------------- CK never to a server key

func TestCKNeverWrappedToServerKeyUnderAnyPath(t *testing.T) {
	e := newLaneEnv(t)
	ctx := context.Background()
	// Direct SQL, phone line, non-legacy circle.
	err := e.sqlErr(`INSERT INTO circle_key_wraps (circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
		VALUES ($1,'phone',1,$2,$3,$4,$5,$6)`, e.circle, e.s.id, e.a.id, e.a.ed, make([]byte, 105), make([]byte, 64))
	if err == nil || !strings.Contains(err.Error(), "e2ee_ck_to_server") {
		t.Fatalf("SQL insert of CK for the server key: %v", err)
	}
	// POST wraps (the admin, who is the publisher, and a member wrapping to a "server" key of her own).
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, e.circle, 1, e.a, e.s, e.key)}}, 400)
	// The same through the epoch bump and with an explicit phone line.
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/epoch",
		epochBody(t, e2ee.ActEpoch, e.circle, 2, e.a, mkWrap(t, e.circle, 2, e.a, e.a, e.key), mkWrap(t, e.circle, 2, e.a, e.s, e.key)), 400)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"key_line": "phone", "epoch": 1, "wraps": []any{mkWrap(t, e.circle, 1, e.a, e.s, e.key)}}, 400)
	// A server key owned by B, wrapped to by B herself.
	bs := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, bs, "server", e.b, e2ee.ActRegister, false), 201)
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"epoch": 1, "wraps": []any{mkWrap(t, e.circle, 1, e.b, bs, e.key)}}, 400)
	// UPDATE of an existing phone wrap's recipient to the server key.
	err = e.sqlErr(`UPDATE circle_key_wraps SET recipient_device_id = $2 WHERE circle_id = $1 AND recipient_device_id = $3`, e.circle, e.s.id, e.b.id)
	if err == nil {
		t.Fatal("re-pointing a CK wrap at the server key was allowed")
	}
	// Changing a phone key's kind to server (to receive its existing CK wrap).
	err = e.sqlErr(`UPDATE device_keys SET kind = 'server' WHERE device_id = $1`, e.c.id)
	if err == nil || !strings.Contains(err.Error(), "kind cannot change") {
		t.Fatalf("kind change: %v", err)
	}
	if e.count(`SELECT count(*) FROM circle_key_wraps w JOIN device_keys d ON d.device_id = w.recipient_device_id WHERE d.kind = 'server' AND w.circle_id = $1`, e.circle) != 0 {
		t.Fatal("the server key holds a wrap")
	}
	_ = ctx
}

func TestSKWrapToServerNeedsPolicyAndAServerLaneMember(t *testing.T) {
	e := newLaneEnv(t)
	// Policy off.
	e.wrapSKToServer(1, 409)
	err := e.sqlErr(`INSERT INTO circle_key_wraps (circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
		VALUES ($1,'server',1,$2,$3,$4,$5,$6)`, e.circle, e.s.id, e.a.id, e.a.ed, make([]byte, 105), make([]byte, 64))
	if err == nil {
		t.Fatal("SQL insert of SK for the server key with the policy off")
	}
	e.enableAssist("allowed")
	// Policy on, nobody in lane server yet: no wrap for the server (rule 5.4.2).
	e.wrapSKToServer(1, 400)
	err = e.sqlErr(`INSERT INTO circle_key_wraps (circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
		VALUES ($1,'server',1,$2,$3,$4,$5,$6)`, e.circle, e.s.id, e.a.id, e.a.ed, make([]byte, 105), make([]byte, 64))
	if err == nil || !strings.Contains(err.Error(), "e2ee_sk_to_server") {
		t.Fatalf("SQL insert of SK with no server-lane member: %v", err)
	}
	if e.count(`SELECT count(*) FROM (SELECT 1 WHERE e2ee_server_assist($1::uuid)) x`, e.circle) != 0 {
		t.Fatal("assistance is in effect before anyone chose the server lane")
	}
	// A wrap made by a non-phone key is refused even then.
	e.setLane("A", e.a, "server", 1, 200)
	web := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, web, "web", e.a, e2ee.ActRegister, false), 201)
	// B cannot wrap the SK for the server (only the publisher can issue to others).
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/wraps", map[string]any{"key_line": "server", "epoch": 1,
		"wraps": []any{mkSKWrap(t, e.circle, 1, e.b, e.s)}}, 400)
	e.wrapSKToServer(1, 200)
	if e.count(`SELECT count(*) FROM (SELECT 1 WHERE e2ee_server_assist($1::uuid)) x`, e.circle) != 1 {
		t.Fatal("assistance not in effect after the wrap")
	}
	// The last server-lane member switches to phone: the server's SK wrap is revoked.
	e.setLane("A", e.a, "phone", 0, 200)
	if e.count(`SELECT count(*) FROM circle_key_wraps w JOIN device_keys d ON d.device_id = w.recipient_device_id WHERE d.kind = 'server' AND w.circle_id = $1`, e.circle) != 0 {
		t.Fatal("the server kept its SK wrap after the last server-lane member left the lane")
	}
	// Policy off revokes it too, and every lane-server pref.
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, false, "phone", "allowed", 1, e.a), 200)
	if e.count(`SELECT count(*) FROM circle_key_wraps w JOIN device_keys d ON d.device_id = w.recipient_device_id WHERE d.kind = 'server' AND w.circle_id = $1`, e.circle) != 0 {
		t.Fatal("the server kept its SK wrap after the policy was turned off")
	}
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND lane = 'server'`, e.circle) != 0 {
		t.Fatal("lane-server prefs survived the policy being turned off")
	}
	if c, _, raw := e.ingest(e.point("fix", e.a, time.Now(), 1, 2)); c != 409 {
		t.Fatalf("ingest after policy off: %d %s", c, raw)
	}
	// Turning it on again needs a NEW generation.
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, mkSKWrap(t, e.circle, 1, e.a, e.a)), 409)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "allowed", 2, e.a, mkSKWrap(t, e.circle, 2, e.a, e.a), mkSKWrap(t, e.circle, 2, e.a, e.b)), 200)
}

// ------------------------------------------------------------------ roles

func TestProcessingRoleMatrix(t *testing.T) {
	e := newLaneEnv(t)
	body := func() map[string]any {
		return policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, mkSKWrap(t, e.circle, 1, e.a, e.a))
	}
	pol := "/circles/" + e.circle + "/e2ee/processing-policy"
	e.mustCode("B", "PUT", pol, body(), 403) // plain member
	e.mustCode("D", "PUT", pol, body(), 404) // outsider
	// A platform admin who is not a circle member has no power over the circle.
	e.sql(`UPDATE users SET role = 'admin' WHERE id = $1`, e.ids["D"])
	e.mustCode("D", "PUT", pol, body(), 404)
	e.mustCode("D", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(e.b, "phone", 0), 404)
	e.mustCode("D", "POST", "/circles/"+e.circle+"/e2ee/processing-upgrade", map[string]any{}, 404)
	e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/processing-upgrade", map[string]any{}, 403)
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND server_assist`, e.circle) != 0 {
		t.Fatal("a refused policy change was applied")
	}
	// The admin's policy signed by another person's key is refused.
	bad := policyBody(t, e.circle, true, "phone", "allowed", 1, e.b, mkSKWrap(t, e.circle, 1, e.a, e.a))
	bad["actor_device_id"] = e.b.id
	e.mustCode("A", "PUT", pol, bad, 400)
	e.mustCode("A", "PUT", pol, body(), 200)
	// Settings change at the same generation (no wraps), by the admin only.
	e.mustCode("B", "PUT", pol, policyBody(t, e.circle, true, "server", "allowed", 1, e.b), 403)
	e.mustCode("A", "PUT", pol, policyBody(t, e.circle, true, "server", "allowed", 1, e.a), 200)
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND server_assist_default = 'server'`, e.circle) != 1 {
		t.Fatal("default_for_new not stored")
	}
	// Nobody can write another member's pref: the statement binds the caller's id,
	// so A cannot sign B's choice, with A's key or with B's.
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(e.b, "phone", 0), 400)
	pb := e.prefBody(e.a, "phone", 0)
	pb["user_id"] = e.ids["B"] // ignored: the user comes from the token
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", pb, 200)
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]) != 0 {
		t.Fatal("B has a pref nobody but B could write")
	}
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["A"]) != 1 {
		t.Fatal("A's own pref missing")
	}
	// A pref for a circle the caller is not in.
	e.mustCode("D", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(e.b, "phone", 0), 404)
	// State is readable by members only, and shows lanes to all of them.
	e.mustCode("D", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 404)
	st := e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	if st["members_phone_only"].(float64) != 3 || st["my_lane"] != "phone" {
		t.Fatalf("state: %v", st)
	}
}

func TestPrefValidation(t *testing.T) {
	e := newLaneEnv(t)
	pref := "/circles/" + e.circle + "/e2ee/processing-pref"
	// Policy off: no server lane.
	e.mustCode("B", "PUT", pref, e.prefBody(e.b, "server", 1), 409)
	e.enableAssist("allowed")
	e.mustCode("B", "PUT", pref, e.prefBody(e.b, "server", 2), 409) // generation that does not exist
	// Wrong server fingerprint: the signature is valid but names another key.
	pb := e.prefBody(e.b, "server", 1)
	fake := newTDev(t, e.ids["B"])
	msg, _ := e2ee.ProcessingPrefMessage(e.circle, e.b.uid, e2ee.LineServer, 1, e.s.id, fake.fp, randBytes(16))
	pb["server_fingerprint"], pb["signature"] = b64s(fake.fp), b64s(ed25519.Sign(e.b.priv, msg))
	e.mustCode("B", "PUT", pref, pb, 400) // nonce in the body does not match the signed one
	// Bad signature / moved field.
	pb = e.prefBody(e.b, "server", 1)
	pb["sk_gen"] = 1
	pb["nonce"] = b64s(randBytes(16))
	e.mustCode("B", "PUT", pref, pb, 400)
	// Signed by a key that is not a phone key of the caller (web viewer).
	web := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, web, "web", e.b, e2ee.ActRegister, false), 201)
	wb := e.prefBody(web, "server", 1)
	e.mustCode("B", "PUT", pref, wb, 400)
	// An app that never declared lanes2 cannot choose the server lane.
	old := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, old, "device", e.b, e2ee.ActRegister, false), 201)
	e.mustCode("B", "PUT", pref, e.prefBody(old, "server", 1), 409)
	// The right one works and is logged.
	r := e.mustCode("B", "PUT", pref, e.prefBody(e.b, "server", 1), 200)
	if r["lane"] != "server" || r["effective_seq"].(float64) < 1 {
		t.Fatalf("%v", r)
	}
	// Another pinned server key is not accepted.
	s2 := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, s2, "server", e.b, e2ee.ActRegister, false), 201)
	other := e.prefBody(e.c, "server", 1)
	other["server_device_id"] = s2.id
	e.mustCode("C", "PUT", pref, other, 400)
	// Phone lane: must name no server key.
	zp := e.prefBody(e.c, "phone", 0)
	zp["server_device_id"] = e.s.id
	e.mustCode("C", "PUT", pref, zp, 400)
}

// ---------------------------------------------------------- caps gating

func TestCapsGateAndOldAppsStayPhoneOnly(t *testing.T) {
	e := newSrvEnvOpt(t, false)
	e.pin()
	e.declareLanes2("A", e.a)
	pol := "/circles/" + e.circle + "/e2ee/processing-policy"
	wraps := []map[string]any{mkSKWrap(t, e.circle, 1, e.a, e.a), mkSKWrap(t, e.circle, 1, e.a, e.b), mkSKWrap(t, e.circle, 1, e.a, e.c)}
	// B and C run apps that never declared lanes2: enabling is refused and says who.
	c, m, raw := e.do("A", "PUT", pol, policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, wraps...))
	if c != 409 || m["code"] != "members_not_ready" || len(m["not_ready"].([]any)) != 2 {
		t.Fatalf("%d %s", c, raw)
	}
	// Caps cannot be set on someone else's key; unknown values are dropped.
	e.mustCode("A", "PUT", "/e2ee/devices/"+e.b.id+"/caps", map[string]any{"caps": []string{"lanes2"}}, 404)
	e.declareLanes2("B", e.b)
	if e.count(`SELECT count(*) FROM device_keys WHERE device_id = $1 AND caps = ARRAY['lanes2']`, e.b.id) != 1 {
		t.Fatal("caps not stored cleanly")
	}
	e.mustCode("A", "PUT", pol, policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, wraps...), 409)
	e.declareLanes2("C", e.c)
	e.mustCode("A", "PUT", pol, policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, wraps...), 200)
	// A later joiner with an old app: cannot choose the server lane, cannot post server-line items.
	d := newTDev(t, e.ids["B"])
	e.mustCode("B", "POST", "/e2ee/devices", regBody(t, d, "device", e.b, e2ee.ActRegister, false), 201)
	e.mustCode("B", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(d, "server", 1), 409)
	// Old-app view: wraps and items default to the phone line only; the circle list
	// flag that old apps read as "server can read it" stays false.
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	w := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/wraps?device_id="+e.a.id, nil, 200)
	for _, x := range w["wraps"].([]any) {
		if x.(map[string]any)["key_line"] != "phone" {
			t.Fatalf("an SK wrap reached an old app: %v", x)
		}
	}
	all := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/wraps?device_id="+e.a.id+"&key_line=all", nil, 200)
	if len(all["wraps"].([]any)) != 2 {
		t.Fatalf("lanes app does not see both wraps: %v", all)
	}
	_, lst, raw2 := e.do("B", "GET", "/circles", nil)
	_ = lst
	if !strings.Contains(string(raw2), `"e2ee_server_member":false`) || !strings.Contains(string(raw2), `"server_assist":true`) {
		t.Fatalf("circle list: %s", raw2)
	}
	// The sidecar (server key) and old apps keep working with the old item API: v1 items post as phone line.
	r := results(e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "fix", 1, 1, []byte("x"))))
	if r[0]["status"] != "stored" {
		t.Fatalf("v1 item refused in a lanes circle: %v", r)
	}
	// An app without lanes2 posting a server-line item is refused.
	it := e.sealV2(d, e2ee.LineServer, 1, 1, "fix")
	rs := results(e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": d.id, "items": []any{it}}, 200))
	if rs[0]["status"] != "rejected" {
		t.Fatalf("server-line item from an old app: %v", rs)
	}
}

// ------------------------------------------------------ ingest, per user

func TestIngestOnlyVerifiedServerLaneMembers(t *testing.T) {
	e := readyLanes(t)
	now := time.Now()
	// C has no pref, B and A are in lane server.
	c, m, raw := e.ingest(e.point("fix", e.a, now, 52.1, 13.1), e.point("fix", e.b, now, 52.2, 13.2), e.point("fix", e.c, now, 41.8781, -87.6298))
	if c != 200 || m["stored"].(float64) != 2 || rejectedCount(m, "lane_not_server") != 1 {
		t.Fatalf("%d %s", c, raw)
	}
	if e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1`, e.ids["C"]) != 0 ||
		e.count(`SELECT count(*) FROM member_positions WHERE user_id = $1 AND lat <> 10`, e.ids["C"]) != 0 {
		t.Fatal("a member without a pref was written")
	}
	// A planted pref row (junk signature) for C: SQL says yes, ingest still refuses.
	e.sql(`INSERT INTO e2ee_processing_pref (circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id, signature, legacy, log_seq)
		VALUES ($1,$2,'server',1,$3,$4,$5,$6,$7,FALSE,1)`, e.circle, e.ids["C"], e.s.id, e.s.fp, randBytes(16), e.c.id, make([]byte, 64))
	if e.count(`SELECT count(*) FROM (SELECT 1 WHERE e2ee_member_server_ok($1::uuid, $2::uuid)) x`, e.circle, e.ids["C"]) != 1 {
		t.Fatal("test premise: SQL view of the planted row")
	}
	if c, m, raw := e.ingest(e.point("fix", e.c, now.Add(time.Second), 41.8781, -87.6298)); c != 200 || m["stored"].(float64) != 0 || rejectedCount(m, "lane_not_server") != 1 {
		t.Fatalf("planted pref accepted: %d %s", c, raw)
	}
	// A planted row with a VALID signature that C once made but replaced (replay):
	// capture a real server pref, switch to phone, restore the old row.
	e.sql(`DELETE FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"])
	e.setLane("C", e.c, "server", 1, 200)
	var lane string
	var gen int
	var srv, appr string
	var fp, nonce, sig []byte
	var seq int64
	if err := e.pool.QueryRow(context.Background(), `SELECT lane, sk_gen, server_device_id::text, server_fingerprint, nonce, approver_device_id::text, signature, log_seq
		FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"]).Scan(&lane, &gen, &srv, &fp, &nonce, &appr, &sig, &seq); err != nil {
		t.Fatal(err)
	}
	if c, m, _ := e.ingest(e.point("fix", e.c, now.Add(2*time.Second), 41.9, -87.7)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatal("C in lane server was not ingested")
	}
	e.setLane("C", e.c, "phone", 0, 200)
	if c, m, _ := e.ingest(e.point("fix", e.c, now.Add(3*time.Second), 41.9, -87.7)); c != 200 || m["stored"].(float64) != 0 {
		t.Fatal("C was ingested right after switching to the phone lane")
	}
	e.sql(`UPDATE e2ee_processing_pref SET lane = $3, sk_gen = $4, server_device_id = $5, server_fingerprint = $6, nonce = $7, signature = $8, log_seq = $9
		WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"], lane, gen, srv, fp, nonce, sig, seq)
	if c, m, raw := e.ingest(e.point("fix", e.c, now.Add(4*time.Second), 41.9, -87.7)); c != 200 || m["stored"].(float64) != 0 {
		t.Fatalf("a replayed old pref was accepted: %d %s", c, raw)
	}
	// A planted legacy consent row does nothing in a lanes circle.
	e.sql(`INSERT INTO e2ee_server_consents (circle_id, user_id, server_device_id, approver_device_id, signature) VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT DO NOTHING`, e.circle, e.ids["C"], e.s.id, e.c.id, make([]byte, 64))
	e.sql(`DELETE FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"])
	if c, m, _ := e.ingest(e.point("fix", e.c, now.Add(5*time.Second), 41.9, -87.7)); c != 200 || m["stored"].(float64) != 0 {
		t.Fatal("a planted legacy consent row let ingest in")
	}
}

// Flipping the policy columns alone (no signed statement) does not enable ingest.
func TestPolicyColumnsAloneDoNotEnableIngest(t *testing.T) {
	e := newLaneEnv(t)
	e.sql(`UPDATE circles SET server_assist = TRUE, e2ee_server_gen = 1 WHERE id = $1`, e.circle)
	e.sql(`INSERT INTO e2ee_processing_pref (circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id, signature, legacy, log_seq)
		VALUES ($1,$2,'server',1,$3,$4,$5,$6,$7,FALSE,1)`, e.circle, e.ids["A"], e.s.id, e.s.fp, randBytes(16), e.a.id, make([]byte, 64))
	e.sql(`INSERT INTO circle_key_wraps (circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
		VALUES ($1,'server',1,$2,$3,$4,$5,$6)`, e.circle, e.s.id, e.a.id, e.a.ed, make([]byte, 105), make([]byte, 64))
	if e.count(`SELECT count(*) FROM (SELECT 1 WHERE e2ee_server_assist($1::uuid)) x`, e.circle) != 1 {
		t.Fatal("test premise: SQL sees assistance")
	}
	if c, _, raw := e.ingest(e.point("fix", e.a, time.Now(), 1, 2)); c != 409 {
		t.Fatalf("columns flipped without a policy: %d %s", c, raw)
	}
}

func TestOneOptedOutMemberCircleHoldsNoPlaintextOfThatMember(t *testing.T) {
	var logs bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)
	e := readyLanes(t)
	var audit []string
	e.srv.auditHook = func(u, f, a, d string) { audit = append(audit, a+"|"+d) }
	now := time.Now()
	e.setLane("C", e.c, "phone", 0, 200)
	if c, m, _ := e.ingest(e.point("fix", e.a, now, 52.5, 13.4), e.point("fix", e.b, now, 52.6, 13.5)); c != 200 || m["stored"].(float64) != 2 {
		t.Fatal("the opted-in members' fixes did not reach locations")
	}
	// C's phone-line sealed fix (the coordinates are inside the ciphertext only).
	r := results(e.post("C", e.c, e.circle, 201, e.sealV2(e.c, e.phoneLine(), 1, 1, "fix")))
	if r[0]["status"] != "stored" {
		t.Fatalf("%v", r)
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND key_line = 'phone' AND device_id = $2`, e.circle, e.c.id) != 1 {
		t.Fatal("C's item is not stored as the phone line")
	}
	// C tries to seal under SK: refused (lane is phone).
	rs := results(e.mustCode("C", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.c.id,
		"items": []any{e.sealV2(e.c, e.serverLine(), 1, 2, "fix")}}, 200))
	if rs[0]["status"] != "rejected" || rs[0]["error"] != "lane_not_server" {
		t.Fatalf("SK item from a phone-lane member: %v", rs)
	}
	// Scan: no plaintext row for C anywhere, no coordinates in audit or logs.
	if e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1`, e.ids["C"]) != 0 ||
		e.count(`SELECT count(*) FROM member_positions WHERE user_id = $1 AND lat <> 10`, e.ids["C"]) != 0 ||
		e.count(`SELECT count(*) FROM alerts WHERE user_id = $1`, e.ids["C"]) != 0 {
		t.Fatal("plaintext of the opted-out member exists on the server")
	}
	for _, needle := range []string{"41.8781", "-87.6298"} {
		if strings.Contains(logs.String(), needle) || strings.Contains(strings.Join(audit, "\n"), needle) ||
			e.count(`SELECT count(*) FROM audit_log WHERE detail LIKE '%'||$1||'%'`, needle) != 0 {
			t.Fatalf("%s leaked", needle)
		}
	}
	// Authz: nobody can see C through this circle, A and B see each other; live
	// broadcast circles exclude it for C and include it for B.
	az := circles.New(e.pool)
	ctx := context.Background()
	if sh, _ := az.SharedWith(ctx, e.ids["A"], e.ids["C"]); len(sh) != 0 {
		t.Fatalf("C visible: %v", sh)
	}
	if sh, _ := az.SharedWith(ctx, e.ids["A"], e.ids["B"]); len(sh) != 1 {
		t.Fatalf("B not visible: %v", sh)
	}
	if sc, _ := az.SharingCircles(ctx, e.ids["C"]); len(sc) != 0 {
		t.Fatalf("live fan-out would reach the circle for C: %v", sc)
	}
	if _, sc, _ := az.OwnAndSharingCircles(ctx, e.ids["C"]); len(sc) != 0 {
		t.Fatalf("OwnAndSharing for C: %v", sc)
	}
	if sc, _ := az.SharingCircles(ctx, e.ids["B"]); len(sc) != 1 {
		t.Fatalf("live fan-out for B: %v", sc)
	}
	vis, _ := az.LocationVisibility(ctx, e.ids["A"], []string{e.circle})
	if vis[e.ids["C"]] || !vis[e.ids["B"]] {
		t.Fatalf("LocationVisibility: %v", vis)
	}
	mc, _ := az.MemberCircles(ctx, e.ids["A"], []string{e.circle})
	for _, x := range mc[e.ids["C"]] {
		if x.Sharing {
			t.Fatal("MemberCircles shares C")
		}
	}
	// The user's own plaintext endpoints: C (private-only circles) cannot upload plaintext.
	e.mustCode("C", "POST", "/locations", map[string]any{"device_id": e.c.id, "lat": 52.1, "lon": 13.1}, 409)
	// SOS and check-in carry no position for C; B (server lane) may.
	if e.srv.memberPlaintextOK(ctx, e.circle, e.ids["C"]) || !e.srv.memberPlaintextOK(ctx, e.circle, e.ids["B"]) {
		t.Fatal("memberPlaintextOK")
	}
	// Places stay phone-evaluated: plaintext places are refused in a lanes circle.
	e.mustCode("A", "POST", "/family/places", map[string]any{"name": "Home", "lat": 1, "lon": 2, "radius_meters": 100, "circle_id": e.circle}, 409)
}

func (e *srvEnv) phoneLine() e2ee.Line  { return e2ee.LinePhone }
func (e *srvEnv) serverLine() e2ee.Line { return e2ee.LineServer }

func TestItemRoutingByKeyLine(t *testing.T) {
	e := readyLanes(t)
	a := e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id, "items": []any{
		e.sealV2(e.a, e.serverLine(), 1, 1, "fix"), e.sealV2(e.a, e.phoneLine(), 1, 2, "history")}}, 201)
	for _, r := range results(a) {
		if r["status"] != "stored" {
			t.Fatalf("%v", a)
		}
	}
	// Mislabelled items fail: header says server, declared phone; unknown line; generation above current.
	bad1 := e.sealV2(e.a, e.serverLine(), 1, 3, "fix")
	bad1["key_line"] = "phone"
	bad2 := e.sealV2(e.a, e.serverLine(), 1, 4, "fix")
	bad2["key_line"] = "sideways"
	bad3 := e.sealV2(e.a, e.serverLine(), 7, 5, "fix")
	bad4 := e.sealV2(e.a, e.phoneLine(), 1, 6, "fix")
	bad4["key_line"] = "server"
	v1 := e.seal(t, e.a, e.circle, "fix", 1, 7, []byte("x"))
	v1["key_line"] = "server"
	rs := results(e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id, "items": []any{bad1, bad2, bad3, bad4, v1}}, 200))
	for i, r := range rs {
		if r["status"] != "rejected" {
			t.Fatalf("item %d accepted: %v", i, r)
		}
	}
	// A v2 item with no declared line is refused.
	nl := e.sealV2(e.a, e.phoneLine(), 1, 8, "fix")
	delete(nl, "key_line")
	if rs := results(e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.a.id, "items": []any{nl}}, 200)); rs[0]["status"] != "rejected" {
		t.Fatalf("v2 without a line: %v", rs)
	}
	// DB backstop: a server-line row from a phone-lane author cannot be inserted.
	err := e.sqlErr(`INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at, key_line)
		VALUES ($1,$2,99,'fix',1,256,'\x00',now(),'server')`, e.circle, e.c.id)
	if err == nil || !strings.Contains(err.Error(), "e2ee_lane") {
		t.Fatalf("DB let a server-line item from a phone-lane member in: %v", err)
	}
	// Listing: default = phone line only; server and all on request; the server key reads the server line only.
	def := e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items", nil, 200)
	if n := len(def["items"].([]any)); n != 1 {
		t.Fatalf("default listing: %d", n)
	}
	if n := len(e.mustCode("B", "GET", "/circles/"+e.circle+"/e2ee/items?key_line=all", nil, 200)["items"].([]any)); n != 2 {
		t.Fatalf("all: %d", n)
	}
	srv := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?key_line=server&as_device="+e.s.id, nil, 200)
	if n := len(srv["items"].([]any)); n != 1 || srv["items"].([]any)[0].(map[string]any)["key_line"] != "server" {
		t.Fatalf("server listing: %v", srv)
	}
	forced := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?key_line=all&as_device="+e.s.id, nil, 200)
	if n := len(forced["items"].([]any)); n != 1 {
		t.Fatalf("a server key read phone-line items: %d", n)
	}
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?key_line=zzz", nil, 400)
}

func TestRequiredServerRefusesPhoneLaneItems(t *testing.T) {
	e := newLaneEnv(t)
	// required_server needs assist on (the statement itself refuses otherwise).
	dl, _ := e2ee.ParseLine("phone")
	if _, err := e2ee.ProcessingPolicyMessage(e.circle, e.a.uid, false, dl, e2ee.OptOutRequiredServer, 0, make([]byte, 32), randBytes(16)); err == nil {
		t.Fatal("required_server without assistance is a valid statement")
	}
	e.enableAssist("required_server")
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	// A is in lane server; B and C are not (no consent yet): their phone-lane items are not relayed.
	for _, u := range []struct {
		name string
		d    *tdev
	}{{"B", e.b}, {"C", e.c}} {
		rs := results(e.mustCode(u.name, "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": u.d.id,
			"items": []any{e.seal(t, u.d, e.circle, "fix", 1, 1, []byte("x")), e.sealV2(u.d, e.phoneLine(), 1, 2, "history")}}, 200))
		for _, r := range rs {
			if r["status"] != "rejected" || r["error"] != "required_server" {
				t.Fatalf("%s: phone-lane item relayed in a required_server circle: %v", u.name, r)
			}
		}
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id IN ($2,$3)`, e.circle, e.b.id, e.c.id) != 0 {
		t.Fatal("items stored")
	}
	// L2: check-ins (SOS) and events are never blocked by the rule.
	for i, purpose := range []string{"checkin", "event"} {
		if r := results(e.mustCode("C", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.c.id,
			"items": []any{e.sealV2(e.c, e.phoneLine(), 1, int64(50+i), purpose)}}, 201)); r[0]["status"] != "stored" {
			t.Fatalf("%s blocked in a required_server circle: %v", purpose, r)
		}
	}
	e.sql(`DELETE FROM e2ee_items WHERE circle_id = $1 AND device_id = $2`, e.circle, e.c.id)
	err := e.sqlErr(`INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at)
		VALUES ($1,$2,99,'fix',1,256,'\x00',now())`, e.circle, e.b.id)
	if err == nil || !strings.Contains(err.Error(), "e2ee_required_server") {
		t.Fatalf("DB backstop: %v", err)
	}
	// After B signs their own consent, B is relayed; the admin still cannot do it for C.
	e.setLane("B", e.b, "server", 1, 200)
	r := results(e.post("B", e.b, e.circle, 201, e.sealV2(e.b, e.serverLine(), 1, 3, "fix")))
	if r[0]["status"] != "stored" {
		t.Fatalf("%v", r)
	}
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-pref", e.prefBody(e.c, "server", 1), 400)
	// Withdrawing consent is always possible (and stops C's relay again).
	e.setLane("B", e.b, "phone", 0, 200)
	rs := results(e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id,
		"items": []any{e.sealV2(e.b, e.phoneLine(), 1, 4, "fix")}}, 200))
	if rs[0]["status"] != "rejected" {
		t.Fatalf("%v", rs)
	}
	// Switching the rule back to allowed relays phone-lane items again.
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, true, "phone", "allowed", 1, e.a), 200)
	if r := results(e.post("B", e.b, e.circle, 201, e.sealV2(e.b, e.phoneLine(), 1, 5, "fix"))); r[0]["status"] != "stored" {
		t.Fatalf("%v", r)
	}
	// Turning required_server on with a member whose app lacks lanes2 is refused.
	e.sql(`UPDATE device_keys SET caps = '{}' WHERE device_id = $1`, e.c.id)
	c, m, _ := e.do("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, true, "phone", "required_server", 1, e.a))
	if c != 409 || m["code"] != "members_not_ready" {
		t.Fatalf("%d %v", c, m)
	}
}

// ---------------------------------------------------- rekey and membership

func TestMemberRemovalFlagsBothLinesAndRotationRestoresAssist(t *testing.T) {
	e := readyLanes(t)
	e.setLane("C", e.c, "server", 1, 200)
	e.sql(`DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"])
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND e2ee_rekey_required AND e2ee_server_rekey_required`, e.circle) != 1 {
		t.Fatal("both lines must request a new generation")
	}
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"]) != 0 {
		t.Fatal("a removed member's pref survived")
	}
	if c, _, _ := e.ingest(e.point("fix", e.a, time.Now(), 1, 2)); c != 409 {
		t.Fatalf("ingest during a pending SK rotation: %d", c)
	}
	// The admin rotates the SK: generation 2, server wrapped again (A and B are in lane server).
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "allowed", 2, e.a, mkSKWrap(t, e.circle, 2, e.a, e.a), mkSKWrap(t, e.circle, 2, e.a, e.b), mkSKWrap(t, e.circle, 2, e.a, e.s)), 200)
	// A rotation without the wraps is refused; a skipped generation too.
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, true, "phone", "allowed", 3, e.a), 400)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, true, "phone", "allowed", 5, e.a, mkSKWrap(t, e.circle, 5, e.a, e.a)), 409)
	// Prefs name generation 1; they still count (consent is to the server key, not a generation).
	if c, m, raw := e.ingest(e.point("fix", e.a, time.Now(), 1, 2)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatalf("%d %s", c, raw)
	}
}

// ------------------------------------------------------------------ purge

func TestPurgeScopeMineAndCircleLeavePhoneLineAlone(t *testing.T) {
	e := readyLanes(t)
	now := time.Now()
	e.ingest(e.point("history", e.a, now.Add(-time.Hour), 1, 2), e.point("history", e.b, now.Add(-time.Hour), 3, 4))
	e.post("B", e.b, e.circle, 201, e.sealV2(e.b, e.serverLine(), 1, 1, "history"), e.sealV2(e.b, e.phoneLine(), 1, 2, "history"),
		e.sealV2(e.b, e.serverLine(), 1, 3, "chat"), e.sealV2(e.b, e.serverLine(), 1, 4, "place"), e.sealV2(e.b, e.serverLine(), 1, 5, "checkin"))
	e.post("A", e.a, e.circle, 201, e.sealV2(e.a, e.serverLine(), 1, 1, "history"), e.sealV2(e.a, e.phoneLine(), 1, 2, "history"))
	e.post("A", e.a, e.circle, 201, e.sealV2(e.a, e.serverLine(), 1, 3, "chat"), e.sealV2(e.a, e.serverLine(), 1, 4, "place"))
	m := e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies", nil, 200)
	// scope=mine removes ALL of B's own server-line items (history, chat, place, checkin).
	if m["locations_deleted"].(float64) != 1 || m["items_deleted"].(float64) != 4 {
		t.Fatalf("scope=mine: %v", m)
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'phone'`, e.circle, e.b.id) != 1 {
		t.Fatal("B's phone-line item was deleted")
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server'`, e.circle, e.a.id) != 3 {
		t.Fatal("A's server-line item was deleted by B")
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server'`, e.circle, e.b.id) != 0 {
		t.Fatal("scope=mine left server-readable items of the author")
	}
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies?scope=circle", nil, 403)
	e.post("B", e.b, e.circle, 201, e.sealV2(e.b, e.serverLine(), 1, 8, "chat"), e.sealV2(e.b, e.serverLine(), 1, 9, "history"))
	m = e.mustCode("A", "DELETE", "/circles/"+e.circle+"/e2ee/server-copies?scope=circle", nil, 200)
	// The admin purge removes B's trail (history) but NOT B's shared chat item; A's own go (3).
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server' AND purpose = 'chat'`, e.circle, e.b.id) != 1 ||
		e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server' AND purpose = 'history'`, e.circle, e.b.id) != 0 {
		t.Fatal("admin scope=circle must delete others' trail only, keeping their shared items")
	}
	if m["items_deleted"].(float64) != 4 || m["locations_deleted"].(float64) != 1 {
		t.Fatalf("scope=circle: %v", m)
	}
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND key_line = 'phone'`, e.circle) != 2 {
		t.Fatal("phone-line ciphertext was purged")
	}
}

// ------------------------------------------------------------ legacy upgrade

func TestLegacyTrustedServerCircleUpgrade(t *testing.T) {
	e := readyEnv(t) // legacy: server holds CK epoch 1, all three consented
	now := time.Now()
	e.declareLanes2("A", e.a)
	e.declareLanes2("B", e.b)
	e.declareLanes2("C", e.c)
	// Old behaviour is untouched until the admin acts.
	if c, m, raw := e.ingest(e.point("fix", e.b, now, 52.5, 13.4)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatalf("legacy ingest: %d %s", c, raw)
	}
	e.post("B", e.b, e.circle, 201, e.seal(t, e.b, e.circle, "history", 1, 1, []byte("old")))
	up := "/circles/" + e.circle + "/e2ee/processing-upgrade"
	mk := func(withServerCK bool, skServer bool) map[string]any {
		ew := []any{mkWrap(t, e.circle, 2, e.a, e.a, e.key), mkWrap(t, e.circle, 2, e.a, e.b, e.key), mkWrap(t, e.circle, 2, e.a, e.c, e.key)}
		if withServerCK {
			ew = append(ew, mkWrap(t, e.circle, 2, e.a, e.s, e.key))
		}
		sw := []map[string]any{mkSKWrap(t, e.circle, 1, e.a, e.a), mkSKWrap(t, e.circle, 1, e.a, e.b), mkSKWrap(t, e.circle, 1, e.a, e.c)}
		if skServer {
			sw = append(sw, mkSKWrap(t, e.circle, 1, e.a, e.s))
		}
		body := epochBody(t, e2ee.ActEpoch, e.circle, 2, e.a, ew[0].(map[string]any))
		body["epoch_wraps"] = ew
		body["policy"] = policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, sw...)
		return body
	}
	e.mustCode("B", "POST", up, mk(false, true), 403)
	// A CK wrap for the server key inside the upgrade is refused and nothing changes.
	e.mustCode("A", "POST", up, mk(true, true), 400)
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND server_legacy_ck AND e2ee_epoch = 1 AND NOT server_assist`, e.circle) != 1 {
		t.Fatal("a failed upgrade changed the circle")
	}
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1`, e.circle) != 0 {
		t.Fatal("a failed upgrade left prefs")
	}
	// An app without lanes2 blocks the upgrade.
	e.sql(`UPDATE device_keys SET caps = '{}' WHERE device_id = $1`, e.c.id)
	if c, m, _ := e.do("A", "POST", up, mk(false, true)); c != 409 || m["code"] != "members_not_ready" {
		t.Fatalf("%d %v", c, m)
	}
	e.declareLanes2("C", e.c)
	r := e.mustCode("A", "POST", up, mk(false, true), 200)
	if r["converted"].(float64) != 3 {
		t.Fatalf("%v", r)
	}
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND NOT server_legacy_ck AND server_assist AND e2ee_epoch = 2 AND server_legacy_epoch_max = 1 AND e2ee_server_gen = 1`, e.circle) != 1 {
		t.Fatal("circle state after the upgrade")
	}
	if e.count(`SELECT count(*) FROM e2ee_server_consents WHERE circle_id = $1`, e.circle) != 0 {
		t.Fatal("legacy consent rows left")
	}
	// The server lost the ability to read new CK items: no CK wrap at epoch 2, and none can be made.
	if e.count(`SELECT count(*) FROM circle_key_wraps WHERE circle_id = $1 AND key_line = 'phone' AND epoch = 2 AND recipient_device_id = $2`, e.circle, e.s.id) != 0 {
		t.Fatal("CK epoch 2 reached the server")
	}
	if err := e.sqlErr(`INSERT INTO circle_key_wraps (circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
		VALUES ($1,'phone',2,$2,$3,$4,$5,$6)`, e.circle, e.s.id, e.a.id, e.a.ed, make([]byte, 105), make([]byte, 64)); err == nil {
		t.Fatal("CK can still be wrapped to the server after the upgrade")
	}
	// Old items are server-line now; reading continues; a stale epoch-1 item is refused.
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND key_line = 'server' AND epoch = 1`, e.circle) != 1 {
		t.Fatal("old server-readable items not relabelled")
	}
	rs := results(e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id,
		"items": []any{e.seal(t, e.b, e.circle, "fix", 1, 9, []byte("late"))}}, 200))
	if rs[0]["status"] != "rejected" || rs[0]["error"] != "legacy_epoch_closed" {
		t.Fatalf("%v", rs)
	}
	// Server processing keeps working per member (converted prefs); the old consent route is closed.
	if c, m, raw := e.ingest(e.point("fix", e.b, now.Add(time.Second), 52.6, 13.5), e.point("fix", e.c, now.Add(time.Second), 52.7, 13.6)); c != 200 || m["stored"].(float64) != 2 {
		t.Fatalf("ingest after upgrade: %d %s", c, raw)
	}
	e.mustCode("B", "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{
		"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": consentSig(t, e.circle, e.b, e.b, e.s)}, 409)
	// Now each member can opt out individually and one member's choice does not close the circle.
	e.setLane("C", e.c, "phone", 0, 200)
	if c, m, _ := e.ingest(e.point("fix", e.b, now.Add(2*time.Second), 52.8, 13.7), e.point("fix", e.c, now.Add(2*time.Second), 52.9, 13.8)); c != 200 || m["stored"].(float64) != 1 || rejectedCount(m, "lane_not_server") != 1 {
		t.Fatalf("after C opted out: %v", m)
	}
	// A second upgrade is refused.
	e.mustCode("A", "POST", up, mk(false, true), 409)
	st := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	if st["members_server"].(float64) != 2 {
		t.Fatalf("state: %v", st)
	}
}

func TestLegacyCircleStaysLegacyAndNewCirclesCannotBe(t *testing.T) {
	e := newLaneEnv(t) // not legacy
	// A fresh circle cannot use the old all-members consent route.
	e.mustCode("B", "PUT", "/circles/"+e.circle+"/e2ee/server-consent", map[string]any{
		"server_device_id": e.s.id, "approver_device_id": e.b.id, "signature": consentSig(t, e.circle, e.b, e.b, e.s)}, 409)
	// And the legacy flag is not settable by any API: policy refuses a legacy circle.
	e.sql(`UPDATE circles SET server_legacy_ck = TRUE WHERE id = $1`, e.circle)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, mkSKWrap(t, e.circle, 1, e.a, e.a)), 409)
	// Migration 220 flags circles that already had consents or a server wrap.
	up, _ := os.ReadFile("../db/migrations/000220_processing_lanes.up.sql")
	e.sql(`UPDATE circles SET server_legacy_ck = FALSE WHERE id = $1`, e.circle)
	e.sql(`INSERT INTO e2ee_server_consents (circle_id, user_id, server_device_id, approver_device_id, signature) VALUES ($1,$2,$3,$4,$5)`,
		e.circle, e.ids["B"], e.s.id, e.b.id, make([]byte, 64))
	if _, err := e.pool.Exec(context.Background(), string(up)); err != nil {
		t.Fatal(err)
	}
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND server_legacy_ck`, e.circle) != 1 {
		t.Fatal("migration did not flag a circle that already had a server consent")
	}
}

// ----------------------------------------------------------- admin counts

func TestAdminCountsAndMapKeepsDataOnPhone(t *testing.T) {
	e := readyLanes(t)
	_, cs, err := loadE2EEAdmin(context.Background(), e.pool, false)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range cs {
		if c.ID == e.circle {
			found = true
			if c.MembersServer != 2 || c.MembersPhoneOnly != 1 || !c.ServerAssist || c.LegacyTrusted {
				t.Fatalf("admin counts: %+v", c)
			}
		}
	}
	if !found {
		t.Fatal("circle missing from the admin overview")
	}
	// C keeps data on the phone: no position on the platform admin map.
	e.sql(`INSERT INTO member_positions (user_id, lat, lon, ts) VALUES ($1, 41.8, -87.6, now()) ON CONFLICT (user_id) DO UPDATE SET lat = 41.8, ts = now()`, e.ids["C"])
	var keeps bool
	if err := e.pool.QueryRow(context.Background(), `SELECT (EXISTS (SELECT 1 FROM live_circle_members km JOIN circles kc ON kc.id = km.circle_id
		WHERE km.user_id = $1 AND kc.e2ee_mode = 'private') AND NOT EXISTS (SELECT 1 FROM live_circle_members km WHERE km.user_id = $1 AND e2ee_member_plaintext_ok(km.circle_id, km.user_id)))`, e.ids["C"]).Scan(&keeps); err != nil || !keeps {
		t.Fatalf("keeps_data_on_phone for C: %v %v", keeps, err)
	}
}

func TestProcessingStateReportsVerifiedLanes(t *testing.T) {
	e := readyLanes(t)
	st := e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	if st["in_effect"] != true || st["members_server"].(float64) != 2 || st["members_phone_only"].(float64) != 1 || st["all_members_lanes2"] != true {
		t.Fatalf("%v", st)
	}
	pol := st["policy"].(map[string]any)
	if pol["server_assist"] != true || pol["sk_gen"].(float64) != 1 || pol["statement"] == nil {
		t.Fatalf("%v", pol)
	}
	// A planted lane-server row with a bad signature is shown as phone.
	e.sql(`INSERT INTO e2ee_processing_pref (circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id, signature, legacy, log_seq)
		VALUES ($1,$2,'server',1,$3,$4,$5,$6,$7,FALSE,1)`, e.circle, e.ids["C"], e.s.id, e.s.fp, randBytes(16), e.c.id, make([]byte, 64))
	st = e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	if st["members_server"].(float64) != 2 {
		t.Fatalf("planted pref counted: %v", st["members"])
	}
}

// ============================================================ review fixes

func (e *srvEnv) upgradeBody(skServer bool) map[string]any {
	ew := []any{mkWrap(e.t, e.circle, 2, e.a, e.a, e.key), mkWrap(e.t, e.circle, 2, e.a, e.b, e.key), mkWrap(e.t, e.circle, 2, e.a, e.c, e.key)}
	sw := []map[string]any{mkSKWrap(e.t, e.circle, 1, e.a, e.a), mkSKWrap(e.t, e.circle, 1, e.a, e.b), mkSKWrap(e.t, e.circle, 1, e.a, e.c)}
	if skServer {
		sw = append(sw, mkSKWrap(e.t, e.circle, 1, e.a, e.s))
	}
	body := epochBody(e.t, e2ee.ActEpoch, e.circle, 2, e.a, ew[0].(map[string]any))
	body["epoch_wraps"] = ew
	body["policy"] = policyBody(e.t, e.circle, true, "phone", "allowed", 1, e.a, sw...)
	return body
}

// seedCopies gives a member server copies: ingested points plus server-line trail items.
func (e *srvEnv) seedCopies(user string, d *tdev, now time.Time) {
	e.t.Helper()
	if c, m, raw := e.ingest(e.point("history", d, now.Add(-time.Hour), 40.1, -80.1), e.point("fix", d, now, 40.2, -80.2)); c != 200 || m["stored"].(float64) != 2 {
		e.t.Fatalf("seed: %d %s", c, raw)
	}
	e.post(user, d, e.circle, 201, e.sealV2(d, e.serverLine(), 1, 71, "history"), e.sealV2(d, e.serverLine(), 1, 72, "fix"), e.sealV2(d, e.serverLine(), 1, 73, "chat"))
}

func (e *srvEnv) copiesOf(user string, d *tdev) (locs, pos, trail, shared int) {
	locs = e.count(`SELECT count(*) FROM locations l JOIN devices dv ON dv.id = l.device_id WHERE dv.user_id = $1 AND l.e2ee_circle_id = $2`, e.ids[user], e.circle)
	pos = e.count(`SELECT count(*) FROM member_positions WHERE user_id = $1 AND lat <> 10`, e.ids[user])
	trail = e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server' AND purpose IN ('fix','history')`, e.circle, d.id)
	shared = e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server' AND purpose = 'chat'`, e.circle, d.id)
	return
}

func (e *srvEnv) wantCopies(user string, d *tdev, locs, pos, trail, shared int, why string) {
	e.t.Helper()
	l, p, tr, sh := e.copiesOf(user, d)
	if l != locs || p != pos || tr != trail || sh != shared {
		e.t.Fatalf("%s: copies of %s = locations %d, last position %d, trail %d, shared %d; want %d %d %d %d", why, user, l, p, tr, sh, locs, pos, trail, shared)
	}
}

// M2: leaving the server lane, policy off, member removal and key revocation delete
// the member's server copies in the same transaction; shared channel items stay.
func TestServerCopiesDeletedWhenTheLaneEnds(t *testing.T) {
	// pref -> phone
	e := readyLanes(t)
	now := time.Now()
	e.seedCopies("B", e.b, now)
	e.seedCopies("A", e.a, now)
	e.wantCopies("B", e.b, 2, 1, 2, 1, "seeded")
	e.setLane("B", e.b, "phone", 0, 200)
	e.wantCopies("B", e.b, 0, 0, 0, 0, "after leaving the server lane")
	e.wantCopies("A", e.a, 2, 1, 2, 1, "A untouched by B leaving")
	// policy off removes everyone's
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, false, "phone", "allowed", 1, e.a), 200)
	e.wantCopies("A", e.a, 0, 0, 0, 0, "after the policy was turned off")
}

func TestServerCopiesDeletedOnMemberRemovalAndKeyRevoke(t *testing.T) {
	e := readyLanes(t)
	now := time.Now()
	e.seedCopies("B", e.b, now)
	e.seedCopies("A", e.a, now)
	e.sql(`DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	e.wantCopies("B", e.b, 0, 0, 0, 0, "after removal")
	// A's phone key is revoked: the pref it signed goes and so do A's copies.
	e.mustCode("A", "DELETE", "/e2ee/devices/"+e.a.id, simpleAction(t, e2ee.ActRevoke, e.a, "", 0, e.a.id, e.a.fp), 200)
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["A"]) != 0 {
		t.Fatal("a pref signed by a revoked key survived")
	}
	e.wantCopies("A", e.a, 0, 0, 0, 0, "after the signing key was revoked")
}

func TestLegacyConsentWithdrawalDeletesCopies(t *testing.T) {
	e := readyEnv(t)
	if c, m, _ := e.ingest(e.point("fix", e.b, time.Now(), 40.3, -80.3)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatal("seed")
	}
	e.mustCode("B", "DELETE", "/circles/"+e.circle+"/e2ee/server-consent", nil, 200)
	if e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1 AND l.e2ee_circle_id = $2`, e.ids["B"], e.circle) != 0 {
		t.Fatal("legacy consent withdrawal left server copies")
	}
}

// M2: the platform-admin paths honour the lane gate.
func TestPlatformAdminPathsHideMembersWhoKeepDataOnPhone(t *testing.T) {
	e := readyLanes(t)
	e.route("GET", "/api/admin/members/{id}/history", e.srv.AdminGetMemberHistory)
	e.route("GET", "/api/admin/members/{id}/history/export", e.srv.AdminExportMemberHistory)
	e.srv.AdminLocationAccess = true // the operator opted in; the lane gate still applies
	now := time.Now().UTC()
	// C keeps data on the phone but has an old plaintext row (from before) and a last position.
	var dev string
	if err := e.pool.QueryRow(context.Background(), `INSERT INTO devices (user_id, platform, name) VALUES ($1, 'android', 'x') RETURNING id::text`, e.ids["C"]).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	e.locAt(dev, now.Add(-time.Minute), 41.5, nil)
	e.sql(`UPDATE member_positions SET lat = 41.5, lon = 5, ts = $2 WHERE user_id = $1`, e.ids["C"], now.Add(-time.Minute))
	q := "?from=" + now.Add(-time.Hour).Format(time.RFC3339) + "&to=" + now.Add(time.Hour).Format(time.RFC3339)
	for _, p := range []string{"/api/admin/members/" + e.ids["C"] + "/history" + q, "/api/admin/members/" + e.ids["C"] + "/history/export" + q + "&format=csv"} {
		if c, _, raw := e.do("A", "GET", p, nil); c != 403 || !strings.Contains(string(raw), "keeps_data_on_phone") {
			t.Fatalf("%s: %d %s", p, c, raw)
		}
	}
	// A server-lane member is still readable by the admin paths.
	e.ingest(e.point("fix", e.b, now, 40.5, -80.5))
	if c, _, raw := e.do("A", "GET", "/api/admin/members/"+e.ids["B"]+"/history"+q, nil); c != 200 {
		t.Fatalf("server-lane member history: %d %s", c, raw)
	}
	snap, err := e.srv.adminMembersSnapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range snap {
		if m.ID == e.ids["C"] && (m.Lat != nil || m.Lon != nil || m.TS != nil || !m.KeepsDataOnPhone) {
			t.Fatalf("admin snapshot exposes a member who keeps data on phone: %+v", m)
		}
		if m.ID == e.ids["B"] && (m.Lat == nil || m.KeepsDataOnPhone) {
			t.Fatalf("admin snapshot hides a server-lane member: %+v", m)
		}
	}
}

// M3: a legacy consent carries over only if the old every-member rule held.
func TestUpgradeDoesNotCarryOverAPartialConsent(t *testing.T) {
	e := newSrvEnv(t)
	e.pin()
	e.wrapServer()
	e.consent("A", e.a, 200) // A consented, B and C did not
	e.declareLanes2("A", e.a)
	e.declareLanes2("B", e.b)
	e.declareLanes2("C", e.c)
	r := e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/processing-upgrade", e.upgradeBody(false), 200)
	if r["converted"].(float64) != 0 {
		t.Fatalf("a partial consent was converted: %v", r)
	}
	if c, _, raw := e.ingest(e.point("fix", e.a, time.Now(), 40.4, -80.4)); c != 409 {
		t.Fatalf("A was ingested after the upgrade without a fresh pref: %d %s", c, raw)
	}
	// A signs a fresh pref (and the server gets SK): now A is ingested; B is not.
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	if c, m, raw := e.ingest(e.point("fix", e.a, time.Now(), 40.4, -80.4), e.point("fix", e.b, time.Now(), 40.5, -80.5)); c != 200 || m["stored"].(float64) != 1 || rejectedCount(m, "lane_not_server") != 1 {
		t.Fatalf("%d %s", c, raw)
	}
}

// M3: converted prefs expire, and die with their signing key.
func TestLegacyConvertedPrefsAreBounded(t *testing.T) {
	e := readyEnv(t)
	e.declareLanes2("A", e.a)
	e.declareLanes2("B", e.b)
	e.declareLanes2("C", e.c)
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/processing-upgrade", e.upgradeBody(true), 200)
	var until *time.Time
	if err := e.pool.QueryRow(context.Background(), `SELECT valid_until FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]).Scan(&until); err != nil || until == nil ||
		until.Before(time.Now().Add(29*24*time.Hour)) || until.After(time.Now().Add(31*24*time.Hour)) {
		t.Fatalf("legacy pref validity: %v %v", until, err)
	}
	now := time.Now()
	if c, m, _ := e.ingest(e.point("fix", e.b, now, 40.6, -80.6)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatal("converted pref not usable")
	}
	e.sql(`UPDATE e2ee_processing_pref SET valid_until = now() - interval '1 minute' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	if c, m, _ := e.ingest(e.point("fix", e.b, now.Add(time.Second), 40.7, -80.7), e.point("fix", e.c, now.Add(time.Second), 40.8, -80.8)); c != 200 || m["stored"].(float64) != 1 || rejectedCount(m, "lane_not_server") != 1 {
		t.Fatalf("expired converted pref still used: %v", m)
	}
	// Re-signing makes B usable again and removes the expiry.
	e.setLane("B", e.b, "server", 1, 200)
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2 AND valid_until IS NULL AND NOT legacy`, e.circle, e.ids["B"]) != 1 {
		t.Fatal("fresh pref did not replace the converted one")
	}
	// Revoking C's signing key kills the converted pref and removes C's copies.
	e.mustCode("C", "DELETE", "/e2ee/devices/"+e.c.id, simpleAction(t, e2ee.ActRevoke, e.c, "", 0, e.c.id, e.c.fp), 200)
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"]) != 0 ||
		e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1 AND l.e2ee_circle_id = $2`, e.ids["C"], e.circle) != 0 {
		t.Fatal("converted pref or copies survived the key revocation")
	}
}

// L1: the admin can end the server's access to the old phone-key epochs.
func TestFinishLegacyServerAccess(t *testing.T) {
	e := readyEnv(t)
	e.declareLanes2("A", e.a)
	e.declareLanes2("B", e.b)
	e.declareLanes2("C", e.c)
	fin := "/circles/" + e.circle + "/e2ee/legacy-server-access"
	e.mustCode("A", "DELETE", fin, nil, 409) // still legacy
	e.mustCode("A", "POST", "/circles/"+e.circle+"/e2ee/processing-upgrade", e.upgradeBody(true), 200)
	holds := `SELECT count(*) FROM circle_key_wraps w JOIN device_keys d ON d.device_id = w.recipient_device_id WHERE w.circle_id = $1 AND d.kind = 'server' AND w.key_line = 'phone'`
	if e.count(holds, e.circle) == 0 {
		t.Fatal("test premise: the server still holds the epoch-1 phone key")
	}
	e.mustCode("B", "DELETE", fin, nil, 403)
	r := e.mustCode("A", "DELETE", fin, nil, 200)
	if r["wraps_removed"].(float64) < 1 || e.count(holds, e.circle) != 0 {
		t.Fatalf("%v", r)
	}
	// SK keeps working.
	if c, m, _ := e.ingest(e.point("fix", e.b, time.Now(), 40.9, -80.9)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatal("ending old-epoch access broke server-lane ingest")
	}
}

// L5: the policy signer must still be a circle admin; a lane withdrawal committed
// while an ingest batch waits is honoured; the item relay uses the same checks.
func TestPolicySignerMustStillBeAdmin(t *testing.T) {
	e := readyLanes(t)
	now := time.Now()
	e.sql(`UPDATE circle_members SET role = 'member' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["A"])
	if c, _, raw := e.ingest(e.point("fix", e.b, now, 40.1, -80.1)); c != 409 {
		t.Fatalf("ingest under a policy whose signer is no longer an admin: %d %s", c, raw)
	}
	rs := results(e.mustCode("B", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.b.id,
		"items": []any{e.sealV2(e.b, e.serverLine(), 1, 1, "fix")}}, 200))
	if rs[0]["status"] != "rejected" {
		t.Fatalf("server-line relay under a stale policy: %v", rs)
	}
	e.sql(`UPDATE circle_members SET role = 'admin' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["A"])
	if c, m, _ := e.ingest(e.point("fix", e.b, now, 40.1, -80.1)); c != 200 || m["stored"].(float64) != 1 {
		t.Fatal("ingest did not resume")
	}
}

func TestMidBatchLaneWithdrawalIsHonoured(t *testing.T) {
	e := readyLanes(t)
	ctx := context.Background()
	tx, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	// A pref change in flight: it holds the circle row exclusively.
	if _, err := tx.Exec(ctx, `SELECT 1 FROM circles WHERE id = $1 FOR UPDATE`, e.circle); err != nil {
		t.Fatal(err)
	}
	type res struct {
		code int
		m    map[string]any
	}
	done := make(chan res, 1)
	go func() {
		c, m, _ := e.ingest(e.point("fix", e.b, time.Now(), 40.1, -80.1), e.point("fix", e.a, time.Now(), 40.2, -80.2))
		done <- res{c, m}
	}()
	select {
	case <-done:
		t.Fatal("ingest did not wait for the in-flight pref change")
	case <-time.After(500 * time.Millisecond):
	}
	if _, err := tx.Exec(ctx, `UPDATE e2ee_processing_pref SET lane = 'phone' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"]); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.code != 200 || r.m["stored"].(float64) != 1 || rejectedCount(r.m, "lane_not_server") != 1 {
		t.Fatalf("a point of a member who withdrew mid-batch landed: %d %v", r.code, r.m)
	}
	if e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1 AND l.e2ee_circle_id = $2`, e.ids["B"], e.circle) != 0 {
		t.Fatal("B has server copies")
	}
}

// L6: capabilities are monotonic.
func TestCapsCannotBeDowngraded(t *testing.T) {
	e := newLaneEnv(t)
	r := e.mustCode("B", "PUT", "/e2ee/devices/"+e.b.id+"/caps", map[string]any{"caps": []string{}}, 200)
	if cs, _ := r["caps"].([]any); len(cs) != 1 || cs[0] != "lanes2" {
		t.Fatalf("an empty list cleared the capability: %v", r)
	}
	e.mustCode("B", "PUT", "/e2ee/devices/"+e.b.id+"/caps", map[string]any{"caps": []string{"unknown"}}, 200)
	if e.count(`SELECT count(*) FROM device_keys WHERE device_id = $1 AND caps = ARRAY['lanes2']`, e.b.id) != 1 {
		t.Fatal("caps changed")
	}
}

// L7: a signed statement is accepted once.
func TestStatementsCannotBeReplayed(t *testing.T) {
	e := newLaneEnv(t)
	pol := "/circles/" + e.circle + "/e2ee/processing-policy"
	pb := policyBody(t, e.circle, true, "phone", "allowed", 1, e.a, mkSKWrap(t, e.circle, 1, e.a, e.a))
	e.mustCode("A", "PUT", pol, pb, 200)
	// Replaying the very same policy body (same nonce) is refused even where it would otherwise be a no-op.
	if c, m, _ := e.do("A", "PUT", pol, pb); c != 409 || m["code"] != "nonce_reused" {
		t.Fatalf("policy replay: %d %v", c, m)
	}
	pref := "/circles/" + e.circle + "/e2ee/processing-pref"
	body := e.prefBody(e.b, "server", 1)
	e.mustCode("B", "PUT", pref, body, 200)
	e.setLane("B", e.b, "phone", 0, 200)
	if c, m, _ := e.do("B", "PUT", pref, body); c != 409 || m["code"] != "nonce_reused" {
		t.Fatalf("pref replay (re-enabling the server lane with an old statement): %d %v", c, m)
	}
	if e.count(`SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2 AND lane = 'server'`, e.circle, e.ids["B"]) != 0 {
		t.Fatal("replayed pref took effect")
	}
}

// L8: the state endpoint reports every member with a fixed number of queries; correctness with many members.
func TestProcessingStateManyMembers(t *testing.T) {
	e := readyLanes(t)
	st := e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	ms := st["members"].([]any)
	lanes := map[string]string{}
	for _, x := range ms {
		mm := x.(map[string]any)
		lanes[mm["user_id"].(string)] = mm["lane"].(string)
	}
	if lanes[e.ids["A"]] != "server" || lanes[e.ids["B"]] != "server" || lanes[e.ids["C"]] != "phone" {
		t.Fatalf("lanes: %v", lanes)
	}
}

// Phone-computed result purposes are ordinary items: same lane rules, and a new
// signed-policy history is served.
func TestResultPurposesAndPolicyHistory(t *testing.T) {
	e := readyLanes(t)
	for i, p := range []string{"trip", "drive", "week"} {
		r := results(e.post("B", e.b, e.circle, 201, e.sealV2(e.b, e.serverLine(), 1, int64(90+i), p), e.sealV2(e.b, e.phoneLine(), 1, int64(95+i), p)))
		if r[0]["status"] != "stored" || r[1]["status"] != "stored" {
			t.Fatalf("%s: %v", p, r)
		}
	}
	// C (phone lane) may not seal results under SK.
	rs := results(e.mustCode("C", "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": e.c.id,
		"items": []any{e.sealV2(e.c, e.serverLine(), 1, 1, "trip")}}, 200))
	if rs[0]["status"] != "rejected" {
		t.Fatalf("%v", rs)
	}
	// Leaving the lane removes B's server-line results as part of the copies.
	e.setLane("B", e.b, "phone", 0, 200)
	if e.count(`SELECT count(*) FROM e2ee_items WHERE circle_id = $1 AND device_id = $2 AND key_line = 'server' AND purpose IN ('trip','drive','week')`, e.circle, e.b.id) != 0 {
		t.Fatal("server-line results survived leaving the lane")
	}
	// Rotate to generation 2, then the history shows both generations.
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "allowed", 2, e.a, mkSKWrap(t, e.circle, 2, e.a, e.a), mkSKWrap(t, e.circle, 2, e.a, e.s)), 200)
	st := e.mustCode("C", "GET", "/circles/"+e.circle+"/e2ee/processing", nil, 200)
	h := st["policy"].(map[string]any)["history"].([]any)
	if len(h) != 2 || h[0].(map[string]any)["sk_gen"].(float64) != 1 || h[1].(map[string]any)["sk_gen"].(float64) != 2 {
		t.Fatalf("policy history: %v", h)
	}
	// Query values the phone sends.
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/wraps?device_id="+e.a.id+"&key_line=all", nil, 200)
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/items?key_line=all", nil, 200)
	e.mustCode("A", "GET", "/circles/"+e.circle+"/e2ee/pending?key_line=server", nil, 200)
}


// Concurrency: every purge path waits for an in-flight ingest batch (which holds the
// circle row FOR SHARE) and then removes what that batch wrote.
func (e *srvEnv) inflightIngest(t *testing.T) (write func(), commit func()) {
	t.Helper()
	ctx := context.Background()
	tx, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })
	if _, err := tx.Exec(ctx, `SELECT 1 FROM circles WHERE id = $1 FOR SHARE`, e.circle); err != nil {
		t.Fatal(err)
	}
	var dev string
	if err := e.pool.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1, 'android', 'x') RETURNING id::text`, e.ids["B"]).Scan(&dev); err != nil {
		t.Fatal(err)
	}
	write = func() {
		if _, err := tx.Exec(ctx, `INSERT INTO locations (device_id, ts, geom, source, e2ee_circle_id) VALUES ($1, now(), ST_SetSRID(ST_MakePoint(5, 6), 4326), 'e2ee_server', $2)`, dev, e.circle); err != nil {
			t.Fatal(err)
		}
	}
	return write, func() {
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
}

func (e *srvEnv) purgeWaitsForIngest(t *testing.T, name string, purge func()) {
	t.Helper()
	write, commit := e.inflightIngest(t)
	done := make(chan struct{})
	go func() { purge(); close(done) }()
	select {
	case <-done:
		t.Fatalf("%s did not wait for the in-flight ingest batch", name)
	case <-time.After(500 * time.Millisecond):
	}
	write() // a row the batch writes while the purge is queued
	commit()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatalf("%s never finished", name)
	}
	if n := e.count(`SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = $1 AND l.e2ee_circle_id = $2`, e.ids["B"], e.circle); n != 0 {
		t.Fatalf("%s: %d row(s) written by the in-flight batch survived the purge", name, n)
	}
}

func TestPurgeOnKeyRevocationSerialisesWithIngest(t *testing.T) {
	e := readyLanes(t)
	e.purgeWaitsForIngest(t, "key revocation", func() {
		e.do("B", "DELETE", "/e2ee/devices/"+e.b.id, simpleAction(t, e2ee.ActRevoke, e.b, "", 0, e.b.id, e.b.fp))
	})
}

func TestPurgeOnMemberRemovalSerialisesWithIngest(t *testing.T) {
	e := readyLanes(t)
	e.purgeWaitsForIngest(t, "member removal", func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	})
}

// A bare pref change (no circle lock taken by the caller) is serialised by the purge itself.
func TestPurgeOnPrefChangeSerialisesWithIngest(t *testing.T) {
	e := readyLanes(t)
	e.purgeWaitsForIngest(t, "pref change", func() {
		_, _ = e.pool.Exec(context.Background(), `UPDATE e2ee_processing_pref SET lane = 'phone' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	})
}

func TestPurgeOnPolicyOffSerialisesWithIngest(t *testing.T) {
	e := readyLanes(t)
	e.purgeWaitsForIngest(t, "policy off", func() {
		e.do("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy", policyBody(t, e.circle, false, "phone", "allowed", 1, e.a))
	})
}
