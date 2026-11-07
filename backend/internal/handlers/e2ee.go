package handlers

// End-to-end encryption, phase 1: public device keys and wrapped circle keys.
//
// The server stores PUBLIC keys and CIPHERTEXT only. It cannot decrypt a wrap,
// and no endpoint accepts a private key or a plaintext circle key. It enforces
// who may publish what (authorization), checks the cryptographic bindings that
// can be checked without a secret (self-signatures), and keeps the epoch
// monotonic. See docs/design/E2EE.md.

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const (
	e2eeMaxDevicesPerUser = 10
	e2eeRegisterPerUser   = 10
	e2eeRegisterWindow    = time.Hour
	e2eeRotatePerUser     = 5
	e2eeRotateWindow      = time.Hour
	e2eeWrapPerUser       = 30
	e2eeWrapWindow        = time.Minute
	e2eeReadPerUser       = 120
	e2eeReadWindow        = time.Minute
	e2eeAdminOpPerUser    = 20
	e2eeAdminOpWindow     = time.Hour
	e2eeMaxWrapsPerReq    = 200
	e2eeMaxBody           = 256 << 10
)

// e2eeDeviceOut is the public record of a device identity.
type e2eeDeviceOut struct {
	DeviceID              string     `json:"device_id"`
	UserID                string     `json:"user_id"`
	Kind                  string     `json:"kind"`
	Ed25519Pub            string     `json:"ed25519_pub"`
	X25519Pub             string     `json:"x25519_pub"`
	Fingerprint           string     `json:"fingerprint"`
	Digits                string     `json:"digits"`
	Short                 string     `json:"short"`
	Signature             string     `json:"signature"`
	RegisteredByDeviceID  string     `json:"registered_by_device_id"`
	RegisteredByPub       string     `json:"registered_by_ed25519_pub"`
	RegistrationAction    int        `json:"registration_action"`
	RegistrationSignature string     `json:"registration_signature"`
	Initial               bool       `json:"initial"`
	Label                 string     `json:"label"`
	CreatedAt             time.Time  `json:"created_at"`
	RevokedAt             *time.Time `json:"revoked_at"`
	RevokedReason         *string    `json:"revoked_reason,omitempty"`
	// Caps are self-declared client capabilities ("lanes2"); advisory only.
	Caps []string `json:"caps"`
	// Approved is set only where a circle is in context (circle state, pending
	// queue): whether wraps may be issued to this device in that circle.
	Approved *bool `json:"approved,omitempty"`
}

const e2eeDeviceCols = `d.device_id::text, d.user_id::text, d.kind, d.ed25519_pub, d.x25519_pub, d.fingerprint, d.signature,
	d.registered_by_device_id::text, d.registered_by_pub, d.registration_action, d.registration_signature, d.initial,
	d.label, d.created_at, d.revoked_at, d.revoked_reason, d.caps`

// e2eeApprovedExpr is true when wraps may go to device d in circle $N. It is
// transitive: see migration 000151 (e2ee_device_approved).
func e2eeApprovedExpr(circleParam string) string {
	return `e2ee_device_approved(d.device_id, ` + circleParam + `::uuid)`
}

type rowScanner interface{ Scan(dest ...any) error }

func scanE2EEDevice(row rowScanner, extra ...any) (e2eeDeviceOut, error) {
	var o e2eeDeviceOut
	var ed, x, sig, rpub, rsig []byte
	dest := []any{&o.DeviceID, &o.UserID, &o.Kind, &ed, &x, &o.Fingerprint, &sig, &o.RegisteredByDeviceID, &rpub,
		&o.RegistrationAction, &rsig, &o.Initial, &o.Label, &o.CreatedAt, &o.RevokedAt, &o.RevokedReason, &o.Caps}
	if err := row.Scan(append(dest, extra...)...); err != nil {
		return o, err
	}
	o.Ed25519Pub = base64.StdEncoding.EncodeToString(ed)
	o.X25519Pub = base64.StdEncoding.EncodeToString(x)
	o.Signature = base64.StdEncoding.EncodeToString(sig)
	o.RegisteredByPub = base64.StdEncoding.EncodeToString(rpub)
	o.RegistrationSignature = base64.StdEncoding.EncodeToString(rsig)
	if fp, err := hex.DecodeString(o.Fingerprint); err == nil && len(fp) == 32 {
		o.Digits = e2ee.DigitGroups(fp)
		o.Short = e2ee.ShortFingerprint(fp)
	}
	return o, nil
}

func decodeE2EEBody(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, e2eeMaxBody)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return false
	}
	return true
}

func b64d(s string, want int) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || (want > 0 && len(b) != want) {
		return nil, false
	}
	return b, true
}

// keyBundle is a device's public keys plus the registration self-signature.
type keyBundle struct {
	DeviceID   string `json:"device_id"`
	Ed25519Pub string `json:"ed25519_pub"`
	X25519Pub  string `json:"x25519_pub"`
	Signature  string `json:"signature"`
	Label      string `json:"label"`
}

type parsedBundle struct {
	ed, x, sig []byte
	fp         []byte
	label      string
}

// parseBundle validates lengths, weak keys and the binding signature for userID.
func parseBundle(userID string, kb keyBundle) (parsedBundle, string) {
	var p parsedBundle
	var ok bool
	if e2ee.CheckID(kb.DeviceID) != nil {
		return p, "device_id must be a lower-case UUID"
	}
	if p.ed, ok = b64d(kb.Ed25519Pub, e2ee.PubLen); !ok {
		return p, "ed25519_pub must be 32 bytes, base64"
	}
	if p.x, ok = b64d(kb.X25519Pub, e2ee.PubLen); !ok {
		return p, "x25519_pub must be 32 bytes, base64"
	}
	if p.sig, ok = b64d(kb.Signature, e2ee.SigLen); !ok {
		return p, "signature must be 64 bytes, base64"
	}
	if len(kb.Label) > 60 {
		return p, "label too long"
	}
	p.label = kb.Label
	if err := e2ee.VerifyBinding(userID, kb.DeviceID, p.ed, p.x, p.sig); err != nil {
		if errors.Is(err, e2ee.ErrBadSig) {
			return p, "signature does not verify"
		}
		return p, "invalid public key"
	}
	fp, err := e2ee.Fingerprint(p.ed, p.x)
	if err != nil {
		return p, "invalid public key"
	}
	p.fp = fp
	return p, ""
}

// ------------------------------------------------------------ the log

var logLockKey int64 = 0x0f2e2ee1

// appendLog adds one signed entry to the transparency log inside tx. The caller
// has already verified the signature. Entries are serialised by an advisory
// lock so the chain has exactly one successor per entry.
func appendLog(ctx context.Context, tx pgx.Tx, action byte, userID, actorID string, actorPub []byte, circleID, subjectID string, epoch uint32, ref, sig []byte) error {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, logLockKey); err != nil {
		return err
	}
	prev, seq := e2ee.GenesisHash, uint64(0)
	var last []byte
	var lastSeq int64
	err := tx.QueryRow(ctx, `SELECT seq, entry_hash FROM e2ee_log ORDER BY seq DESC LIMIT 1`).Scan(&lastSeq, &last)
	if err == nil {
		prev, seq = last, uint64(lastSeq)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	seq++
	msg, err := e2ee.LogActionMessage(action, userID, actorID, circleID, subjectID, epoch, ref)
	if err != nil {
		return err
	}
	hash := e2ee.LogEntryHash(prev, seq, msg, sig)
	var cid, sid any
	if circleID != "" {
		cid = circleID
	}
	if subjectID != "" {
		sid = subjectID
	}
	if ref == nil {
		ref = make([]byte, 32)
	}
	_, err = tx.Exec(ctx, `INSERT INTO e2ee_log (seq, action, user_id, actor_device_id, actor_pub, circle_id, subject_id, epoch, ref, signature, prev_hash, entry_hash)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		seq, int(action), userID, actorID, actorPub, cid, sid, int(epoch), ref, sig, prev, hash)
	return err
}

// activeKeyPub returns the Ed25519 key of an ACTIVE key (device or recovery)
// owned by userID.
func activeKeyPub(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, userID, deviceID string) ([]byte, bool) {
	var pub []byte
	err := q.QueryRow(ctx, `SELECT ed25519_pub FROM device_keys WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
		deviceID, userID).Scan(&pub)
	return pub, err == nil
}

type registerReq struct {
	keyBundle
	Kind string `json:"kind"`
	// ActorDeviceID is the existing key that cross-signs this one. Empty or equal
	// to device_id makes this a ROOT key (signed by itself).
	ActorDeviceID string `json:"actor_device_id"`
	// LogSignature is the actor's signature over the log action message.
	LogSignature string `json:"log_signature"`
	// Reset declares that this root key replaces ALL the user's active keys.
	Reset bool `json:"reset"`
	// CanUpload lets a "web" or "service" key post sealed items. Phones always
	// can; recovery keys never; read-only kinds default to false.
	CanUpload bool `json:"can_upload"`
	// Caps are the client's self-declared capabilities (unsigned; see
	// e2ee_processing.go). Unknown values are dropped. A key without "lanes2"
	// stays phone-only: it is never counted ready for server assistance.
	Caps []string `json:"caps"`
}

const devInsert = `INSERT INTO device_keys (device_id, user_id, kind, ed25519_pub, x25519_pub, fingerprint, signature,
	registered_by_device_id, registered_by_pub, registration_action, registration_signature, initial, label, can_upload, caps)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
	RETURNING ` + `device_id::text, user_id::text, kind, ed25519_pub, x25519_pub, fingerprint, signature,
	registered_by_device_id::text, registered_by_pub, registration_action, registration_signature, initial,
	label, created_at, revoked_at, revoked_reason, caps`

// E2EERegisterDevice registers a device identity (public keys only).
//
//   - The first key a user ever registers is a root and needs no vouching.
//   - Every later key must be cross-signed by an existing active key of the same
//     user (a device or the recovery identity); the signature is the log entry.
//   - A root key while the user still has active keys needs "reset": true, which
//     revokes all of them, and a circle admin must approve it per circle before
//     it receives any wrap.
//   - kind "recovery" registers the recovery-phrase identity; never a root.
//
// Re-registering the identical active key returns the existing record.
func (s *Server) E2EERegisterDevice(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eereg:user:"+uid, e2eeRegisterPerUser, e2eeRegisterWindow) {
		return
	}
	var req registerReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if req.Kind == "" {
		req.Kind = "device"
	}
	if req.Kind != "device" && req.Kind != "recovery" && req.Kind != "web" && req.Kind != "service" && req.Kind != "server" {
		writeError(w, http.StatusBadRequest, "kind must be device, recovery, web, service or server")
		return
	}
	if !registerServerKindOK(w, req.Kind) {
		return
	}
	p, msg := parseBundle(uid, req.keyBundle)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	logSig, ok := b64d(req.LogSignature, e2ee.SigLen)
	if !ok {
		writeError(w, http.StatusBadRequest, "log_signature must be 64 bytes, base64")
		return
	}
	actor := req.ActorDeviceID
	if actor == "" {
		actor = req.DeviceID
	}
	root := actor == req.DeviceID
	ctx := r.Context()
	if root && (req.Kind == "web" || req.Kind == "service" || req.Kind == "server") {
		writeError(w, http.StatusBadRequest, "a web, service or server key must be cross-signed by an existing key of the same user")
		return
	}
	if root && req.Kind == "recovery" {
		writeError(w, http.StatusBadRequest, "a recovery key must be cross-signed by an existing key")
		return
	}

	// Idempotent re-registration.
	if ex, err := scanE2EEDevice(s.Pool.QueryRow(ctx, `SELECT `+e2eeDeviceCols+` FROM device_keys d
		WHERE d.ed25519_pub = $1 AND d.revoked_at IS NULL`, p.ed)); err == nil {
		if ex.UserID == uid && ex.DeviceID == req.DeviceID && ex.X25519Pub == req.X25519Pub {
			writeJSON(w, http.StatusOK, ex)
			return
		}
		writeError(w, http.StatusConflict, "key already registered")
		return
	} else if !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}

	if req.Kind == "device" && !hasLanes2(cleanCaps(req.Caps)) && oldKeyBlocksRegistration(ctx, s.Pool, uid) {
		writeUpdateRequired(w, nil)
		return
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	defer tx.Rollback(ctx)
	// Serialise per user so two concurrent registrations cannot both be "first".
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "e2eeuser:"+uid); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	var total, active, activeDevices int
	if err := tx.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE revoked_at IS NULL),
		count(*) FILTER (WHERE revoked_at IS NULL AND kind = 'device') FROM device_keys WHERE user_id = $1`, uid).Scan(&total, &active, &activeDevices); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	var signerPub []byte
	var action byte
	initial := false
	switch {
	case root:
		signerPub = p.ed
		switch {
		case total == 0:
			action, initial = e2ee.ActRegister, true
		case active > 0 && !req.Reset:
			writeJSON(w, http.StatusConflict, map[string]string{"error": "cross_signature_required",
				"detail": "sign this key with an existing device or the recovery phrase, or reset all keys"})
			return
		default:
			action = e2ee.ActReset
		}
	default:
		signerPub, ok = activeKeyPub(ctx, tx, uid, actor)
		if !ok {
			writeError(w, http.StatusBadRequest, "cross-signing key is not an active key of the caller")
			return
		}
		action = e2ee.ActRegister
		if req.Kind == "recovery" {
			action = e2ee.ActRecovery
		}
	}
	if req.Kind == "device" && activeDevices >= e2eeMaxDevicesPerUser && !(root && req.Reset) {
		writeError(w, http.StatusConflict, "too many active device keys; revoke one first")
		return
	}
	if req.Kind == "web" || req.Kind == "service" || req.Kind == "server" {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM device_keys WHERE user_id = $1 AND revoked_at IS NULL AND kind IN ('web','service','server')`, uid).Scan(&n); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to register key")
			return
		}
		if n >= 5 {
			writeError(w, http.StatusConflict, "too many active web/service keys; revoke one first")
			return
		}
	}
	if err := e2ee.VerifyLogAction(signerPub, action, uid, actor, "", req.DeviceID, 0, p.fp, logSig); err != nil {
		writeError(w, http.StatusBadRequest, "log signature does not verify")
		return
	}
	if root && action == e2ee.ActReset && active > 0 {
		if _, err := tx.Exec(ctx, `UPDATE device_keys SET revoked_at = now(), revoked_reason = 'revoked'
			WHERE user_id = $1 AND revoked_at IS NULL`, uid); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to register key")
			return
		}
	}
	out, err := scanE2EEDevice(tx.QueryRow(ctx, devInsert, req.DeviceID, uid, req.Kind, p.ed, p.x, e2ee.FingerprintHex(p.fp), p.sig,
		actor, signerPub, int(action), logSig, initial, p.label, req.Kind == "device" || (req.CanUpload && req.Kind != "recovery" && req.Kind != "server"), cleanCaps(req.Caps)))
	if err != nil {
		if isUpdateRequiredErr(err) {
			writeUpdateRequired(w, nil)
			return
		}
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "key already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	if err := appendLog(ctx, tx, action, uid, actor, signerPub, "", req.DeviceID, 0, p.fp, logSig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to register key")
		return
	}
	name := "e2ee.device_registered"
	if action == e2ee.ActReset {
		name = "e2ee.device_reset"
	} else if req.Kind == "recovery" {
		name = "e2ee.recovery_registered"
	}
	s.logAudit(ctx, uid, "", name, "device "+out.DeviceID+" fingerprint "+out.Short, clientIP(r))
	writeJSON(w, http.StatusCreated, out)
}

// E2EERotateDevice replaces one of the caller's keys with a new pair. The OLD
// key must sign (log action "rotate", subject = new device id, ref = new
// fingerprint), so a stolen session token alone cannot swap a key; without the
// old key use revoke plus register (peers see an unrelated key, honestly).
func (s *Server) E2EERotateDevice(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eerot:user:"+uid, e2eeRotatePerUser, e2eeRotateWindow) {
		return
	}
	oldID := chi.URLParam(r, "id")
	var req registerReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if e2ee.CheckID(oldID) != nil {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	}
	p, msg := parseBundle(uid, req.keyBundle)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	logSig, ok := b64d(req.LogSignature, e2ee.SigLen)
	if !ok {
		writeError(w, http.StatusBadRequest, "log_signature must be 64 bytes, base64")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	defer tx.Rollback(ctx)
	var oldEd []byte
	var kind string
	var oldCanUpload bool
	var oldCaps []string
	err = tx.QueryRow(ctx, `SELECT ed25519_pub, kind, can_upload, caps FROM device_keys
		WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL FOR UPDATE`, oldID, uid).Scan(&oldEd, &kind, &oldCanUpload, &oldCaps)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	if kind == "device" && !hasLanes2(rotatedCaps(req.Caps, oldCaps)) && oldKeyBlocksRegistration(ctx, tx, uid) {
		writeUpdateRequired(w, nil)
		return
	}
	if kind == "server" {
		writeError(w, http.StatusBadRequest, "a server key cannot be rotated; revoke it and enroll a new one (every member consents again)")
		return
	}
	if e2ee.ConstEq(oldEd, p.ed) {
		writeError(w, http.StatusBadRequest, "new key must differ from the old key")
		return
	}
	if err := e2ee.VerifyLogAction(oldEd, e2ee.ActRotate, uid, oldID, "", req.DeviceID, 0, p.fp, logSig); err != nil {
		writeError(w, http.StatusBadRequest, "rotation signature does not verify")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE device_keys SET revoked_at = now(), revoked_reason = 'rotated' WHERE device_id = $1`, oldID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	out, err := scanE2EEDevice(tx.QueryRow(ctx, devInsert, req.DeviceID, uid, kind, p.ed, p.x, e2ee.FingerprintHex(p.fp), p.sig,
		oldID, oldEd, int(e2ee.ActRotate), logSig, false, p.label, oldCanUpload, rotatedCaps(req.Caps, oldCaps)))
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "key already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	if err := appendLog(ctx, tx, e2ee.ActRotate, uid, oldID, oldEd, "", req.DeviceID, 0, p.fp, logSig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to rotate key")
		return
	}
	s.logAudit(ctx, uid, "", "e2ee.device_rotated", "device "+oldID+" -> "+out.DeviceID+" fingerprint "+out.Short, clientIP(r))
	writeJSON(w, http.StatusCreated, out)
}

type signedAction struct {
	ActorDeviceID string `json:"actor_device_id"`
	LogSignature  string `json:"log_signature"`
}

// E2EERevokeDevice revokes one of the caller's keys. The request body carries
// the acting key and its signature over the log action (action "revoke").
func (s *Server) E2EERevokeDevice(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eerot:user:"+uid, e2eeRotatePerUser*2, e2eeRotateWindow) {
		return
	}
	id := chi.URLParam(r, "id")
	var req signedAction
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if e2ee.CheckID(id) != nil {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	}
	sig, ok := b64d(req.LogSignature, e2ee.SigLen)
	if !ok || e2ee.CheckID(req.ActorDeviceID) != nil {
		writeError(w, http.StatusBadRequest, "actor_device_id and log_signature required")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke key")
		return
	}
	defer tx.Rollback(ctx)
	var fp string
	if err := tx.QueryRow(ctx, `SELECT fingerprint FROM device_keys WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL FOR UPDATE`, id, uid).Scan(&fp); err != nil {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	}
	actorPub, ok := activeKeyPub(ctx, tx, uid, req.ActorDeviceID)
	if !ok {
		writeError(w, http.StatusBadRequest, "acting key is not an active key of the caller")
		return
	}
	fpRaw, _ := hex.DecodeString(fp)
	if err := e2ee.VerifyLogAction(actorPub, e2ee.ActRevoke, uid, req.ActorDeviceID, "", id, 0, fpRaw, sig); err != nil {
		writeError(w, http.StatusBadRequest, "log signature does not verify")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE device_keys SET revoked_at = now(), revoked_reason = 'revoked' WHERE device_id = $1`, id); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke key")
		return
	}
	if err := appendLog(ctx, tx, e2ee.ActRevoke, uid, req.ActorDeviceID, actorPub, "", id, 0, fpRaw, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke key")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to revoke key")
		return
	}
	s.logAudit(ctx, uid, "", "e2ee.device_revoked", "device "+id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// E2EEMyDevices returns the server's record of the caller's own device keys,
// revoked ones included, so the phone can compare it with what it holds.
func (s *Server) E2EEMyDevices(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	rows, err := s.Pool.Query(r.Context(), `SELECT `+e2eeDeviceCols+` FROM device_keys d
		WHERE d.user_id = $1 ORDER BY d.created_at DESC LIMIT 50`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load keys")
		return
	}
	defer rows.Close()
	out := []e2eeDeviceOut{}
	for rows.Next() {
		d, err := scanE2EEDevice(rows)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load keys")
			return
		}
		out = append(out, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// sharesCircle reports whether a and b are members of one live circle (or are
// the same user).
func (s *Server) sharesCircle(ctx context.Context, a, b string) (bool, error) {
	if a == b {
		return true, nil
	}
	var ok bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM live_circle_members x JOIN live_circle_members y ON x.circle_id = y.circle_id
		WHERE x.user_id = $1 AND y.user_id = $2)`, a, b).Scan(&ok)
	return ok, err
}

// E2EEUserDevices lists a user's ACTIVE device keys. Visible to the user and to
// people who share a circle with them; everyone else gets 404.
func (s *Server) E2EEUserDevices(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	target := chi.URLParam(r, "user_id")
	if e2ee.CheckID(target) != nil {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	shares, err := s.sharesCircle(r.Context(), uid, target)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load keys")
		return
	}
	if !shares {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `SELECT `+e2eeDeviceCols+` FROM device_keys d
		WHERE d.user_id = $1 AND d.revoked_at IS NULL ORDER BY d.created_at`, target)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load keys")
		return
	}
	defer rows.Close()
	out := []e2eeDeviceOut{}
	for rows.Next() {
		d, err := scanE2EEDevice(rows)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load keys")
			return
		}
		out = append(out, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"user_id": target, "devices": out})
}

type e2eeMemberOut struct {
	UserID  string          `json:"user_id"`
	Name    string          `json:"name"`
	Role    string          `json:"role"`
	Devices []e2eeDeviceOut `json:"devices"`
}

// E2EECircleState returns a circle's E2EE state and its members' ACTIVE keys
// (public data), each flagged approved or waiting for approval. Any member.
func (s *Server) E2EECircleState(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	ctx := r.Context()
	var mode string
	var epoch int
	var rekey bool
	var updated *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode, e2ee_epoch, e2ee_rekey_required, e2ee_updated_at FROM circles WHERE id = $1`,
		m.CircleID).Scan(&mode, &epoch, &rekey, &updated); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT cm.user_id::text, u.name, cm.role
		FROM live_circle_members cm JOIN users u ON u.id = cm.user_id
		WHERE cm.circle_id = $1 ORDER BY u.name, cm.user_id`, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	members := []*e2eeMemberOut{}
	byID := map[string]*e2eeMemberOut{}
	for rows.Next() {
		mo := &e2eeMemberOut{Devices: []e2eeDeviceOut{}}
		if err := rows.Scan(&mo.UserID, &mo.Name, &mo.Role); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load members")
			return
		}
		byID[mo.UserID] = mo
		members = append(members, mo)
	}
	rows.Close()
	drows, err := s.Pool.Query(ctx, `
		SELECT `+e2eeDeviceCols+`, `+e2eeApprovedExpr("$1")+`
		FROM live_circle_members cm
		JOIN device_keys d ON d.user_id = cm.user_id AND d.revoked_at IS NULL
		WHERE cm.circle_id = $1 ORDER BY d.created_at`, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	defer drows.Close()
	for drows.Next() {
		var approved bool
		d, err := scanE2EEDevice(drows, &approved)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load members")
			return
		}
		d.Approved = &approved
		if mo := byID[d.UserID]; mo != nil {
			mo.Devices = append(mo.Devices, d)
		}
	}
	type epochOut struct {
		Epoch         int    `json:"epoch"`
		Action        int    `json:"action"`
		PublisherUser string `json:"publisher_user_id"`
		PublisherDev  string `json:"publisher_device_id"`
		PublisherPub  string `json:"publisher_ed25519_pub"`
		KeyCommitment string `json:"key_commitment"`
		Signature     string `json:"signature"`
	}
	epochs := []epochOut{}
	if er, err := s.Pool.Query(ctx, `SELECT epoch, action, user_id::text, actor_device_id::text, actor_pub, ref, signature
		FROM e2ee_log WHERE circle_id = $1 AND action IN (5, 6) ORDER BY seq`, m.CircleID); err == nil {
		for er.Next() {
			var o epochOut
			var pub, ref, sig []byte
			if er.Scan(&o.Epoch, &o.Action, &o.PublisherUser, &o.PublisherDev, &pub, &ref, &sig) == nil {
				o.PublisherPub, o.KeyCommitment, o.Signature = base64.StdEncoding.EncodeToString(pub),
					base64.StdEncoding.EncodeToString(ref), base64.StdEncoding.EncodeToString(sig)
				epochs = append(epochs, o)
			}
		}
		er.Close()
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"circle_id": m.CircleID, "mode": mode, "epoch": epoch, "rekey_required": rekey,
		"updated_at": updated, "members": members, "epochs": epochs,
	})
}

// wrapIn is one wrapped key in a request.
type wrapIn struct {
	RecipientDeviceID string `json:"recipient_device_id"`
	WrapperDeviceID   string `json:"wrapper_device_id"`
	WrappedKey        string `json:"wrapped_key"`
	Signature         string `json:"signature"`
}

type wrapsReq struct {
	Epoch int      `json:"epoch"`
	Wraps []wrapIn `json:"wraps"`
	// KeyCommitment = HKDF(circle_key, ..., "OFE2EE1-KEY-COMMIT") (base64, 32
	// bytes). It is the signed `ref` of the enable/epoch log action; phones check
	// every unwrapped key against it before accepting it.
	KeyCommitment string `json:"key_commitment"`
	// KeyLine is "phone" (default) or "server". For the server line Epoch is the
	// SK generation.
	KeyLine string `json:"key_line"`
	signedAction
}

// insertWraps validates and stores wraps for (circleID, epoch). Every wrap must
// come from an active key of the caller, go to an active key of a current circle
// member that is APPROVED in this circle, and carry a valid wrapper signature.
// It returns how many rows were inserted and whether any wrap targets one of the
// caller's own keys. Existing wraps are never overwritten.
func (s *Server) insertWraps(ctx context.Context, tx pgx.Tx, circleID string, line e2ee.Line, epoch int, callerID, publisherUserID string, wraps []wrapIn) (inserted int, selfWrapped bool, msg string) {
	if len(wraps) > e2eeMaxWrapsPerReq {
		return 0, false, "too many wraps in one request"
	}
	if !line.Valid() || epoch < 1 {
		return 0, false, "invalid key line or generation"
	}
	var legacyCK, policyOn, hasServerLane bool
	if err := tx.QueryRow(ctx, `SELECT server_legacy_ck, server_assist,
		EXISTS (SELECT 1 FROM e2ee_processing_pref p WHERE p.circle_id = circles.id AND p.lane = 'server')
		FROM circles WHERE id = $1`, circleID).Scan(&legacyCK, &policyOn, &hasServerLane); err != nil {
		return 0, false, "failed to store wraps"
	}
	seen := map[string]bool{}
	for _, w := range wraps {
		if e2ee.CheckID(w.RecipientDeviceID) != nil || e2ee.CheckID(w.WrapperDeviceID) != nil {
			return 0, false, "invalid device id"
		}
		if seen[w.RecipientDeviceID] {
			return 0, false, "duplicate recipient"
		}
		seen[w.RecipientDeviceID] = true
		blob, ok1 := b64d(w.WrappedKey, e2ee.WrapBlobLen)
		sig, ok2 := b64d(w.Signature, e2ee.SigLen)
		if !ok1 || !ok2 || blob[0] != e2ee.WrapVersion {
			return 0, false, "malformed wrap"
		}
		wrapperEd, ok := activeKeyPub(ctx, tx, callerID, w.WrapperDeviceID)
		if !ok {
			return 0, false, "wrapper must be an active device of the caller"
		}
		var recipientUser, recipientKind string
		var approved bool
		err := tx.QueryRow(ctx, `SELECT d.user_id::text, d.kind, `+e2eeApprovedExpr("$1")+` FROM device_keys d
			JOIN live_circle_members m ON m.user_id = d.user_id AND m.circle_id = $1
			WHERE d.device_id = $2 AND d.revoked_at IS NULL`, circleID, w.RecipientDeviceID).Scan(&recipientUser, &recipientKind, &approved)
		if err != nil {
			return 0, false, "recipient must be an active device of a circle member"
		}
		if !approved {
			return 0, false, "recipient device is waiting for approval"
		}
		// The phone key is never wrapped to a server device (a legacy trusted-
		// server circle is the one flagged exception until its admin upgrades it);
		// the server key only while the policy is on and a member is in lane
		// server, and only by a phone. The database trigger repeats this.
		if recipientKind == "server" {
			if !(line == e2ee.LinePhone && legacyCK) {
				if e2ee.CheckWrapRecipient(line, recipientKind, policyOn, hasServerLane) != nil {
					return 0, false, "this key line may not be wrapped to a server device"
				}
			}
			var wk string
			if tx.QueryRow(ctx, `SELECT kind FROM device_keys WHERE device_id = $1`, w.WrapperDeviceID).Scan(&wk) != nil || wk != "device" {
				return 0, false, "a server device's wrap must be made by a phone key"
			}
		}
		// Only the epoch's publisher may issue the key to other people; anyone may
		// wrap only to their OWN other keys (new phone, recovery identity). A
		// malicious member therefore cannot pre-seed or substitute a wrap.
		if recipientUser != callerID && callerID != publisherUserID {
			return 0, false, "only the publisher of this epoch may wrap its key for other members"
		}
		if line == e2ee.LineServer {
			if err := e2ee.VerifyWrapSignatureLine(wrapperEd, circleID, line, uint32(epoch), w.RecipientDeviceID, w.WrapperDeviceID, blob, sig); err != nil {
				return 0, false, "wrap signature does not verify"
			}
		} else if e2ee.VerifyWrapSignature(wrapperEd, circleID, uint32(epoch), w.RecipientDeviceID, w.WrapperDeviceID, blob, sig) != nil &&
			e2ee.VerifyWrapSignatureLine(wrapperEd, circleID, line, uint32(epoch), w.RecipientDeviceID, w.WrapperDeviceID, blob, sig) != nil {
			return 0, false, "wrap signature does not verify"
		}
		ct, err := tx.Exec(ctx, `INSERT INTO circle_key_wraps
			(circle_id, key_line, epoch, recipient_device_id, wrapper_device_id, wrapper_ed25519_pub, wrapped_key, signature)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			ON CONFLICT (circle_id, key_line, epoch, recipient_device_id) DO UPDATE SET
			  wrapper_device_id = EXCLUDED.wrapper_device_id, wrapper_ed25519_pub = EXCLUDED.wrapper_ed25519_pub,
			  wrapped_key = EXCLUDED.wrapped_key, signature = EXCLUDED.signature, created_at = now()`,
			circleID, line.String(), epoch, w.RecipientDeviceID, w.WrapperDeviceID, wrapperEd, blob, sig)
		if err != nil {
			return 0, false, "failed to store wraps"
		}
		inserted += int(ct.RowsAffected())
		if recipientUser == callerID {
			selfWrapped = true
		}
	}
	return inserted, selfWrapped, ""
}

func (s *Server) e2eeCircleTx(w http.ResponseWriter, r *http.Request, circleID string) (pgx.Tx, string, int, bool) {
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return nil, "", 0, false
	}
	var mode string
	var epoch int
	if err := tx.QueryRow(r.Context(), `SELECT e2ee_mode, e2ee_epoch FROM circles WHERE id = $1 FOR UPDATE`,
		circleID).Scan(&mode, &epoch); err != nil {
		_ = tx.Rollback(r.Context())
		writeError(w, http.StatusNotFound, "circle not found")
		return nil, "", 0, false
	}
	return tx, mode, epoch, true
}

// verifyCircleAction checks the actor key and its signature over a circle-level
// log action, and appends the entry. ref is nil for actions without one.
func (s *Server) verifyCircleAction(w http.ResponseWriter, r *http.Request, tx pgx.Tx, action byte, uid, circleID string, epoch int, subject string, ref []byte, sa signedAction) bool {
	ctx := r.Context()
	sig, ok := b64d(sa.LogSignature, e2ee.SigLen)
	if !ok || e2ee.CheckID(sa.ActorDeviceID) != nil {
		writeError(w, http.StatusBadRequest, "actor_device_id and log_signature required")
		return false
	}
	pub, ok := activeKeyPub(ctx, tx, uid, sa.ActorDeviceID)
	if !ok {
		writeError(w, http.StatusBadRequest, "acting key is not an active key of the caller")
		return false
	}
	if err := e2ee.VerifyLogAction(pub, action, uid, sa.ActorDeviceID, circleID, subject, uint32(epoch), ref, sig); err != nil {
		writeError(w, http.StatusBadRequest, "log signature does not verify")
		return false
	}
	if err := appendLog(ctx, tx, action, uid, sa.ActorDeviceID, pub, circleID, subject, uint32(epoch), ref, sig); err != nil {
		if isUpdateRequiredErr(err) {
			writeUpdateRequired(w, nil)
			return false
		}
		writeError(w, http.StatusInternalServerError, "failed to log action")
		return false
	}
	return true
}

// E2EEEnable switches a circle to Private mode (circle admin). The admin's
// phone has generated the epoch-1 key and wrapped it; the server stores only
// the wraps. Phase 1 changes no location behavior.
func (s *Server) E2EEEnable(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req wrapsReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	tx, mode, cur, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if mode != "off" {
		writeError(w, http.StatusConflict, "circle is already private")
		return
	}
	if req.Epoch != cur+1 {
		writeError(w, http.StatusConflict, "epoch must be exactly the current epoch plus one")
		return
	}
	if !s.commitEpoch(w, r, tx, e2ee.ActEnable, m.CircleID, uid, req) {
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.enabled", "private circle enabled at epoch "+itoa(req.Epoch), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "mode": "private", "epoch": req.Epoch})
}

// E2EEBumpEpoch publishes the next epoch (circle admin): a new key generated on
// the admin's phone, wrapped to every remaining approved active key.
func (s *Server) E2EEBumpEpoch(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req wrapsReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	tx, mode, cur, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if mode != "private" {
		writeError(w, http.StatusConflict, "circle is not private")
		return
	}
	if req.Epoch != cur+1 {
		writeError(w, http.StatusConflict, "epoch must be exactly the current epoch plus one")
		return
	}
	if !s.commitEpoch(w, r, tx, e2ee.ActEpoch, m.CircleID, uid, req) {
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.epoch_bumped", "epoch "+itoa(req.Epoch), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "mode": "private", "epoch": req.Epoch})
}

// commitEpoch stores the wraps, logs the signed action, sets the new epoch and
// commits. It writes the error response itself and returns false on failure.
func (s *Server) commitEpoch(w http.ResponseWriter, r *http.Request, tx pgx.Tx, action byte, circleID, uid string, req wrapsReq) bool {
	ctx := r.Context()
	if len(req.Wraps) == 0 {
		writeError(w, http.StatusBadRequest, "at least one wrap is required")
		return false
	}
	commit, ok := b64d(req.KeyCommitment, e2ee.KeyLen)
	if !ok {
		writeError(w, http.StatusBadRequest, "key_commitment must be 32 bytes, base64")
		return false
	}
	_, self, msg := s.insertWraps(ctx, tx, circleID, e2ee.LinePhone, req.Epoch, uid, uid, req.Wraps)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return false
	}
	if !self {
		writeError(w, http.StatusBadRequest, "the new key must be wrapped to the caller's own device")
		return false
	}
	if !s.verifyCircleAction(w, r, tx, action, uid, circleID, req.Epoch, "", commit, req.signedAction) {
		return false
	}
	if _, err := tx.Exec(ctx, `UPDATE circles SET e2ee_mode = 'private', e2ee_epoch = $2,
		e2ee_rekey_required = FALSE, e2ee_updated_at = now() WHERE id = $1`, circleID, req.Epoch); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update circle")
		return false
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return false
	}
	return true
}

// E2EESubmitWraps lets any circle member publish wraps of an existing epoch key
// (<= current) for approved devices that lack one. Never overwrites.
func (s *Server) E2EESubmitWraps(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eewrap:user:"+uid, e2eeWrapPerUser, e2eeWrapWindow) {
		return
	}
	var req wrapsReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	line := e2ee.LinePhone
	if req.KeyLine != "" {
		l, err := e2ee.ParseLine(req.KeyLine)
		if err != nil {
			writeError(w, http.StatusBadRequest, "key_line must be phone or server")
			return
		}
		line = l
	}
	tx, mode, cur, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if mode != "private" {
		writeError(w, http.StatusConflict, "circle is not private")
		return
	}
	var publisher string
	if line == e2ee.LineServer {
		var assist bool
		var gen int
		if err := tx.QueryRow(r.Context(), `SELECT server_assist, e2ee_server_gen FROM circles WHERE id = $1`, m.CircleID).Scan(&assist, &gen); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to store wraps")
			return
		}
		if !assist || req.Epoch < 1 || req.Epoch > gen {
			writeError(w, http.StatusConflict, "server assistance is off or the generation does not exist")
			return
		}
		// The publisher of an SK generation is the admin whose signed policy created it.
		_ = tx.QueryRow(r.Context(), `SELECT user_id::text FROM e2ee_log WHERE circle_id = $1 AND action = $3 AND epoch = $2
			ORDER BY seq ASC LIMIT 1`, m.CircleID, req.Epoch, int(e2ee.ActProcessingPolicy)).Scan(&publisher)
	} else {
		if req.Epoch < 1 || req.Epoch > cur {
			writeError(w, http.StatusConflict, "epoch must be between 1 and the current epoch")
			return
		}
		_ = tx.QueryRow(r.Context(), `SELECT user_id::text FROM e2ee_log WHERE circle_id = $1 AND epoch = $2 AND action IN (5, 6)
			ORDER BY seq DESC LIMIT 1`, m.CircleID, req.Epoch).Scan(&publisher)
	}
	n, _, msg := s.insertWraps(r.Context(), tx, m.CircleID, line, req.Epoch, uid, publisher, req.Wraps)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	if n > 0 {
		s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.wraps_added", itoa(n)+" wrap(s) at "+line.String()+" key "+itoa(req.Epoch), clientIP(r))
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "stored": n})
}

// E2EEDisable switches a circle back to the normal mode (circle admin) and
// deletes its wraps. The epoch counter is kept so it can never repeat.
func (s *Server) E2EEDisable(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req signedAction
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	tx, mode, cur, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if mode != "private" {
		writeError(w, http.StatusConflict, "circle is not private")
		return
	}
	if !s.verifyCircleAction(w, r, tx, e2ee.ActDisable, uid, m.CircleID, cur, "", nil, req) {
		return
	}
	if _, err := tx.Exec(r.Context(), `DELETE FROM circle_key_wraps WHERE circle_id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	// The ciphertext is useless without the keys and must not outlive private mode.
	if _, err := tx.Exec(r.Context(), `DELETE FROM e2ee_items WHERE circle_id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE circles SET e2ee_mode = 'off', e2ee_rekey_required = FALSE, e2ee_updated_at = now() WHERE id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to disable")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.disabled", "private circle disabled", clientIP(r))
	s.notifyCircleNormalMode(r.Context(), uid, m.CircleID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "mode": "off"})
}

type approveReq struct {
	DeviceID string `json:"device_id"`
	signedAction
}

// E2EEApproveDevice records a circle admin's approval of a replacement device
// (one that is neither its user's first key nor cross-signed by an earlier key
// of that user) for THIS circle. The admin signs the approval after comparing
// the safety number out of band. The approver must be another user's admin key.
func (s *Server) E2EEApproveDevice(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser*3, e2eeAdminOpWindow) {
		return
	}
	var req approveReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if e2ee.CheckID(req.DeviceID) != nil {
		writeError(w, http.StatusBadRequest, "device_id required")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve")
		return
	}
	defer tx.Rollback(ctx)
	var subjUser, fp string
	err = tx.QueryRow(ctx, `SELECT d.user_id::text, d.fingerprint FROM device_keys d
		JOIN live_circle_members cm ON cm.user_id = d.user_id AND cm.circle_id = $1
		WHERE d.device_id = $2 AND d.revoked_at IS NULL`, m.CircleID, req.DeviceID).Scan(&subjUser, &fp)
	if err != nil {
		writeError(w, http.StatusNotFound, "device not found in this circle")
		return
	}
	if subjUser == uid {
		writeError(w, http.StatusForbidden, "another circle admin must approve your own device")
		return
	}
	fpRaw, _ := hex.DecodeString(fp)
	if !s.verifyCircleAction(w, r, tx, e2ee.ActApprove, uid, m.CircleID, 0, req.DeviceID, fpRaw, req.signedAction) {
		return
	}
	pub, _ := activeKeyPub(ctx, tx, uid, req.ActorDeviceID)
	sig, _ := b64d(req.LogSignature, e2ee.SigLen)
	if _, err := tx.Exec(ctx, `INSERT INTO device_approvals (device_id, circle_id, approver_user_id, approver_device_id, approver_pub, signature)
		VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`, req.DeviceID, m.CircleID, uid, req.ActorDeviceID, pub, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to approve")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.device_approved", "device "+req.DeviceID+" of user "+subjUser, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type wrapOut struct {
	Epoch             int       `json:"epoch"`
	RecipientDeviceID string    `json:"recipient_device_id"`
	WrapperDeviceID   string    `json:"wrapper_device_id"`
	WrapperEd25519Pub string    `json:"wrapper_ed25519_pub"`
	WrappedKey        string    `json:"wrapped_key"`
	Signature         string    `json:"signature"`
	CreatedAt         time.Time `json:"created_at"`
	// KeyLine is "phone" or "server"; for "server" Epoch is the SK generation.
	KeyLine string `json:"key_line"`
}

// E2EEMyWraps returns the wrapped circle keys addressed to one of the caller's
// own active keys (?device_id=, which may be the recovery identity). Ciphertext
// only; another member's wraps are never served.
func (s *Server) E2EEMyWraps(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	dev := r.URL.Query().Get("device_id")
	if e2ee.CheckID(dev) != nil {
		writeError(w, http.StatusBadRequest, "device_id required")
		return
	}
	// key_line: absent = phone wraps only (an old app never sees an SK wrap and
	// cannot mistake a generation for an epoch); "server" or "all" for lanes apps.
	lf := r.URL.Query().Get("key_line")
	switch lf {
	case "":
		lf = "phone"
	case "phone", "server", "all":
	default:
		writeError(w, http.StatusBadRequest, "key_line must be phone, server or all")
		return
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT k.epoch, k.recipient_device_id::text, k.wrapper_device_id::text, k.wrapper_ed25519_pub,
		       k.wrapped_key, k.signature, k.created_at, k.key_line
		FROM circle_key_wraps k
		JOIN device_keys d ON d.device_id = k.recipient_device_id
		WHERE k.circle_id = $1 AND k.recipient_device_id = $2 AND d.user_id = $3 AND d.revoked_at IS NULL
		  AND ($4 = 'all' OR k.key_line = $4)
		ORDER BY k.key_line, k.epoch DESC`, m.CircleID, dev, uid, lf)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load wraps")
		return
	}
	defer rows.Close()
	out := []wrapOut{}
	for rows.Next() {
		var o wrapOut
		var ed, blob, sig []byte
		if err := rows.Scan(&o.Epoch, &o.RecipientDeviceID, &o.WrapperDeviceID, &ed, &blob, &sig, &o.CreatedAt, &o.KeyLine); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load wraps")
			return
		}
		o.WrapperEd25519Pub = base64.StdEncoding.EncodeToString(ed)
		o.WrappedKey = base64.StdEncoding.EncodeToString(blob)
		o.Signature = base64.StdEncoding.EncodeToString(sig)
		out = append(out, o)
	}
	writeJSON(w, http.StatusOK, map[string]any{"circle_id": m.CircleID, "wraps": out})
}

type pendingOut struct {
	e2eeDeviceOut
	UserName string `json:"user_name"`
}

// E2EEPending lists the active keys of circle members that hold no wrap of the
// current epoch (the queue a member's phone works through), each flagged
// approved or "waiting for approval". Public keys only; the server cannot tell
// whether a listed key is genuine, so phones apply the verification policy and
// show the requester before wrapping.
func (s *Server) E2EEPending(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	// key_line=server lists the keys lacking a wrap of the CURRENT SK generation
	// (never the server-kind key itself: it is wrapped by explicit decision).
	line := r.URL.Query().Get("key_line")
	if line != "" && line != "phone" && line != "server" {
		writeError(w, http.StatusBadRequest, "key_line must be phone or server")
		return
	}
	if line == "" {
		line = "phone"
	}
	rows, err := s.Pool.Query(r.Context(), `
		SELECT `+e2eeDeviceCols+`, `+e2eeApprovedExpr("$1")+`, u.name
		FROM circles c
		JOIN live_circle_members cm ON cm.circle_id = c.id
		JOIN users u ON u.id = cm.user_id
		JOIN device_keys d ON d.user_id = cm.user_id AND d.revoked_at IS NULL
		WHERE c.id = $1 AND c.e2ee_mode = 'private' AND ($2 = 'phone' OR (c.server_assist AND d.kind <> 'server'))
		  AND NOT EXISTS (SELECT 1 FROM circle_key_wraps k
		                  WHERE k.circle_id = c.id AND k.key_line = $2
		                    AND k.epoch = CASE WHEN $2 = 'server' THEN c.e2ee_server_gen ELSE c.e2ee_epoch END
		                    AND k.recipient_device_id = d.device_id)
		ORDER BY d.created_at LIMIT 200`, m.CircleID, line)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load pending devices")
		return
	}
	defer rows.Close()
	out := []pendingOut{}
	for rows.Next() {
		var approved bool
		var name string
		d, err := scanE2EEDevice(rows, &approved, &name)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load pending devices")
			return
		}
		d.Approved = &approved
		out = append(out, pendingOut{d, name})
	}
	writeJSON(w, http.StatusOK, map[string]any{"circle_id": m.CircleID, "pending": out})
}

type logEntryOut struct {
	Seq           int64      `json:"seq"`
	PrevHash      string     `json:"prev_hash"`
	EntryHash     string     `json:"entry_hash"`
	Redacted      bool       `json:"redacted"`
	Action        *int       `json:"action,omitempty"`
	UserID        *string    `json:"user_id,omitempty"`
	ActorDeviceID *string    `json:"actor_device_id,omitempty"`
	ActorPub      *string    `json:"actor_ed25519_pub,omitempty"`
	CircleID      *string    `json:"circle_id,omitempty"`
	SubjectID     *string    `json:"subject_id,omitempty"`
	Epoch         *int       `json:"epoch,omitempty"`
	Ref           *string    `json:"ref,omitempty"`
	Signature     *string    `json:"signature,omitempty"`
	CreatedAt     *time.Time `json:"created_at,omitempty"`
}

// E2EELog serves the key transparency log after ?after=<seq> (max 500 entries)
// with the current head. Entries about people the caller shares no circle with
// are REDACTED to (seq, prev_hash, entry_hash): the chain linkage stays
// checkable, the other tenants' ids stay private.
func (s *Server) E2EELog(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if after < 0 {
		after = 0
	}
	ctx := r.Context()
	visible := map[string]bool{uid: true}
	vr, err := s.Pool.Query(ctx, `SELECT DISTINCT y.user_id::text FROM live_circle_members x
		JOIN live_circle_members y ON y.circle_id = x.circle_id WHERE x.user_id = $1`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load log")
		return
	}
	for vr.Next() {
		var id string
		if vr.Scan(&id) == nil {
			visible[id] = true
		}
	}
	vr.Close()
	mine := map[string]bool{}
	cr, err := s.Pool.Query(ctx, `SELECT circle_id::text FROM live_circle_members WHERE user_id = $1`, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load log")
		return
	}
	for cr.Next() {
		var id string
		if cr.Scan(&id) == nil {
			mine[id] = true
		}
	}
	cr.Close()
	rows, err := s.Pool.Query(ctx, `SELECT seq, action, user_id::text, actor_device_id::text, actor_pub, circle_id::text,
		subject_id::text, epoch, ref, signature, prev_hash, entry_hash, created_at
		FROM e2ee_log WHERE seq > $1 ORDER BY seq LIMIT 500`, after)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load log")
		return
	}
	defer rows.Close()
	out := []logEntryOut{}
	for rows.Next() {
		var e logEntryOut
		var action, epoch int
		var user, actor string
		var circle, subject *string
		var pub, ref, sig, prev, hash []byte
		var created time.Time
		if err := rows.Scan(&e.Seq, &action, &user, &actor, &pub, &circle, &subject, &epoch, &ref, &sig, &prev, &hash, &created); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load log")
			return
		}
		e.PrevHash, e.EntryHash = hex.EncodeToString(prev), hex.EncodeToString(hash)
		// An entry is shown in full only when the caller can see the person AND
		// (for circle-scoped entries) is a member of that circle AND (for an
		// approval) can see the person whose key was approved. Otherwise only the
		// hash-chain fields are returned: no ids, circle, subject or epoch.
		show := visible[user]
		if show && circle != nil && !mine[*circle] {
			show = false
		}
		if show && action == int(e2ee.ActApprove) && subject != nil {
			var owner string
			if s.Pool.QueryRow(ctx, `SELECT user_id::text FROM device_keys WHERE device_id = $1`, *subject).Scan(&owner) != nil || !visible[owner] {
				show = false
			}
		}
		if !show {
			e.Redacted = true
		} else {
			rs := hex.EncodeToString(ref)
			ps := base64.StdEncoding.EncodeToString(pub)
			ss := base64.StdEncoding.EncodeToString(sig)
			e.Action, e.UserID, e.ActorDeviceID, e.ActorPub = &action, &user, &actor, &ps
			e.CircleID, e.SubjectID, e.Epoch, e.Ref, e.Signature, e.CreatedAt = circle, subject, &epoch, &rs, &ss, &created
		}
		out = append(out, e)
	}
	var headSeq int64
	var headHash []byte
	_ = s.Pool.QueryRow(ctx, `SELECT seq, entry_hash FROM e2ee_log ORDER BY seq DESC LIMIT 1`).Scan(&headSeq, &headHash)
	writeJSON(w, http.StatusOK, map[string]any{
		"entries": out, "head": map[string]any{"seq": headSeq, "hash": hex.EncodeToString(headHash)},
	})
}

// auditRekeyIfNeeded records that a membership change forced a re-key of a
// private circle (the trigger in migration 150 sets the flag).
func (s *Server) auditRekeyIfNeeded(ctx context.Context, actorID, circleID, ip string) {
	var need bool
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode = 'private' AND e2ee_rekey_required FROM circles WHERE id = $1`, circleID).Scan(&need); err == nil && need {
		s.auditCircle(ctx, actorID, circleID, "e2ee.rekey_required", "membership change in a private circle", ip)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

// notifyCircleNormalMode tells the other members that the circle left Private
// mode, in plain words: from now on the server keeps readable locations. Best effort.
func (s *Server) notifyCircleNormalMode(ctx context.Context, actor, circleID string) {
	if s.Pool == nil {
		return
	}
	var name string
	_ = s.Pool.QueryRow(ctx, `SELECT name FROM circles WHERE id = $1`, circleID).Scan(&name)
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM live_circle_members WHERE circle_id = $1 AND user_id <> $2`, circleID, actor)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if len(ids) == 0 {
		return
	}
	// The circle name only goes to the push provider when the operator opted into verbose push.
	circleLabel := "A circle"
	if s.VerbosePush && name != "" {
		circleLabel = name
	}
	go s.pushUsers(context.WithoutCancel(ctx), ids, "A circle is back in normal mode",
		"An admin switched "+circleLabel+" to normal mode. The server now keeps its locations so maps, history and driving reports work.")
}
