package e2ee

// Processing lanes: the crypto and wire formats of docs/design/PRIVACY_PROCESSING.md
// (section 5). A Private circle has two key LINES, both held by all members'
// phones:
//
//	LinePhone  (0x00)  the circle key CK and its epochs. NEVER wrapped to a server-kind device.
//	LineServer (0x01)  the server key SK with its own generation counter.
//
// Item format v2 puts the line and generation in the payload header, in the
// Ed25519 item signature and in the AEAD associated data, so the server (or a
// hostile member) cannot relabel an item. Wrap AAD v3 binds the line, so a CK
// wrap can never be replayed as an SK wrap. v1 items and v1 wraps keep their
// meaning and bytes (item.go, e2ee.go); they are the phone line.
//
// "Lane" (a member's choice) and "line" (a key) share the same two values: a
// member in lane server seals under line server.
//
// Everything here is pure: no I/O, no logging, and no key material in errors.
// Unknown line or version values are rejected (fail closed).

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

// Line identifies a key line (and, for a member's preference, a lane).
type Line byte

const (
	LinePhone  Line = 0x00 // CK: phone-only
	LineServer Line = 0x01 // SK: server-assisted
)

// Valid reports whether l is one of the two defined lines.
func (l Line) Valid() bool { return l == LinePhone || l == LineServer }

// String is the wire/API name ("phone" or "server"); unknown values render as "invalid".
func (l Line) String() string {
	switch l {
	case LinePhone:
		return "phone"
	case LineServer:
		return "server"
	}
	return "invalid"
}

// ParseLine maps "phone"/"server" (the key_line / lane column values) to a Line.
func ParseLine(s string) (Line, error) {
	switch s {
	case "phone":
		return LinePhone, nil
	case "server":
		return LineServer, nil
	}
	return 0, ErrBadLine
}

const (
	// MsgVersionV2 is the first byte of a v2 sealed payload.
	MsgVersionV2 = 2
	// ItemVersionV2 is the first byte of the v2 item envelope inside the padding.
	ItemVersionV2 = 2
	// PayloadHeaderLenV2 = version(1) || line(1) || gen(4 BE).
	PayloadHeaderLenV2 = 6
	// ProcessingNonceLen is the length of the random nonce in signed processing statements.
	ProcessingNonceLen = 16

	domMsgKeyV3    = "OFE2EE3-MSG-KEY\x00"
	domItemAADV3   = "OFE2EE3-ITEM-AAD\x00"
	domItemV3      = "OFE2EE3-ITEM\x00"
	domWrapAADV3   = "OFE2EE3-WRAP-AAD\x00"
	domWrapSigV3   = "OFE2EE3-WRAP-SIG\x00"
	domCommitV3    = "OFE2EE3-KEY-COMMIT\x00"
	domProcessing  = "OFE2EE3-PROCESSING\x00"
	domPolicy      = "OFE2EE3-POLICY\x00"
	defaultGraceMs = 10 * 60 * 1000
)

var (
	ErrBadLine      = errors.New("e2ee: unknown key line")
	ErrLineMismatch = errors.New("e2ee: item line does not match the expected line")
	ErrBadGen       = errors.New("e2ee: generation out of range")
	ErrRollback     = errors.New("e2ee: item sealed under an outdated key generation")
	ErrBadStatement = errors.New("e2ee: malformed processing statement")
	ErrWrapTarget   = errors.New("e2ee: this key line may not be wrapped to that device kind")
)

func checkLineGen(line Line, gen uint32) error {
	if !line.Valid() {
		return ErrBadLine
	}
	if gen == 0 {
		return ErrBadGen
	}
	return nil
}

func lineGenBytes(line Line, gen uint32) []byte {
	return binary.BigEndian.AppendUint32([]byte{byte(line)}, gen)
}

// ------------------------------------------------------------------ wraps

// WrapAADLine is the v3 wrap AAD: "OFE2EE3-WRAP-AAD\0" || line(1) || circle(36)
// || gen(4 BE) || recipient_device(36) || wrapper_device(36). Wraps of the
// server line MUST use it; new phone-line wraps may. Legacy phone-line wraps
// keep WrapAAD (v1) and stay valid.
func WrapAADLine(circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string) ([]byte, error) {
	if err := checkLineGen(line, gen); err != nil {
		return nil, err
	}
	for _, id := range []string{circleID, recipientDeviceID, wrapperDeviceID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	a := append([]byte(domWrapAADV3), byte(line))
	a = append(a, circleID...)
	a = binary.BigEndian.AppendUint32(a, gen)
	a = append(a, recipientDeviceID...)
	return append(a, wrapperDeviceID...), nil
}

// WrapSigMessageLine is what the wrapper signs for a v3 wrap:
// "OFE2EE3-WRAP-SIG\0" || (the AAD fields after the domain) || blob.
func WrapSigMessageLine(circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string, blob []byte) ([]byte, error) {
	if len(blob) != WrapBlobLen {
		return nil, ErrBadBlob
	}
	aad, err := WrapAADLine(circleID, line, gen, recipientDeviceID, wrapperDeviceID)
	if err != nil {
		return nil, err
	}
	m := append([]byte(domWrapSigV3), aad[len(domWrapAADV3):]...)
	return append(m, blob...), nil
}

// VerifyWrapSignatureLine is the server's and the phone's check of a v3 wrap signature.
func VerifyWrapSignatureLine(wrapperEdPub []byte, circleID string, line Line, gen uint32, recipientDeviceID, wrapperDeviceID string, blob, sig []byte) error {
	m, err := WrapSigMessageLine(circleID, line, gen, recipientDeviceID, wrapperDeviceID, blob)
	if err != nil {
		return err
	}
	if len(wrapperEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(ed25519.PublicKey(wrapperEdPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

// KeyCommitmentLine binds (line, gen) to a key without revealing it:
// HKDF-SHA256(ikm = key, salt = circle_id || line(1) || gen(4 BE),
// info = "OFE2EE3-KEY-COMMIT\0", 32). For the server line the admin signs it in
// the processing_policy statement; every phone recomputes it from the SK it
// unwrapped, so a wrapper cannot hand different members different keys. The
// phone line keeps KeyCommitment (v1) for CK epochs.
func KeyCommitmentLine(key []byte, circleID string, line Line, gen uint32) ([]byte, error) {
	if len(key) != KeyLen {
		return nil, errors.New("e2ee: key must be 32 bytes")
	}
	if err := checkLineGen(line, gen); err != nil {
		return nil, err
	}
	if err := CheckID(circleID); err != nil {
		return nil, err
	}
	salt := append([]byte(circleID), lineGenBytes(line, gen)...)
	out := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, key, salt, []byte(domCommitV3)), out); err != nil {
		return nil, err
	}
	return out, nil
}

// LineWrap is one v3 wrap addressed to a device, with raw (not base64) fields.
type LineWrap struct {
	Line              Line
	Gen               uint32
	RecipientDeviceID string
	WrapperDeviceID   string
	WrapperEdPub      []byte
	Blob              []byte
	Signature         []byte
}

// OpenWrapLine verifies and unwraps one v3 wrap. The caller states which
// (wantLine, wantGen) it expects and passes the commitment it already verified
// from the signed log/policy record (fail closed: nil or short commitment is
// rejected). It rejects: a wrap whose line or gen differ from what was asked
// (cross-line confusion), a bad wrapper signature, an AEAD failure (AAD binds
// line, circle, gen, recipient and wrapper) and a key whose recomputed
// commitment differs. The key is returned only when everything holds.
func OpenWrapLine(circleID, deviceID string, xSecret, xPub []byte, w LineWrap, wantLine Line, wantGen uint32, commitment []byte) ([]byte, error) {
	if w.Line != wantLine || w.Gen != wantGen || w.RecipientDeviceID != deviceID || len(commitment) != 32 {
		return nil, fmt.Errorf("%w: not the requested line/generation or recipient", ErrWrapRejected)
	}
	if VerifyWrapSignatureLine(w.WrapperEdPub, circleID, w.Line, w.Gen, deviceID, w.WrapperDeviceID, w.Blob, w.Signature) != nil {
		return nil, fmt.Errorf("%w: wrapper signature", ErrWrapRejected)
	}
	aad, err := WrapAADLine(circleID, w.Line, w.Gen, deviceID, w.WrapperDeviceID)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrWrapRejected, err)
	}
	key, err := Unwrap(w.Blob, xSecret, xPub, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: cannot unwrap", ErrWrapRejected)
	}
	got, err := KeyCommitmentLine(key, circleID, w.Line, w.Gen)
	if err != nil || !ConstEq(got, commitment) {
		return nil, fmt.Errorf("%w: key commitment mismatch", ErrWrapRejected)
	}
	return key, nil
}

// CheckWrapRecipient enforces the hard "who may wrap what" rules of section 5.4
// that a phone (and the server's trigger) can decide locally. The phone line is
// never wrapped to a `server` device. The server line is wrapped to a `server`
// device only while the admin policy is on AND at least one member is in lane
// server. Other kinds are not restricted here (service/web policy is a UI
// decision of the owner's phone).
func CheckWrapRecipient(line Line, recipientKind string, policyOn, hasServerLaneMember bool) error {
	if !line.Valid() {
		return ErrBadLine
	}
	if recipientKind != "server" {
		return nil
	}
	if line == LinePhone || !policyOn || !hasServerLaneMember {
		return ErrWrapTarget
	}
	return nil
}

// ------------------------------------------------------------ item format v2

// PayloadHeader is the parsed, UNAUTHENTICATED header of a sealed payload. For
// a v1 payload Line is LinePhone and Gen is the epoch.
type PayloadHeader struct {
	Version byte
	Line    Line
	Gen     uint32
}

// ParsePayloadHeader reads version, line and generation without decrypting.
// Anything but a well-formed v1 or v2 header is rejected.
func ParsePayloadHeader(payload []byte) (PayloadHeader, error) {
	if len(payload) < 1 {
		return PayloadHeader{}, ErrBadBlob
	}
	switch payload[0] {
	case MsgVersion:
		if len(payload) < 5 {
			return PayloadHeader{}, ErrBadBlob
		}
		g := binary.BigEndian.Uint32(payload[1:5])
		if g == 0 {
			return PayloadHeader{}, ErrBadGen
		}
		return PayloadHeader{Version: MsgVersion, Line: LinePhone, Gen: g}, nil
	case MsgVersionV2:
		if len(payload) < PayloadHeaderLenV2 {
			return PayloadHeader{}, ErrBadBlob
		}
		l := Line(payload[1])
		g := binary.BigEndian.Uint32(payload[2:6])
		if err := checkLineGen(l, g); err != nil {
			return PayloadHeader{}, err
		}
		return PayloadHeader{Version: MsgVersionV2, Line: l, Gen: g}, nil
	}
	return PayloadHeader{}, ErrBadBlob
}

func msgKeyV2(key []byte, circleID string, line Line, gen uint32, purpose string) ([]byte, error) {
	salt := append([]byte(circleID), lineGenBytes(line, gen)...)
	r := hkdf.New(sha256.New, key, salt, append([]byte(domMsgKeyV3), purpose...))
	k := make([]byte, KeyLen)
	if _, err := io.ReadFull(r, k); err != nil {
		return nil, err
	}
	return k, nil
}

// ItemAADV2 = "OFE2EE3-ITEM-AAD\0" || circle || line || gen(4) || device_id || purpose.
func ItemAADV2(circleID string, line Line, gen uint32, deviceID, purpose string) []byte {
	a := append([]byte(domItemAADV3), circleID...)
	a = append(a, lineGenBytes(line, gen)...)
	a = append(a, deviceID...)
	return append(a, purpose...)
}

func checkItemFields(circleID, deviceID, purpose string, line Line, gen uint32) error {
	if len(purpose) == 0 || len(purpose) > 64 {
		return ErrBadPurpose
	}
	if err := checkLineGen(line, gen); err != nil {
		return err
	}
	if err := CheckID(circleID); err != nil {
		return err
	}
	return CheckID(deviceID)
}

// SealWithNonceV2 is the v2 payload format with an explicit nonce (vectors).
// Output: 0x02 || line(1) || gen(4 BE) || nonce(24) || ciphertext || tag(16).
// The AEAD key is HKDF(key, salt = circle||line||gen, info = "OFE2EE3-MSG-KEY\0"||purpose).
func SealWithNonceV2(key []byte, circleID string, line Line, gen uint32, deviceID, purpose string, plaintext []byte, nonce [NonceLen]byte) ([]byte, error) {
	if len(key) != KeyLen {
		return nil, errors.New("e2ee: key must be 32 bytes")
	}
	if err := checkItemFields(circleID, deviceID, purpose, line, gen); err != nil {
		return nil, err
	}
	k, err := msgKeyV2(key, circleID, line, gen, purpose)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	out := append([]byte{MsgVersionV2}, lineGenBytes(line, gen)...)
	out = append(out, nonce[:]...)
	return aead.Seal(out, nonce[:], plaintext, ItemAADV2(circleID, line, gen, deviceID, purpose)), nil
}

// OpenV2 decrypts a v2 payload under key, which MUST be the key of the header's
// (line, gen) that the caller holds. expectLine is the line the caller believes
// the item belongs to (for example the server's routing key_line); a header that
// says otherwise is rejected before any decryption.
func OpenV2(key []byte, circleID string, expectLine Line, deviceID, purpose string, payload []byte) ([]byte, PayloadHeader, error) {
	h, err := ParsePayloadHeader(payload)
	if err != nil {
		return nil, h, err
	}
	if h.Version != MsgVersionV2 {
		return nil, h, ErrBadBlob
	}
	if h.Line != expectLine {
		return nil, h, ErrLineMismatch
	}
	if len(payload) < PayloadHeaderLenV2+NonceLen+TagLen || len(key) != KeyLen {
		return nil, h, ErrShortCipher
	}
	if err := checkItemFields(circleID, deviceID, purpose, h.Line, h.Gen); err != nil {
		return nil, h, err
	}
	k, err := msgKeyV2(key, circleID, h.Line, h.Gen, purpose)
	if err != nil {
		return nil, h, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, h, err
	}
	n := payload[PayloadHeaderLenV2 : PayloadHeaderLenV2+NonceLen]
	pt, err := aead.Open(nil, n, payload[PayloadHeaderLenV2+NonceLen:], ItemAADV2(circleID, h.Line, h.Gen, deviceID, purpose))
	if err != nil {
		return nil, h, ErrDecrypt
	}
	return pt, h, nil
}

// ItemSignedMessageV2 is the byte string the sender device signs for a v2 item:
// "OFE2EE3-ITEM\0" || circle || line || gen(4) || device_id || len(purpose)(1) ||
// purpose || seq(8) || ts_ms(8) || body.
func ItemSignedMessageV2(circleID string, line Line, gen uint32, deviceID, purpose string, seq, tsMs uint64, body []byte) ([]byte, error) {
	if err := checkItemFields(circleID, deviceID, purpose, line, gen); err != nil {
		return nil, err
	}
	m := append([]byte(domItemV3), circleID...)
	m = append(m, lineGenBytes(line, gen)...)
	m = append(m, deviceID...)
	m = append(m, byte(len(purpose)))
	m = append(m, purpose...)
	m = binary.BigEndian.AppendUint64(m, seq)
	m = binary.BigEndian.AppendUint64(m, tsMs)
	return append(m, body...), nil
}

// SealItemV2 signs body as the sender device and seals it (padded) under the
// key of (line, gen). Envelope inside the padding: 0x02 || seq || ts_ms || sig || body.
func SealItemV2(key []byte, circleID string, line Line, gen uint32, deviceID string, priv ed25519.PrivateKey,
	purpose string, seq, tsMs uint64, body []byte, nonce [NonceLen]byte) ([]byte, error) {
	msg, err := ItemSignedMessageV2(circleID, line, gen, deviceID, purpose, seq, tsMs, body)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(priv, msg)
	env := []byte{ItemVersionV2}
	env = binary.BigEndian.AppendUint64(env, seq)
	env = binary.BigEndian.AppendUint64(env, tsMs)
	env = append(env, sig...)
	env = append(env, body...)
	padded, err := Pad(env)
	if err != nil {
		return nil, err
	}
	return SealWithNonceV2(key, circleID, line, gen, deviceID, purpose, padded, nonce)
}

// ItemV2 is a successfully opened and verified v2 item.
type ItemV2 struct {
	Line Line
	Gen  uint32
	Seq  uint64
	TsMs uint64
	Body []byte
}

// OpenItemV2 decrypts a v2 payload, checks that its line equals expectLine,
// that the signed seq equals the relayed one, and verifies the sender signature
// (which covers line and gen). The caller still owes: sender approval, the
// signed-time window, the replay window, RollbackGuard.Check, and ClassifyItemLane.
func OpenItemV2(key []byte, circleID string, expectLine Line, deviceID string, senderEdPub []byte, purpose string, serverSeq uint64, payload []byte) (ItemV2, error) {
	padded, h, err := OpenV2(key, circleID, expectLine, deviceID, purpose, payload)
	if err != nil {
		return ItemV2{}, err
	}
	env, err := Unpad(padded)
	if err != nil {
		return ItemV2{}, err
	}
	if len(env) < 1+8+8+SigLen || env[0] != ItemVersionV2 {
		return ItemV2{}, ErrBadEnvelope
	}
	it := ItemV2{Line: h.Line, Gen: h.Gen,
		Seq:  binary.BigEndian.Uint64(env[1:9]),
		TsMs: binary.BigEndian.Uint64(env[9:17]),
		Body: env[17+SigLen:]}
	if it.Seq != serverSeq {
		return ItemV2{}, ErrItemSeqMatch
	}
	msg, err := ItemSignedMessageV2(circleID, h.Line, h.Gen, deviceID, purpose, it.Seq, it.TsMs, it.Body)
	if err != nil {
		return ItemV2{}, err
	}
	if len(senderEdPub) != PubLen || !ed25519.Verify(senderEdPub, msg, env[17:17+SigLen]) {
		return ItemV2{}, ErrBadItemSig
	}
	return it, nil
}

// ------------------------------------------------- signed processing statements

func checkNonce(n []byte) error {
	if len(n) != ProcessingNonceLen {
		return ErrBadStatement
	}
	return nil
}

func allZero(b []byte) bool {
	var d byte
	for _, v := range b {
		d |= v
	}
	return d == 0
}

// ProcessingPrefMessage is what a member's phone signs to choose its lane (and,
// for lane server, to consent to the exact server key). It supersedes
// ServerConsentMessage (OFE2EE1-SERVERCONSENT), which stays valid for legacy rows:
//
//	"OFE2EE3-PROCESSING\0" || circle(36) || user(36) || lane(1) || sk_gen(4 BE) ||
//	server_device_id(36) || server_fingerprint(32) || nonce(16)
//
// lane server requires sk_gen >= 1, a real server device id and a non-zero
// fingerprint (consent names the exact server key). lane phone requires the zero
// UUID and an all-zero fingerprint (it names no server key); sk_gen may be 0 or
// the current generation. Withdrawal is a new statement with lane phone.
func ProcessingPrefMessage(circleID, userID string, lane Line, skGen uint32, serverDeviceID string, serverFingerprint, nonce []byte) ([]byte, error) {
	if !lane.Valid() {
		return nil, ErrBadLine
	}
	for _, id := range []string{circleID, userID, serverDeviceID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	if len(serverFingerprint) != 32 {
		return nil, ErrKeyLength
	}
	if err := checkNonce(nonce); err != nil {
		return nil, err
	}
	if lane == LineServer && (skGen == 0 || serverDeviceID == zeroUUID || allZero(serverFingerprint)) {
		return nil, ErrBadStatement
	}
	if lane == LinePhone && (serverDeviceID != zeroUUID || !allZero(serverFingerprint)) {
		return nil, ErrBadStatement
	}
	m := append([]byte(domProcessing), circleID...)
	m = append(m, userID...)
	m = append(m, byte(lane))
	m = binary.BigEndian.AppendUint32(m, skGen)
	m = append(m, serverDeviceID...)
	m = append(m, serverFingerprint...)
	return append(m, nonce...), nil
}

// VerifyProcessingPref checks a member's lane statement against the approver's key.
func VerifyProcessingPref(approverEdPub []byte, circleID, userID string, lane Line, skGen uint32, serverDeviceID string, serverFingerprint, nonce, sig []byte) error {
	m, err := ProcessingPrefMessage(circleID, userID, lane, skGen, serverDeviceID, serverFingerprint, nonce)
	if err != nil {
		return err
	}
	if len(approverEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(ed25519.PublicKey(approverEdPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

// MemberOptOut is the circle-wide rule on whether members may choose the phone lane.
type MemberOptOut byte

const (
	// OptOutAllowed (default): every member chooses their own lane.
	OptOutAllowed MemberOptOut = 0x00
	// OptOutRequiredServer: the admin requires the server lane (owner decision,
	// ADR 16.1). Requires server_assist on. A member's phone still signs its own pref.
	OptOutRequiredServer MemberOptOut = 0x01
)

// Valid reports whether o is a defined value (unknown values fail closed).
func (o MemberOptOut) Valid() bool { return o == OptOutAllowed || o == OptOutRequiredServer }

// String is the wire/API name ("allowed" or "required_server"), "invalid" otherwise.
func (o MemberOptOut) String() string {
	switch o {
	case OptOutAllowed:
		return "allowed"
	case OptOutRequiredServer:
		return "required_server"
	}
	return "invalid"
}

// ParseMemberOptOut maps "allowed"/"required_server" to a MemberOptOut.
func ParseMemberOptOut(s string) (MemberOptOut, error) {
	switch s {
	case "allowed":
		return OptOutAllowed, nil
	case "required_server":
		return OptOutRequiredServer, nil
	}
	return 0, ErrBadStatement
}

// ProcessingPolicyMessage is what a circle admin's phone signs to set the
// circle-wide policy:
//
//	"OFE2EE3-POLICY\0" || circle(36) || admin_user(36) || server_assist(1: 0 off, 1 on) ||
//	default_for_new(1: lane) || member_opt_out(1: 0 allowed, 1 required_server) || sk_gen(4 BE) || commitment(32) || nonce(16)
//
// commitment is KeyCommitmentLine(SK, circle, LineServer, sk_gen). With
// server_assist on, sk_gen >= 1 and a non-zero commitment are required; with it
// off they may be zero (never enabled) or describe the last generation.
func ProcessingPolicyMessage(circleID, adminUserID string, serverAssist bool, defaultForNew Line, optOut MemberOptOut, skGen uint32, commitment, nonce []byte) ([]byte, error) {
	if !defaultForNew.Valid() {
		return nil, ErrBadLine
	}
	if !optOut.Valid() || (optOut == OptOutRequiredServer && !serverAssist) {
		return nil, ErrBadStatement
	}
	for _, id := range []string{circleID, adminUserID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	if len(commitment) != 32 {
		return nil, ErrBadStatement
	}
	if err := checkNonce(nonce); err != nil {
		return nil, err
	}
	if serverAssist && (skGen == 0 || allZero(commitment)) {
		return nil, ErrBadStatement
	}
	if skGen == 0 && !allZero(commitment) {
		return nil, ErrBadStatement
	}
	m := append([]byte(domPolicy), circleID...)
	m = append(m, adminUserID...)
	if serverAssist {
		m = append(m, 1)
	} else {
		m = append(m, 0)
	}
	m = append(m, byte(defaultForNew), byte(optOut))
	m = binary.BigEndian.AppendUint32(m, skGen)
	m = append(m, commitment...)
	return append(m, nonce...), nil
}

// VerifyProcessingPolicy checks an admin's policy statement. That the signer is
// currently a circle admin is the caller's check (membership role is not in the
// statement).
func VerifyProcessingPolicy(adminEdPub []byte, circleID, adminUserID string, serverAssist bool, defaultForNew Line, optOut MemberOptOut, skGen uint32, commitment, nonce, sig []byte) error {
	m, err := ProcessingPolicyMessage(circleID, adminUserID, serverAssist, defaultForNew, optOut, skGen, commitment, nonce)
	if err != nil {
		return err
	}
	if len(adminEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(ed25519.PublicKey(adminEdPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

// ProcessingRef is the 32-byte `ref` of the transparency-log entry for a
// processing_pref / processing_policy action: SHA-256 of the signed statement.
// The log entry itself is LogActionMessage(ActProcessingPref|ActProcessingPolicy,
// user, actor_device, circle, subject, sk_gen as epoch, ProcessingRef(statement)),
// where subject is the server device id for a lane-server pref and empty otherwise.
// The "effective_seq" of a pref is the log entry's own seq (chain position), not
// a signed field.
func ProcessingRef(statement []byte) []byte {
	h := sha256.Sum256(statement)
	return h[:]
}

// ------------------------------------------------------ receiver-side checks

// RollbackGuard is the per-line epoch/generation rollback rule of E2EE.md
// (phase 2 receiving) applied independently to each line: a newer SK generation
// never outdates CK and vice versa. Not safe for concurrent use. Call Check only
// AFTER the item's AEAD and signature verified, and call Observe when a key of
// (line, gen) is first accepted.
type RollbackGuard struct {
	// GraceMs is how long after a newer generation was first seen an older one is
	// still tolerated circle-wide (default 10 minutes).
	GraceMs int64
	first   map[Line]map[uint32]int64
	high    map[Line]uint32
	dev     map[string]uint32 // device id + line -> highest gen accepted from that device
}

// NewRollbackGuard returns a guard with the default 10 minute grace.
func NewRollbackGuard() *RollbackGuard {
	return &RollbackGuard{GraceMs: defaultGraceMs, first: map[Line]map[uint32]int64{}, high: map[Line]uint32{}, dev: map[string]uint32{}}
}

// Observe records that a key of (line, gen) became known at nowMs.
func (g *RollbackGuard) Observe(line Line, gen uint32, nowMs int64) error {
	if err := checkLineGen(line, gen); err != nil {
		return err
	}
	if g.first[line] == nil {
		g.first[line] = map[uint32]int64{}
	}
	if _, ok := g.first[line][gen]; !ok {
		g.first[line][gen] = nowMs
	}
	if gen > g.high[line] {
		g.high[line] = gen
	}
	return nil
}

// Check applies the rule to a verified item of (line, gen) from deviceID with
// signed time itemTsMs, received at nowMs. Circle-wide, per line: an item below
// the highest generation seen on that line is refused once the grace has passed,
// unless its signed time precedes the moment the newer generation was first seen
// (backlog). Per device and line: a device never returns to an older generation
// for items signed after it first used the newer one. On success the item is
// recorded.
func (g *RollbackGuard) Check(line Line, gen uint32, deviceID string, itemTsMs uint64, nowMs int64) error {
	if err := checkLineGen(line, gen); err != nil {
		return err
	}
	ts := int64(itemTsMs)
	if itemTsMs > uint64(1)<<62 {
		return ErrRollback
	}
	if hi := g.high[line]; gen < hi {
		firstHi := g.first[line][hi]
		if ts >= firstHi && nowMs-firstHi > g.GraceMs {
			return ErrRollback
		}
	}
	dk := deviceID + string([]byte{byte(line)})
	if dh := g.dev[dk]; gen < dh && ts >= g.first[line][dh] {
		return ErrRollback
	}
	if err := g.Observe(line, gen, nowMs); err != nil {
		return err
	}
	if gen > g.dev[dk] {
		g.dev[dk] = gen
	}
	return nil
}

// PrefEntry is one VERIFIED processing_pref of one user. SinceMs is the time the
// preference took effect as recorded with the log entry; it is advisory (the
// server could skew it) and is used only to flag, never to grant access.
type PrefEntry struct {
	Lane    Line
	SinceMs int64
}

// LaneVerdict is the outcome of ClassifyItemLane.
type LaneVerdict int

const (
	// LaneConsistent: the item's line is consistent with its author's signed preference.
	LaneConsistent LaneVerdict = iota
	// LaneFlagged: a line-server item from an author with no server preference at
	// that time. Accepted but flagged; the UI must not show "server-processed".
	LaneFlagged
)

// ClassifyItemLane decides the badge for one item. prefs must be the author's
// verified processing_pref entries (any order). Phone-line items are always
// consistent (sealing more privately than your lane is harmless). A server-line
// item is consistent only if the latest pref effective at its signed time is lane server.
func ClassifyItemLane(prefs []PrefEntry, line Line, itemTsMs uint64) LaneVerdict {
	if line == LinePhone {
		return LaneConsistent
	}
	if line != LineServer || itemTsMs > uint64(1)<<62 {
		return LaneFlagged
	}
	ts := int64(itemTsMs)
	var best *PrefEntry
	for i := range prefs {
		p := &prefs[i]
		if p.SinceMs <= ts && (best == nil || p.SinceMs >= best.SinceMs) {
			best = p
		}
	}
	if best != nil && best.Lane == LineServer {
		return LaneConsistent
	}
	return LaneFlagged
}
