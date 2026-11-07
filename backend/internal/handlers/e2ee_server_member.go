package handlers

// End-to-end encryption: "trusted server member" mode (docs/design/E2EE.md,
// section "Trusted-server mode").
//
// The instance owner may make the OpenFamily server itself an approved MEMBER
// DEVICE of a Private circle. The server device (kind "server") is a separate
// process (`e2ee-bridge` in server mode) that holds its own private key outside
// the database, pulls sealed items, verifies and decrypts them like a phone
// does, and hands the plaintext positions to POST /internal/e2ee/ingest below.
//
// What binds this to the phones' consent (never a toggle):
//   - the circle counts as a server-member circle only while the SQL function
//     e2ee_server_member() is true: the pinned server key is active, approved
//     (cross-signed by a phone), holds a wrap of the CURRENT epoch (only a phone
//     can make one) and EVERY member signed a consent naming this circle and this
//     server key;
//   - the ingest endpoint re-derives that, and re-verifies every consent
//     signature in Go against the member's phone key, before it writes anything;
//   - the endpoint is reachable only with the server-device token (not a user
//     token) and only when the operator configured one; without it nothing in
//     this file does anything and Private circles behave exactly as in phase 2.

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/circles"
	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const (
	serverTokenMinLen    = 32
	serverIngestMaxBody  = 2 << 20
	serverIngestMaxPts   = 500
	serverIngestAuthFail = 20
	serverIngestPerMin   = 600
	serverConsentOpsHour = 30
	serverPurgeOpsHour   = 10
	// serverIngestMaxAge bounds how old a history point may be (matches the
	// largest location retention window an operator can set).
	serverIngestMaxAge = 400 * 24 * time.Hour
	serverSource       = "e2ee_server"
)

// serverIngestToken returns the configured server-device token, or "" when the
// mode is not enabled. E2EE_SERVER_INGEST_TOKEN_FILE wins over the variable.
func serverIngestToken() string {
	if f := strings.TrimSpace(os.Getenv("E2EE_SERVER_INGEST_TOKEN_FILE")); f != "" {
		if b, err := os.ReadFile(f); err == nil {
			if t := strings.TrimSpace(string(b)); len(t) >= serverTokenMinLen {
				return t
			}
		}
		return ""
	}
	if t := strings.TrimSpace(os.Getenv("E2EE_SERVER_INGEST_TOKEN")); len(t) >= serverTokenMinLen {
		return t
	}
	return ""
}

func serverMemberEnabled() bool { return serverIngestToken() != "" }

// serverDeviceInfo is the pinned server key.
type serverDeviceInfo struct {
	DeviceID    string `json:"device_id"`
	OwnerUserID string `json:"owner_user_id"`
	Label       string `json:"label"`
	Fingerprint string `json:"fingerprint"`
	Digits      string `json:"digits"`
	Short       string `json:"short"`
	fp          []byte
}

// pinnedServerDevice returns the active pinned server key, or nil.
func (s *Server) pinnedServerDevice(ctx context.Context) (*serverDeviceInfo, error) {
	return pinnedServerDeviceQ(ctx, s.Pool)
}

// pinnedServerDeviceQ is pinnedServerDevice on any querier (pool or transaction).
func pinnedServerDeviceQ(ctx context.Context, q rowQuerier) (*serverDeviceInfo, error) {
	var i serverDeviceInfo
	err := q.QueryRow(ctx, `
		SELECT d.device_id::text, d.user_id::text, d.label, d.fingerprint
		FROM e2ee_server_device sd JOIN device_keys d ON d.device_id = sd.device_id
		WHERE d.kind = 'server' AND d.revoked_at IS NULL`).Scan(&i.DeviceID, &i.OwnerUserID, &i.Label, &i.Fingerprint)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	fp, err := hex.DecodeString(i.Fingerprint)
	if err != nil || len(fp) != 32 {
		return nil, errors.New("server device fingerprint is malformed")
	}
	i.fp = fp
	i.Digits, i.Short = e2ee.DigitGroups(fp), e2ee.ShortFingerprint(fp)
	return &i, nil
}

// requireServerToken authenticates the server-device process. A server without
// the mode answers 404 (the endpoints do not exist for it).
func (s *Server) requireServerToken(w http.ResponseWriter, r *http.Request) bool {
	want := serverIngestToken()
	if want == "" {
		writeError(w, http.StatusNotFound, "not found")
		return false
	}
	if !s.allowAuth(w, authIPKey("e2eeserver", clientIP(r)), serverIngestAuthFail, time.Minute) {
		return false
	}
	got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if got == r.Header.Get("Authorization") || subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return false
	}
	return true
}

// consentStatus is the verified consent state of one circle.
type consentStatus struct {
	ServerMember bool
	Required     []string // members that must consent (they hold an active phone key)
	Consented    []string // members with a valid, verified consent
}

// verifyServerConsents derives the server-member state of a circle AND re-verifies
// every consent signature in Go. It fails closed: any member without a valid
// consent, or any database/crypto problem, answers "not a server member".
func (s *Server) verifyServerConsents(ctx context.Context, q querier, circleID string, dev *serverDeviceInfo) (consentStatus, error) {
	var st consentStatus
	if dev == nil || e2ee.CheckID(circleID) != nil {
		return st, nil
	}
	rows, err := q.Query(ctx, `
		SELECT m.user_id::text,
		       COALESCE((SELECT encode(k.ed25519_pub, 'hex') FROM e2ee_server_consents sc
		                   JOIN device_keys k ON k.device_id = sc.approver_device_id AND k.user_id = m.user_id
		                                     AND k.kind = 'device' AND k.revoked_at IS NULL
		                  WHERE sc.circle_id = m.circle_id AND sc.user_id = m.user_id AND sc.server_device_id = $2), ''),
		       COALESCE((SELECT encode(sc.signature, 'hex') FROM e2ee_server_consents sc
		                  WHERE sc.circle_id = m.circle_id AND sc.user_id = m.user_id AND sc.server_device_id = $2), '')
		FROM live_circle_members m
		WHERE m.circle_id = $1
		ORDER BY m.user_id`, circleID, dev.DeviceID)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	all := true
	for rows.Next() {
		var uid, pubHex, sigHex string
		if err := rows.Scan(&uid, &pubHex, &sigHex); err != nil {
			return st, err
		}
		st.Required = append(st.Required, uid)
		pub, e1 := hex.DecodeString(pubHex)
		sig, e2 := hex.DecodeString(sigHex)
		if e1 != nil || e2 != nil || e2ee.VerifyServerConsent(pub, circleID, uid, dev.DeviceID, dev.fp, sig) != nil {
			all = false
			continue
		}
		st.Consented = append(st.Consented, uid)
	}
	if err := rows.Err(); err != nil {
		return st, err
	}
	if !all || len(st.Required) == 0 {
		return st, nil
	}
	if err := q.QueryRow(ctx, `SELECT e2ee_server_member_legacy($1::uuid)`, circleID).Scan(&st.ServerMember); err != nil {
		return consentStatus{}, err
	}
	return st, nil
}

// ---------------------------------------------------------------- user API

// E2EEServerDevice tells a signed-in client whether the mode is enabled and which
// key is the OpenFamily server's. GET /e2ee/server-device.
func (s *Server) E2EEServerDevice(w http.ResponseWriter, r *http.Request) {
	if _, ok := circleCaller(w, r); !ok {
		return
	}
	out := map[string]any{"enabled": serverMemberEnabled(), "device": nil, "trusted_server_default": false}
	if serverMemberEnabled() {
		dev, err := s.pinnedServerDevice(r.Context())
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load server device")
			return
		}
		if dev != nil {
			out["device"] = dev
			// Only a recommendation: true only while the mode is usable at all.
			out["trusted_server_default"] = s.trustedServerDefaultSetting(r.Context())
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// E2EEServerMemberState is the per-circle view. GET /circles/{id}/e2ee/server-member
// (any member).
func (s *Server) E2EEServerMemberState(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	out := map[string]any{"enabled": serverMemberEnabled(), "server_member": false, "device": nil,
		"required": []string{}, "consented": []string{}, "my_consent": false}
	if !serverMemberEnabled() {
		writeJSON(w, http.StatusOK, out)
		return
	}
	ctx := r.Context()
	dev, err := s.pinnedServerDevice(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load server device")
		return
	}
	if dev == nil {
		writeJSON(w, http.StatusOK, out)
		return
	}
	st, err := s.verifyServerConsents(ctx, s.Pool, m.CircleID, dev)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load consents")
		return
	}
	// Whether the server key already holds a wrap of the current epoch (a phone
	// wraps it after all members consented).
	var wrapped bool
	_ = s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM circle_key_wraps w JOIN circles c ON c.id = w.circle_id AND w.epoch = c.e2ee_epoch
		WHERE w.circle_id = $1 AND w.key_line = 'phone' AND w.recipient_device_id = $2)`, m.CircleID, dev.DeviceID).Scan(&wrapped)
	mine := false
	for _, u := range st.Consented {
		if u == uid {
			mine = true
		}
	}
	// The signed consents themselves, so the server device (and any client) can
	// verify them against the key log instead of trusting this answer.
	type consentOut struct {
		UserID           string `json:"user_id"`
		ApproverDeviceID string `json:"approver_device_id"`
		Signature        string `json:"signature"`
	}
	consents := []consentOut{}
	if cr, err := s.Pool.Query(ctx, `SELECT user_id::text, approver_device_id::text, signature FROM e2ee_server_consents
		WHERE circle_id = $1 AND server_device_id = $2 ORDER BY user_id`, m.CircleID, dev.DeviceID); err == nil {
		for cr.Next() {
			var c consentOut
			var sig []byte
			if cr.Scan(&c.UserID, &c.ApproverDeviceID, &sig) == nil {
				c.Signature = base64.StdEncoding.EncodeToString(sig)
				consents = append(consents, c)
			}
		}
		cr.Close()
	}
	out["consents"] = consents
	var legacyCircle bool
	_ = s.Pool.QueryRow(ctx, `SELECT server_legacy_ck FROM circles WHERE id = $1`, m.CircleID).Scan(&legacyCircle)
	out["legacy"] = legacyCircle
	out["server_member"], out["device"], out["wrapped"] = st.ServerMember, dev, wrapped
	out["required"], out["consented"], out["my_consent"] = nonNil(st.Required), nonNil(st.Consented), mine
	writeJSON(w, http.StatusOK, out)
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

type serverConsentReq struct {
	ServerDeviceID   string `json:"server_device_id"`
	ApproverDeviceID string `json:"approver_device_id"`
	Signature        string `json:"signature"`
}

// E2EEPutServerConsent records the caller's consent to let the pinned server
// key read this circle. PUT /circles/{id}/e2ee/server-consent. The signature is
// made by one of the caller's own active phone keys, so a session token alone
// cannot grant it.
func (s *Server) E2EEPutServerConsent(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !serverMemberEnabled() {
		writeE2EECode(w, http.StatusConflict, "server_member_disabled", "this server is not set up to be a circle member")
		return
	}
	if !s.allowKey(w, "e2eeservercons:user:"+uid, serverConsentOpsHour, time.Hour) {
		return
	}
	var req serverConsentReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	sig, ok := b64d(req.Signature, e2ee.SigLen)
	if !ok || e2ee.CheckID(req.ServerDeviceID) != nil || e2ee.CheckID(req.ApproverDeviceID) != nil {
		writeError(w, http.StatusBadRequest, "server_device_id, approver_device_id and a 64-byte signature are required")
		return
	}
	ctx := r.Context()
	if !s.circleIsPrivate(ctx, m.CircleID) {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	// The all-members consent exists only for circles that were already in the old
	// trusted-server mode. Every other circle uses per-member lanes (processing-pref).
	var legacy bool
	if err := s.Pool.QueryRow(ctx, `SELECT server_legacy_ck FROM circles WHERE id = $1`, m.CircleID).Scan(&legacy); err != nil || !legacy {
		writeE2EECode(w, http.StatusConflict, "use_processing_pref", "this circle uses per-member processing lanes; sign a processing preference instead")
		return
	}
	dev, err := s.pinnedServerDevice(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load server device")
		return
	}
	if dev == nil || dev.DeviceID != req.ServerDeviceID {
		writeE2EECode(w, http.StatusConflict, "not_the_server_device", "that key is not the OpenFamily server device")
		return
	}
	var pub []byte
	var kind string
	if err := s.Pool.QueryRow(ctx, `SELECT ed25519_pub, kind FROM device_keys
		WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`, req.ApproverDeviceID, uid).Scan(&pub, &kind); err != nil || kind != "device" {
		writeError(w, http.StatusBadRequest, "approver_device_id must be one of your active phone keys")
		return
	}
	if e2ee.VerifyServerConsent(pub, m.CircleID, uid, dev.DeviceID, dev.fp, sig) != nil {
		writeError(w, http.StatusBadRequest, "consent signature does not verify")
		return
	}
	if _, err := s.Pool.Exec(ctx, `
		INSERT INTO e2ee_server_consents (circle_id, user_id, server_device_id, approver_device_id, signature)
		VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (circle_id, user_id, server_device_id) DO UPDATE
		SET approver_device_id = EXCLUDED.approver_device_id, signature = EXCLUDED.signature, created_at = now()`,
		m.CircleID, uid, dev.DeviceID, req.ApproverDeviceID, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store consent")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.server_consent", "member allowed the server key "+dev.Short+" to read this circle", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// E2EEDeleteServerConsent withdraws the caller's consent. DELETE
// /circles/{id}/e2ee/server-consent. The circle stops being a server-member
// circle at once (ingest refuses, plaintext places are refused again) and a new
// key epoch is requested so the server's old key copy covers no future data.
func (s *Server) E2EEDeleteServerConsent(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeservercons:user:"+uid, serverConsentOpsHour, time.Hour) {
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `DELETE FROM e2ee_server_consents WHERE circle_id = $1 AND user_id = $2`, m.CircleID, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to withdraw consent")
		return
	}
	if tag.RowsAffected() > 0 {
		if _, err := tx.Exec(ctx, `SELECT e2ee_purge_user_server_copies($1::uuid, $2::uuid)`, m.CircleID, uid); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to withdraw consent")
			return
		}
		if _, err := tx.Exec(ctx, `UPDATE circles SET e2ee_rekey_required = TRUE, e2ee_updated_at = now()
			WHERE id = $1 AND e2ee_mode = 'private'`, m.CircleID); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to withdraw consent")
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.server_consent_withdrawn", "member withdrew the server key's consent", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "withdrawn": tag.RowsAffected()})
}

// E2EEPurgeServerCopies deletes the plaintext positions the server decrypted
// from this circle. DELETE /circles/{id}/e2ee/server-copies?scope=mine|circle
// (circle scope: admin only). Works whether or not the circle is still a
// server-member circle; it never touches sealed items or positions that phones
// uploaded in plaintext for ordinary circles.
func (s *Server) E2EEPurgeServerCopies(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeserverpurge:user:"+uid, serverPurgeOpsHour, time.Hour) {
		return
	}
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "mine"
	}
	if scope != "mine" && scope != "circle" {
		writeError(w, http.StatusBadRequest, "scope must be mine or circle")
		return
	}
	if scope == "circle" && m.Role != circles.RoleAdmin {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}
	ctx := r.Context()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(ctx)
	// Serialise with ingest (it holds this row FOR SHARE for its batch).
	if _, err := tx.Exec(ctx, `SELECT 1 FROM circles WHERE id = $1 FOR UPDATE`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to purge")
		return
	}
	rows, err := tx.Query(ctx, `
		DELETE FROM locations l USING devices d
		WHERE d.id = l.device_id AND l.e2ee_circle_id = $1 AND ($2 = 'circle' OR d.user_id = $3)
		RETURNING d.user_id::text, l.ts`, m.CircleID, scope, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to purge")
		return
	}
	deleted := map[string][]time.Time{}
	var nDeleted int64
	for rows.Next() {
		var u string
		var ts time.Time
		if err := rows.Scan(&u, &ts); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to purge")
			return
		}
		deleted[u] = append(deleted[u], ts)
		nDeleted++
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to purge")
		return
	}
	// scope=mine: ALL of the caller's own server-line items (any purpose; the server can
	// read them under SK). scope=circle (admin): other members' location trail only
	// (fix, history, trip, drive, week) plus the admin's own server-line items; shared
	// channel items of others (place, chat, checkin, event) are never deleted by an
	// admin purge, nor is any phone-line item (use DELETE .../items for those).
	// Members who had not pulled a deleted item yet lose it; phones keep what they pulled.
	itemsTag, err := tx.Exec(ctx, `
		DELETE FROM e2ee_items i
		WHERE i.circle_id = $1 AND i.key_line = 'server'
		  AND (($2 = 'circle' AND i.purpose IN ('fix', 'history', 'trip', 'drive', 'week')) OR i.device_id IN (SELECT device_id FROM device_keys WHERE user_id = $3))`, m.CircleID, scope, uid)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to purge")
		return
	}
	// A last-known position is touched only if it IS one of the purged points (same
	// user, same instant). It is then recomputed from the newest remaining location
	// of any source (another server-member circle, a plaintext circle), or removed
	// when nothing remains. Every other position is left alone.
	var repositioned, removed int64
	for u, tss := range deleted {
		var cur time.Time
		if err := tx.QueryRow(ctx, `SELECT ts FROM member_positions WHERE user_id = $1`, u).Scan(&cur); err != nil {
			continue
		}
		hit := false
		for _, t := range tss {
			if t.Equal(cur) {
				hit = true
			}
		}
		if !hit {
			continue
		}
		tag, err := tx.Exec(ctx, `
			UPDATE member_positions mp SET lat = n.lat, lon = n.lon, ts = n.ts, device_id = n.device_id,
			       accuracy_meters = n.acc, speed_mps = n.spd, battery_pct = n.bat, heading_deg = NULL, motion_state = NULL
			FROM (SELECT ST_Y(l.geom) AS lat, ST_X(l.geom) AS lon, l.ts, l.device_id, l.accuracy_meters AS acc,
			             l.speed_mps AS spd, l.battery_pct AS bat
			      FROM locations l JOIN devices d ON d.id = l.device_id
			      WHERE d.user_id = $1 AND (l.e2ee_circle_id IS NULL OR e2ee_member_server_ok(l.e2ee_circle_id, d.user_id))
			      ORDER BY l.ts DESC LIMIT 1) n
			WHERE mp.user_id = $1`, u)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to purge")
			return
		}
		if tag.RowsAffected() > 0 {
			repositioned++
			continue
		}
		if _, err := tx.Exec(ctx, `DELETE FROM member_positions WHERE user_id = $1`, u); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to purge")
			return
		}
		removed++
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.server_copies_purged", "scope "+scope, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"locations_deleted": nDeleted, "items_deleted": itemsTag.RowsAffected(),
		"last_positions_deleted": removed, "last_positions_recomputed": repositioned})
}

// ----------------------------------------------------------- internal API

// E2EEPinServerDevice pins THE server key. PUT /internal/e2ee/server-device
// (server token). Only a key that is already registered as kind "server" (so it
// was cross-signed by a phone key of its owner) can be pinned; pinning grants
// nothing by itself: the circles still need wraps and per-member consents.
func (s *Server) E2EEPinServerDevice(w http.ResponseWriter, r *http.Request) {
	if !s.requireServerToken(w, r) {
		return
	}
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if !decodeE2EEBody(w, r, &req) || e2ee.CheckID(req.DeviceID) != nil {
		if req.DeviceID == "" {
			writeError(w, http.StatusBadRequest, "device_id is required")
		} else if e2ee.CheckID(req.DeviceID) != nil {
			writeError(w, http.StatusBadRequest, "device_id is malformed")
		}
		return
	}
	ctx := r.Context()
	var owner string
	if err := s.Pool.QueryRow(ctx, `SELECT user_id::text FROM device_keys
		WHERE device_id = $1 AND kind = 'server' AND revoked_at IS NULL`, req.DeviceID).Scan(&owner); err != nil {
		writeError(w, http.StatusNotFound, "no active server key with that id")
		return
	}
	cur, err := s.pinnedServerDevice(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to pin")
		return
	}
	if cur != nil && cur.DeviceID != req.DeviceID {
		writeE2EECode(w, http.StatusConflict, "already_pinned", "another active server key is pinned; revoke it first")
		return
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO e2ee_server_device (singleton, device_id) VALUES (TRUE, $1)
		ON CONFLICT (singleton) DO UPDATE SET device_id = EXCLUDED.device_id, set_at = now()`, req.DeviceID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to pin")
		return
	}
	s.logAudit(ctx, owner, "", "e2ee.server_device_pinned", "device "+req.DeviceID, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type serverIngestPoint struct {
	Kind           string   `json:"kind"` // "fix" (live) or "history"
	UserID         string   `json:"user_id"`
	SenderDeviceID string   `json:"sender_device_id"`
	TSMs           int64    `json:"ts_ms"`
	Lat            *float64 `json:"lat"`
	Lon            *float64 `json:"lon"`
	Acc            *float64 `json:"acc,omitempty"`
	Alt            *float64 `json:"alt,omitempty"`
	Spd            *float64 `json:"spd,omitempty"`
	Bat            *float64 `json:"bat,omitempty"`
}

type serverIngestReq struct {
	CircleID       string              `json:"circle_id"`
	ServerDeviceID string              `json:"server_device_id"`
	Points         []serverIngestPoint `json:"points"`
}

func finiteOrNil(p *float64) *float64 {
	if p == nil || math.IsNaN(*p) || math.IsInf(*p, 0) {
		return nil
	}
	return p
}

// E2EEServerIngest stores positions that the server device decrypted and
// verified. POST /internal/e2ee/ingest (server token). The server trusts its
// sidecar for decryption and signature checks (it is the server's own
// component), but never trusts a claim about WHO may be read: circle, sender
// and sharing state are all checked here against the database.
func (s *Server) E2EEServerIngest(w http.ResponseWriter, r *http.Request) {
	if !s.requireServerToken(w, r) {
		return
	}
	if !s.allowAuth(w, "e2eeserveringest", serverIngestPerMin, time.Minute) {
		return
	}
	var req serverIngestReq
	r.Body = http.MaxBytesReader(w, r.Body, serverIngestMaxBody)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if e2ee.CheckID(req.CircleID) != nil || e2ee.CheckID(req.ServerDeviceID) != nil || len(req.Points) == 0 || len(req.Points) > serverIngestMaxPts {
		writeError(w, http.StatusBadRequest, "circle_id, server_device_id and 1 to 500 points are required")
		return
	}
	ctx := r.Context()
	dev, err := s.pinnedServerDevice(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load server device")
		return
	}
	if dev == nil || dev.DeviceID != req.ServerDeviceID {
		writeE2EECode(w, http.StatusForbidden, "not_the_server_device", "that key is not the pinned, active server device")
		return
	}
	// Per-user gate: only members whose VERIFIED lane is server (legacy circle:
	// every member, after the all-consent check) are ever written. A phone-lane
	// member, a member without a pref, or a row planted in the database is not.
	// The lane check runs INSIDE the transaction that writes, with the circle row
	// share-locked: a lane withdrawal (which locks the row exclusively and purges
	// the member's copies) either commits before we look, or waits for us.
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to begin transaction")
		return
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT 1 FROM circles WHERE id = $1 FOR SHARE`, req.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to lock circle")
		return
	}
	lanes, err := s.ingestLanes(ctx, tx, req.CircleID, dev)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to verify consents")
		return
	}
	if len(lanes) == 0 {
		writeE2EECode(w, http.StatusConflict, "not_a_server_member_circle",
			"this circle is not readable by the server: it needs the server key's wrap and a member whose own signed choice is the server lane")
		return
	}

	now := time.Now().UTC()
	rejected := map[string]int{}
	stored, dup := 0, 0
	type liveFix struct {
		user string
		p    serverIngestPoint
		ts   time.Time
	}
	newest := map[string]*liveFix{}
	senderOK := map[string]string{} // sender device -> user it was verified for ("" = refused)
	userDevice := map[string]string{}
	var fixes []*liveFix

	for _, p := range req.Points {
		if p.Lat == nil || p.Lon == nil || math.IsNaN(*p.Lat) || math.IsNaN(*p.Lon) || *p.Lat < -90 || *p.Lat > 90 || *p.Lon < -180 || *p.Lon > 180 {
			rejected["bad_coordinates"]++
			continue
		}
		if p.Kind != "fix" && p.Kind != "history" {
			rejected["bad_kind"]++
			continue
		}
		ts := time.UnixMilli(p.TSMs).UTC()
		if p.TSMs <= 0 || ts.After(now.Add(maxTSSkew)) || ts.Before(now.Add(-serverIngestMaxAge)) {
			rejected["bad_time"]++
			continue
		}
		if e2ee.CheckID(p.UserID) != nil || e2ee.CheckID(p.SenderDeviceID) != nil {
			rejected["bad_sender"]++
			continue
		}
		// The sender key must be an active, approved phone key of exactly this
		// user, who is a live member that is currently sharing in this circle.
		if _, seen := senderOK[p.SenderDeviceID]; !seen {
			var owner string
			err := tx.QueryRow(ctx, `
				SELECT d.user_id::text FROM device_keys d
				JOIN live_circle_members m ON m.user_id = d.user_id AND m.circle_id = $2
				WHERE d.device_id = $1 AND d.kind = 'device' AND d.can_upload AND d.revoked_at IS NULL
				  AND e2ee_device_approved(d.device_id, $2::uuid)
				  AND m.sharing_enabled AND NOT EXISTS (SELECT 1 FROM sharing_pauses sp WHERE sp.user_id = m.user_id AND sp.paused_until > now())
				  AND NOT EXISTS (SELECT 1 FROM circle_members x JOIN circles c ON c.id = x.circle_id
				                   WHERE x.user_id = d.user_id AND c.e2ee_mode = 'off')`, p.SenderDeviceID, req.CircleID).Scan(&owner)
			if err != nil {
				owner = ""
			}
			senderOK[p.SenderDeviceID] = owner
		}
		if senderOK[p.SenderDeviceID] == "" || senderOK[p.SenderDeviceID] != p.UserID {
			rejected["sender_not_allowed"]++
			continue
		}
		if !lanes[p.UserID] {
			rejected["lane_not_server"]++
			continue
		}
		dv, ok := userDevice[p.UserID]
		if !ok {
			dv, err = s.serverIngestDevice(ctx, tx, p.UserID)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "failed to store location")
				return
			}
			userDevice[p.UserID] = dv
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO locations (device_id, ts, geom, accuracy_meters, altitude_meters, speed_mps, battery_pct, source, e2ee_circle_id)
			VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, $6, $7, $8, $9, $10)
			ON CONFLICT (device_id, ts) DO NOTHING`,
			dv, ts, *p.Lon, *p.Lat, finiteOrNil(p.Acc), finiteOrNil(p.Alt), finiteOrNil(p.Spd), finiteOrNil(p.Bat), serverSource, req.CircleID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to store location")
			return
		}
		if tag.RowsAffected() == 0 {
			dup++
			continue
		}
		stored++
		lf := &liveFix{user: p.UserID, p: p, ts: ts}
		if cur := newest[p.UserID]; cur == nil || ts.After(cur.ts) {
			newest[p.UserID] = lf
		}
		if p.Kind == "fix" && ts.After(now.Add(-maxTSAge)) {
			fixes = append(fixes, lf)
		}
	}

	// Last-known position: only ever forward in time, never from an old backfill.
	for uid, lf := range newest {
		dv := userDevice[uid]
		if _, err := tx.Exec(ctx, `
			INSERT INTO member_positions (user_id, lat, lon, ts, battery_pct, speed_mps, accuracy_meters, device_id, updated_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8, now())
			ON CONFLICT (user_id) DO UPDATE SET lat = EXCLUDED.lat, lon = EXCLUDED.lon, ts = EXCLUDED.ts,
			  battery_pct = EXCLUDED.battery_pct, speed_mps = EXCLUDED.speed_mps, accuracy_meters = EXCLUDED.accuracy_meters,
			  device_id = EXCLUDED.device_id, updated_at = now()
			WHERE member_positions.ts < EXCLUDED.ts`,
			uid, *lf.p.Lat, *lf.p.Lon, lf.ts, finiteOrNil(lf.p.Bat), finiteOrNil(lf.p.Spd), finiteOrNil(lf.p.Acc), dv); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to store member position")
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	// Live fixes behave like a plaintext fix: geofences/bubbles, battery alerts and
	// the live fan-out (the server is the single evaluator for this circle).
	for _, f := range fixes {
		lat, lon, ts, p, uid := *f.p.Lat, *f.p.Lon, f.ts, f.p, f.user
		if _, err := s.Pool.Exec(ctx, `UPDATE devices SET last_seen = now() WHERE id = $1`, userDevice[uid]); err != nil {
			slog.Warn("e2ee server ingest: device heartbeat", "err", err)
		}
		postCommitRunner.Submit(func() {
			evalCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			s.evaluateGeofences(evalCtx, uid, lon, lat, ts, finiteOrNil(p.Acc))
		})
		s.noteBattery(uid, finiteOrNil(p.Bat))
		postCommitRunner.Submit(func() {
			s.broadcastLocation(uid, wsLocation{Type: "location", UserID: uid, Lat: lat, Lon: lon, TS: ts,
				LastSeenAt: time.Now().UTC(), BatteryPct: finiteOrNil(p.Bat), SpeedMPS: finiteOrNil(p.Spd), AccuracyMeters: finiteOrNil(p.Acc)})
		})
	}
	if stored > 0 && (s.viewAudit == nil || s.viewAudit.Allow("e2eeserveraudit:"+req.CircleID, 1, time.Hour)) {
		// Counts only: never a coordinate.
		s.logAudit(ctx, dev.OwnerUserID, "", "e2ee.server_ingest", "circle "+req.CircleID+" stored a batch", clientIP(r))
	}
	writeJSON(w, http.StatusOK, map[string]any{"stored": stored, "duplicate": dup, "rejected": rejected})
}

// serverIngestDevice returns the devices row that carries a user's server-
// decrypted positions: their most recently used device, or a placeholder.
func (s *Server) serverIngestDevice(ctx context.Context, q rowQuerier, userID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id::text FROM devices WHERE user_id = $1
		ORDER BY last_seen DESC NULLS LAST, created_at DESC LIMIT 1`, userID).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	err = q.QueryRow(ctx, `INSERT INTO devices (user_id, platform, name) VALUES ($1, 'android', 'Private circle (server copy)')
		RETURNING id::text`, userID).Scan(&id)
	return id, err
}

// registerServerKindOK enforces the mode switch for kind "server" registrations.
func registerServerKindOK(w http.ResponseWriter, kind string) bool {
	if kind == "server" && !serverMemberEnabled() {
		writeE2EECode(w, http.StatusForbidden, "server_member_disabled", "this server is not set up to be a circle member")
		return false
	}
	return true
}
