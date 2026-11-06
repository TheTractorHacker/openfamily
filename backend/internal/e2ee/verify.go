package e2ee

// Client-side verification policy for the key transparency log, device
// registrations, epoch records and wrapped circle keys. These functions mirror the
// phone's Dart code (app/lib/services/e2ee/e2ee_trust.dart: verifyRegistration,
// verifyLogSlice, and e2ee_service.dart: syncCircleKeys) so that other device
// members (the Dawarich bridge, later the web viewer) apply the same policy. The
// server is the adversary: nothing here trusts a field just because the server sent it.

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

// DeviceRecord is the public record of a device key as served by the API
// (GET /circles/{id}/e2ee members[].devices[], GET /e2ee/me).
type DeviceRecord struct {
	DeviceID              string     `json:"device_id"`
	UserID                string     `json:"user_id"`
	Kind                  string     `json:"kind"`
	Ed25519Pub            string     `json:"ed25519_pub"` // std base64
	X25519Pub             string     `json:"x25519_pub"`  // std base64
	Fingerprint           string     `json:"fingerprint"` // hex
	Signature             string     `json:"signature"`   // binding signature, std base64
	RegisteredByDeviceID  string     `json:"registered_by_device_id"`
	RegisteredByPub       string     `json:"registered_by_ed25519_pub"`
	RegistrationAction    int        `json:"registration_action"`
	RegistrationSignature string     `json:"registration_signature"`
	Initial               bool       `json:"initial"`
	Label                 string     `json:"label"`
	RevokedAt             *time.Time `json:"revoked_at"`
	Approved              *bool      `json:"approved,omitempty"`
}

// IsRoot reports whether the key vouches for itself.
func (d DeviceRecord) IsRoot() bool { return d.RegisteredByDeviceID == d.DeviceID }

func b64(s string) ([]byte, error) { return base64.StdEncoding.DecodeString(s) }

// VerifyRegistration checks that a key is vouched for by the key named in its
// record: itself (root) or an earlier key of the same user. Like the Dart
// verifyRegistration it checks signatures only (whether the voucher is trusted is
// a separate matter); additionally it checks the self-signed binding of the
// public keys to the account, which the server verified at registration too.
func VerifyRegistration(d DeviceRecord) bool {
	ed, err1 := b64(d.Ed25519Pub)
	x, err2 := b64(d.X25519Pub)
	bind, err3 := b64(d.Signature)
	byPub, err4 := b64(d.RegisteredByPub)
	rsig, err5 := b64(d.RegistrationSignature)
	ref, err6 := hex.DecodeString(d.Fingerprint)
	if err := errors.Join(err1, err2, err3, err4, err5, err6); err != nil {
		return false
	}
	if d.RegistrationAction < int(ActRegister) || d.RegistrationAction > int(ActApprove) {
		return false
	}
	msg, err := LogActionMessage(byte(d.RegistrationAction), d.UserID, d.RegisteredByDeviceID, "", d.DeviceID, 0, ref)
	if err != nil {
		return false
	}
	if d.IsRoot() && !ConstEq(byPub, ed) {
		return false
	}
	fp, err := Fingerprint(ed, x)
	if err != nil || !ConstEq(fp, ref) {
		return false
	}
	if VerifyBinding(d.UserID, d.DeviceID, ed, x, bind) != nil {
		return false
	}
	return len(byPub) == PubLen && len(rsig) == SigLen && ed25519.Verify(byPub, msg, rsig)
}

// EpochRecord is the signed record of one circle key epoch (enable/epoch log
// entry) as served in the circle state.
type EpochRecord struct {
	Epoch         int    `json:"epoch"`
	Action        int    `json:"action"`
	PublisherUser string `json:"publisher_user_id"`
	PublisherDev  string `json:"publisher_device_id"`
	PublisherPub  string `json:"publisher_ed25519_pub"`
	KeyCommitment string `json:"key_commitment"`
	Signature     string `json:"signature"`
}

// VerifyEpochRecord checks the publisher's signature over (action, publisher,
// circle, epoch, commitment). Only enable and epoch actions are epoch records.
func VerifyEpochRecord(circleID string, r EpochRecord) bool {
	if r.Action != int(ActEnable) && r.Action != int(ActEpoch) || r.Epoch < 1 {
		return false
	}
	pub, err1 := b64(r.PublisherPub)
	commit, err2 := b64(r.KeyCommitment)
	sig, err3 := b64(r.Signature)
	if errors.Join(err1, err2, err3) != nil {
		return false
	}
	return VerifyLogAction(pub, byte(r.Action), r.PublisherUser, r.PublisherDev, circleID, "", uint32(r.Epoch), commit, sig) == nil
}

// WrapRecord is one wrapped circle key addressed to a device
// (GET /circles/{id}/e2ee/wraps?device_id=).
type WrapRecord struct {
	Epoch             int    `json:"epoch"`
	RecipientDeviceID string `json:"recipient_device_id"`
	WrapperDeviceID   string `json:"wrapper_device_id"`
	WrapperEd25519Pub string `json:"wrapper_ed25519_pub"`
	WrappedKey        string `json:"wrapped_key"`
	Signature         string `json:"signature"`
}

var (
	// ErrWrapRejected is returned for a wrap that must not be accepted: bad
	// wrapper signature, bad or missing epoch record, tampered blob, wrong
	// recipient, or a key that does not match the publisher's commitment.
	ErrWrapRejected = errors.New("e2ee: wrap rejected")
)

// OpenWrap verifies and unwraps one circle key like the phone's syncCircleKeys:
// recipient is the caller's device, the wrapper's signature verifies, the epoch's
// signed record verifies, AEAD (AAD binds circle/epoch/recipient/wrapper) opens,
// and the key commitment recomputed from the key equals the signed one. rec may
// be nil (fail closed).
func OpenWrap(circleID, deviceID string, xSecret, xPub []byte, w WrapRecord, rec *EpochRecord) ([]byte, error) {
	if w.RecipientDeviceID != deviceID || w.Epoch < 1 || rec == nil || rec.Epoch != w.Epoch {
		return nil, fmt.Errorf("%w: not addressed to this device or no epoch record", ErrWrapRejected)
	}
	blob, err1 := b64(w.WrappedKey)
	wsig, err2 := b64(w.Signature)
	wpub, err3 := b64(w.WrapperEd25519Pub)
	if errors.Join(err1, err2, err3) != nil {
		return nil, fmt.Errorf("%w: malformed", ErrWrapRejected)
	}
	if VerifyWrapSignature(wpub, circleID, uint32(w.Epoch), deviceID, w.WrapperDeviceID, blob, wsig) != nil {
		return nil, fmt.Errorf("%w: wrapper signature", ErrWrapRejected)
	}
	if !VerifyEpochRecord(circleID, *rec) {
		return nil, fmt.Errorf("%w: epoch record signature", ErrWrapRejected)
	}
	aad, err := WrapAAD(circleID, uint32(w.Epoch), deviceID, w.WrapperDeviceID)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrWrapRejected, err)
	}
	key, err := Unwrap(blob, xSecret, xPub, aad)
	if err != nil {
		return nil, fmt.Errorf("%w: cannot unwrap", ErrWrapRejected)
	}
	commit, err := KeyCommitment(key, circleID, uint32(w.Epoch))
	want, err2b := b64(rec.KeyCommitment)
	if err != nil || err2b != nil || !ConstEq(commit, want) {
		return nil, fmt.Errorf("%w: key commitment mismatch", ErrWrapRejected)
	}
	return key, nil
}

// ------------------------------------------------------------------ the log

// LogEntry is one entry of GET /e2ee/log. Redacted entries carry only
// seq, prev_hash and entry_hash.
type LogEntry struct {
	Seq           int64   `json:"seq"`
	PrevHash      string  `json:"prev_hash"`  // hex
	EntryHash     string  `json:"entry_hash"` // hex
	Redacted      bool    `json:"redacted"`
	Action        *int    `json:"action,omitempty"`
	UserID        *string `json:"user_id,omitempty"`
	ActorDeviceID *string `json:"actor_device_id,omitempty"`
	ActorPub      *string `json:"actor_ed25519_pub,omitempty"` // std base64
	CircleID      *string `json:"circle_id,omitempty"`
	SubjectID     *string `json:"subject_id,omitempty"`
	Epoch         *int    `json:"epoch,omitempty"`
	Ref           *string `json:"ref,omitempty"`       // hex
	Signature     *string `json:"signature,omitempty"` // std base64
}

// LogHead is the pinned tip of the log.
type LogHead struct {
	Seq  int64  `json:"seq"`
	Hash []byte `json:"-"`
}

// HashHex is the lower-case hex of the head hash.
func (h LogHead) HashHex() string { return hex.EncodeToString(h.Hash) }

// LogProblem classifies a verification failure.
type LogProblem int

const (
	LogOK LogProblem = iota
	LogRollback
	LogFork
	LogBrokenChain
	LogBadSignature
	LogBadHash
	LogGap
	LogMalformed
)

func (p LogProblem) String() string {
	return [...]string{"ok", "rollback", "fork", "broken-chain", "bad-signature", "bad-hash", "gap", "malformed"}[p]
}

// LogCheck is the outcome of verifying a slice.
type LogCheck struct {
	Problem LogProblem
	Detail  string
	NewHead *LogHead
	// Events are the visible entries newer than the previously pinned head.
	Events []LogEntry
}

// OK reports whether the slice verified.
func (c LogCheck) OK() bool { return c.Problem == LogOK }

func (e LogEntry) hashes() (prev, hash []byte, err error) {
	prev, err = hex.DecodeString(e.PrevHash)
	if err != nil || len(prev) != 32 {
		return nil, nil, errors.New("bad prev_hash")
	}
	hash, err = hex.DecodeString(e.EntryHash)
	if err != nil || len(hash) != 32 {
		return nil, nil, errors.New("bad entry_hash")
	}
	return prev, hash, nil
}

// verifyEntry checks the action signature and the entry hash of a visible entry.
func (e LogEntry) verifyFull(prev []byte) LogCheck {
	if e.Action == nil || e.UserID == nil || e.ActorDeviceID == nil || e.ActorPub == nil || e.Signature == nil || e.Ref == nil {
		return LogCheck{Problem: LogMalformed, Detail: fmt.Sprintf("entry %d is malformed", e.Seq)}
	}
	pub, err1 := b64(*e.ActorPub)
	sig, err2 := b64(*e.Signature)
	ref, err3 := hex.DecodeString(*e.Ref)
	if errors.Join(err1, err2, err3) != nil || *e.Action < int(ActRegister) || *e.Action > int(ActApprove) {
		return LogCheck{Problem: LogMalformed, Detail: fmt.Sprintf("entry %d is malformed", e.Seq)}
	}
	circle, subject, epoch := "", "", 0
	if e.CircleID != nil {
		circle = *e.CircleID
	}
	if e.SubjectID != nil {
		subject = *e.SubjectID
	}
	if e.Epoch != nil {
		epoch = *e.Epoch
	}
	msg, err := LogActionMessage(byte(*e.Action), *e.UserID, *e.ActorDeviceID, circle, subject, uint32(epoch), ref)
	if err != nil {
		return LogCheck{Problem: LogMalformed, Detail: fmt.Sprintf("entry %d is malformed", e.Seq)}
	}
	if len(pub) != PubLen || len(sig) != SigLen || !ed25519.Verify(pub, msg, sig) {
		return LogCheck{Problem: LogBadSignature, Detail: fmt.Sprintf("entry %d has an invalid signature", e.Seq)}
	}
	_, hash, _ := e.hashes()
	if !ConstEq(LogEntryHash(prev, uint64(e.Seq), msg, sig), hash) {
		return LogCheck{Problem: LogBadHash, Detail: fmt.Sprintf("entry %d does not match its hash", e.Seq)}
	}
	return LogCheck{}
}

// VerifyLogSlice verifies a server-served log slice against the pinned head,
// exactly like the Dart verifyLogSlice. entries must start at
// max(pinned.Seq-1, 0)+1, i.e. include the pinned entry itself. It detects
// rollback (head older than pinned), fork/rewrite (the pinned entry has another
// hash now), broken linkage, forged signatures, altered content and gaps. A
// server that shows different logs to different people (split view) is not
// detectable here.
func VerifyLogSlice(pinned *LogHead, entries []LogEntry, head LogHead) LogCheck {
	if pinned != nil && head.Seq < pinned.Seq {
		return LogCheck{Problem: LogRollback,
			Detail: fmt.Sprintf("the server log is shorter (%d) than the one pinned (%d)", head.Seq, pinned.Seq)}
	}
	if len(entries) == 0 {
		if pinned == nil && head.Seq == 0 {
			return LogCheck{NewHead: &head}
		}
		if pinned != nil && head.Seq == pinned.Seq && ConstEq(head.Hash, pinned.Hash) {
			return LogCheck{NewHead: &head}
		}
		return LogCheck{Problem: LogGap, Detail: "the server returned no entries but a different head"}
	}
	var prev []byte
	var lastSeq int64
	first := true
	var events []LogEntry
	for _, e := range entries {
		ePrev, eHash, err := e.hashes()
		if err != nil {
			return LogCheck{Problem: LogMalformed, Detail: fmt.Sprintf("entry %d is malformed", e.Seq)}
		}
		if !first && e.Seq != lastSeq+1 {
			return LogCheck{Problem: LogGap, Detail: fmt.Sprintf("entry %d is missing", lastSeq+1)}
		}
		if first {
			if pinned == nil && e.Seq != 1 {
				return LogCheck{Problem: LogGap, Detail: "the log does not start at entry 1"}
			}
			if pinned != nil && e.Seq > pinned.Seq {
				return LogCheck{Problem: LogGap, Detail: "the pinned entry was not returned"}
			}
			if e.Seq == 1 && !bytes.Equal(ePrev, GenesisHash) {
				return LogCheck{Problem: LogBrokenChain, Detail: "entry 1 does not start from the genesis hash"}
			}
		} else if !ConstEq(ePrev, prev) {
			return LogCheck{Problem: LogBrokenChain, Detail: fmt.Sprintf("entry %d does not extend entry %d", e.Seq, e.Seq-1)}
		}
		if !e.Redacted {
			if c := e.verifyFull(ePrev); !c.OK() {
				return c
			}
		}
		if pinned != nil && e.Seq == pinned.Seq && !ConstEq(eHash, pinned.Hash) {
			return LogCheck{Problem: LogFork,
				Detail: fmt.Sprintf("entry %d is not the one pinned: the history was rewritten or another log is shown", pinned.Seq)}
		}
		if (pinned == nil || e.Seq > pinned.Seq) && !e.Redacted {
			events = append(events, e)
		}
		prev, lastSeq, first = eHash, e.Seq, false
	}
	if pinned != nil && lastSeq < pinned.Seq {
		return LogCheck{Problem: LogGap, Detail: "the pinned entry was not returned"}
	}
	if lastSeq != head.Seq || !ConstEq(prev, head.Hash) {
		return LogCheck{Problem: LogBrokenChain, Detail: "the reported head is not the last entry"}
	}
	return LogCheck{NewHead: &head, Events: events}
}

// LogFetcher returns up to one page of entries after seq `after` and the
// server's current head.
type LogFetcher func(after int64) (entries []LogEntry, head LogHead, err error)

// SyncLog walks the whole log from the pinned head, page by page (the server
// serves at most 500 entries per page), verifying every page with
// VerifyLogSlice. Every page request overlaps the previous page's last entry so
// the chain linkage across pages is verified. The returned LogCheck carries the
// head to pin when OK. A fetch error is returned as err (not a log problem).
func SyncLog(pinned *LogHead, fetch LogFetcher) (LogCheck, error) {
	cur := pinned
	var events []LogEntry
	for page := 0; page < 100000; page++ {
		after := int64(0)
		if cur != nil && cur.Seq > 0 {
			after = cur.Seq - 1
		}
		entries, head, err := fetch(after)
		if err != nil {
			return LogCheck{}, err
		}
		if cur != nil && head.Seq < cur.Seq {
			return LogCheck{Problem: LogRollback,
				Detail: fmt.Sprintf("the server log is shorter (%d) than the one pinned (%d)", head.Seq, cur.Seq)}, nil
		}
		tip := head
		if n := len(entries); n > 0 && entries[n-1].Seq != head.Seq {
			// A partial page: verify up to its last entry, then continue.
			_, h, err := entries[n-1].hashes()
			if err != nil {
				return LogCheck{Problem: LogMalformed, Detail: "malformed log page"}, nil
			}
			tip = LogHead{Seq: entries[n-1].Seq, Hash: h}
		}
		c := VerifyLogSlice(cur, entries, tip)
		if !c.OK() {
			return c, nil
		}
		events = append(events, c.Events...)
		progressed := cur == nil || c.NewHead.Seq > cur.Seq
		cur = c.NewHead
		if cur.Seq == head.Seq {
			if !ConstEq(cur.Hash, head.Hash) {
				return LogCheck{Problem: LogBrokenChain, Detail: "the reported head is not the last entry"}, nil
			}
			return LogCheck{NewHead: cur, Events: events}, nil
		}
		if !progressed {
			return LogCheck{Problem: LogGap, Detail: "the server did not advance the log"}, nil
		}
	}
	return LogCheck{Problem: LogGap, Detail: "the log is too long to verify"}, nil
}

// ------------------------------------------------------- authorization against the log
//
// The circle state (GET /circles/{id}/e2ee) is served by the adversary. The
// functions below accept a key only when (a) the state lists it with the same
// public key, (b) its registration signatures verify, (c) the verified
// transparency log really contains that registration (so the server cannot
// invent a device out of thin air), (d) it is approved and not revoked. They
// FAIL CLOSED: a missing device, a missing log index, or any mismatch rejects.

// CircleMember is one member of the circle state with their active device keys.
type CircleMember struct {
	UserID  string         `json:"user_id"`
	Name    string         `json:"name"`
	Role    string         `json:"role"`
	Devices []DeviceRecord `json:"devices"`
}

// FindDevice returns the listed device and its member, or nils.
func FindDevice(members []CircleMember, deviceID string) (*DeviceRecord, *CircleMember) {
	for i := range members {
		for j := range members[i].Devices {
			if members[i].Devices[j].DeviceID == deviceID {
				return &members[i].Devices[j], &members[i]
			}
		}
	}
	return nil, nil
}

// LogIndex indexes a fully verified log (every page from entry 1).
type LogIndex struct {
	hashes  map[int64][]byte
	regs    map[string]LogEntry // subject device -> its registration entry
	epochs  map[string]LogEntry // circle|epoch -> enable/epoch entry
	revoked map[string]int64    // device -> sequence number of the first logged revoke
	// actorKey is the one Ed25519 key each acting device id has used in the log.
	// A log entry only proves "some key signed this"; binding it to the device id is
	// what stops a forged voucher.
	actorKey map[string]string
	// conflict is set when one device id appears with two different keys (the log
	// is then not trusted at all).
	conflict string
}

// ErrNotInLog marks a key the verified log does not contain (yet).
var ErrNotInLog = errors.New("e2ee: not in the verified log")

func newLogIndex() *LogIndex {
	return &LogIndex{hashes: map[int64][]byte{}, regs: map[string]LogEntry{}, epochs: map[string]LogEntry{}, revoked: map[string]int64{}, actorKey: map[string]string{}}
}

func (x *LogIndex) add(e LogEntry) {
	if h, err := hex.DecodeString(e.EntryHash); err == nil {
		x.hashes[e.Seq] = h
	}
	if e.Redacted || e.Action == nil {
		return
	}
	if e.ActorDeviceID != nil && e.ActorPub != nil {
		if k, ok := x.actorKey[*e.ActorDeviceID]; ok && k != *e.ActorPub && x.conflict == "" {
			x.conflict = fmt.Sprintf("entry %d: device %s signs with a different key than before", e.Seq, *e.ActorDeviceID)
		} else if !ok {
			x.actorKey[*e.ActorDeviceID] = *e.ActorPub
		}
	}
	switch byte(*e.Action) {
	case ActEnable, ActEpoch:
		if e.CircleID != nil && e.Epoch != nil {
			x.epochs[fmt.Sprintf("%s|%d", *e.CircleID, *e.Epoch)] = e
		}
	case ActRegister, ActRotate, ActRecovery, ActReset:
		if e.SubjectID != nil {
			if _, dup := x.regs[*e.SubjectID]; dup && x.conflict == "" {
				x.conflict = fmt.Sprintf("entry %d: device %s is registered twice", e.Seq, *e.SubjectID)
			} else if !dup {
				x.regs[*e.SubjectID] = e
			}
		}
	case ActRevoke:
		if e.SubjectID != nil {
			if _, ok := x.revoked[*e.SubjectID]; !ok {
				x.revoked[*e.SubjectID] = e.Seq
			}
		}
	}
}

// SyncLogFull verifies the whole log from entry 1 (page by page) and indexes it.
// The pinned head still applies: a shorter log is a rollback, and a different
// hash at the pinned sequence number is a fork.
func SyncLogFull(pinned *LogHead, fetch LogFetcher) (LogCheck, *LogIndex, error) {
	idx := newLogIndex()
	var all []LogEntry
	seen := map[int64]bool{}
	capture := func(after int64) ([]LogEntry, LogHead, error) {
		es, h, err := fetch(after)
		for _, e := range es { // pages overlap by one entry; index each sequence number once
			if !seen[e.Seq] {
				seen[e.Seq] = true
				all = append(all, e)
			}
		}
		return es, h, err
	}
	c, err := SyncLog(nil, capture)
	if err != nil || !c.OK() {
		return c, nil, err
	}
	for _, e := range all {
		idx.add(e)
	}
	if idx.conflict != "" {
		return LogCheck{Problem: LogMalformed, Detail: idx.conflict}, nil, nil
	}
	if pinned != nil {
		if c.NewHead.Seq < pinned.Seq {
			return LogCheck{Problem: LogRollback, Detail: fmt.Sprintf("the server log is shorter (%d) than the one pinned (%d)", c.NewHead.Seq, pinned.Seq)}, nil, nil
		}
		if h, ok := idx.hashes[pinned.Seq]; !ok || !ConstEq(h, pinned.Hash) {
			return LogCheck{Problem: LogFork, Detail: fmt.Sprintf("entry %d is not the one pinned", pinned.Seq)}, nil, nil
		}
	}
	return c, idx, nil
}

// Revoked reports whether the log revokes the device.
func (x *LogIndex) Revoked(deviceID string) bool {
	if x == nil {
		return false
	}
	_, ok := x.revoked[deviceID]
	return ok
}

// RegistrationLogged requires a log entry that matches every field of the
// device's registration (user, actor, action, fingerprint, signature, actor key).
func (x *LogIndex) RegistrationLogged(d DeviceRecord) bool {
	if x == nil {
		return false
	}
	e, ok := x.regs[d.DeviceID]
	if !ok || e.Action == nil || e.UserID == nil || e.ActorDeviceID == nil || e.Ref == nil || e.Signature == nil || e.ActorPub == nil {
		return false
	}
	return *e.Action == d.RegistrationAction && *e.UserID == d.UserID && *e.ActorDeviceID == d.RegisteredByDeviceID &&
		*e.Ref == d.Fingerprint && *e.Signature == d.RegistrationSignature && *e.ActorPub == d.RegisteredByPub
}

// ChainLogged follows the registration chain (voucher after voucher) up to a
// self-registered root. Strict rules, all fail closed:
//   - every hop's registration is in the log, field for field;
//   - each voucher's key as used in the hop (RegisteredByPub) is the key that
//     device id has always signed with in the log, and equals the key the circle
//     state lists for it when it is listed (so a forged "voucher" under a real
//     device id but an attacker's key is refused);
//   - a voucher revoked in the log BEFORE the vouched registration cannot mint
//     devices (a registration that predates the revoke stays valid).
func (x *LogIndex) ChainLogged(d DeviceRecord, members []CircleMember) bool {
	if x == nil {
		return false
	}
	if k, ok := x.actorKey[d.DeviceID]; ok && k != d.Ed25519Pub {
		return false
	}
	cur := d
	for depth := 0; depth < 16; depth++ {
		if !x.RegistrationLogged(cur) {
			return false
		}
		regSeq := x.regs[cur.DeviceID].Seq
		v := cur.RegisteredByDeviceID
		k, ok := x.actorKey[v]
		if !ok || k != cur.RegisteredByPub {
			return false
		}
		if v == cur.DeviceID {
			if vd, _ := FindDevice(members, v); vd != nil && vd.Ed25519Pub != k {
				return false
			}
			return true // self-registered root, anchored by its own key
		}
		// A non-root voucher's key is only known to be genuine from the circle state
		// (its fingerprint binds that key). A voucher that is no longer listed counts
		// only if it is itself a self-registered root, whose entry anchors its key.
		if vd, _ := FindDevice(members, v); vd != nil {
			if vd.Ed25519Pub != k {
				return false
			}
		} else if re, ok := x.regs[v]; !ok || re.ActorDeviceID == nil || *re.ActorDeviceID != v {
			return false
		}
		if r, revoked := x.revoked[v]; revoked && r < regSeq {
			return false
		}
		e := x.regs[v]
		if e.Action == nil || e.SubjectID == nil || e.UserID == nil || e.ActorDeviceID == nil || e.Ref == nil || e.Signature == nil || e.ActorPub == nil {
			return false
		}
		if *e.UserID != d.UserID {
			return false
		}
		cur = DeviceRecord{DeviceID: *e.SubjectID, UserID: *e.UserID, RegisteredByDeviceID: *e.ActorDeviceID,
			RegistrationAction: *e.Action, Fingerprint: *e.Ref, RegistrationSignature: *e.Signature, RegisteredByPub: *e.ActorPub}
	}
	return false
}

// EpochLogged requires an enable/epoch log entry that matches the served record.
func (x *LogIndex) EpochLogged(circleID string, r EpochRecord) bool {
	if x == nil {
		return false
	}
	e, ok := x.epochs[fmt.Sprintf("%s|%d", circleID, r.Epoch)]
	if !ok || e.Action == nil || e.UserID == nil || e.ActorDeviceID == nil || e.ActorPub == nil || e.Ref == nil || e.Signature == nil {
		return false
	}
	commit, err := b64(r.KeyCommitment)
	if err != nil {
		return false
	}
	return *e.Action == r.Action && *e.UserID == r.PublisherUser && *e.ActorDeviceID == r.PublisherDev &&
		*e.ActorPub == r.PublisherPub && *e.Ref == hex.EncodeToString(commit) && *e.Signature == r.Signature
}

// usable: listed, active, approved, registration verifies and is chained in the log.
func usable(idx *LogIndex, members []CircleMember, d *DeviceRecord) error {
	switch {
	case d == nil:
		return errors.New("device is not in the circle state")
	case d.RevokedAt != nil || idx.Revoked(d.DeviceID):
		return errors.New("device is revoked")
	case d.Kind == "recovery":
		return errors.New("recovery keys do not act in a circle")
	case d.Approved == nil || !*d.Approved:
		return errors.New("device is not approved")
	case !VerifyRegistration(*d):
		return errors.New("device registration does not verify")
	case !idx.ChainLogged(*d, members):
		return fmt.Errorf("device registration: %w", ErrNotInLog)
	}
	return nil
}

// AuthorizeSender checks that an item's sender device may speak for its member:
// listed, owned by that member (the signed user id equals the member's), usable.
func AuthorizeSender(idx *LogIndex, members []CircleMember, d *DeviceRecord, m *CircleMember) error {
	if d == nil || m == nil {
		return errors.New("sender is not in the circle state")
	}
	if d.UserID != m.UserID {
		return errors.New("device belongs to another user than the member it is listed under")
	}
	return usable(idx, members, d)
}

// AuthorizeWrap decides whether a wrap addressed to the caller may be opened:
// the epoch record is in the log and published by an active, approved circle
// admin whose key matches the record; the wrapper is an active, approved listed
// device whose key matches; and the wrapper is either the publisher's user or
// the recipient's own user (the server enforces the same rule).
func AuthorizeWrap(idx *LogIndex, members []CircleMember, circleID, recipientUserID string, w WrapRecord, rec *EpochRecord) error {
	if idx == nil || rec == nil {
		return errors.New("no verified log or epoch record")
	}
	if !idx.EpochLogged(circleID, *rec) {
		return fmt.Errorf("epoch record: %w", ErrNotInLog)
	}
	pd, pm := FindDevice(members, rec.PublisherDev)
	if pd == nil || pm == nil {
		return errors.New("epoch publisher is not in the circle state")
	}
	if pd.Ed25519Pub != rec.PublisherPub || pd.UserID != rec.PublisherUser || pm.UserID != rec.PublisherUser {
		return errors.New("epoch publisher key differs from the registered key")
	}
	if pm.Role != "admin" {
		return errors.New("epoch publisher is not a circle admin")
	}
	if err := usable(idx, members, pd); err != nil {
		return fmt.Errorf("epoch publisher: %w", err)
	}
	wd, wm := FindDevice(members, w.WrapperDeviceID)
	if wd == nil || wm == nil {
		return errors.New("wrapper is not in the circle state")
	}
	if wd.Ed25519Pub != w.WrapperEd25519Pub || wd.UserID != wm.UserID {
		return errors.New("wrapper key differs from the registered key")
	}
	if err := usable(idx, members, wd); err != nil {
		return fmt.Errorf("wrapper: %w", err)
	}
	if wd.UserID != rec.PublisherUser && wd.UserID != recipientUserID {
		return errors.New("wrapper is neither the epoch publisher nor the recipient's own device")
	}
	return nil
}
