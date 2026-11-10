package e2ee

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// testdata/lanes.json is the shared cross-language vector file for the
// processing-lanes formats (docs/design/PRIVACY_PROCESSING.md, "Phase 1 API").
// Go generates it (UPDATE_VECTORS=1 go test ./internal/e2ee/ -run Lanes); the
// Dart tests (app/test/services/e2ee/e2ee_lanes_test.dart) must reproduce every
// positive value and reject every negative one.
const lanesVectorPath = "testdata/lanes.json"

const (
	devSrv = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
	uidAdm = "33333333-3333-4333-8333-333333333333"
)

type lItem struct {
	Name       string `json:"name"`
	KeyHex     string `json:"key_hex"`
	Line       int    `json:"line"`
	Gen        uint32 `json:"gen"`
	Purpose    string `json:"purpose"`
	Seq        uint64 `json:"seq"`
	TsMs       uint64 `json:"ts_ms"`
	BodyHex    string `json:"body_hex"`
	NonceHex   string `json:"nonce_hex"`
	AADHex     string `json:"aad_hex"`
	SignedHex  string `json:"signed_message_hex"`
	PayloadHex string `json:"payload_hex"`
}

type lWrap struct {
	Name          string `json:"name"`
	Line          int    `json:"line"`
	Gen           uint32 `json:"gen"`
	KeyHex        string `json:"key_hex"`
	EphemeralHex  string `json:"ephemeral_secret_hex"`
	NonceHex      string `json:"nonce_hex"`
	AADHex        string `json:"aad_hex"`
	BlobHex       string `json:"blob_hex"`
	SigMessageHex string `json:"sig_message_hex"`
	SigHex        string `json:"sig_hex"`
	CommitmentHex string `json:"commitment_hex"`
}

type lPref struct {
	Name           string `json:"name"`
	Lane           int    `json:"lane"`
	SkGen          uint32 `json:"sk_gen"`
	ServerDeviceID string `json:"server_device_id"`
	ServerFPHex    string `json:"server_fingerprint_hex"`
	NonceHex       string `json:"nonce_hex"`
	MessageHex     string `json:"message_hex"`
	SigHex         string `json:"sig_hex"`
	LogRefHex      string `json:"log_ref_hex"`
	LogMessageHex  string `json:"log_action_message_hex"`
}

type lPolicy struct {
	Name          string `json:"name"`
	ServerAssist  bool   `json:"server_assist"`
	DefaultForNew int    `json:"default_for_new"`
	MemberOptOut  int    `json:"member_opt_out"`
	SkGen         uint32 `json:"sk_gen"`
	CommitmentHex string `json:"commitment_hex"`
	NonceHex      string `json:"nonce_hex"`
	MessageHex    string `json:"message_hex"`
	SigHex        string `json:"sig_hex"`
	LogRefHex     string `json:"log_ref_hex"`
	LogMessageHex string `json:"log_action_message_hex"`
}

// Negative cases: every one MUST be rejected by its operation.
type lNegItem struct {
	Name         string `json:"name"`
	KeyHex       string `json:"key_hex"`
	CircleID     string `json:"circle_id"`
	ExpectLine   int    `json:"expect_line"`
	DeviceID     string `json:"device_id"`
	SenderPubHex string `json:"sender_pub_hex"`
	Purpose      string `json:"purpose"`
	ServerSeq    uint64 `json:"server_seq"`
	PayloadHex   string `json:"payload_hex"`
}

type lNegWrap struct {
	Name              string `json:"name"`
	CircleID          string `json:"circle_id"`
	DeviceID          string `json:"device_id"` // the opening device
	XSecretHex        string `json:"x_secret_hex"`
	XPubHex           string `json:"x_pub_hex"`
	WrapLine          int    `json:"wrap_line"`
	WrapGen           uint32 `json:"wrap_gen"`
	RecipientDeviceID string `json:"recipient_device_id"`
	WrapperDeviceID   string `json:"wrapper_device_id"`
	WrapperPubHex     string `json:"wrapper_pub_hex"`
	BlobHex           string `json:"blob_hex"`
	SigHex            string `json:"sig_hex"`
	WantLine          int    `json:"want_line"`
	WantGen           uint32 `json:"want_gen"`
	CommitmentHex     string `json:"commitment_hex"`
}

type lNegPref struct {
	Name           string `json:"name"`
	PubHex         string `json:"approver_pub_hex"`
	CircleID       string `json:"circle_id"`
	UserID         string `json:"user_id"`
	Lane           int    `json:"lane"`
	SkGen          uint32 `json:"sk_gen"`
	ServerDeviceID string `json:"server_device_id"`
	ServerFPHex    string `json:"server_fingerprint_hex"`
	NonceHex       string `json:"nonce_hex"`
	SigHex         string `json:"sig_hex"`
}

type lNegPolicy struct {
	Name          string `json:"name"`
	PubHex        string `json:"admin_pub_hex"`
	CircleID      string `json:"circle_id"`
	AdminUserID   string `json:"admin_user_id"`
	ServerAssist  bool   `json:"server_assist"`
	DefaultForNew int    `json:"default_for_new"`
	MemberOptOut  int    `json:"member_opt_out"`
	SkGen         uint32 `json:"sk_gen"`
	CommitmentHex string `json:"commitment_hex"`
	NonceHex      string `json:"nonce_hex"`
	SigHex        string `json:"sig_hex"`
}

type lanesVector struct {
	Note        string    `json:"note"`
	CircleID    string    `json:"circle_id"`
	CKHex       string    `json:"ck_hex"`
	SKHex       string    `json:"sk_hex"`
	Sender      lID       `json:"sender"`
	Admin       lID       `json:"admin"`
	Recipient   lID       `json:"recipient"`
	ServerDev   string    `json:"server_device_id"`
	ServerFPHex string    `json:"server_fingerprint_hex"`
	Items       []lItem   `json:"items"`
	Wraps       []lWrap   `json:"wraps"`
	Prefs       []lPref   `json:"prefs"`
	Policies    []lPolicy `json:"policies"`
	Neg         struct {
		Items    []lNegItem   `json:"items"`
		Wraps    []lNegWrap   `json:"wraps"`
		Prefs    []lNegPref   `json:"prefs"`
		Policies []lNegPolicy `json:"policies"`
	} `json:"negative"`
}

type lID struct {
	UserID   string `json:"user_id"`
	DeviceID string `json:"device_id"`
	EdSeed   string `json:"ed_seed_hex"`
	EdPub    string `json:"ed_pub_hex"`
	XSecret  string `json:"x_secret_hex"`
	XPub     string `json:"x_pub_hex"`
}

func hx(b []byte) string { return hex.EncodeToString(b) }

func lid(id ident, user, dev string) lID {
	return lID{user, dev, hx(id.edSeed), hx(id.ed), hx(id.xSecret), hx(id.x)}
}

func mustOf[T any](t *testing.T) func(T, error) T {
	return func(v T, err error) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
}

func mb(t *testing.T) func([]byte, error) []byte { return mustOf[[]byte](t) }

func nonce24(b byte) (n [NonceLen]byte) {
	copy(n[:], bytes.Repeat([]byte{b}, NonceLen))
	return
}

func flip(p []byte, i int, v byte) []byte {
	c := append([]byte{}, p...)
	c[i] = v
	return c
}

func buildLanes(t *testing.T) lanesVector {
	sender, admin, rcpt := mk(t, 1), mk(t, 3), mk(t, 2)
	ck, sk := seed(0x42), seed(0x5a)
	fp := make([]byte, 32)
	for i := range fp {
		fp[i] = byte(0xa0 + i)
	}
	v := lanesVector{
		Note:     "Processing lanes vectors (docs/design/PRIVACY_PROCESSING.md). Generated by backend/internal/e2ee (UPDATE_VECTORS=1 go test -run Lanes). line/lane: 0 phone, 1 server. Dart must reproduce every positive value and reject every negative case.",
		CircleID: circ, CKHex: hx(ck), SKHex: hx(sk),
		Sender: lid(sender, uidA, devA), Admin: lid(admin, uidAdm, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"), Recipient: lid(rcpt, uidB, devB),
		ServerDev: devSrv, ServerFPHex: hx(fp),
	}
	adminDev := v.Admin.DeviceID

	// ---- items
	mkItem := func(name string, key []byte, line Line, gen uint32, purpose string, seq, ts uint64, body []byte, nb byte) (lItem, []byte) {
		n := nonce24(nb)
		payload := mb(t)(SealItemV2(key, circ, line, gen, devA, sender.priv, purpose, seq, ts, body, n))
		msg := mb(t)(ItemSignedMessageV2(circ, line, gen, devA, purpose, seq, ts, body))
		return lItem{name, hx(key), int(line), gen, purpose, seq, ts, hx(body), hx(n[:]),
			hx(ItemAADV2(circ, line, gen, devA, purpose)), hx(msg), hx(payload)}, payload
	}
	body := []byte(`{"lat":52.52,"lon":13.405,"acc":8}`)
	iP, payP := mkItem("phone_line_gen3", ck, LinePhone, 3, "fix", 7, 1700000000123, body, 0x0c)
	iS, payS := mkItem("server_line_gen2", sk, LineServer, 2, "fix", 8, 1700000000456, body, 0x0d)
	v.Items = []lItem{iP, iS}

	// ---- wraps (admin wraps to recipient)
	mkWrap := func(name string, key []byte, line Line, gen uint32, eb, nb byte) (lWrap, []byte, []byte) {
		var esk [32]byte
		copy(esk[:], bytes.Repeat([]byte{eb}, 32))
		n := nonce24(nb)
		aad := mb(t)(WrapAADLine(circ, line, gen, devB, v.Admin.DeviceID))
		blob := mb(t)(WrapWithRandomness(key, rcpt.x, aad, esk, n))
		sm := mb(t)(WrapSigMessageLine(circ, line, gen, devB, v.Admin.DeviceID, blob))
		sig := ed25519.Sign(admin.priv, sm)
		c := mb(t)(KeyCommitmentLine(key, circ, line, gen))
		return lWrap{name, int(line), gen, hx(key), hx(esk[:]), hx(n[:]), hx(aad), hx(blob), hx(sm), hx(sig), hx(c)}, blob, sig
	}
	wS, blobS, sigS := mkWrap("sk_gen2", sk, LineServer, 2, 0x07, 0x09)
	wP, blobP, sigP := mkWrap("ck_v3_gen3", ck, LinePhone, 3, 0x08, 0x0a)
	v.Wraps = []lWrap{wS, wP}
	commitSK, commitCK := mb(t)(KeyCommitmentLine(sk, circ, LineServer, 2)), mb(t)(KeyCommitmentLine(ck, circ, LinePhone, 3))

	// ---- prefs
	userPriv := sender.priv
	mkPref := func(name string, lane Line, gen uint32, srv string, fpb []byte, nb byte) (lPref, []byte) {
		n := bytes.Repeat([]byte{nb}, ProcessingNonceLen)
		m := mb(t)(ProcessingPrefMessage(circ, uidA, lane, gen, srv, fpb, n))
		sig := ed25519.Sign(userPriv, m)
		subj := ""
		if lane == LineServer {
			subj = srv
		}
		lm := mb(t)(LogActionMessage(ActProcessingPref, uidA, devA, circ, subj, gen, ProcessingRef(m)))
		return lPref{name, int(lane), gen, srv, hx(fpb), hx(n), hx(m), hx(sig), hx(ProcessingRef(m)), hx(lm)}, sig
	}
	pS, pSSig := mkPref("lane_server", LineServer, 2, devSrv, fp, 0x11)
	pP, _ := mkPref("lane_phone", LinePhone, 2, zeroUUID, make([]byte, 32), 0x12)
	v.Prefs = []lPref{pS, pP}

	// ---- policies
	mkPol := func(name string, on bool, def Line, oo MemberOptOut, gen uint32, c []byte, nb byte) (lPolicy, []byte) {
		n := bytes.Repeat([]byte{nb}, ProcessingNonceLen)
		m := mb(t)(ProcessingPolicyMessage(circ, uidAdm, on, def, oo, gen, c, n))
		sig := ed25519.Sign(admin.priv, m)
		lm := mb(t)(LogActionMessage(ActProcessingPolicy, uidAdm, adminDev, circ, "", gen, ProcessingRef(m)))
		return lPolicy{name, on, int(def), int(oo), gen, hx(c), hx(n), hx(m), hx(sig), hx(ProcessingRef(m)), hx(lm)}, sig
	}
	polOn, polOnSig := mkPol("assist_on_default_phone_optout_allowed", true, LinePhone, OptOutAllowed, 2, commitSK, 0x21)
	polOff, _ := mkPol("assist_off_never_enabled", false, LinePhone, OptOutAllowed, 0, make([]byte, 32), 0x22)
	polReq, polReqSig := mkPol("assist_on_required_server", true, LineServer, OptOutRequiredServer, 2, commitSK, 0x23)
	v.Policies = []lPolicy{polOn, polOff, polReq}

	// ---- negative items
	ni := func(name string, key []byte, expect Line, dev string, pub []byte, purpose string, seq uint64, payload []byte) lNegItem {
		return lNegItem{name, hx(key), circ, int(expect), dev, hx(pub), purpose, seq, hx(payload)}
	}
	negs := []lNegItem{
		ni("tamper_line_phone_to_server", ck, LineServer, devA, sender.ed, "fix", 7, flip(payP, 1, 1)),
		ni("tamper_line_server_to_phone", sk, LinePhone, devA, sender.ed, "fix", 8, flip(payS, 1, 0)),
		ni("tamper_gen_phone", ck, LinePhone, devA, sender.ed, "fix", 7, flip(payP, 5, 4)),
		ni("tamper_gen_server", sk, LineServer, devA, sender.ed, "fix", 8, flip(payS, 5, 3)),
		ni("line_header_differs_from_expected", sk, LinePhone, devA, sender.ed, "fix", 8, payS),
		ni("ck_item_opened_with_sk_key", sk, LinePhone, devA, sender.ed, "fix", 7, payP),
		ni("sk_item_opened_with_ck_key", ck, LineServer, devA, sender.ed, "fix", 8, payS),
		ni("unknown_line", sk, LineServer, devA, sender.ed, "fix", 8, flip(payS, 1, 2)),
		ni("unknown_version", sk, LineServer, devA, sender.ed, "fix", 8, flip(payS, 0, 3)),
		ni("v1_header_on_v2_payload", ck, LinePhone, devA, sender.ed, "fix", 7, flip(payP, 0, 1)),
		ni("wrong_sender_key", sk, LineServer, devA, rcpt.ed, "fix", 8, payS),
		ni("wrong_device_id", sk, LineServer, devB, sender.ed, "fix", 8, payS),
		ni("wrong_purpose", sk, LineServer, devA, sender.ed, "place", 8, payS),
		ni("wrong_server_seq", sk, LineServer, devA, sender.ed, "fix", 9, payS),
		ni("truncated", sk, LineServer, devA, sender.ed, "fix", 8, payS[:20]),
	}
	// Same 32 key bytes under both lines: the header patch must still fail.
	same := seed(0x77)
	_, paySame := mkItem("same", same, LinePhone, 1, "fix", 1, 1700000000000, body, 0x0e)
	negs = append(negs, ni("same_key_bytes_relabelled_phone_to_server", same, LineServer, devA, sender.ed, "fix", 1, flip(paySame, 1, 1)))
	// A member holding both keys signs for the phone line but seals under the server line.
	{
		msg := mb(t)(ItemSignedMessageV2(circ, LinePhone, 2, devA, "fix", 5, 1700000000000, body))
		sig := ed25519.Sign(sender.priv, msg)
		env := []byte{ItemVersionV2}
		env = append(env, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x00)
		env = append(env, sig...)
		env = append(env, body...)
		padded := mb(t)(Pad(env))
		forged := mb(t)(SealWithNonceV2(sk, circ, LineServer, 2, devA, "fix", padded, nonce24(0x31)))
		negs = append(negs, ni("signature_for_other_line_inside_server_payload", sk, LineServer, devA, sender.ed, "fix", 5, forged))
	}
	v.Neg.Items = negs

	// ---- negative wraps
	nw := func(name string, line Line, gen uint32, wrapper string, wpub []byte, blob, sig []byte, wantLine Line, wantGen uint32, c []byte) lNegWrap {
		return lNegWrap{name, circ, devB, hx(rcpt.xSecret), hx(rcpt.x), int(line), gen, devB, wrapper, hx(wpub), hx(blob), hx(sig), int(wantLine), wantGen, hx(c)}
	}
	admDev := v.Admin.DeviceID
	// legacy v1 CK wrap (v1 AAD) re-signed by the wrapper as an SK wrap
	aadV1 := mb(t)(WrapAAD(circ, 2, devB, admDev))
	var eskL [32]byte
	copy(eskL[:], bytes.Repeat([]byte{0x0b}, 32))
	blobV1 := mb(t)(WrapWithRandomness(ck, rcpt.x, aadV1, eskL, nonce24(0x0f)))
	sigV1asSK := ed25519.Sign(admin.priv, mb(t)(WrapSigMessageLine(circ, LineServer, 2, devB, admDev, blobV1)))
	// CK (v3 phone-line AAD, gen 2) blob re-signed as SK gen 2
	var eskC [32]byte
	copy(eskC[:], bytes.Repeat([]byte{0x0c}, 32))
	aadCK2 := mb(t)(WrapAADLine(circ, LinePhone, 2, devB, admDev))
	blobCK2 := mb(t)(WrapWithRandomness(ck, rcpt.x, aadCK2, eskC, nonce24(0x10)))
	sigCK2asSK := ed25519.Sign(admin.priv, mb(t)(WrapSigMessageLine(circ, LineServer, 2, devB, admDev, blobCK2)))
	commitWrong := mb(t)(KeyCommitmentLine(ck, circ, LineServer, 2))
	v.Neg.Wraps = []lNegWrap{
		nw("ck_wrap_signature_replayed_as_sk", LineServer, 3, admDev, admin.ed, blobP, sigP, LineServer, 3, commitCK),
		nw("ck_wrap_resigned_as_sk_fails_aad", LineServer, 2, admDev, admin.ed, blobCK2, sigCK2asSK, LineServer, 2, commitSK),
		nw("legacy_v1_ck_wrap_resigned_as_sk_fails_aad", LineServer, 2, admDev, admin.ed, blobV1, sigV1asSK, LineServer, 2, commitSK),
		nw("gen_tampered_in_record", LineServer, 3, admDev, admin.ed, blobS, sigS, LineServer, 3, commitSK),
		nw("record_gen_differs_from_wanted", LineServer, 2, admDev, admin.ed, blobS, sigS, LineServer, 3, commitSK),
		nw("record_line_differs_from_wanted", LineServer, 2, admDev, admin.ed, blobS, sigS, LinePhone, 2, commitSK),
		nw("line_tampered_in_record", LinePhone, 2, admDev, admin.ed, blobS, sigS, LinePhone, 2, commitSK),
		nw("commitment_of_other_key", LineServer, 2, admDev, admin.ed, blobS, sigS, LineServer, 2, commitWrong),
		nw("short_commitment", LineServer, 2, admDev, admin.ed, blobS, sigS, LineServer, 2, commitSK[:16]),
		nw("wrong_wrapper_key", LineServer, 2, admDev, sender.ed, blobS, sigS, LineServer, 2, commitSK),
		nw("wrapper_device_id_swapped", LineServer, 2, devA, admin.ed, blobS, sigS, LineServer, 2, commitSK),
	}
	{
		x := nw("not_addressed_to_this_device", LineServer, 2, admDev, admin.ed, blobS, sigS, LineServer, 2, commitSK)
		x.RecipientDeviceID = devA
		v.Neg.Wraps = append(v.Neg.Wraps, x)
	}

	// ---- negative prefs / consent
	np := func(name string, circle, user string, lane Line, gen uint32, srv string, fpb []byte, nb byte, sig []byte) lNegPref {
		return lNegPref{name, hx(sender.ed), circle, user, int(lane), gen, srv, hx(fpb), hx(bytes.Repeat([]byte{nb}, ProcessingNonceLen)), hx(sig)}
	}
	other := "44444444-4444-4444-8444-444444444444"
	fp2 := append([]byte{}, fp...)
	fp2[31] ^= 1
	legacySig := ed25519.Sign(sender.priv, mb(t)(ServerConsentMessage(circ, uidA, devSrv, fp)))
	v.Neg.Prefs = []lNegPref{
		np("moved_to_other_circle", other, uidA, LineServer, 2, devSrv, fp, 0x11, pSSig),
		np("moved_to_other_user", circ, other, LineServer, 2, devSrv, fp, 0x11, pSSig),
		np("gen_changed", circ, uidA, LineServer, 3, devSrv, fp, 0x11, pSSig),
		np("wrong_server_fingerprint", circ, uidA, LineServer, 2, devSrv, fp2, 0x11, pSSig),
		np("wrong_server_device", circ, uidA, LineServer, 2, other, fp, 0x11, pSSig),
		np("lane_flipped_to_phone", circ, uidA, LinePhone, 2, zeroUUID, make([]byte, 32), 0x11, pSSig),
		np("nonce_changed", circ, uidA, LineServer, 2, devSrv, fp, 0x12, pSSig),
		np("unknown_lane", circ, uidA, Line(2), 2, devSrv, fp, 0x11, pSSig),
		np("legacy_consent_signature_as_new", circ, uidA, LineServer, 2, devSrv, fp, 0x11, legacySig),
		np("lane_server_without_fingerprint", circ, uidA, LineServer, 2, devSrv, make([]byte, 32), 0x11, pSSig),
		np("lane_server_gen_zero", circ, uidA, LineServer, 0, devSrv, fp, 0x11, pSSig),
	}

	// ---- negative policies
	npo := func(name string, circle, adm string, on bool, def Line, oo MemberOptOut, gen uint32, c []byte, nb byte, sig []byte) lNegPolicy {
		return lNegPolicy{name, hx(admin.ed), circle, adm, on, int(def), int(oo), gen, hx(c), hx(bytes.Repeat([]byte{nb}, ProcessingNonceLen)), hx(sig)}
	}
	c2 := append([]byte{}, commitSK...)
	c2[0] ^= 1
	v.Neg.Policies = []lNegPolicy{
		npo("other_circle", other, uidAdm, true, LinePhone, OptOutAllowed, 2, commitSK, 0x21, polOnSig),
		npo("other_admin", circ, other, true, LinePhone, OptOutAllowed, 2, commitSK, 0x21, polOnSig),
		npo("assist_flipped_off", circ, uidAdm, false, LinePhone, OptOutAllowed, 2, commitSK, 0x21, polOnSig),
		npo("default_changed", circ, uidAdm, true, LineServer, OptOutAllowed, 2, commitSK, 0x21, polOnSig),
		npo("gen_changed", circ, uidAdm, true, LinePhone, OptOutAllowed, 3, commitSK, 0x21, polOnSig),
		npo("commitment_changed", circ, uidAdm, true, LinePhone, OptOutAllowed, 2, c2, 0x21, polOnSig),
		npo("on_with_zero_commitment", circ, uidAdm, true, LinePhone, OptOutAllowed, 2, make([]byte, 32), 0x21, polOnSig),
		npo("opt_out_flipped_to_required", circ, uidAdm, true, LinePhone, OptOutRequiredServer, 2, commitSK, 0x21, polOnSig),
		npo("opt_out_flipped_to_allowed", circ, uidAdm, true, LineServer, OptOutAllowed, 2, commitSK, 0x23, polReqSig),
		npo("unknown_opt_out", circ, uidAdm, true, LinePhone, MemberOptOut(2), 2, commitSK, 0x21, polOnSig),
		npo("required_server_with_assist_off", circ, uidAdm, false, LineServer, OptOutRequiredServer, 2, commitSK, 0x23, polReqSig),
		npo("pref_signature_as_policy", circ, uidAdm, true, LinePhone, OptOutAllowed, 2, commitSK, 0x21, pSSig),
	}
	return v
}

func marshalLanes(t *testing.T, v lanesVector) []byte {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}

func TestLanesVectorFrozen(t *testing.T) {
	want := marshalLanes(t, buildLanes(t))
	if os.Getenv("UPDATE_VECTORS") == "1" {
		if err := os.WriteFile(lanesVectorPath, want, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(lanesVectorPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("lanes vector changed; the wire format is frozen (UPDATE_VECTORS=1 only for an intentional new vector)")
	}
}

func dh(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func loadLanes(t *testing.T) lanesVector {
	raw, err := os.ReadFile(lanesVectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var v lanesVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// Reads the committed file (not the generator) so a broken verifier cannot hide.
func TestLanesPositiveVectors(t *testing.T) {
	v := loadLanes(t)
	for _, it := range v.Items {
		got, err := OpenItemV2(dh(t, it.KeyHex), v.CircleID, Line(it.Line), v.Sender.DeviceID, dh(t, v.Sender.EdPub), it.Purpose, it.Seq, dh(t, it.PayloadHex))
		if err != nil || got.Gen != it.Gen || got.TsMs != it.TsMs || got.Line != Line(it.Line) || hx(got.Body) != it.BodyHex {
			t.Fatalf("item %s: %v %+v", it.Name, err, got)
		}
		if hx(ItemAADV2(v.CircleID, Line(it.Line), it.Gen, v.Sender.DeviceID, it.Purpose)) != it.AADHex {
			t.Fatalf("item %s aad", it.Name)
		}
	}
	for _, w := range v.Wraps {
		lw := LineWrap{Line(w.Line), w.Gen, v.Recipient.DeviceID, v.Admin.DeviceID, dh(t, v.Admin.EdPub), dh(t, w.BlobHex), dh(t, w.SigHex)}
		key, err := OpenWrapLine(v.CircleID, v.Recipient.DeviceID, dh(t, v.Recipient.XSecret), dh(t, v.Recipient.XPub), lw, Line(w.Line), w.Gen, dh(t, w.CommitmentHex))
		if err != nil || hx(key) != w.KeyHex {
			t.Fatalf("wrap %s: %v", w.Name, err)
		}
	}
	for _, p := range v.Prefs {
		if err := VerifyProcessingPref(dh(t, v.Sender.EdPub), v.CircleID, v.Sender.UserID, Line(p.Lane), p.SkGen, p.ServerDeviceID, dh(t, p.ServerFPHex), dh(t, p.NonceHex), dh(t, p.SigHex)); err != nil {
			t.Fatalf("pref %s: %v", p.Name, err)
		}
		if hx(ProcessingRef(dh(t, p.MessageHex))) != p.LogRefHex {
			t.Fatalf("pref %s ref", p.Name)
		}
	}
	for _, p := range v.Policies {
		if err := VerifyProcessingPolicy(dh(t, v.Admin.EdPub), v.CircleID, v.Admin.UserID, p.ServerAssist, Line(p.DefaultForNew), MemberOptOut(p.MemberOptOut), p.SkGen, dh(t, p.CommitmentHex), dh(t, p.NonceHex), dh(t, p.SigHex)); err != nil {
			t.Fatalf("policy %s: %v", p.Name, err)
		}
	}
}

func TestLanesNegativeVectors(t *testing.T) {
	v := loadLanes(t)
	if len(v.Neg.Items) < 10 || len(v.Neg.Wraps) < 8 || len(v.Neg.Prefs) < 8 || len(v.Neg.Policies) < 10 {
		t.Fatal("negative vectors missing")
	}
	for _, n := range v.Neg.Items {
		if _, err := OpenItemV2(dh(t, n.KeyHex), n.CircleID, Line(n.ExpectLine), n.DeviceID, dh(t, n.SenderPubHex), n.Purpose, n.ServerSeq, dh(t, n.PayloadHex)); err == nil {
			t.Errorf("item %s was accepted", n.Name)
		}
	}
	for _, n := range v.Neg.Wraps {
		lw := LineWrap{Line(n.WrapLine), n.WrapGen, n.RecipientDeviceID, n.WrapperDeviceID, dh(t, n.WrapperPubHex), dh(t, n.BlobHex), dh(t, n.SigHex)}
		if _, err := OpenWrapLine(n.CircleID, n.DeviceID, dh(t, n.XSecretHex), dh(t, n.XPubHex), lw, Line(n.WantLine), n.WantGen, dh(t, n.CommitmentHex)); err == nil {
			t.Errorf("wrap %s was accepted", n.Name)
		} else if !errors.Is(err, ErrWrapRejected) {
			t.Errorf("wrap %s: unexpected error %v", n.Name, err)
		}
	}
	for _, n := range v.Neg.Prefs {
		if err := VerifyProcessingPref(dh(t, n.PubHex), n.CircleID, n.UserID, Line(n.Lane), n.SkGen, n.ServerDeviceID, dh(t, n.ServerFPHex), dh(t, n.NonceHex), dh(t, n.SigHex)); err == nil {
			t.Errorf("pref %s was accepted", n.Name)
		}
	}
	for _, n := range v.Neg.Policies {
		if err := VerifyProcessingPolicy(dh(t, n.PubHex), n.CircleID, n.AdminUserID, n.ServerAssist, Line(n.DefaultForNew), MemberOptOut(n.MemberOptOut), n.SkGen, dh(t, n.CommitmentHex), dh(t, n.NonceHex), dh(t, n.SigHex)); err == nil {
			t.Errorf("policy %s was accepted", n.Name)
		}
	}
}

func TestLanesLegacyVectorsStillVerify(t *testing.T) {
	// Legacy consent (frozen OFE2EE1-SERVERCONSENT).
	raw, err := os.ReadFile(consentVectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var c consentVector
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	if err := VerifyServerConsent(dh(t, c.PubHex), c.CircleID, c.UserID, c.ServerDev, dh(t, c.FingerHex), dh(t, c.SignatureHx)); err != nil {
		t.Fatalf("legacy consent no longer verifies: %v", err)
	}
	// Legacy v1 item and wrap vectors are covered by TestVectorsFrozen; here: a v1
	// payload keeps parsing as phone line, gen = epoch, and v2 helpers refuse it.
	a := mk(t, 1)
	p1 := mb(t)(SealItem(seed(0x42), circ, 3, devA, a.priv, "fix", 1, 1, []byte("x"), nonce24(1)))
	h, err := ParsePayloadHeader(p1)
	if err != nil || h.Version != 1 || h.Line != LinePhone || h.Gen != 3 {
		t.Fatalf("v1 header: %+v %v", h, err)
	}
	if _, _, _, err := OpenItem(seed(0x42), circ, devA, a.ed, "fix", 1, p1); err != nil {
		t.Fatalf("v1 item stopped opening: %v", err)
	}
	if _, _, err := OpenV2(seed(0x42), circ, LinePhone, devA, "fix", p1); err == nil {
		t.Fatal("OpenV2 accepted a v1 payload")
	}
}

func TestLanesRoundTripAndParse(t *testing.T) {
	a := mk(t, 1)
	for _, l := range []Line{LinePhone, LineServer} {
		p := mb(t)(SealItemV2(seed(0x10+byte(l)), circ, l, 5, devA, a.priv, "event", 9, 1700000000000, []byte(`{"k":1}`), nonce24(2)))
		h := mustOf[PayloadHeader](t)(ParsePayloadHeader(p))
		if h.Version != 2 || h.Line != l || h.Gen != 5 {
			t.Fatalf("header %+v", h)
		}
		it := mustOf[ItemV2](t)(OpenItemV2(seed(0x10+byte(l)), circ, l, devA, a.ed, "event", 9, p))
		if string(it.Body) != `{"k":1}` || it.Line != l || it.Gen != 5 {
			t.Fatalf("item %+v", it)
		}
	}
	for _, bad := range [][]byte{nil, {}, {2}, {2, 0, 0, 0, 0}, {2, 9, 0, 0, 0, 1}, {2, 0, 0, 0, 0, 0}, {3, 0, 0, 0, 0, 1}, {1, 0, 0, 0, 0}} {
		if _, err := ParsePayloadHeader(bad); err == nil {
			t.Errorf("header %x accepted", bad)
		}
	}
	if _, err := SealItemV2(seed(1), circ, Line(2), 1, devA, a.priv, "fix", 1, 1, nil, nonce24(1)); !errors.Is(err, ErrBadLine) {
		t.Fatal("sealed under an unknown line")
	}
	if _, err := SealItemV2(seed(1), circ, LinePhone, 0, devA, a.priv, "fix", 1, 1, nil, nonce24(1)); !errors.Is(err, ErrBadGen) {
		t.Fatal("sealed under gen 0")
	}
}

func TestLanesCheckWrapRecipient(t *testing.T) {
	cases := []struct {
		line           Line
		kind           string
		policy, member bool
		ok             bool
	}{
		{LinePhone, "server", true, true, false},
		{LinePhone, "server", false, false, false},
		{LinePhone, "phone", false, false, true},
		{LineServer, "server", true, true, true},
		{LineServer, "server", false, true, false},
		{LineServer, "server", true, false, false},
		{LineServer, "phone", false, false, true},
		{LineServer, "web", false, false, true},
		{Line(7), "phone", true, true, false},
	}
	for i, c := range cases {
		if (CheckWrapRecipient(c.line, c.kind, c.policy, c.member) == nil) != c.ok {
			t.Errorf("case %d", i)
		}
	}
}

func TestLanesRollbackPerLine(t *testing.T) {
	g := NewRollbackGuard()
	const min = int64(60_000)
	now := int64(1_000_000_000_000)
	// CK gen 2 is seen, SK gen 1 is seen: independent.
	if err := g.Observe(LinePhone, 2, now); err != nil {
		t.Fatal(err)
	}
	if err := g.Observe(LineServer, 1, now); err != nil {
		t.Fatal(err)
	}
	// A newer SK gen does not outdate CK.
	if err := g.Observe(LineServer, 2, now); err != nil {
		t.Fatal(err)
	}
	if err := g.Check(LinePhone, 2, devA, uint64(now+1), now+20*min); err != nil {
		t.Fatalf("CK outdated by SK: %v", err)
	}
	// Old SK gen 1 after grace, signed after gen 2 was first seen: refused.
	if err := g.Check(LineServer, 1, devB, uint64(now+min), now+20*min); !errors.Is(err, ErrRollback) {
		t.Fatalf("rollback accepted: %v", err)
	}
	// Within grace it is tolerated.
	if err := g.Check(LineServer, 1, devB, uint64(now+min), now+5*min); err != nil {
		t.Fatalf("grace: %v", err)
	}
	// Backlog (signed before gen 2 was first seen) is tolerated after grace.
	if err := g.Check(LineServer, 1, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", uint64(now-min), now+20*min); err != nil {
		t.Fatalf("backlog: %v", err)
	}
	// Per device: after devA used SK gen 2, devA going back to gen 1 for a fresh item is refused even within grace.
	if err := g.Check(LineServer, 2, devA, uint64(now+2*min), now+3*min); err != nil {
		t.Fatal(err)
	}
	if err := g.Check(LineServer, 1, devA, uint64(now+3*min), now+4*min); !errors.Is(err, ErrRollback) {
		t.Fatalf("device went back: %v", err)
	}
	// ... but that does not affect the same device on the other line.
	if err := g.Check(LinePhone, 2, devA, uint64(now+3*min), now+4*min); err != nil {
		t.Fatal(err)
	}
	if err := g.Check(Line(5), 1, devA, 1, now); err == nil {
		t.Fatal("unknown line")
	}
}

func TestLanesClassifyItemLane(t *testing.T) {
	prefs := []PrefEntry{{LineServer, 1000}, {LinePhone, 2000}, {LineServer, 3000}}
	cases := []struct {
		line Line
		ts   uint64
		want LaneVerdict
	}{
		{LinePhone, 5000, LaneConsistent},
		{LinePhone, 1, LaneConsistent},
		{LineServer, 500, LaneFlagged},
		{LineServer, 1500, LaneConsistent},
		{LineServer, 2500, LaneFlagged},
		{LineServer, 3500, LaneConsistent},
		{Line(9), 1500, LaneFlagged},
	}
	for i, c := range cases {
		if got := ClassifyItemLane(prefs, c.line, c.ts); got != c.want {
			t.Errorf("case %d: %v", i, got)
		}
	}
	if ClassifyItemLane(nil, LineServer, 10) != LaneFlagged {
		t.Fatal("no pref must flag")
	}
}

func TestLanesLogActionCodes(t *testing.T) {
	if _, err := LogActionMessage(ActServerAttach+1, uidA, devA, circ, "", 1, nil); err == nil {
		t.Fatal("unknown action accepted")
	}
	if _, err := LogActionMessage(ActProcessingPref, uidA, devA, circ, "", 1, nil); err != nil {
		t.Fatal(err)
	}
}
