package handlers

import (
	"context"
	"crypto/ed25519"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// The owner policy "require server processing" (ADR 16.1) and its ONE narrow catch-up exception:
// a member whose own signed server pref went stale because the server key was replaced less than
// 72 hours ago. Handler (Go, signatures re-verified) and the e2ee_item_guard trigger (SQL) enforce
// the same rule. Needs TEST_DATABASE_URL.

var catchSeq int64 = 1000

func nextCatchSeq() int64 { return atomic.AddInt64(&catchSeq, 1) }

// requiredEnv: required_server circle, A and B signed the server lane (gen 1), C never chose.
func requiredEnv(t *testing.T) *srvEnv {
	e := newLaneEnv(t)
	e.enableAssist("required_server")
	e.setLane("A", e.a, "server", 1, 200)
	e.wrapSKToServer(1, 200)
	e.setLane("B", e.b, "server", 1, 200)
	return e
}

// phoneItem posts one phone-line item through the handler: status and error code.
func (e *srvEnv) phoneItem(user string, d *tdev, purpose string) (string, string) {
	e.t.Helper()
	code, m, raw := e.do(user, "POST", "/circles/"+e.circle+"/e2ee/batch", map[string]any{"sender_device_id": d.id,
		"items": []any{e.sealV2(d, e.phoneLine(), 1, nextCatchSeq(), purpose)}})
	if code != 200 && code != 201 {
		e.t.Fatalf("batch: %d %s", code, raw)
	}
	r := results(m)[0]
	s, _ := r["error"].(string)
	return r["status"].(string), s
}

// sqlPhoneItem inserts one phone-line item straight into the table (the trigger is the judge) and rolls back.
func (e *srvEnv) sqlPhoneItem(d *tdev, purpose string) error {
	e.t.Helper()
	tx, err := e.pool.Begin(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	_, err = tx.Exec(context.Background(), `INSERT INTO e2ee_items (circle_id, device_id, seq, purpose, epoch, size_bucket, ciphertext, received_at)
		VALUES ($1,$2,$3,$4,1,256,'\x00',now())`, e.circle, d.id, nextCatchSeq(), purpose)
	return err
}

func (e *srvEnv) sqlCatching(user string) bool {
	e.t.Helper()
	var b bool
	if err := e.pool.QueryRow(context.Background(), `SELECT e2ee_member_catching_up($1::uuid, $2::uuid)`, e.circle, e.ids[user]).Scan(&b); err != nil {
		e.t.Fatal(err)
	}
	return b
}

// wantRefused / wantRelayed check handler and trigger together.
func (e *srvEnv) wantRefused(why, user string, d *tdev, sqlToo bool) {
	e.t.Helper()
	if st, code := e.phoneItem(user, d, "fix"); st != "rejected" || code != "required_server" {
		e.t.Fatalf("%s: %s: handler relayed or refused for another reason: %s %s", user, why, st, code)
	}
	if sqlToo {
		if err := e.sqlPhoneItem(d, "fix"); err == nil || !strings.Contains(err.Error(), "e2ee_required_server") {
			e.t.Fatalf("%s: %s: trigger accepted it: %v", user, why, err)
		}
	}
}

func (e *srvEnv) wantRelayed(why, user string, d *tdev) {
	e.t.Helper()
	if st, code := e.phoneItem(user, d, "fix"); st != "stored" {
		e.t.Fatalf("%s: %s: handler refused: %s %s", user, why, st, code)
	}
	if err := e.sqlPhoneItem(d, "fix"); err != nil {
		e.t.Fatalf("%s: %s: trigger refused: %v", user, why, err)
	}
}

// exemptPurposesPass: check-ins, events and chat are never blocked.
func (e *srvEnv) exemptPurposesPass(user string, d *tdev) {
	e.t.Helper()
	for _, p := range []string{"checkin", "event", "chat"} {
		if st, code := e.phoneItem(user, d, p); st != "stored" {
			e.t.Fatalf("%s: %s blocked in a required_server circle: %s %s", user, p, st, code)
		}
		if err := e.sqlPhoneItem(d, p); err != nil {
			e.t.Fatalf("%s: trigger blocked %s: %v", user, p, err)
		}
	}
}

func (e *srvEnv) revokeServerKey(ago string) {
	e.sql(`UPDATE device_keys SET revoked_at = now() - $2::interval WHERE device_id = $1`, e.s.id, ago)
}

func (e *srvEnv) wantFlags(user, member string, stale, catching bool) {
	e.t.Helper()
	mo, _ := e.memberOut(user, member)
	if (mo["pref_stale"] == true) != stale || (mo["catching_up"] == true) != catching {
		e.t.Fatalf("state of %s: want pref_stale=%v catching_up=%v, got %v", member, stale, catching, mo)
	}
}

func TestRequiredServerNeverConsentedIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.wantRefused("never chose", "C", e.c, true)
	e.exemptPurposesPass("C", e.c)
	e.wantFlags("A", "C", false, false)
	// Even right after a key replacement a member with no pref gets no exception.
	e.revokeServerKey("0 seconds")
	e.wantRefused("never chose, key just replaced", "C", e.c, true)
	e.wantFlags("A", "C", false, false)
}

func TestRequiredServerWithdrawnLanePhoneIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.setLane("B", e.b, "phone", 0, 200)
	e.wantRefused("withdrew (lane phone)", "B", e.b, true)
	e.exemptPurposesPass("B", e.b)
	e.revokeServerKey("0 seconds")
	e.wantRefused("withdrew, key just replaced", "B", e.b, true)
	e.wantFlags("A", "B", false, false)
}

func TestRequiredServerStalePrefInsideTheWindowIsRelayed(t *testing.T) {
	e := requiredEnv(t)
	e.wantRelayed("lane server on the pinned key (the normal case)", "B", e.b)
	// The server key is revoked (replaced) just now: B's pref names a revoked key.
	e.revokeServerKey("0 seconds")
	if !e.sqlCatching("B") {
		t.Fatal("SQL does not see B as catching up")
	}
	e.wantRelayed("revoked server key, 1 minute", "B", e.b)
	e.wantFlags("A", "B", true, true)
	e.exemptPurposesPass("B", e.b)
	// C is not helped by B's situation.
	e.wantRefused("never chose", "C", e.c, true)
	// Inside the window, 71 hours after the replacement.
	e.revokeServerKey("71 hours")
	e.wantRelayed("revoked server key, 71 hours", "B", e.b)
	e.wantFlags("A", "B", true, true)
}

func TestRequiredServerStalePrefPastTheWindowIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.revokeServerKey("73 hours")
	if e.sqlCatching("B") {
		t.Fatal("SQL still sees B as catching up after 73 hours")
	}
	e.wantRefused("revoked server key, 73 hours", "B", e.b, true)
	// Stale is still reported (the phone must renew), but it is not "catching up" any more.
	e.wantFlags("A", "B", true, false)
	e.exemptPurposesPass("B", e.b)
}

// The server key is replaced by another one that is pinned; the old one is NOT revoked here, so the
// only record of the replacement is e2ee_server_device.set_at.
func TestRequiredServerReplacedPinnedKeyWindowFollowsSetAt(t *testing.T) {
	e := requiredEnv(t)
	s2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s2, "server", e.a, e2ee.ActRegister, false), 201)
	e.sql(`UPDATE e2ee_server_device SET device_id = $1, set_at = now() - interval '2 hours'`, s2.id)
	if e.count(`SELECT count(*) FROM device_keys WHERE device_id = $1 AND revoked_at IS NULL`, e.s.id) != 1 {
		t.Fatal("fixture: the old key must still be active")
	}
	e.wantRelayed("pinned key replaced 2 hours ago", "B", e.b)
	e.wantFlags("A", "B", true, true)
	e.sql(`UPDATE e2ee_server_device SET set_at = now() - interval '73 hours'`)
	e.wantRefused("pinned key replaced 73 hours ago", "B", e.b, true)
	e.wantFlags("A", "B", true, false)
}

// An older SK generation alone: the replacement time is circles.e2ee_server_gen_at (stamped by a trigger
// whenever the generation changes). A pref of an older generation still counts as lane server for
// ingestion (existing rule), so this is checked at the definition itself (SQL function and Go).
func TestCatchUpDefinitionForAnOlderGeneration(t *testing.T) {
	e := requiredEnv(t)
	e.sql(`UPDATE circles SET e2ee_server_gen = 2 WHERE id = $1`, e.circle)
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND e2ee_server_gen_at > now() - interval '1 minute'`, e.circle) != 1 {
		t.Fatal("the generation change was not stamped")
	}
	if !e.sqlCatching("B") {
		t.Fatal("older generation, just rotated: SQL")
	}
	stale, catching, err := memberStates(context.Background(), e.pool, e.circle, "")
	if err != nil || !stale[e.ids["B"]] || !catching[e.ids["B"]] || stale[e.ids["C"]] {
		t.Fatalf("Go: stale=%v catching=%v err=%v", stale, catching, err)
	}
	e.sql(`UPDATE circles SET e2ee_server_gen_at = now() - interval '73 hours' WHERE id = $1`, e.circle)
	stale, catching, _ = memberStates(context.Background(), e.pool, e.circle, "")
	if e.sqlCatching("B") || !stale[e.ids["B"]] || catching[e.ids["B"]] {
		t.Fatalf("older generation, 73 h: SQL=%v Go stale=%v catching=%v", e.sqlCatching("B"), stale, catching)
	}
	// An unknown time is never recent.
	e.sql(`UPDATE circles SET e2ee_server_gen_at = NULL WHERE id = $1`, e.circle)
	stale, catching, _ = memberStates(context.Background(), e.pool, e.circle, "")
	if e.sqlCatching("B") || !stale[e.ids["B"]] || catching[e.ids["B"]] {
		t.Fatal("an unrecorded replacement time counted as recent")
	}
}

func TestRequiredServerExpiredPrefIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.revokeServerKey("0 seconds")
	e.sql(`UPDATE e2ee_processing_pref SET valid_until = now() - interval '1 minute' WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	e.wantRefused("expired pref", "B", e.b, true)
	e.wantFlags("A", "B", false, false)
}

// A pref row planted in the database without a valid signature, or signed but never submitted to the key log,
// never counts for the handler (SQL cannot verify signatures; the handler does).
func TestRequiredServerForgedOrUnsignedPrefIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.revokeServerKey("0 seconds")
	plant := func(sig []byte, nonce []byte) {
		e.sql(`DELETE FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["C"])
		e.sql(`INSERT INTO e2ee_processing_pref (circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id, signature, legacy, log_seq)
			VALUES ($1,$2,'server',1,$3,$4,$5,$6,$7,FALSE,NULL)`, e.circle, e.ids["C"], e.s.id, e.s.fp, nonce, e.c.id, sig)
	}
	// 1. random signature
	plant(randBytes(64), randBytes(16))
	if !e.sqlCatching("C") {
		t.Fatal("fixture: SQL should be fooled by a planted row (it cannot verify signatures)")
	}
	e.wantRefused("random signature", "C", e.c, false)
	e.wantFlags("A", "C", false, false)
	// 2. a genuine signature by C's own key, but the row was planted: it is not C's latest entry in the key log
	nonce := randBytes(16)
	msg, err := e2ee.ProcessingPrefMessage(e.circle, e.ids["C"], e2ee.LineServer, 1, e.s.id, e.s.fp, nonce)
	if err != nil {
		t.Fatal(err)
	}
	plant(ed25519.Sign(e.c.priv, msg), nonce)
	e.wantRefused("signed but never logged", "C", e.c, false)
	e.wantFlags("A", "C", false, false)
	// 3. a genuine pref of B whose signature is replaced by garbage after the fact
	e.sql(`UPDATE e2ee_processing_pref SET signature = $3 WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"], randBytes(64))
	e.wantRefused("tampered signature", "B", e.b, false)
	e.wantFlags("A", "B", false, false)
}

// Not the original signature for the key the row names: another fingerprint.
func TestRequiredServerPrefWithWrongFingerprintIsRefused(t *testing.T) {
	e := requiredEnv(t)
	e.revokeServerKey("0 seconds")
	e.sql(`UPDATE e2ee_processing_pref SET server_fingerprint = $3 WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"], randBytes(32))
	e.wantRefused("wrong fingerprint", "B", e.b, false)
}

func TestRequiredServerRevokedApproverIsRefused(t *testing.T) {
	e := requiredEnv(t)
	// B gets a second phone; the phone that signed the pref is revoked afterwards.
	b2 := newTDev(t, e.ids["B"])
	body := regBody(t, b2, "device", e.b, e2ee.ActRegister, false)
	body["caps"] = []string{"lanes2"}
	e.mustCode("B", "POST", "/e2ee/devices", body, 201)
	e.approveByAdmin(b2, e.a)
	e.revokeServerKey("0 seconds")
	e.wantRelayed("approver still live", "B", b2)
	e.sql(`UPDATE device_keys SET revoked_at = now() WHERE device_id = $1`, e.b.id)
	if e.sqlCatching("B") {
		t.Fatal("SQL counts a pref whose approver key is revoked")
	}
	e.wantRefused("approver revoked", "B", b2, true)
	e.wantFlags("A", "B", false, false)
}

func TestRequiredServerRemovedMemberIsNotCatchingUp(t *testing.T) {
	e := requiredEnv(t)
	e.revokeServerKey("0 seconds")
	if !e.sqlCatching("B") {
		t.Fatal("fixture")
	}
	e.sql(`DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, e.circle, e.ids["B"])
	if e.sqlCatching("B") {
		t.Fatal("a removed member counts as catching up")
	}
}

// The renewed pref ends the exception: B signs for the new key and is a normal server-lane member again.
func TestRequiredServerRenewedPrefIsNotCatchingUp(t *testing.T) {
	e := requiredEnv(t)
	oldS := e.s
	s2 := newTDev(t, e.ids["A"])
	e.mustCode("A", "POST", "/e2ee/devices", regBody(t, s2, "server", e.a, e2ee.ActRegister, false), 201)
	e.sql(`UPDATE device_keys SET revoked_at = now() WHERE device_id = $1`, oldS.id)
	e.s = s2
	e.pin()
	e.wantFlags("A", "B", true, true)
	e.wantRelayed("stale, inside the window", "B", e.b)
	e.mustCode("A", "PUT", "/circles/"+e.circle+"/e2ee/processing-policy",
		policyBody(t, e.circle, true, "phone", "required_server", 2, e.a,
			mkSKWrap(t, e.circle, 2, e.a, e.a), mkSKWrap(t, e.circle, 2, e.a, e.b), mkSKWrap(t, e.circle, 2, e.a, e.c), mkSKWrap(t, e.circle, 2, e.a, s2)), 200)
	e.setLane("B", e.b, "server", 2, 200)
	e.wantFlags("A", "B", false, false)
	e.wantRelayed("signed again for the new key", "B", e.b)
}

// Migration 000410 on a database that already applied the earlier 000410 (which had no catch-up rule and no
// required_server clause in the guard): re-applying it is idempotent and installs the rule; down removes it.
func TestCatchUpMigrationOnTopOfTheEarlierVersion(t *testing.T) {
	e := newLaneEnv(t)
	up, err := os.ReadFile("../db/migrations/000410_server_key_across_reset.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	down, err := os.ReadFile("../db/migrations/000410_server_key_across_reset.down.sql")
	if err != nil {
		t.Fatal(err)
	}
	// The earlier 000410: the guard without the required_server clause, no catch-up function, no stamp column.
	earlier := `
DROP TRIGGER IF EXISTS trg_e2ee_server_gen_stamp ON circles;
DROP FUNCTION IF EXISTS e2ee_server_gen_stamp();
CREATE OR REPLACE FUNCTION e2ee_item_guard() RETURNS trigger AS $$
DECLARE
    c circles%ROWTYPE;
    u UUID;
BEGIN
    SELECT * INTO c FROM circles WHERE id = NEW.circle_id;
    SELECT user_id INTO u FROM device_keys WHERE device_id = NEW.device_id;
    IF NEW.purpose = 'chat' AND NEW.key_line <> 'phone' THEN
        RAISE EXCEPTION 'e2ee_chat_phone_only: chat is sealed under the phone key only' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.key_line = 'server' THEN
        IF NOT (c.e2ee_mode = 'private' AND c.server_assist AND e2ee_pref_lane_server(NEW.circle_id, u)) THEN
            RAISE EXCEPTION 'e2ee_lane: a server-line item needs server assistance and an author in lane server' USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        IF c.server_legacy_epoch_max > 0 AND NEW.epoch <= c.server_legacy_epoch_max THEN
            RAISE EXCEPTION 'e2ee_legacy_epoch_closed: this key epoch is closed' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP FUNCTION IF EXISTS e2ee_member_catching_up(UUID, UUID);
ALTER TABLE circles DROP COLUMN IF EXISTS e2ee_server_gen_at;`
	e.sql(earlier)
	e.enableAssist("required_server")
	if err := e.sqlPhoneItem(e.c, "fix"); err != nil {
		t.Fatalf("fixture: the earlier version should accept the item: %v", err)
	}
	for i := 0; i < 3; i++ {
		e.sql(string(up))
	}
	if err := e.sqlPhoneItem(e.c, "fix"); err == nil || !strings.Contains(err.Error(), "e2ee_required_server") {
		t.Fatalf("after the migration the guard still accepts it: %v", err)
	}
	if e.count(`SELECT count(*) FROM information_schema.columns WHERE table_name = 'circles' AND column_name = 'e2ee_server_gen_at'`) != 1 {
		t.Fatal("no stamp column")
	}
	// The generation stamp fires only when the generation changes.
	e.sql(`UPDATE circles SET e2ee_server_gen_at = NULL WHERE id = $1`, e.circle)
	e.sql(`UPDATE circles SET e2ee_mode = e2ee_mode WHERE id = $1`, e.circle)
	if e.count(`SELECT count(*) FROM circles WHERE id = $1 AND e2ee_server_gen_at IS NULL`, e.circle) != 1 {
		t.Fatal("the stamp fired without a generation change")
	}
	// down twice, then up again: still consistent.
	e.sql(string(down))
	e.sql(string(down))
	if e.count(`SELECT count(*) FROM pg_proc WHERE proname IN ('e2ee_member_catching_up', 'e2ee_server_gen_stamp')`) != 0 {
		t.Fatal("down left functions behind")
	}
	e.sql(string(up))
	if err := e.sqlPhoneItem(e.c, "fix"); err == nil || !strings.Contains(err.Error(), "e2ee_required_server") {
		t.Fatalf("after down+up: %v", err)
	}
}
