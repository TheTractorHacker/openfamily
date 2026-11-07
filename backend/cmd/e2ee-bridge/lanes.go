package main

// Processing lanes (docs/design/PRIVACY_PROCESSING.md, sections 5.4, 8.9, 14 phase 3).
//
// In a lanes circle the server device (and the Dawarich bridge, for circles whose
// server assistance is on) reads ONLY the server line:
//
//   - it holds the server key SK, never the circle key CK, and refuses (alarm, exit
//     7) any CK wrap or an SK that equals / commits like a CK;
//   - it pulls only `key_line=server` items;
//   - every author must have a VERIFIED lane server: the member's signed
//     processing_pref, the newest one in the verified key log, naming the server key;
//     an item of any other author is never decrypted;
//   - the policy (assist on, SK generation, commitment) is a signed statement of a
//     circle admin that the verified log contains; nothing the server flags is trusted.
//
// Result items (trip, drive, week) are never requested: the server computes its own
// from the fixes it ingests (ADR 8.4), and a phone-lane author's results stay on the phones.

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// errPolicyOff: every circle the server device was reading turned server assistance
// off. The device stops (exit 3) instead of idling with keys that no longer matter.
var errPolicyOff = errors.New("server assistance was switched off in every circle this server device was reading (admin policy off); its server key was dropped")

// alarmError is a lanes trust violation by the server: the process stops (exit 7).
type alarmError struct{ msg string }

func (e *alarmError) Error() string { return "SECURITY ALARM: " + e.msg }

func isAlarm(err error) bool {
	var a *alarmError
	return errors.As(err, &a)
}

// skID is the key-store / cursor namespace of the server line of a circle.
func skID(circle string) string { return circle + "#sk" }

type circleMode int

const (
	modeOld       circleMode = iota // legacy trusted-server circle, or a circle that never had a lanes policy
	modeLanes                       // server assistance is on: server line only
	modePolicyOff                   // a verified policy says assistance is off
	modeSkip                        // lanes statements did not verify: read nothing
)

type processingResp struct {
	Policy struct {
		ServerAssist bool                   `json:"server_assist"`
		SKGen        int                    `json:"sk_gen"`
		Statement    *e2ee.PolicyStatement  `json:"statement"`
		History      []e2ee.PolicyStatement `json:"history"`
	} `json:"policy"`
	Legacy struct {
		Active bool `json:"active"`
	} `json:"legacy"`
	Members []struct {
		UserID string              `json:"user_id"`
		Pref   *e2ee.PrefStatement `json:"pref"`
	} `json:"members"`
}

// srvKey is the server key that a member's lane statement must name.
type srvKey struct {
	ID string
	FP []byte
}

// fetchProcessing returns nil (no error) when the server has no lanes API.
func (b *bridge) fetchProcessing(ctx context.Context, circle string) (*processingResp, error) {
	var p processingResp
	err := b.api.do(ctx, "GET", "/circles/"+circle+"/e2ee/processing", nil, &p)
	var ae *apiError
	if errors.As(err, &ae) && (ae.Status == 404 || ae.Status == 405) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// circleMode decides how a circle is read. It trusts nothing the server says about
// the mode: once the verified key log holds a processing_policy for the circle, the
// served policy statement must be the newest one in that log or the circle is not read.
func (b *bridge) circleMode(ctx context.Context, circle string, st *circleState) (circleMode, *processingResp, *e2ee.VerifiedPolicy, error) {
	if b.logIdx == nil || !b.logIdx.HasPolicy(circle) {
		return modeOld, nil, nil, nil
	}
	proc, err := b.fetchProcessing(ctx, circle)
	if err != nil {
		return modeSkip, nil, nil, err
	}
	if proc == nil || proc.Policy.Statement == nil {
		b.log.Warn("lanes: the key log has a policy for this circle but the server serves none; circle not read", "circle", circle[:8])
		return modeSkip, nil, nil, nil
	}
	vp, err := b.trust(st).VerifyPolicy(circle, *proc.Policy.Statement, true)
	if err != nil {
		b.log.Warn("lanes: the served policy does not verify; circle not read", "circle", circle[:8], "reason", err.Error())
		return modeSkip, nil, nil, nil
	}
	if !vp.ServerAssist {
		return modePolicyOff, proc, vp, nil
	}
	return modeLanes, proc, vp, nil
}

// policyOff: the admin turned server assistance off. Forget the server key of the
// circle (the server deleted its wraps too) and report it.
func (b *bridge) policyOff(circle string) error {
	id := skID(circle)
	if len(b.keys.epochs(id)) > 0 {
		b.offSeen = true
		b.log.Warn("lanes: the circle admin switched server assistance off; dropping the server key", "circle", circle[:8])
		delete(b.keys.m, id)
		if err := b.st.writeSecret(fileKeys, b.keys.m); err != nil {
			return err
		}
	}
	delete(b.rs.Recv.Cursor, id)
	delete(b.rs.Recv.SKGuard, circle)
	b.lanes[circle] = nil
	return nil
}

// serverKey returns the key members' lane statements must name: this device in
// server mode, the pinned server device (GET /e2ee/server-device) for the Dawarich bridge.
func (b *bridge) serverKey(ctx context.Context) (*srvKey, error) {
	if b.cfg.serverMode() {
		return &srvKey{ID: b.id.f.DeviceID, FP: b.id.fp}, nil
	}
	if b.srvDev != nil {
		return b.srvDev, nil
	}
	var r struct {
		Enabled bool `json:"enabled"`
		Device  *struct {
			DeviceID    string `json:"device_id"`
			Fingerprint string `json:"fingerprint"`
		} `json:"device"`
	}
	if err := b.api.do(ctx, "GET", "/e2ee/server-device", nil, &r); err != nil {
		return nil, err
	}
	if !r.Enabled || r.Device == nil {
		return nil, nil
	}
	fp, err := hex.DecodeString(r.Device.Fingerprint)
	if err != nil || len(fp) != 32 || e2ee.CheckID(r.Device.DeviceID) != nil {
		return nil, nil
	}
	b.srvDev = &srvKey{ID: r.Device.DeviceID, FP: fp}
	return b.srvDev, nil
}

// syncLanes reads one circle through the server line.
func (b *bridge) syncLanes(ctx context.Context, circle string, st *circleState, proc *processingResp, vp *e2ee.VerifiedPolicy) error {
	srv, err := b.serverKey(ctx)
	if err != nil {
		return err
	}
	tr := b.trust(st)
	lanes := map[string]bool{}
	if srv != nil {
		prefs := map[string]*e2ee.PrefStatement{}
		for _, m := range proc.Members {
			prefs[m.UserID] = m.Pref
		}
		for _, m := range st.Members {
			lane, err := tr.VerifyPref(circle, m.UserID, prefs[m.UserID], srv.ID, srv.FP, vp.SKGen)
			if err == nil && lane == e2ee.LineServer {
				lanes[m.UserID] = true
			}
		}
	}
	b.lanes[circle] = lanes
	if err := b.syncSK(ctx, circle, st, proc, vp); err != nil {
		return err
	}
	have := b.keys.get(skID(circle), int(vp.SKGen)) != nil
	b.reportMissing(ctx, circle, vp, have)
	if len(lanes) == 0 {
		b.log.Info("lanes: no member has a verified server lane; nothing is read", "circle", circle[:8])
		return nil
	}
	if len(b.keys.epochs(skID(circle))) == 0 {
		return nil
	}
	b.laneOn[circle] = true
	b.active++
	return b.pull(ctx, circle)
}

// ckKeys lists every circle key (phone line) this device holds for the circle: none
// for a lanes circle, possibly old epochs of an upgraded legacy circle or the keys a
// Dawarich bridge's owner chose to give it.
func (b *bridge) ckKeys(circle string) [][]byte {
	var out [][]byte
	for _, e := range b.keys.epochs(circle) {
		if k := b.keys.get(circle, e); k != nil {
			out = append(out, k)
		}
	}
	return out
}

func (b *bridge) guard(circle string) *e2ee.RollbackGuard {
	if s := b.rs.Recv.SKGuard[circle]; s != nil {
		return e2ee.RestoreRollbackGuard(*s)
	}
	return e2ee.NewRollbackGuard()
}

func (b *bridge) saveGuard(circle string, g *e2ee.RollbackGuard) {
	s := g.State()
	b.rs.Recv.SKGuard[circle] = &s
}

// policyForGen returns the newest VERIFIED policy statement with assistance on for an SK generation.
func (b *bridge) policyForGen(circle string, st *circleState, proc *processingResp, vp *e2ee.VerifiedPolicy, gen int) *e2ee.VerifiedPolicy {
	if uint32(gen) == vp.SKGen {
		return vp
	}
	var best *e2ee.VerifiedPolicy
	for _, h := range proc.Policy.History {
		if h.SKGen != gen || !h.ServerAssist {
			continue
		}
		if v, err := b.trust(st).VerifyPolicy(circle, h, false); err == nil && v.ServerAssist && (best == nil || v.LogSeq > best.LogSeq) {
			best = v
		}
	}
	return best
}

// syncSK fetches and verifies the server-line wraps addressed to this device.
func (b *bridge) syncSK(ctx context.Context, circle string, st *circleState, proc *processingResp, vp *e2ee.VerifiedPolicy) error {
	id := skID(circle)
	if b.keys.get(id, int(vp.SKGen)) != nil {
		delete(b.keyRetry, id)
		return nil
	}
	kr := b.keyRetry[id]
	if kr == nil {
		kr = &keyRetry{}
		b.keyRetry[id] = kr
	}
	if b.now().Before(kr.next) {
		return nil
	}
	var resp struct {
		Wraps []e2ee.SKWrap `json:"wraps"`
	}
	if err := b.api.do(ctx, "GET", "/circles/"+circle+"/e2ee/wraps?key_line=server&device_id="+url.QueryEscape(b.id.f.DeviceID), nil, &resp); err != nil {
		return err
	}
	for _, w := range resp.Wraps {
		if w.KeyLine != "server" {
			// We asked for the server line only. A phone-line wrap (CK) for this device is a
			// violation by the server, or a bug: either way this key must never hold CK.
			b.rs.Stats.Rejected["ck_wrap_offered"]++
			return &alarmError{fmt.Sprintf("the server offered a circle-key (phone line, line %q) wrap to this device in circle %s. This key must only ever hold the server key. Nothing was stored. Revoke this key and investigate the server (and any admin phone that wrapped CK to a server-kind key).", w.KeyLine, circle[:8])}
		}
		if w.RecipientDeviceID != b.id.f.DeviceID || b.keys.get(id, w.Epoch) != nil {
			continue
		}
		pol := b.policyForGen(circle, st, proc, vp, w.Epoch)
		if pol == nil {
			b.rs.Stats.Rejected["wrap_rejected"]++
			b.log.Warn("lanes: server-key wrap without a verified policy for its generation", "circle", circle[:8], "gen", w.Epoch)
			continue
		}
		key, err := b.trust(st).OpenSKWrap(circle, b.id.f.DeviceID, b.id.xSecret, b.id.xPub, w, pol)
		if err != nil {
			b.rs.Stats.Rejected["wrap_rejected"]++
			b.log.Warn("lanes: server-key wrap rejected", "circle", circle[:8], "gen", w.Epoch, "reason", err.Error())
			continue
		}
		if err := e2ee.CheckSKIndependent(key, circle, b.ckKeys(circle), st.Epochs); err != nil {
			b.rs.Stats.Rejected["sk_equals_ck"]++
			return &alarmError{fmt.Sprintf("circle %s generation %d: %v. An admin phone used the phone key as the server key. The key was NOT stored.", circle[:8], w.Epoch, err)}
		}
		if err := b.keys.put(id, w.Epoch, key); err != nil {
			return err
		}
		g := b.guard(circle)
		if err := g.Observe(e2ee.LineServer, uint32(w.Epoch), b.now().UnixMilli()); err == nil {
			b.saveGuard(circle, g)
		}
		b.log.Info("server key stored", "circle", circle[:8], "gen", w.Epoch)
	}
	if b.keys.get(id, int(vp.SKGen)) == nil {
		d := 30 * time.Second << min(kr.attempt, 5)
		kr.attempt++
		kr.next = b.now().Add(min(d, 10*time.Minute))
	} else {
		delete(b.keyRetry, id)
	}
	return nil
}

// reportMissing says clearly who lacks the current SK: this device, and the member
// devices the server lists as lacking a wrap (they cannot decrypt each other's server-line data).
func (b *bridge) reportMissing(ctx context.Context, circle string, vp *e2ee.VerifiedPolicy, have bool) {
	var resp struct {
		Pending []struct {
			DeviceID string `json:"device_id"`
			UserName string `json:"user_name"`
			Kind     string `json:"kind"`
		} `json:"pending"`
	}
	var pend []string
	if err := b.api.do(ctx, "GET", "/circles/"+circle+"/e2ee/pending?key_line=server", nil, &resp); err == nil {
		for _, p := range resp.Pending {
			pend = append(pend, p.DeviceID[:min(8, len(p.DeviceID))])
		}
	}
	sort.Strings(pend)
	msg := fmt.Sprintf("gen=%d own=%v pending=%s", vp.SKGen, have, strings.Join(pend, ","))
	if b.lastMissing[circle] == msg {
		return
	}
	b.lastMissing[circle] = msg
	if !have {
		b.log.Warn("lanes: this device holds no server key for the current generation yet; waiting for an admin's phone to wrap it (open the circle's encryption screen on an admin phone)",
			"circle", circle[:8], "gen", vp.SKGen)
	}
	if len(pend) > 0 {
		b.log.Warn("lanes: member devices that lack the current server key (they joined after it was wrapped)", "circle", circle[:8], "gen", vp.SKGen, "devices", len(pend))
	}
}

// processLane verifies one server-line item. Order matters: everything that needs no
// key (shape, line, author, author's lane) happens BEFORE decryption, so an item of an
// author whose lane is not server is never opened.
func (b *bridge) processLane(ctx context.Context, circle string, it wireItem) reason {
	if (it.Purpose != "fix" && it.Purpose != "history") || it.Seq <= 0 || it.Epoch < 1 || e2ee.CheckID(it.DeviceID) != nil {
		return rMalformed
	}
	if it.KeyLine != "server" {
		return rLineMismatch
	}
	ct, err := base64.StdEncoding.DecodeString(it.Ciphertext)
	if err != nil {
		return rMalformed
	}
	hdr, err := e2ee.ParsePayloadHeader(ct)
	if err != nil {
		return rMalformed
	}
	if hdr.Version != e2ee.MsgVersionV2 || hdr.Line != e2ee.LineServer {
		return rLineMismatch // a phone-line payload relayed as server line: cross-line confusion
	}
	if int(hdr.Gen) != it.Epoch {
		return rMalformed
	}
	dk := devKey(circle, it.DeviceID) + "#sk"
	ds := b.rs.Recv.Dev[dk]
	if ds == nil {
		ds = &devState{}
	}
	for _, s := range ds.Window {
		if s == it.Seq {
			return rDuplicate
		}
	}
	st := b.cur[circle]
	dev, mem := st.device(it.DeviceID)
	if dev == nil && !b.resynced {
		b.resynced = true
		if ns, err := b.fetchState(ctx, circle); err == nil {
			st = ns
			dev, mem = st.device(it.DeviceID)
		}
	}
	if dev == nil {
		return rUnknownSender
	}
	if err := b.trust(st).AuthorizeSender(dev, mem); err != nil {
		switch {
		case errors.Is(err, e2ee.ErrNotInLog):
			return rUnknownSender
		case dev.UserID == mem.UserID && dev.Approved != nil && *dev.Approved && dev.RevokedAt == nil && dev.Kind != "recovery":
			return rBadReg
		}
		return rNotMember
	}
	if !b.lanes[circle][dev.UserID] {
		return rNotServerLn
	}
	key := b.keys.get(skID(circle), int(hdr.Gen))
	if key == nil {
		return rNoKey
	}
	edPub, err := base64.StdEncoding.DecodeString(dev.Ed25519Pub)
	if err != nil {
		return rBadReg
	}
	item, err := e2ee.OpenItemV2(key, circle, e2ee.LineServer, it.DeviceID, edPub, it.Purpose, uint64(it.Seq), ct)
	switch {
	case err == nil:
	case errors.Is(err, e2ee.ErrLineMismatch):
		return rLineMismatch
	case errors.Is(err, e2ee.ErrDecrypt):
		return rBadCipher
	case errors.Is(err, e2ee.ErrItemSeqMatch):
		return rSeqMismatch
	case errors.Is(err, e2ee.ErrBadItemSig):
		return rBadSignature
	case errors.Is(err, e2ee.ErrBadEnvelope), errors.Is(err, e2ee.ErrBadBlob), errors.Is(err, e2ee.ErrShortCipher):
		return rBadEnvelope
	default:
		return rMalformed
	}
	if item.Line != e2ee.LineServer || item.Gen != hdr.Gen {
		return rLineMismatch
	}
	now := b.now()
	if item.TsMs > uint64(math.MaxInt64) || time.UnixMilli(int64(item.TsMs)).After(now.Add(maxSkew)) {
		return rClockSkew
	}
	g := b.guard(circle)
	if err := g.Check(e2ee.LineServer, item.Gen, it.DeviceID, item.TsMs, now.UnixMilli()); err != nil {
		return rRollback
	}
	b.saveGuard(circle, g)
	if int64(item.Seq) > ds.HighSeq {
		ds.HighSeq = int64(item.Seq)
	}
	ds.Window = append(ds.Window, it.Seq)
	if len(ds.Window) > windowKeep {
		sort.Slice(ds.Window, func(i, j int) bool { return ds.Window[i] < ds.Window[j] })
		ds.Window = ds.Window[len(ds.Window)-windowKeep:]
	}
	b.rs.Recv.Dev[dk] = ds
	if !b.collect(circle, it.Purpose, dev.UserID, mem.Name, it.DeviceID, int64(item.TsMs), item.Body) {
		return rBadBody
	}
	return rOK
}
