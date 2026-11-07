package handlers

// Per-member privacy lanes (docs/design/PRIVACY_PROCESSING.md, phase 2).
//
// A Private circle has a phone key line (CK, never held by the server) and a
// server key line (SK). The circle admin's signed processing_policy says whether
// server assistance exists at all; each member's own phone signs a
// processing_pref choosing the lane for the data THEY author. The server can
// write or read a member's plaintext only while ALL of these hold, re-checked
// here in Go (signatures included) and again in SQL (e2ee_member_server_ok):
//   - the admin policy is on and the pinned server key holds the current SK;
//   - the member's pref is lane server, signed by an active phone key of theirs,
//     naming exactly this server key, and matching the latest pref in the log.
// No role, token or endpoint can write another user's pref.

import (
	"bytes"
	"context"
	"encoding/base64"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const (
	capLanes2         = "lanes2"
	processingOpsHour = 60
	upgradeOpsHour    = 10
	maxStatementsOut  = 30
)

var knownCaps = map[string]bool{capLanes2: true}

// cleanCaps keeps only known capability names (sorted, unique, at most 8).
func cleanCaps(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, c := range in {
		c = strings.TrimSpace(c)
		if knownCaps[c] && !seen[c] && len(out) < 8 {
			seen[c] = true
			out = append(out, c)
		}
	}
	sort.Strings(out)
	return out
}

// rotatedCaps: a rotated key keeps the old key's caps unless the request declares its own.
func rotatedCaps(req, old []string) []string {
	if req != nil {
		return cleanCaps(req)
	}
	if old == nil {
		return []string{}
	}
	return old
}

type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ------------------------------------------------------------ verification

// prefRow is one stored processing_pref joined with its approver's key.
type prefRow struct {
	Lane          string
	SKGen         int
	ServerDevice  string
	ServerFP      []byte
	Nonce         []byte
	Sig           []byte
	Legacy        bool
	LogSeq        *int64
	ApproverPub   []byte
	CircleSKGen   int
	CircleAssist  bool
	CircleLegacyK bool
}

func loadPrefRow(ctx context.Context, q rowQuerier, circleID, userID string) (prefRow, bool) {
	var p prefRow
	var srv *string
	err := q.QueryRow(ctx, `
		SELECT p.lane, p.sk_gen, p.server_device_id::text, p.server_fingerprint, p.nonce, p.signature, p.legacy, p.log_seq,
		       ak.ed25519_pub, c.e2ee_server_gen, c.server_assist
		FROM e2ee_processing_pref p
		JOIN circles c ON c.id = p.circle_id
		JOIN device_keys ak ON ak.device_id = p.approver_device_id AND ak.user_id = p.user_id AND ak.kind = 'device' AND ak.revoked_at IS NULL
		WHERE p.circle_id = $1 AND p.user_id = $2`, circleID, userID).
		Scan(&p.Lane, &p.SKGen, &srv, &p.ServerFP, &p.Nonce, &p.Sig, &p.Legacy, &p.LogSeq, &p.ApproverPub, &p.CircleSKGen, &p.CircleAssist)
	if err != nil {
		return p, false
	}
	if srv != nil {
		p.ServerDevice = *srv
	}
	return p, true
}

// verifyServerPref is true only if the stored pref is a valid lane-server
// statement for exactly dev, in range of the circle's SK generations.
func verifyServerPref(p prefRow, circleID, userID string, dev *serverDeviceInfo) bool {
	if dev == nil || p.Lane != "server" || !p.CircleAssist || p.ServerDevice != dev.DeviceID {
		return false
	}
	if p.SKGen < 1 || p.SKGen > p.CircleSKGen {
		return false
	}
	if p.Legacy {
		return e2ee.VerifyServerConsent(p.ApproverPub, circleID, userID, dev.DeviceID, dev.fp, p.Sig) == nil
	}
	if !e2ee.ConstEq(p.ServerFP, dev.fp) {
		return false
	}
	return e2ee.VerifyProcessingPref(p.ApproverPub, circleID, userID, e2ee.LineServer, uint32(p.SKGen), dev.DeviceID, dev.fp, p.Nonce, p.Sig) == nil
}

// prefLogMatches checks that the pref is the member's LATEST pref in the key
// log (a replayed old statement, or a row planted in the database, is not).
// Legacy conversions have no log entry and are covered by their consent signature.
func prefLogMatches(ctx context.Context, q rowQuerier, p prefRow, circleID, userID string, dev *serverDeviceInfo) bool {
	if p.Legacy {
		return true
	}
	if p.LogSeq == nil || dev == nil {
		return false
	}
	var seq int64
	var ref []byte
	if q.QueryRow(ctx, `SELECT seq, ref FROM e2ee_log WHERE circle_id = $1 AND user_id = $2 AND action = $3
		ORDER BY seq DESC LIMIT 1`, circleID, userID, int(e2ee.ActProcessingPref)).Scan(&seq, &ref) != nil || seq != *p.LogSeq {
		return false
	}
	msg, err := e2ee.ProcessingPrefMessage(circleID, userID, e2ee.LineServer, uint32(p.SKGen), dev.DeviceID, dev.fp, p.Nonce)
	return err == nil && bytes.Equal(ref, e2ee.ProcessingRef(msg))
}

// verifiedLaneServer answers whether userID's lane in the circle is VERIFIED
// server. Every write decision about server-readable data goes through it (or
// through the legacy consent check): SQL alone is never trusted.
func (s *Server) verifiedLaneServer(ctx context.Context, q rowQuerier, circleID, userID string) bool {
	if e2ee.CheckID(circleID) != nil || e2ee.CheckID(userID) != nil {
		return false
	}
	var ok bool
	if q.QueryRow(ctx, `SELECT e2ee_pref_lane_server($1::uuid, $2::uuid)`, circleID, userID).Scan(&ok) != nil || !ok {
		return false
	}
	dev, err := pinnedServerDeviceQ(ctx, q)
	if err != nil || dev == nil {
		return false
	}
	p, found := loadPrefRow(ctx, q, circleID, userID)
	return found && verifyServerPref(p, circleID, userID, dev) && prefLogMatches(ctx, q, p, circleID, userID, dev)
}

// policyVerified re-verifies the latest signed processing_policy against the
// circle's mirrored columns, so flipping the columns alone (a planted row) does
// not switch assistance on for ingest.
func (s *Server) policyVerified(ctx context.Context, q rowQuerier, circleID string) bool {
	var assist bool
	var gen int
	var def, optOut string
	var commit []byte
	if q.QueryRow(ctx, `SELECT server_assist, e2ee_server_gen, server_assist_default, member_opt_out, e2ee_server_commitment
		FROM circles WHERE id = $1`, circleID).Scan(&assist, &gen, &def, &optOut, &commit) != nil || !assist || gen < 1 {
		return false
	}
	var uid, actor, lane string
	var skGen int
	var nonce, sig, stmtCommit []byte
	var seq int64
	var dflt, oo *string
	if q.QueryRow(ctx, `SELECT user_id::text, actor_device_id::text, lane, default_for_new, member_opt_out, sk_gen, commitment, nonce, signature, log_seq
		FROM e2ee_processing_statements WHERE circle_id = $1 AND kind = 'policy' ORDER BY log_seq DESC LIMIT 1`, circleID).
		Scan(&uid, &actor, &lane, &dflt, &oo, &skGen, &stmtCommit, &nonce, &sig, &seq) != nil {
		return false
	}
	if lane != "server" || dflt == nil || oo == nil || *dflt != def || *oo != optOut || skGen != gen || !e2ee.ConstEq(stmtCommit, commit) {
		return false
	}
	var pub []byte
	if q.QueryRow(ctx, `SELECT ed25519_pub FROM device_keys WHERE device_id = $1 AND user_id = $2 AND kind = 'device'`, actor, uid).Scan(&pub) != nil {
		return false
	}
	dl, e1 := e2ee.ParseLine(def)
	oo2, e2 := e2ee.ParseMemberOptOut(optOut)
	if e1 != nil || e2 != nil {
		return false
	}
	return e2ee.VerifyProcessingPolicy(pub, circleID, uid, true, dl, oo2, uint32(gen), commit, nonce, sig) == nil
}

// ingestLanes returns the users the server may ingest for the circle, or an
// empty set. Legacy circle: every member (all consented, re-verified). Lanes
// circle: only members whose own signed lane is server (re-verified).
func (s *Server) ingestLanes(ctx context.Context, circleID string, dev *serverDeviceInfo) (map[string]bool, error) {
	out := map[string]bool{}
	if dev == nil || e2ee.CheckID(circleID) != nil {
		return out, nil
	}
	var legacy, assist bool
	if err := s.Pool.QueryRow(ctx, `SELECT server_legacy_ck, server_assist FROM circles WHERE id = $1`, circleID).Scan(&legacy, &assist); err != nil {
		return out, err
	}
	if legacy && !assist {
		st, err := s.verifyServerConsents(ctx, circleID, dev)
		if err != nil || !st.ServerMember {
			return out, err
		}
		for _, u := range st.Required {
			out[u] = true
		}
		return out, nil
	}
	if !assist {
		return out, nil
	}
	var ok bool
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_server_assist($1::uuid)`, circleID).Scan(&ok); err != nil || !ok {
		return out, err
	}
	if !s.policyVerified(ctx, s.Pool, circleID) {
		return out, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT user_id::text FROM e2ee_processing_pref WHERE circle_id = $1 AND lane = 'server'`, circleID)
	if err != nil {
		return out, err
	}
	var cand []string
	for rows.Next() {
		var u string
		if rows.Scan(&u) == nil {
			cand = append(cand, u)
		}
	}
	rows.Close()
	for _, u := range cand {
		if s.verifiedLaneServer(ctx, s.Pool, circleID, u) {
			out[u] = true
		}
	}
	return out, nil
}

// membersLackingLanes2 lists live members with no active phone key that
// declared the lanes2 capability.
func membersLackingLanes2(ctx context.Context, q interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}, circleID string) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT m.user_id::text FROM live_circle_members m WHERE m.circle_id = $1
		AND NOT EXISTS (SELECT 1 FROM device_keys d WHERE d.user_id = m.user_id AND d.kind = 'device'
		                AND d.revoked_at IS NULL AND 'lanes2' = ANY(d.caps)) ORDER BY m.user_id`, circleID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// lastLogSeq is the newest log sequence; valid inside the transaction that
// just appended (the log advisory lock is held until it ends).
func lastLogSeq(ctx context.Context, tx pgx.Tx) (int64, error) {
	var seq int64
	err := tx.QueryRow(ctx, `SELECT COALESCE(max(seq), 0) FROM e2ee_log`).Scan(&seq)
	return seq, err
}

// ----------------------------------------------------------------- caps API

// E2EEPutDeviceCaps lets a user (re)declare the capabilities of ONE OF THEIR
// OWN active phone keys. PUT /e2ee/devices/{id}/caps {"caps":["lanes2"]}.
// Advisory and unsigned; nothing server-side trusts it for confidentiality.
func (s *Server) E2EEPutDeviceCaps(w http.ResponseWriter, r *http.Request) {
	uid, ok := circleCaller(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eecaps:user:"+uid, e2eeRegisterPerUser*3, e2eeRegisterWindow) {
		return
	}
	var req struct {
		Caps []string `json:"caps"`
	}
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	id := chi.URLParam(r, "id")
	if e2ee.CheckID(id) != nil {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	}
	caps := cleanCaps(req.Caps)
	tag, err := s.Pool.Exec(r.Context(), `UPDATE device_keys SET caps = $3 WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`, id, uid, caps)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "device key not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "caps": caps})
}

// ------------------------------------------------------------------- state

type processingMemberOut struct {
	UserID    string     `json:"user_id"`
	Name      string     `json:"name"`
	Role      string     `json:"role"`
	Lane      string     `json:"lane"` // verified: "server" or "phone"
	Since     *time.Time `json:"since,omitempty"`
	SKGenOK   bool       `json:"sk_gen_ok"`
	Lanes2    bool       `json:"lanes2"`
	Processed string     `json:"processing"` // "server" | "phone" (what the UI shows)
	// The member's signed statement, so phones verify it against the key log.
	Pref *prefStatementOut `json:"pref,omitempty"`
}

type prefStatementOut struct {
	Lane             string `json:"lane"`
	SKGen            int    `json:"sk_gen"`
	ServerDeviceID   string `json:"server_device_id,omitempty"`
	ServerFingerprint string `json:"server_fingerprint,omitempty"`
	Nonce            string `json:"nonce,omitempty"`
	ApproverDeviceID string `json:"approver_device_id"`
	Signature        string `json:"signature"`
	Legacy           bool   `json:"legacy"`
	LogSeq           *int64 `json:"log_seq,omitempty"`
}

type policyStatementOut struct {
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

// E2EEProcessingState is GET /circles/{id}/e2ee/processing (any member).
func (s *Server) E2EEProcessingState(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeread:user:"+uid, e2eeReadPerUser, e2eeReadWindow) {
		return
	}
	ctx := r.Context()
	var mode, def, optOut string
	var assist, rekey, legacy bool
	var gen, legacyMax int
	var commit []byte
	if err := s.Pool.QueryRow(ctx, `SELECT e2ee_mode, server_assist, server_assist_default, member_opt_out, e2ee_server_gen,
		e2ee_server_commitment, e2ee_server_rekey_required, server_legacy_ck, server_legacy_epoch_max FROM circles WHERE id = $1`, m.CircleID).
		Scan(&mode, &assist, &def, &optOut, &gen, &commit, &rekey, &legacy, &legacyMax); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	dev, err := s.pinnedServerDevice(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load server device")
		return
	}
	policy := map[string]any{"server_assist": assist, "default_for_new": def, "member_opt_out": optOut, "sk_gen": gen,
		"commitment": base64.StdEncoding.EncodeToString(commit), "rekey_required": rekey}
	var ps policyStatementOut
	var psig, pnonce, pcommit []byte
	var pdef, pquot *string
	var pLane string
	if err := s.Pool.QueryRow(ctx, `SELECT log_seq, user_id::text, actor_device_id::text, lane, default_for_new, member_opt_out, sk_gen, commitment, nonce, signature
		FROM e2ee_processing_statements WHERE circle_id = $1 AND kind = 'policy' ORDER BY log_seq DESC LIMIT 1`, m.CircleID).
		Scan(&ps.LogSeq, &ps.AdminUserID, &ps.ActorDeviceID, &pLane, &pdef, &pquot, &ps.SKGen, &pcommit, &pnonce, &psig); err == nil {
		ps.ServerAssist = pLane == "server"
		if pdef != nil {
			ps.DefaultForNew = *pdef
		}
		if pquot != nil {
			ps.MemberOptOut = *pquot
		}
		ps.Commitment, ps.Nonce, ps.Signature = base64.StdEncoding.EncodeToString(pcommit), base64.StdEncoding.EncodeToString(pnonce), base64.StdEncoding.EncodeToString(psig)
		policy["statement"] = ps
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT cm.user_id::text, u.name, cm.role,
		       EXISTS (SELECT 1 FROM device_keys d WHERE d.user_id = cm.user_id AND d.kind = 'device' AND d.revoked_at IS NULL AND 'lanes2' = ANY(d.caps))
		FROM live_circle_members cm JOIN users u ON u.id = cm.user_id
		WHERE cm.circle_id = $1 ORDER BY u.name, cm.user_id`, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load members")
		return
	}
	members := []*processingMemberOut{}
	for rows.Next() {
		mo := &processingMemberOut{Lane: "phone", Processed: "phone"}
		if err := rows.Scan(&mo.UserID, &mo.Name, &mo.Role, &mo.Lanes2); err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "failed to load members")
			return
		}
		members = append(members, mo)
	}
	rows.Close()
	serverCount, notReady := 0, []string{}
	for _, mo := range members {
		if !mo.Lanes2 {
			notReady = append(notReady, mo.UserID)
		}
		p, found := loadPrefRow(ctx, s.Pool, m.CircleID, mo.UserID)
		var rawPref prefStatementOut
		var signedAt time.Time
		var approver string
		if s.Pool.QueryRow(ctx, `SELECT approver_device_id::text, signed_at FROM e2ee_processing_pref WHERE circle_id = $1 AND user_id = $2`, m.CircleID, mo.UserID).Scan(&approver, &signedAt) == nil {
			rawPref = prefStatementOut{Lane: p.Lane, SKGen: p.SKGen, ServerDeviceID: p.ServerDevice, ApproverDeviceID: approver,
				Signature: base64.StdEncoding.EncodeToString(p.Sig), Legacy: p.Legacy, LogSeq: p.LogSeq}
			if len(p.ServerFP) == 32 {
				rawPref.ServerFingerprint = base64.StdEncoding.EncodeToString(p.ServerFP)
			}
			if len(p.Nonce) == 16 {
				rawPref.Nonce = base64.StdEncoding.EncodeToString(p.Nonce)
			}
			mo.Pref = &rawPref
			mo.Since = &signedAt
		}
		if legacy {
			// Legacy circle: the lane is server only while the whole circle is a
			// verified server-member circle.
			if dev != nil {
				if st, err := s.verifyServerConsents(ctx, m.CircleID, dev); err == nil && st.ServerMember {
					for _, c := range st.Consented {
						if c == mo.UserID {
							mo.Lane = "server"
						}
					}
				}
			}
		} else if found && s.verifiedLaneServer(ctx, s.Pool, m.CircleID, mo.UserID) {
			mo.Lane = "server"
			mo.SKGenOK = p.SKGen >= 1 && p.SKGen <= gen
		}
		mo.Processed = mo.Lane
		if mo.Lane == "server" {
			serverCount++
		}
	}
	myLane := "phone"
	for _, mo := range members {
		if mo.UserID == uid {
			myLane = mo.Lane
		}
	}
	out := map[string]any{
		"circle_id": m.CircleID, "mode": mode, "enabled": serverMemberEnabled(), "device": nil,
		"policy": policy, "legacy": map[string]any{"active": legacy, "epoch_max": legacyMax},
		"members": members, "my_lane": myLane, "members_server": serverCount, "members_phone_only": len(members) - serverCount,
		"all_members_lanes2": len(notReady) == 0, "not_ready": notReady,
	}
	if serverMemberEnabled() && dev != nil {
		out["device"] = dev
	}
	// Whether server assistance is actually in effect right now.
	var inEffect bool
	_ = s.Pool.QueryRow(ctx, `SELECT e2ee_server_assist($1::uuid)`, m.CircleID).Scan(&inEffect)
	out["in_effect"] = inEffect
	writeJSON(w, http.StatusOK, out)
}

// -------------------------------------------------------------------- policy

type policyReq struct {
	ServerAssist  bool     `json:"server_assist"`
	DefaultForNew string   `json:"default_for_new"`
	MemberOptOut  string   `json:"member_opt_out"`
	SKGen         int      `json:"sk_gen"`
	Commitment    string   `json:"commitment"`
	Nonce         string   `json:"nonce"`
	Signature     string   `json:"signature"`
	ActorDeviceID string   `json:"actor_device_id"`
	LogSignature  string   `json:"log_signature"`
	Wraps         []wrapIn `json:"wraps"`
}

func (s *Server) policyErr(w http.ResponseWriter, status int, code, msg string) bool {
	writeE2EECode(w, status, code, msg)
	return false
}

// applyPolicy validates and applies a signed processing_policy inside tx. The
// caller is a verified circle admin and holds the circle row lock. It writes the
// error response itself and returns false on failure; it never commits.
func (s *Server) applyPolicy(w http.ResponseWriter, r *http.Request, tx pgx.Tx, uid, circleID string, req policyReq) bool {
	ctx := r.Context()
	var mode, curOptOut string
	var assist, legacy bool
	var gen int
	var storedCommit []byte
	if err := tx.QueryRow(ctx, `SELECT e2ee_mode, server_assist, e2ee_server_gen, server_legacy_ck, e2ee_server_commitment, member_opt_out
		FROM circles WHERE id = $1`, circleID).Scan(&mode, &assist, &gen, &legacy, &storedCommit, &curOptOut); err != nil {
		writeError(w, http.StatusNotFound, "circle not found")
		return false
	}
	if mode != "private" {
		return s.policyErr(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
	}
	if legacy {
		return s.policyErr(w, http.StatusConflict, "legacy_circle", "this circle is in the old trusted-server mode; use the privacy upgrade first")
	}
	defLine, err := e2ee.ParseLine(req.DefaultForNew)
	optOut, err2 := e2ee.ParseMemberOptOut(req.MemberOptOut)
	commit, ok1 := b64d(req.Commitment, 32)
	nonce, ok2 := b64d(req.Nonce, e2ee.ProcessingNonceLen)
	sig, ok3 := b64d(req.Signature, e2ee.SigLen)
	if err != nil || err2 != nil || !ok1 || !ok2 || !ok3 || req.SKGen < 0 || req.SKGen > 1<<30 || e2ee.CheckID(req.ActorDeviceID) != nil {
		writeError(w, http.StatusBadRequest, "default_for_new, member_opt_out, sk_gen, commitment, nonce, signature and actor_device_id are required and must be well-formed")
		return false
	}
	var pub []byte
	var kind string
	if tx.QueryRow(ctx, `SELECT ed25519_pub, kind FROM device_keys WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`,
		req.ActorDeviceID, uid).Scan(&pub, &kind) != nil || kind != "device" {
		writeError(w, http.StatusBadRequest, "actor_device_id must be one of your active phone keys")
		return false
	}
	msg, err := e2ee.ProcessingPolicyMessage(circleID, uid, req.ServerAssist, defLine, optOut, uint32(req.SKGen), commit, nonce)
	if err != nil {
		writeError(w, http.StatusBadRequest, "malformed policy statement")
		return false
	}
	if e2ee.VerifyProcessingPolicy(pub, circleID, uid, req.ServerAssist, defLine, optOut, uint32(req.SKGen), commit, nonce, sig) != nil {
		writeError(w, http.StatusBadRequest, "policy signature does not verify")
		return false
	}

	needWraps := false
	gateMembers := false
	if req.ServerAssist {
		if !serverMemberEnabled() {
			return s.policyErr(w, http.StatusConflict, "server_member_disabled", "this server is not set up to process circle data")
		}
		dev, err := pinnedServerDeviceQ(ctx, tx)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load server device")
			return false
		}
		var approved bool
		if dev == nil || tx.QueryRow(ctx, `SELECT e2ee_device_approved($1::uuid, $2::uuid)`, dev.DeviceID, circleID).Scan(&approved) != nil || !approved {
			return s.policyErr(w, http.StatusConflict, "no_server_device", "no approved server key is available for this circle")
		}
		switch {
		case !assist: // turning on
			if req.SKGen != gen+1 {
				return s.policyErr(w, http.StatusConflict, "bad_generation", "sk_gen must be the last generation plus one")
			}
			needWraps, gateMembers = true, true
		case req.SKGen == gen: // settings change
			if !e2ee.ConstEq(commit, storedCommit) {
				return s.policyErr(w, http.StatusConflict, "commitment_mismatch", "the commitment must match the current server key generation")
			}
			if len(req.Wraps) > 0 {
				writeError(w, http.StatusBadRequest, "wraps for an existing generation are added with the wraps endpoint")
				return false
			}
			gateMembers = optOut == e2ee.OptOutRequiredServer && curOptOut != "required_server"
		case req.SKGen == gen+1: // rotation
			needWraps = true
		default:
			return s.policyErr(w, http.StatusConflict, "bad_generation", "sk_gen must be the current generation or the next one")
		}
	} else {
		if !assist {
			return s.policyErr(w, http.StatusConflict, "already_off", "server assistance is already off")
		}
		if req.SKGen != gen || len(req.Wraps) > 0 {
			return s.policyErr(w, http.StatusConflict, "bad_generation", "turning assistance off keeps the current generation and carries no wraps")
		}
	}
	if gateMembers {
		lacking, err := membersLackingLanes2(ctx, tx, circleID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to check members")
			return false
		}
		if len(lacking) > 0 {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "some members' apps do not support this yet", "code": "members_not_ready", "not_ready": lacking})
			return false
		}
	}
	if needWraps && len(req.Wraps) == 0 {
		writeError(w, http.StatusBadRequest, "the new server key generation must be wrapped to the caller's own device and the other members")
		return false
	}

	newCommit := storedCommit
	if req.ServerAssist {
		newCommit = commit
	}
	rekey := "e2ee_server_rekey_required"
	if needWraps {
		rekey = "FALSE"
	}
	outGen := gen
	if req.ServerAssist {
		outGen = req.SKGen
	}
	optOutStr := optOut.String()
	if !req.ServerAssist {
		optOutStr = "allowed"
	}
	if _, err := tx.Exec(ctx, `UPDATE circles SET server_assist = $2, server_assist_default = $3, member_opt_out = $4,
		e2ee_server_gen = $5, e2ee_server_commitment = $6, e2ee_server_rekey_required = `+rekey+`, e2ee_updated_at = now() WHERE id = $1`,
		circleID, req.ServerAssist, defLine.String(), optOutStr, outGen, newCommit); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update policy")
		return false
	}
	if needWraps {
		_, self, m := s.insertWraps(ctx, tx, circleID, e2ee.LineServer, req.SKGen, uid, uid, req.Wraps)
		if m != "" {
			writeError(w, http.StatusBadRequest, m)
			return false
		}
		if !self {
			writeError(w, http.StatusBadRequest, "the new server key must be wrapped to the caller's own device")
			return false
		}
	}
	ref := e2ee.ProcessingRef(msg)
	if !s.verifyCircleAction(w, r, tx, e2ee.ActProcessingPolicy, uid, circleID, req.SKGen, "", ref,
		signedAction{ActorDeviceID: req.ActorDeviceID, LogSignature: req.LogSignature}) {
		return false
	}
	seq, err := lastLogSeq(ctx, tx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to log policy")
		return false
	}
	lane := "phone"
	if req.ServerAssist {
		lane = "server"
	}
	if _, err := tx.Exec(ctx, `INSERT INTO e2ee_processing_statements
		(log_seq, circle_id, user_id, kind, lane, default_for_new, member_opt_out, sk_gen, commitment, nonce, actor_device_id, signature)
		VALUES ($1,$2,$3,'policy',$4,$5,$6,$7,$8,$9,$10,$11)`,
		seq, circleID, uid, lane, defLine.String(), optOut.String(), req.SKGen, commit, nonce, req.ActorDeviceID, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store policy")
		return false
	}
	return true
}

// E2EEPutProcessingPolicy is PUT /circles/{id}/e2ee/processing-policy: the
// circle ADMIN (and only an admin) turns server assistance on or off, sets the
// default shown to new members and the member_opt_out rule, and publishes a
// new SK generation with its wraps.
func (s *Server) E2EEPutProcessingPolicy(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeprocessing:user:"+uid, processingOpsHour, time.Hour) {
		return
	}
	var req policyReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	tx, _, _, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if !s.applyPolicy(w, r, tx, uid, m.CircleID, req) {
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	what := "off"
	if req.ServerAssist {
		what = "on, member opt-out " + req.MemberOptOut + ", generation " + itoa(req.SKGen)
	}
	s.auditCircle(r.Context(), uid, m.CircleID, "e2ee.processing_policy", "server processing "+what, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "server_assist": req.ServerAssist, "sk_gen": req.SKGen})
}

// ---------------------------------------------------------------------- pref

type prefReq struct {
	Lane              string `json:"lane"`
	SKGen             int    `json:"sk_gen"`
	ServerDeviceID    string `json:"server_device_id"`
	ServerFingerprint string `json:"server_fingerprint"`
	Nonce             string `json:"nonce"`
	ApproverDeviceID  string `json:"approver_device_id"`
	Signature         string `json:"signature"`
	LogSignature      string `json:"log_signature"`
}

// E2EEPutProcessingPref is PUT /circles/{id}/e2ee/processing-pref. The caller
// sets THEIR OWN lane; the user id is never taken from the body, and the
// statement must be signed by one of the caller's own active phone keys, so a
// session token (or any other role, the platform admin and circle admins
// included) cannot move anyone's data to the server.
func (s *Server) E2EEPutProcessingPref(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleMember(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeprocessing:user:"+uid, processingOpsHour, time.Hour) {
		return
	}
	var req prefReq
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	lane, err := e2ee.ParseLine(req.Lane)
	sig, ok1 := b64d(req.Signature, e2ee.SigLen)
	nonce, ok2 := b64d(req.Nonce, e2ee.ProcessingNonceLen)
	fp, ok3 := b64d(req.ServerFingerprint, 32)
	if err != nil || !ok1 || !ok2 || !ok3 || e2ee.CheckID(req.ApproverDeviceID) != nil || e2ee.CheckID(req.ServerDeviceID) != nil || req.SKGen < 0 || req.SKGen > 1<<30 {
		writeError(w, http.StatusBadRequest, "lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id and signature are required (use the zero uuid and a zero fingerprint for lane phone)")
		return
	}
	ctx := r.Context()
	tx, mode, _, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(ctx)
	if mode != "private" {
		writeE2EECode(w, http.StatusConflict, "circle_not_private", "circle is not end-to-end encrypted")
		return
	}
	var assist bool
	var gen int
	if err := tx.QueryRow(ctx, `SELECT server_assist, e2ee_server_gen FROM circles WHERE id = $1`, m.CircleID).Scan(&assist, &gen); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	var pub []byte
	var kind string
	var lanes2, approved bool
	if tx.QueryRow(ctx, `SELECT ed25519_pub, kind, 'lanes2' = ANY(caps), e2ee_device_approved(device_id, $3::uuid)
		FROM device_keys WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL`, req.ApproverDeviceID, uid, m.CircleID).
		Scan(&pub, &kind, &lanes2, &approved) != nil || kind != "device" {
		writeError(w, http.StatusBadRequest, "approver_device_id must be one of your active phone keys")
		return
	}
	msg, merr := e2ee.ProcessingPrefMessage(m.CircleID, uid, lane, uint32(req.SKGen), req.ServerDeviceID, fp, nonce)
	if merr != nil {
		writeError(w, http.StatusBadRequest, "malformed preference statement")
		return
	}
	if e2ee.VerifyProcessingPref(pub, m.CircleID, uid, lane, uint32(req.SKGen), req.ServerDeviceID, fp, nonce, sig) != nil {
		writeError(w, http.StatusBadRequest, "preference signature does not verify")
		return
	}
	subject := ""
	var serverDev any
	var serverFP any
	if lane == e2ee.LineServer {
		if !serverMemberEnabled() || !assist || gen < 1 {
			s.policyErr(w, http.StatusConflict, "server_assist_off", "the circle admin has not turned server processing on")
			return
		}
		dev, err := pinnedServerDeviceQ(ctx, tx)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load server device")
			return
		}
		if dev == nil || dev.DeviceID != req.ServerDeviceID || !e2ee.ConstEq(dev.fp, fp) {
			s.policyErr(w, http.StatusConflict, "not_the_server_device", "that key is not the OpenFamily server device")
			return
		}
		if !lanes2 {
			s.policyErr(w, http.StatusConflict, "device_lacks_lanes2", "this app does not support server processing lanes")
			return
		}
		if !approved {
			writeE2EECode(w, http.StatusForbidden, "device_not_approved", "this device is not approved in this circle")
			return
		}
		if req.SKGen < 1 || req.SKGen > gen {
			s.policyErr(w, http.StatusConflict, "bad_generation", "sk_gen must be an existing server key generation")
			return
		}
		subject = req.ServerDeviceID
		serverDev, serverFP = req.ServerDeviceID, fp
	} else if req.SKGen > gen {
		s.policyErr(w, http.StatusConflict, "bad_generation", "sk_gen is above the current generation")
		return
	}
	if !s.verifyCircleAction(w, r, tx, e2ee.ActProcessingPref, uid, m.CircleID, req.SKGen, subject, e2ee.ProcessingRef(msg),
		signedAction{ActorDeviceID: req.ApproverDeviceID, LogSignature: req.LogSignature}) {
		return
	}
	seq, err := lastLogSeq(ctx, tx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to log preference")
		return
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO e2ee_processing_pref (circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, nonce, approver_device_id, signature, legacy, log_seq, signed_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,FALSE,$10, now())
		ON CONFLICT (circle_id, user_id) DO UPDATE SET lane = EXCLUDED.lane, sk_gen = EXCLUDED.sk_gen,
		  server_device_id = EXCLUDED.server_device_id, server_fingerprint = EXCLUDED.server_fingerprint, nonce = EXCLUDED.nonce,
		  approver_device_id = EXCLUDED.approver_device_id, signature = EXCLUDED.signature, legacy = FALSE,
		  log_seq = EXCLUDED.log_seq, signed_at = now()`,
		m.CircleID, uid, lane.String(), req.SKGen, serverDev, serverFP, nonce, req.ApproverDeviceID, sig, seq); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store preference")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO e2ee_processing_statements
		(log_seq, circle_id, user_id, kind, lane, sk_gen, server_device_id, server_fingerprint, nonce, actor_device_id, signature)
		VALUES ($1,$2,$3,'pref',$4,$5,$6,$7,$8,$9,$10)`,
		seq, m.CircleID, uid, lane.String(), req.SKGen, serverDev, serverFP, nonce, req.ApproverDeviceID, sig); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store preference")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.processing_pref", "member chose lane "+lane.String(), clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "lane": lane.String(), "effective_seq": seq})
}

// ------------------------------------------------------------------- upgrade

type upgradeReq struct {
	// The new phone-key epoch N+1, NOT wrapped to the server key.
	Epoch         int      `json:"epoch"`
	KeyCommitment string   `json:"key_commitment"`
	EpochWraps    []wrapIn `json:"epoch_wraps"`
	signedAction           // log signature of the epoch action
	// The signed policy (assist on, generation 1) with the SK wraps.
	Policy policyReq `json:"policy"`
}

// E2EEUpgradeProcessing is POST /circles/{id}/e2ee/processing-upgrade: the
// admin-triggered migration of a legacy trusted-server circle (ADR section 11).
// In one transaction it (1) clears the legacy flag so the server can no longer
// be wrapped CK, (2) publishes CK epoch N+1 without a server wrap, (3) records
// epoch N as the last one the server may read, (4) applies a signed policy with
// SK generation 1, (5) converts each verified legacy consent into a lane-server
// pref and (6) relabels old server-readable items as line server.
func (s *Server) E2EEUpgradeProcessing(w http.ResponseWriter, r *http.Request) {
	uid, m, ok := s.requireCircleAdmin(w, r)
	if !ok {
		return
	}
	if !s.allowKey(w, "e2eeupgrade:user:"+uid, upgradeOpsHour, time.Hour) {
		return
	}
	var req upgradeReq
	r.Body = http.MaxBytesReader(w, r.Body, e2eeMaxBody*2)
	if !decodeE2EEBody(w, r, &req) {
		return
	}
	if !req.Policy.ServerAssist {
		writeError(w, http.StatusBadRequest, "the upgrade turns server assistance on; policy.server_assist must be true")
		return
	}
	ctx := r.Context()
	tx, mode, cur, ok := s.e2eeCircleTx(w, r, m.CircleID)
	if !ok {
		return
	}
	defer tx.Rollback(ctx)
	var legacy bool
	if err := tx.QueryRow(ctx, `SELECT server_legacy_ck FROM circles WHERE id = $1`, m.CircleID).Scan(&legacy); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load circle")
		return
	}
	if mode != "private" || !legacy {
		writeE2EECode(w, http.StatusConflict, "not_legacy", "only a circle in the old trusted-server mode can be upgraded")
		return
	}
	if req.Epoch != cur+1 {
		writeError(w, http.StatusConflict, "epoch must be exactly the current epoch plus one")
		return
	}
	commit, okc := b64d(req.KeyCommitment, e2ee.KeyLen)
	if !okc || len(req.EpochWraps) == 0 {
		writeError(w, http.StatusBadRequest, "key_commitment and epoch_wraps are required")
		return
	}
	dev, err := pinnedServerDeviceQ(ctx, tx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to load server device")
		return
	}
	if !serverMemberEnabled() || dev == nil {
		writeE2EECode(w, http.StatusConflict, "no_server_device", "no pinned server key")
		return
	}
	lacking, err := membersLackingLanes2(ctx, tx, m.CircleID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to check members")
		return
	}
	if len(lacking) > 0 {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "some members' apps do not support this yet", "code": "members_not_ready", "not_ready": lacking})
		return
	}
	// (1) from here on the server can never be wrapped the phone key.
	if _, err := tx.Exec(ctx, `UPDATE circles SET server_legacy_ck = FALSE WHERE id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to upgrade")
		return
	}
	// (2) CK epoch N+1; a wrap to the server key is refused here and by the trigger.
	_, self, msg := s.insertWraps(ctx, tx, m.CircleID, e2ee.LinePhone, req.Epoch, uid, uid, req.EpochWraps)
	if msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return
	}
	if !self {
		writeError(w, http.StatusBadRequest, "the new phone key must be wrapped to the caller's own device")
		return
	}
	if !s.verifyCircleAction(w, r, tx, e2ee.ActEpoch, uid, m.CircleID, req.Epoch, "", commit, req.signedAction) {
		return
	}
	// (3) epochs <= N stay readable by the server only as already stored data.
	if _, err := tx.Exec(ctx, `UPDATE circles SET e2ee_epoch = $2, e2ee_rekey_required = FALSE, server_legacy_epoch_max = $3, e2ee_updated_at = now() WHERE id = $1`,
		m.CircleID, req.Epoch, cur); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to upgrade")
		return
	}
	// (5) each legacy consent that verifies becomes a lane-server pref at generation 1.
	crow, err := tx.Query(ctx, `
		SELECT sc.user_id::text, sc.approver_device_id::text, sc.signature, ak.ed25519_pub
		FROM e2ee_server_consents sc
		JOIN live_circle_members m ON m.circle_id = sc.circle_id AND m.user_id = sc.user_id
		JOIN device_keys ak ON ak.device_id = sc.approver_device_id AND ak.user_id = sc.user_id AND ak.kind = 'device' AND ak.revoked_at IS NULL
		WHERE sc.circle_id = $1 AND sc.server_device_id = $2`, m.CircleID, dev.DeviceID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to upgrade")
		return
	}
	type conv struct {
		user, approver string
		sig, pub       []byte
	}
	var convs []conv
	for crow.Next() {
		var c conv
		if err := crow.Scan(&c.user, &c.approver, &c.sig, &c.pub); err != nil {
			crow.Close()
			writeError(w, http.StatusInternalServerError, "failed to upgrade")
			return
		}
		if e2ee.VerifyServerConsent(c.pub, m.CircleID, c.user, dev.DeviceID, dev.fp, c.sig) == nil {
			convs = append(convs, c)
		}
	}
	crow.Close()
	for _, c := range convs {
		if _, err := tx.Exec(ctx, `INSERT INTO e2ee_processing_pref
			(circle_id, user_id, lane, sk_gen, server_device_id, server_fingerprint, approver_device_id, signature, legacy)
			VALUES ($1,$2,'server',1,$3,$4,$5,$6,TRUE)
			ON CONFLICT (circle_id, user_id) DO UPDATE SET lane = 'server', sk_gen = 1, server_device_id = EXCLUDED.server_device_id,
			  server_fingerprint = EXCLUDED.server_fingerprint, nonce = NULL, approver_device_id = EXCLUDED.approver_device_id,
			  signature = EXCLUDED.signature, legacy = TRUE, log_seq = NULL, signed_at = now()`,
			m.CircleID, c.user, dev.DeviceID, dev.fp, c.approver, c.sig); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to upgrade")
			return
		}
	}
	// (4) the signed policy (generation 1) and the SK wraps.
	if !s.applyPolicy(w, r, tx, uid, m.CircleID, req.Policy) {
		return
	}
	// (6) Items from epochs the server could read are server-line data now.
	if _, err := tx.Exec(ctx, `DELETE FROM e2ee_server_consents WHERE circle_id = $1`, m.CircleID); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to upgrade")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE e2ee_items SET key_line = 'server' WHERE circle_id = $1 AND key_line = 'phone' AND epoch <= $2`, m.CircleID, cur); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to upgrade")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to commit")
		return
	}
	s.auditCircle(ctx, uid, m.CircleID, "e2ee.processing_upgraded", "legacy trusted-server circle upgraded to per-member lanes; "+itoa(len(convs))+" consent(s) converted", clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "epoch": req.Epoch, "sk_gen": req.Policy.SKGen, "converted": len(convs)})
}

// ------------------------------------------------------------------- helpers
