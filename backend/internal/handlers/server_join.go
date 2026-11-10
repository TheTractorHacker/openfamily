package handlers

import (
	"context"
	"encoding/hex"
	"net/http"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2eebridge"
)

// ServerDeviceHost is the built-in server device (internal/e2eebridge Embedded).
type ServerDeviceHost interface {
	Info() e2eebridge.EmbeddedInfo
	JoinRequestFor(userID string) (e2eebridge.JoinRequest, error)
	Approve(ctx context.Context, userID, actorDeviceID, logSignature string) error
	// NoteRevoked: this process just revoked deviceID (an owner key reset). Ignored unless it
	// is the device's own registered key; never approves anything.
	NoteRevoked(deviceID string)
	// Reattach: an owner key reset KEPT the server key; the owner's new root phone signed the
	// attach statement. The device verifies it itself and moves its trust anchor to that phone.
	Reattach(actorDeviceID string, actorPub, signature []byte) error
}

func (s *Server) isPlatformAdmin(ctx context.Context, uid string) bool {
	var ok bool
	if err := s.Pool.QueryRow(ctx, `SELECT platform_admin FROM users WHERE id = $1`, uid).Scan(&ok); err != nil {
		return false
	}
	return ok
}

// E2EEServerJoin: GET /e2ee/server-join. Any signed-in user learns whether the
// server wants to join; only a platform admin gets the request to approve (the
// key material and the binding for THAT admin's account).
func (s *Server) E2EEServerJoin(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if s.ServerDevice == nil {
		writeJSON(w, http.StatusOK, map[string]any{"builtin": false, "waiting": false, "can_approve": false})
		return
	}
	in := s.ServerDevice.Info()
	admin := s.isPlatformAdmin(r.Context(), uid)
	out := map[string]any{"builtin": true, "state": in.State, "state_detail": in.StateDetail, "registered": in.Registered,
		"waiting": !in.Registered && !in.Revoked && in.State == e2eebridge.StateWaitingApproval, "can_approve": admin,
		"short": in.Short, "digits": in.Digits, "fingerprint": in.Fingerprint}
	if admin && out["waiting"] == true {
		req, err := s.ServerDevice.JoinRequestFor(uid)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to prepare the request")
			return
		}
		out["request"] = req
	}
	writeJSON(w, http.StatusOK, out)
}

// E2EEServerJoinApprove: POST /e2ee/server-join/approve {actor_device_id,
// log_signature}. The admin's phone signs the same registration action it signs
// for a sidecar after the person compared the code. Platform admins only.
func (s *Server) E2EEServerJoinApprove(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if s.ServerDevice == nil {
		writeError(w, http.StatusNotFound, "this server uses a separate server device")
		return
	}
	if !s.isPlatformAdmin(r.Context(), uid) {
		writeError(w, http.StatusForbidden, "only a server administrator can approve the server")
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req struct {
		ActorDeviceID string `json:"actor_device_id"`
		LogSignature  string `json:"log_signature"`
		DeviceID      string `json:"device_id"`
	}
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	in := s.ServerDevice.Info()
	if req.DeviceID != "" && req.DeviceID != in.DeviceID {
		writeE2EECode(w, http.StatusConflict, "stale_request", "the server key changed; reload and compare the code again")
		return
	}
	if e2ee.CheckID(req.ActorDeviceID) != nil || req.LogSignature == "" {
		writeError(w, http.StatusBadRequest, "actor_device_id and log_signature are required")
		return
	}
	if err := s.ServerDevice.Approve(r.Context(), uid, req.ActorDeviceID, req.LogSignature); err != nil {
		writeError(w, http.StatusBadRequest, "the approval does not match the server's request")
		return
	}
	s.logAudit(r.Context(), uid, "", "e2ee.server_device_approved", "built-in server device "+in.DeviceID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "device_id": in.DeviceID})
}

// NotifyServerJoinWaiting pushes "Your server wants to join" to every server
// administrator while the built-in device still waits for a phone to approve it.
// Called at start-up and then now and then; harmless when push is unavailable (the
// app also shows a banner when opened).
func (s *Server) NotifyServerJoinWaiting(ctx context.Context) {
	if s.ServerDevice == nil || s.Pool == nil {
		return
	}
	if in := s.ServerDevice.Info(); in.Registered || in.State != e2eebridge.StateWaitingApproval {
		return
	}
	rows, err := s.Pool.Query(ctx, `SELECT id::text FROM users WHERE platform_admin`)
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
	if len(ids) > 0 {
		s.pushUsers(ctx, ids, "Your server wants to join", "Open Orbitly and check that the code matches, then tap Approve.")
	}
}

// E2EEServerReplace: POST /e2ee/server-device/replace {actor_device_id, log_signature}.
// The ONE deliberate way to change the server's key (besides a real compromise, which an
// owner key reset or a revoke already covers): "Replace the server key". A platform admin
// whose own account holds the server key signs a normal revoke action (ActRevoke,
// subject = the server key) with an ACTIVE PHONE key of theirs. The key is revoked, the
// built-in device makes a new one at once and it waits for the usual human-compared
// approval, so it is never silent and never automatic. An owner key reset does NOT go
// through here: it keeps the key (keep_server) or replaces it automatically.
func (s *Server) E2EEServerReplace(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if s.ServerDevice == nil {
		writeError(w, http.StatusNotFound, "this server uses a separate server device")
		return
	}
	if !s.isPlatformAdmin(r.Context(), uid) {
		writeError(w, http.StatusForbidden, "only a server administrator can replace the server key")
		return
	}
	if !s.allowKey(w, "e2eeadmin:user:"+uid, e2eeAdminOpPerUser, e2eeAdminOpWindow) {
		return
	}
	var req struct {
		signedAction
		DeviceID string `json:"device_id"`
	}
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	sig, ok := b64d(req.LogSignature, e2ee.SigLen)
	if !ok || e2ee.CheckID(req.ActorDeviceID) != nil {
		writeError(w, http.StatusBadRequest, "actor_device_id and log_signature required")
		return
	}
	in := s.ServerDevice.Info()
	if !in.Registered || in.DeviceID == "" {
		writeE2EECode(w, http.StatusConflict, "no_server_key", "the server has no approved key to replace")
		return
	}
	if req.DeviceID != "" && req.DeviceID != in.DeviceID {
		writeE2EECode(w, http.StatusConflict, "stale_request", "the server key changed; reload and try again")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to replace the server key")
		return
	}
	defer tx.Rollback(ctx)
	var fpHex string
	if err := tx.QueryRow(ctx, `SELECT fingerprint FROM device_keys WHERE device_id = $1 AND user_id = $2 AND kind = 'server' AND revoked_at IS NULL FOR UPDATE`,
		in.DeviceID, uid).Scan(&fpHex); err != nil {
		writeE2EECode(w, http.StatusForbidden, "not_key_owner", "the server key belongs to another administrator's account")
		return
	}
	// The acting key must be a live PHONE key of this administrator (not a web, service or recovery key).
	var actorPub []byte
	if err := tx.QueryRow(ctx, `SELECT ed25519_pub FROM device_keys WHERE device_id = $1 AND user_id = $2 AND kind = 'device' AND revoked_at IS NULL`,
		req.ActorDeviceID, uid).Scan(&actorPub); err != nil {
		writeError(w, http.StatusBadRequest, "acting key is not an active phone key of the caller")
		return
	}
	fp, err := hex.DecodeString(fpHex)
	if err != nil || len(fp) != 32 {
		writeError(w, http.StatusInternalServerError, "failed to replace the server key")
		return
	}
	if err := e2ee.VerifyLogAction(actorPub, e2ee.ActRevoke, uid, req.ActorDeviceID, "", in.DeviceID, 0, fp, sig); err != nil {
		writeError(w, http.StatusBadRequest, "log signature does not verify")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE device_keys SET revoked_at = now(), revoked_reason = 'revoked' WHERE device_id = $1`, in.DeviceID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to replace the server key")
		return
	}
	if err := appendLog(ctx, tx, e2ee.ActRevoke, uid, req.ActorDeviceID, actorPub, "", in.DeviceID, 0, fp, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to replace the server key")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to replace the server key")
		return
	}
	s.ServerDevice.NoteRevoked(in.DeviceID)
	s.logAudit(ctx, uid, "", "e2ee.server_key_replaced", "server device "+in.DeviceID+" revoked by an admin phone; a new key waits for approval", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "replaced": in.DeviceID})
}
