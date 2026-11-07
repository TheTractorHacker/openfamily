package e2ee

// Verification of the signed processing statements (lanes) against the verified
// key log, for components that are not phones: the server-device sidecar and the
// Dawarich bridge. Everything the server serves (policy, member prefs, SK wraps)
// is re-derived here from signatures, the verified log and the circle state; no
// flag the server sets is trusted. All checks FAIL CLOSED.

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
)

// ErrStatement marks a processing statement or SK wrap that did not verify.
var ErrStatement = errors.New("e2ee: processing statement not verified")

func stmtErr(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrStatement, fmt.Sprintf(format, a...))
}

func procKey(action byte, circleID, userID string) string {
	return fmt.Sprintf("%d|%s|%s", action, circleID, userID)
}

// PolicyStatement is one signed processing_policy as GET .../e2ee/processing serves it.
type PolicyStatement struct {
	LogSeq        int64  `json:"log_seq"`
	AdminUserID   string `json:"admin_user_id"`
	ActorDeviceID string `json:"actor_device_id"`
	ServerAssist  bool   `json:"server_assist"`
	DefaultForNew string `json:"default_for_new"`
	MemberOptOut  string `json:"member_opt_out"`
	SKGen         int    `json:"sk_gen"`
	Commitment    string `json:"commitment"`
	Nonce         string `json:"nonce"`
	Signature     string `json:"signature"`
}

// VerifiedPolicy is a policy statement whose signature, signer and log entry check out.
type VerifiedPolicy struct {
	ServerAssist  bool
	OptOut        MemberOptOut
	SKGen         uint32
	Commitment    []byte
	AdminUserID   string
	ActorDeviceID string
	LogSeq        int64
}

// PrefStatement is a member's signed processing_pref as served.
type PrefStatement struct {
	Lane              string `json:"lane"`
	SKGen             int    `json:"sk_gen"`
	ServerDeviceID    string `json:"server_device_id,omitempty"`
	ServerFingerprint string `json:"server_fingerprint,omitempty"`
	Nonce             string `json:"nonce,omitempty"`
	ApproverDeviceID  string `json:"approver_device_id"`
	Signature         string `json:"signature"`
	Legacy            bool   `json:"legacy"`
	LogSeq            *int64 `json:"log_seq,omitempty"`
}

// logProcessing returns the log entry at seq if it is a processing entry of the circle.
func (x *LogIndex) logProcessing(seq int64, action byte, circleID string) (LogEntry, bool) {
	if x == nil {
		return LogEntry{}, false
	}
	e, ok := x.proc[seq]
	if !ok || e.Action == nil || byte(*e.Action) != action || e.CircleID == nil || *e.CircleID != circleID {
		return LogEntry{}, false
	}
	return e, true
}

// latestProcessing returns the newest verified-log entry for (action, circle, user).
func (x *LogIndex) latestProcessing(action byte, circleID, userID string) (LogEntry, bool) {
	if x == nil {
		return LogEntry{}, false
	}
	e, ok := x.procLatest[procKey(action, circleID, userID)]
	return e, ok
}

// entryMatches reports whether a log entry is exactly the statement we hold.
func entryMatches(e LogEntry, user, actorDev, actorPub string, epoch int, ref []byte) bool {
	return e.UserID != nil && *e.UserID == user && e.ActorDeviceID != nil && *e.ActorDeviceID == actorDev &&
		e.ActorPub != nil && *e.ActorPub == actorPub && e.Epoch != nil && *e.Epoch == epoch &&
		e.Ref != nil && *e.Ref == hex.EncodeToString(ref)
}

// VerifyPolicy verifies one policy statement: the signer is a listed, usable
// device of a circle ADMIN, the Ed25519 signature verifies, and the verified log
// contains the entry that carries the statement's hash, signed by that device.
// If latest is set it must also be the newest policy entry of the circle in the log.
func (t Trust) VerifyPolicy(circleID string, p PolicyStatement, latest bool) (*VerifiedPolicy, error) {
	if t.Index == nil {
		return nil, stmtErr("no verified log")
	}
	dev, mem := FindDevice(t.Members, p.ActorDeviceID)
	if dev == nil || mem == nil || mem.UserID != p.AdminUserID || mem.Role != "admin" || dev.Kind != "device" {
		return nil, stmtErr("policy signer is not a device of a circle admin")
	}
	if err := t.AuthorizeSender(dev, mem); err != nil {
		return nil, stmtErr("policy signer: %v", err)
	}
	pub, err1 := b64(dev.Ed25519Pub)
	commit, err2 := b64(p.Commitment)
	nonce, err3 := b64(p.Nonce)
	sig, err4 := b64(p.Signature)
	if errors.Join(err1, err2, err3, err4) != nil || p.SKGen < 0 {
		return nil, stmtErr("malformed policy statement")
	}
	def, err := ParseLine(p.DefaultForNew)
	if err != nil {
		return nil, stmtErr("default_for_new")
	}
	oo, err := ParseMemberOptOut(p.MemberOptOut)
	if err != nil {
		return nil, stmtErr("member_opt_out")
	}
	msg, err := ProcessingPolicyMessage(circleID, p.AdminUserID, p.ServerAssist, def, oo, uint32(p.SKGen), commit, nonce)
	if err != nil {
		return nil, stmtErr("policy fields: %v", err)
	}
	if VerifyProcessingPolicy(pub, circleID, p.AdminUserID, p.ServerAssist, def, oo, uint32(p.SKGen), commit, nonce, sig) != nil {
		return nil, stmtErr("policy signature")
	}
	e, ok := t.Index.logProcessing(p.LogSeq, ActProcessingPolicy, circleID)
	if !ok || !entryMatches(e, p.AdminUserID, p.ActorDeviceID, dev.Ed25519Pub, p.SKGen, ProcessingRef(msg)) {
		return nil, stmtErr("policy is not in the verified key log")
	}
	if latest {
		if l, ok := t.Index.latestProcessing(ActProcessingPolicy, circleID, ""); !ok || l.Seq != p.LogSeq {
			return nil, stmtErr("a newer policy exists in the key log (or the served one is not the newest)")
		}
	}
	return &VerifiedPolicy{ServerAssist: p.ServerAssist, OptOut: oo, SKGen: uint32(p.SKGen), Commitment: commit,
		AdminUserID: p.AdminUserID, ActorDeviceID: p.ActorDeviceID, LogSeq: p.LogSeq}, nil
}

// VerifyPref returns the lane a member's served statement PROVES. LineServer only
// if the statement is the member's newest processing_pref in the verified log,
// signed by one of their usable phone keys and naming exactly serverDeviceID and
// serverFP; the sk_gen must be in 1..maxGen. A verified lane-phone statement
// returns LinePhone. Anything else is an error (callers treat it as phone).
// A converted legacy consent (Legacy) is accepted only while the log holds no
// processing_pref of that member at all (any later statement supersedes it).
func (t Trust) VerifyPref(circleID, userID string, p *PrefStatement, serverDeviceID string, serverFP []byte, maxGen uint32) (Line, error) {
	if t.Index == nil || p == nil {
		return LinePhone, stmtErr("no statement or no verified log")
	}
	dev, mem := FindDevice(t.Members, p.ApproverDeviceID)
	if dev == nil || mem == nil || mem.UserID != userID || dev.Kind != "device" {
		return LinePhone, stmtErr("approver is not a phone key of that member")
	}
	if err := t.AuthorizeSender(dev, mem); err != nil {
		return LinePhone, stmtErr("approver: %v", err)
	}
	pub, err1 := b64(dev.Ed25519Pub)
	sig, err2 := b64(p.Signature)
	if errors.Join(err1, err2) != nil {
		return LinePhone, stmtErr("malformed statement")
	}
	lane, err := ParseLine(p.Lane)
	if err != nil {
		return LinePhone, stmtErr("lane")
	}
	_, hasLog := t.Index.latestProcessing(ActProcessingPref, circleID, userID)
	if p.Legacy {
		if lane != LineServer || hasLog || len(serverFP) != 32 {
			return LinePhone, stmtErr("legacy consent is superseded or not a server consent")
		}
		if p.ServerDeviceID != serverDeviceID || VerifyServerConsent(pub, circleID, userID, serverDeviceID, serverFP, sig) != nil {
			return LinePhone, stmtErr("legacy consent signature")
		}
		return LineServer, nil
	}
	nonce, err := b64(p.Nonce)
	if err != nil {
		return LinePhone, stmtErr("nonce")
	}
	fp := make([]byte, 32)
	srvDev := zeroUUID
	if lane == LineServer {
		if p.ServerDeviceID != serverDeviceID || len(serverFP) != 32 {
			return LinePhone, stmtErr("the statement names another server key")
		}
		got, err := b64(p.ServerFingerprint)
		if err != nil || !ConstEq(got, serverFP) {
			return LinePhone, stmtErr("the statement names another server fingerprint")
		}
		if p.SKGen < 1 || uint32(p.SKGen) > maxGen {
			return LinePhone, stmtErr("sk_gen out of range")
		}
		fp, srvDev = got, serverDeviceID
	}
	msg, err := ProcessingPrefMessage(circleID, userID, lane, uint32(p.SKGen), srvDev, fp, nonce)
	if err != nil {
		return LinePhone, stmtErr("statement fields: %v", err)
	}
	if VerifyProcessingPref(pub, circleID, userID, lane, uint32(p.SKGen), srvDev, fp, nonce, sig) != nil {
		return LinePhone, stmtErr("signature")
	}
	e, ok := t.Index.latestProcessing(ActProcessingPref, circleID, userID)
	if !ok || !entryMatches(e, userID, p.ApproverDeviceID, dev.Ed25519Pub, p.SKGen, ProcessingRef(msg)) {
		return LinePhone, stmtErr("not the member's newest preference in the verified key log")
	}
	if p.LogSeq != nil && *p.LogSeq != e.Seq {
		return LinePhone, stmtErr("log position differs")
	}
	if lane == LineServer && (e.SubjectID == nil || *e.SubjectID != serverDeviceID) {
		return LinePhone, stmtErr("log subject is not the server key")
	}
	return lane, nil
}

// SKWrap is one wrap of the server line as GET .../e2ee/wraps?key_line=server serves it.
type SKWrap struct {
	Epoch             int    `json:"epoch"` // the SK generation for the server line
	RecipientDeviceID string `json:"recipient_device_id"`
	WrapperDeviceID   string `json:"wrapper_device_id"`
	WrapperEd25519Pub string `json:"wrapper_ed25519_pub"`
	WrappedKey        string `json:"wrapped_key"`
	Signature         string `json:"signature"`
	KeyLine           string `json:"key_line"`
}

// OpenSKWrap authorizes and opens one server-line wrap for deviceID. pol must be
// the VERIFIED policy statement of the wrap's generation (its commitment is what
// the unwrapped key must match). The wrapper must be a listed, usable, approved
// device of the admin who signed that policy (the publisher rule), with exactly
// the key the wrap carries; a wrapper of our own account must chain to the
// approving phone. Returns the SK. A wrap of the phone line is NEVER opened here.
func (t Trust) OpenSKWrap(circleID, deviceID string, xSecret, xPub []byte, w SKWrap, pol *VerifiedPolicy) ([]byte, error) {
	if pol == nil || !pol.ServerAssist || w.Epoch < 1 || uint32(w.Epoch) != pol.SKGen {
		return nil, fmt.Errorf("%w: no verified policy for that generation", ErrWrapRejected)
	}
	line, err := ParseLine(w.KeyLine)
	if err != nil || line != LineServer {
		return nil, fmt.Errorf("%w: not a server-line wrap", ErrWrapRejected)
	}
	wd, wm := FindDevice(t.Members, w.WrapperDeviceID)
	if wd == nil || wm == nil || wd.Ed25519Pub != w.WrapperEd25519Pub || wm.UserID != pol.AdminUserID || wm.Role != "admin" || wd.Kind != "device" {
		return nil, fmt.Errorf("%w: wrapper is not a device of the admin who set this generation", ErrWrapRejected)
	}
	if err := t.AuthorizeSender(wd, wm); err != nil {
		return nil, fmt.Errorf("%w: wrapper: %v", ErrWrapRejected, err)
	}
	blob, e1 := b64(w.WrappedKey)
	sig, e2 := b64(w.Signature)
	wpub, e3 := b64(w.WrapperEd25519Pub)
	if errors.Join(e1, e2, e3) != nil {
		return nil, fmt.Errorf("%w: malformed", ErrWrapRejected)
	}
	return OpenWrapLine(circleID, deviceID, xSecret, xPub, LineWrap{Line: LineServer, Gen: uint32(w.Epoch), RecipientDeviceID: w.RecipientDeviceID,
		WrapperDeviceID: w.WrapperDeviceID, WrapperEdPub: wpub, Blob: blob, Signature: sig}, LineServer, pol.SKGen, pol.Commitment)
}

// CheckSKIndependent returns an error if sk equals any held CK (ckKeys), or if its
// phone-line commitment (KeyCommitment, the v1 derivation) equals the commitment
// of any CK epoch in the circle state. Either means an admin phone reused the
// phone key as the server key (ADR 5.4 rule 3).
func CheckSKIndependent(sk []byte, circleID string, ckKeys [][]byte, epochs []EpochRecord) error {
	for _, k := range ckKeys {
		if len(k) == len(sk) && bytes.Equal(k, sk) {
			return errors.New("e2ee: the server key SK is byte-identical to a circle key CK")
		}
	}
	for _, r := range epochs {
		if r.Epoch < 1 {
			continue
		}
		c, err := KeyCommitment(sk, circleID, uint32(r.Epoch))
		want, err2 := base64.StdEncoding.DecodeString(r.KeyCommitment)
		if err == nil && err2 == nil && ConstEq(c, want) {
			return fmt.Errorf("e2ee: the server key SK has the commitment of circle key epoch %d (SK reuses CK)", r.Epoch)
		}
	}
	return nil
}

// HasPolicy reports whether the verified log holds any processing_policy entry
// for the circle. A circle without one never had lanes configured.
func (x *LogIndex) HasPolicy(circleID string) bool {
	_, ok := x.latestProcessing(ActProcessingPolicy, circleID, "")
	return ok
}
