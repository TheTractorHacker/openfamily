package main

// The bridge engine: key sync, log verification, sender authorisation, item
// verification (the phone's ChannelReceiver policy) and hand-over to Dawarich.

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const (
	maxSkew          = 10 * time.Minute
	rollbackGrace    = 10 * time.Minute
	windowKeep       = 512
	unknownSenderTTL = 15 * time.Minute // an unknown sender is retried this long, then dropped
	noKeyTTL         = 7 * 24 * time.Hour
	pageLimit        = 500
)

// Exit codes.
const (
	exitOK       = 0
	exitError    = 1
	exitUsage    = 2
	exitRevoked  = 3
	exitLog      = 4
	exitReauth   = 5
	exitDawarich = 6
	exitAlarm    = 7 // lanes: the server handed this key a phone key (CK) or an SK that reuses a CK
)

// logError means the key transparency log failed verification: stop loudly.
type logError struct {
	problem e2ee.LogProblem
	detail  string
}

func (e *logError) Error() string {
	return fmt.Sprintf("KEY TRANSPARENCY LOG VERIFICATION FAILED (%s): %s", e.problem, e.detail)
}

// ---- wire types

type circleOut struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	E2EEMode  string `json:"e2ee_mode"`
	E2EEEpoch int    `json:"e2ee_epoch"`
}

type memberOut = e2ee.CircleMember

type circleState struct {
	CircleID string             `json:"circle_id"`
	Mode     string             `json:"mode"`
	Epoch    int                `json:"epoch"`
	Members  []memberOut        `json:"members"`
	Epochs   []e2ee.EpochRecord `json:"epochs"`

	regOK map[string]bool // verified registration per device (cache for this snapshot)
}

func (s *circleState) device(id string) (*e2ee.DeviceRecord, *memberOut) {
	for i := range s.Members {
		for j := range s.Members[i].Devices {
			if s.Members[i].Devices[j].DeviceID == id {
				return &s.Members[i].Devices[j], &s.Members[i]
			}
		}
	}
	return nil, nil
}

func (s *circleState) record(epoch int) *e2ee.EpochRecord {
	for i := range s.Epochs {
		if s.Epochs[i].Epoch == epoch {
			return &s.Epochs[i]
		}
	}
	return nil
}

func (s *circleState) registrationOK(d *e2ee.DeviceRecord) bool {
	if s.regOK == nil {
		s.regOK = map[string]bool{}
	}
	// Keyed by every field the verification covers, so a record that differs in
	// any of them can never reuse an earlier verdict.
	k := strings.Join([]string{d.DeviceID, d.UserID, d.Kind, d.Ed25519Pub, d.X25519Pub, d.Fingerprint, d.Signature,
		d.RegisteredByDeviceID, d.RegisteredByPub, strconv.Itoa(d.RegistrationAction), d.RegistrationSignature}, "\x00")
	if v, ok := s.regOK[k]; ok {
		return v
	}
	v := e2ee.VerifyRegistration(*d)
	s.regOK[k] = v
	return v
}

type wireItem struct {
	ID         int64  `json:"id"`
	DeviceID   string `json:"device_id"`
	Seq        int64  `json:"seq"`
	Purpose    string `json:"purpose"`
	Epoch      int    `json:"epoch"`
	Ciphertext string `json:"ciphertext"`
	KeyLine    string `json:"key_line,omitempty"`
}

type itemsPage struct {
	Items      []wireItem `json:"items"`
	NextCursor int64      `json:"next_cursor"`
	HasMore    bool       `json:"has_more"`
}

// ---- the bridge

type keyRetry struct {
	next    time.Time
	attempt int
}

type bridge struct {
	st   *store
	id   *identity
	keys *circleKeys
	api  *apiClient
	cfg  *config
	rs   *runState
	sink pointSink
	log  *slog.Logger
	now  func() time.Time

	consents map[string]map[string]bool // server mode: verified consents per circle
	cur      map[string]*circleState    // newest state per circle
	keyRetry map[string]*keyRetry
	pending  []point        // points collected while handling a page
	resynced bool           // state already refreshed for this page
	snap     *recvState     // receiver state before the current page
	logIdx   *e2ee.LogIndex // fully verified log; nil until the first verification (everything is then refused)

	// lanes (docs/design/PRIVACY_PROCESSING.md, section 19): per circle read through the server line only
	laneOn      map[string]bool            // circle is read via key_line=server this cycle
	lanes       map[string]map[string]bool // circle -> user -> VERIFIED lane server
	srvDev      *srvKey                    // the server key members' prefs must name (nil: unknown)
	active      int                        // circles read (either flow) in this cycle
	offSeen     bool                       // a circle whose server key we held turned its policy off
	lastMissing map[string]string          // circle -> last missing-wrap report (log only on change)
}

func newBridge(st *store, id *identity, api *apiClient, cfg *config, log *slog.Logger) (*bridge, error) {
	keys, err := st.loadCircleKeys()
	if err != nil {
		return nil, err
	}
	rs, err := st.loadRunState()
	if err != nil {
		return nil, err
	}
	var sink pointSink = newSink(cfg, log)
	if cfg.serverMode() {
		sink = newServerSink(cfg, id.f.DeviceID, log)
	}
	return &bridge{st: st, id: id, keys: keys, api: api, cfg: cfg, rs: rs, sink: sink, log: log,
		now: time.Now, cur: map[string]*circleState{}, keyRetry: map[string]*keyRetry{}, consents: map[string]map[string]bool{},
		laneOn: map[string]bool{}, lanes: map[string]map[string]bool{}, lastMissing: map[string]string{}}, nil
}

func (b *bridge) save() error { return b.st.saveRunState(b.rs) }

// saveSent persists the delivery high-water marks WITHOUT the receiver state of
// the page being handled (that is committed only once the whole page is done).
func (b *bridge) saveSent() error {
	tmp := *b.rs
	if b.snap != nil {
		tmp.Recv = *b.snap
	}
	return b.st.saveRunState(&tmp)
}

func (b *bridge) fetchState(ctx context.Context, circle string) (*circleState, error) {
	var cs circleState
	if err := b.api.do(ctx, "GET", "/circles/"+circle+"/e2ee", nil, &cs); err != nil {
		return nil, err
	}
	b.cur[circle] = &cs
	return &cs, nil
}

// cycle runs one pass over every private circle of the account.
func (b *bridge) cycle(ctx context.Context) error {
	var circles []circleOut
	if err := b.api.do(ctx, "GET", "/circles", nil, &circles); err != nil {
		return err
	}
	if err := b.verifyLog(ctx); err != nil {
		return err
	}
	var first error
	b.active, b.srvDev = 0, nil
	for _, c := range circles {
		if c.E2EEMode != "private" || !b.cfg.wantCircle(c.ID) {
			continue
		}
		if ctx.Err() != nil {
			break
		}
		if err := b.syncCircle(ctx, c); err != nil {
			if fatal(err) {
				return err
			}
			b.log.Warn("circle sync failed, will retry", "circle", c.ID[:8], "err", err)
			if first == nil {
				first = err
			}
		}
	}
	b.rs.Stats.LastSync = b.now().UTC().Format(time.RFC3339)
	if err := b.save(); err != nil {
		return err
	}
	if b.offSeen && b.active == 0 && b.cfg.serverMode() {
		return errPolicyOff
	}
	return first
}

func fatal(err error) bool {
	var le *logError
	return errors.Is(err, errNoApproved) || errors.Is(err, errReauth) || errors.Is(err, errDawarichAuth) || errors.Is(err, errIngestAuth) || errors.Is(err, errPolicyOff) || errors.As(err, &le) || isAlarm(err)
}

// ---- transparency log

func (b *bridge) verifyLog(ctx context.Context) error {
	var pinned *e2ee.LogHead
	if b.rs.LogSeq > 0 {
		h, err := hex.DecodeString(b.rs.LogHash)
		if err != nil || len(h) != 32 {
			return errors.New("state.json: pinned log head is corrupt")
		}
		pinned = &e2ee.LogHead{Seq: b.rs.LogSeq, Hash: h}
	}
	fetch := func(after int64) ([]e2ee.LogEntry, e2ee.LogHead, error) {
		var resp struct {
			Entries []e2ee.LogEntry `json:"entries"`
			Head    struct {
				Seq  int64  `json:"seq"`
				Hash string `json:"hash"`
			} `json:"head"`
		}
		if err := b.api.do(ctx, "GET", "/e2ee/log?after="+strconv.FormatInt(after, 10), nil, &resp); err != nil {
			return nil, e2ee.LogHead{}, err
		}
		h, err := hex.DecodeString(resp.Head.Hash)
		if err != nil {
			return nil, e2ee.LogHead{}, errors.New("malformed log head")
		}
		return resp.Entries, e2ee.LogHead{Seq: resp.Head.Seq, Hash: h}, nil
	}
	c, idx, err := e2ee.SyncLogFull(pinned, fetch)
	if err != nil {
		return err
	}
	if !c.OK() {
		return &logError{c.Problem, c.Detail}
	}
	b.logIdx = idx
	if c.NewHead != nil && c.NewHead.Seq > b.rs.LogSeq {
		b.rs.LogSeq, b.rs.LogHash = c.NewHead.Seq, c.NewHead.HashHex()
		return b.save()
	}
	return nil
}

// ---- circle keys

// syncKeys fetches and verifies wraps for epochs this bridge does not hold yet.
// Unless force is set it honours an exponential backoff after a miss.
func (b *bridge) syncKeys(ctx context.Context, circle string, st *circleState, force bool) error {
	var missing []int
	for _, r := range st.Epochs {
		if b.keys.get(circle, r.Epoch) == nil {
			missing = append(missing, r.Epoch)
		}
	}
	if len(missing) == 0 {
		delete(b.keyRetry, circle)
		return nil
	}
	kr := b.keyRetry[circle]
	if kr == nil {
		kr = &keyRetry{}
		b.keyRetry[circle] = kr
	}
	if !force && b.now().Before(kr.next) {
		return nil
	}
	var resp struct {
		Wraps []e2ee.WrapRecord `json:"wraps"`
	}
	if err := b.api.do(ctx, "GET", "/circles/"+circle+"/e2ee/wraps?device_id="+url.QueryEscape(b.id.f.DeviceID), nil, &resp); err != nil {
		return err
	}
	for _, w := range resp.Wraps {
		if b.keys.get(circle, w.Epoch) != nil {
			continue
		}
		key, err := b.acceptWrap(circle, st, w)
		if err != nil {
			b.rs.Stats.Rejected["wrap_rejected"]++
			b.log.Warn("wrap rejected", "circle", circle[:8], "epoch", w.Epoch, "reason", err.Error())
			continue
		}
		if err := b.keys.put(circle, w.Epoch, key); err != nil {
			return err
		}
		b.log.Info("circle key stored", "circle", circle[:8], "epoch", w.Epoch)
	}
	still := false
	for _, e := range missing {
		if b.keys.get(circle, e) == nil {
			still = true
		}
	}
	if still {
		d := 30 * time.Second << min(kr.attempt, 5)
		kr.attempt++
		kr.next = b.now().Add(min(d, 10*time.Minute))
	} else {
		delete(b.keyRetry, circle)
	}
	return nil
}

// trust bundles what the authorization rules need. An enrollment without a pinned
// approver has no anchor, so devices of our own account are refused (fail closed).
func (b *bridge) trust(st *circleState) e2ee.Trust {
	t := e2ee.Trust{Index: b.logIdx, Members: st.Members, OwnUserID: b.id.f.UserID}
	if b.id.f.ApprovedBy != "" && b.id.f.ApproverEdPub != "" {
		t.Anchor = &e2ee.Anchor{DeviceID: b.id.f.ApprovedBy, EdPub: b.id.f.ApproverEdPub}
	}
	return t
}

// acceptWrap is the phone's syncCircleKeys policy plus server-independent
// authorization, failing closed: the epoch publisher and the wrapper must be
// listed, active, approved devices with the keys the wrap/record carry, their
// registrations must be in the verified log, and so must the epoch record.
func (b *bridge) acceptWrap(circle string, st *circleState, w e2ee.WrapRecord) ([]byte, error) {
	rec := st.record(w.Epoch)
	level, err := b.trust(st).AuthorizeWrap(circle, w, rec)
	if err != nil {
		return nil, err
	}
	if level != e2ee.TrustAnchored {
		b.log.Warn("circle key accepted from another member (first-use trust, not verified by your phone)", "circle", circle[:8], "epoch", w.Epoch)
	}
	return e2ee.OpenWrap(circle, b.id.f.DeviceID, b.id.xSecret, b.id.xPub, w, rec)
}

// ---- one circle

func (b *bridge) syncCircle(ctx context.Context, c circleOut) error {
	st, err := b.fetchState(ctx, c.ID)
	if err != nil {
		return err
	}
	if st.Mode != "private" {
		return nil
	}
	delete(b.laneOn, c.ID)
	mode, proc, vp, err := b.circleMode(ctx, c.ID, st)
	if err != nil {
		return err
	}
	switch mode {
	case modeLanes:
		return b.syncLanes(ctx, c.ID, st, proc, vp)
	case modeSkip:
		return nil
	case modePolicyOff:
		if b.cfg.serverMode() {
			return b.policyOff(c.ID)
		}
		// The Dawarich bridge: assistance off means there is no server lane; the old
		// flow (the keys its owner chose to give it) is unchanged.
	}
	if err := b.syncKeys(ctx, c.ID, st, false); err != nil {
		return err
	}
	if b.cfg.serverMode() {
		// Legacy trusted-server circle: the server device reads it only while EVERY
		// member's phone has signed a consent for this key (verified here, not taken
		// from the server).
		var resp struct {
			Consents []consentWire `json:"consents"`
		}
		if err := b.api.do(ctx, "GET", "/circles/"+c.ID+"/e2ee/server-member", nil, &resp); err != nil {
			return err
		}
		ok := b.verifiedConsents(c.ID, st, resp.Consents)
		b.consents[c.ID] = ok
		if missing := consentsComplete(st, ok); len(missing) > 0 {
			b.log.Info("server mode: waiting for member consent, circle not read", "circle", c.ID[:8], "missing", len(missing))
			return nil
		}
		if len(ok) == 0 {
			return nil
		}
	}
	b.active++
	return b.pull(ctx, c.ID)
}

func (b *bridge) pull(ctx context.Context, circle string) error {
	curKey, lineQ := circle, ""
	if b.laneOn[circle] {
		curKey, lineQ = skID(circle), "&key_line=server"
	}
	stored := b.rs.Recv.Cursor[curKey]
	after := stored
	frozen := int64(-1) // once an item is deferred, the persisted cursor stays before it
	for page := 0; page < 400 && ctx.Err() == nil; page++ {
		var resp itemsPage
		q := fmt.Sprintf("/circles/%s/e2ee/items?after=%d&as_device=%s&purpose=fix,history&limit=%d%s", circle, after, b.id.f.DeviceID, pageLimit, lineQ)
		if err := b.api.do(ctx, "GET", q, nil, &resp); err != nil {
			return err
		}
		// A fetched page is handled to the end even when shutdown is requested.
		snap := b.rs.cloneRecv()
		b.snap = &snap
		b.pending, b.resynced = nil, false
		firstDeferred, err := b.handlePage(context.WithoutCancel(ctx), circle, resp.Items)
		if err != nil {
			b.rs.Recv = snap // the page is re-processed next time, nothing is lost
			b.pending = nil
			return err
		}
		next := max(resp.NextCursor, after)
		if firstDeferred > 0 && frozen < 0 {
			frozen = max(firstDeferred-1, stored)
		}
		if frozen >= 0 && next > frozen {
			next = frozen
		}
		if next > stored {
			b.rs.Recv.Cursor[curKey], stored = next, next
		}
		if err := b.save(); err != nil {
			return err
		}
		after = max(resp.NextCursor, after)
		if !resp.HasMore || len(resp.Items) == 0 {
			break
		}
	}
	return nil
}

type reason string

const (
	rOK            reason = ""
	rDuplicate     reason = "duplicate"
	rMalformed     reason = "malformed"
	rNoKey         reason = "no_key"
	rNoConsent     reason = "no_consent"
	rUnknownSender reason = "unknown_sender"
	rNotMember     reason = "sender_not_member"
	rBadReg        reason = "sender_registration_invalid"
	rBadCipher     reason = "bad_ciphertext"
	rBadEnvelope   reason = "bad_envelope"
	rSeqMismatch   reason = "seq_mismatch"
	rBadSignature  reason = "bad_signature"
	rClockSkew     reason = "clock_skew"
	rRollback      reason = "epoch_rollback"
	rBadBody       reason = "bad_body"
	// lanes
	rLineMismatch reason = "line_mismatch"          // not a server-line v2 item (cross-line confusion)
	rNotServerLn  reason = "author_not_server_lane" // the author's verified lane is not server: never decrypted
)

// transient verdicts keep the cursor in front of the item and are retried until a TTL. An author
// whose lane is not (yet) server is one of them: a member who signs the server lane right after
// our last state refresh must not lose the first items to a race, and an honest phone never
// puts a server-line item in the relay without a server-lane statement anyway.
func transient(r reason) bool { return r == rNoKey || r == rUnknownSender || r == rNotServerLn }

// handlePage verifies every item, collects points, delivers them and returns the
// id of the first item that stays deferred (0 if none).
func (b *bridge) handlePage(ctx context.Context, circle string, items []wireItem) (int64, error) {
	var firstDeferred int64
	counts := map[reason]int{}
	accepted := 0
	for _, it := range items {
		r := b.process(ctx, circle, it)
		key := circle + "/" + it.DeviceID + "/" + strconv.FormatInt(it.Seq, 10)
		if transient(r) {
			now := b.now().UnixMilli()
			first, seen := b.rs.Recv.Deferred[key]
			if !seen {
				b.rs.Recv.Deferred[key], first = now, now
			}
			ttl := unknownSenderTTL
			if r == rNoKey && !b.laneOn[circle] {
				ttl = noKeyTTL
			}
			if time.Duration(now-first)*time.Millisecond > ttl {
				delete(b.rs.Recv.Deferred, key)
				counts[reason(string(r)+"_expired")]++
				continue
			}
			if firstDeferred == 0 {
				firstDeferred = it.ID
			}
			counts["deferred_"+r]++
			continue
		}
		delete(b.rs.Recv.Deferred, key)
		if r == rOK {
			accepted++
		} else {
			counts[r]++
		}
	}
	if len(b.pending) > 0 {
		sent, dropped, err := b.sink.flush(ctx, b.pending, b.rs.Sent.LastTsMs, b.saveSent)
		b.rs.Stats.Sent += int64(sent)
		for k, v := range dropped {
			b.rs.Stats.Dropped[k] += v
		}
		if err != nil {
			return 0, err
		}
		b.pending = nil
	}
	b.rs.Stats.Accepted += int64(accepted)
	rej := 0
	for r, n := range counts {
		b.rs.Stats.Rejected[string(r)] += int64(n)
		if r != rDuplicate && !strings.HasPrefix(string(r), "deferred_") {
			rej += n
		}
	}
	if len(items) > 0 {
		b.log.Info("page handled", "circle", circle[:8], "items", len(items), "accepted", accepted,
			"rejected", rej, "duplicates", counts[rDuplicate], "deferred", int(firstDeferredCount(counts)))
	}
	return firstDeferred, nil
}

func firstDeferredCount(c map[reason]int) int {
	n := 0
	for r, v := range c {
		if strings.HasPrefix(string(r), "deferred_") {
			n += v
		}
	}
	return n
}

func devKey(circle, dev string) string { return circle + "/" + dev }

// process runs the phone's ChannelReceiver policy for one item.
func (b *bridge) process(ctx context.Context, circle string, it wireItem) reason {
	if b.laneOn[circle] {
		return b.processLane(ctx, circle, it)
	}
	if (it.Purpose != "fix" && it.Purpose != "history") || it.Seq <= 0 || it.Epoch < 1 || e2ee.CheckID(it.DeviceID) != nil {
		return rMalformed
	}
	ct, err := base64.StdEncoding.DecodeString(it.Ciphertext)
	if err != nil {
		return rMalformed
	}
	if hdr, err := e2ee.PayloadEpoch(ct); err != nil || int(hdr) != it.Epoch {
		return rMalformed
	}
	dk := devKey(circle, it.DeviceID)
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
	key := b.keys.get(circle, it.Epoch)
	if key == nil && !b.resynced {
		// An unknown epoch: re-read the circle state and try to fetch its key.
		b.resynced = true
		if ns, err := b.fetchState(ctx, circle); err == nil {
			st = ns
			_ = b.syncKeys(ctx, circle, st, false)
			key = b.keys.get(circle, it.Epoch)
		}
	}
	if key == nil {
		return rNoKey
	}
	dev, mem := st.device(it.DeviceID)
	if dev == nil && !b.resynced {
		b.resynced = true
		if ns, err := b.fetchState(ctx, circle); err == nil {
			st = ns
			dev, mem = st.device(it.DeviceID)
		}
	}
	if dev == nil {
		// A revoked or foreign key. Authentic ciphertext may still heal after a state
		// refresh (a just-approved phone); tampered ciphertext is rejected now.
		if _, err := e2ee.Open(key, circle, it.DeviceID, it.Purpose, ct); err != nil {
			return rBadCipher
		}
		return rUnknownSender
	}
	if err := b.trust(st).AuthorizeSender(dev, mem); err != nil {
		switch {
		case errors.Is(err, e2ee.ErrNotInLog):
			return rUnknownSender // may appear after the next log verification
		case dev.UserID == mem.UserID && dev.Approved != nil && *dev.Approved && dev.RevokedAt == nil && dev.Kind != "recovery":
			return rBadReg
		}
		return rNotMember
	}
	if b.cfg.serverMode() && !b.consents[circle][dev.UserID] {
		return rNoConsent
	}
	edPub, err := base64.StdEncoding.DecodeString(dev.Ed25519Pub)
	if err != nil {
		return rBadReg
	}
	seq, tsMs, body, err := e2ee.OpenItem(key, circle, it.DeviceID, edPub, it.Purpose, uint64(it.Seq), ct)
	switch {
	case err == nil:
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
	now := b.now()
	if tsMs > uint64(math.MaxInt64) || time.UnixMilli(int64(tsMs)).After(now.Add(maxSkew)) {
		return rClockSkew
	}
	// ---- epoch rollback (phone rules)
	if int64(seq) > ds.HighSeq && it.Epoch < ds.Epoch {
		return rRollback
	}
	seen := b.rs.Recv.EpochSeen[circle]
	if seen != nil && it.Epoch < seen.Epoch {
		backlog := int64(tsMs) < seen.AtMs
		inGrace := now.UnixMilli()-seen.AtMs < rollbackGrace.Milliseconds()
		if !backlog && !inGrace {
			return rRollback
		}
	}
	// ---- record receiver state
	if seen == nil || it.Epoch > seen.Epoch {
		b.rs.Recv.EpochSeen[circle] = &epochSeen{Epoch: it.Epoch, AtMs: now.UnixMilli()}
	}
	if int64(seq) > ds.HighSeq {
		ds.HighSeq = int64(seq)
	}
	if it.Epoch > ds.Epoch {
		ds.Epoch = it.Epoch
	}
	ds.Window = append(ds.Window, it.Seq)
	if len(ds.Window) > windowKeep {
		sort.Slice(ds.Window, func(i, j int) bool { return ds.Window[i] < ds.Window[j] })
		ds.Window = ds.Window[len(ds.Window)-windowKeep:]
	}
	b.rs.Recv.Dev[dk] = ds

	if !b.collect(circle, it.Purpose, dev.UserID, mem.Name, it.DeviceID, int64(tsMs), body) {
		return rBadBody
	}
	return rOK
}

// ---- bodies -> points

type fixBody struct {
	Lat *float64 `json:"lat"`
	Lon *float64 `json:"lon"`
	Acc *float64 `json:"acc"`
	Alt *float64 `json:"alt"`
	Spd *float64 `json:"spd"`
	Bat *float64 `json:"bat"`
}

func validCoord(lat, lon float64) bool {
	return !math.IsNaN(lat) && !math.IsNaN(lon) && !math.IsInf(lat, 0) && !math.IsInf(lon, 0) &&
		lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
}

func okNum(p *float64) *float64 {
	if p == nil || math.IsNaN(*p) || math.IsInf(*p, 0) {
		return nil
	}
	return p
}

// collect turns a verified body into points for the member's Dawarich account.
// It returns false for an unusable body. A person without a mapping is skipped
// (counted as a drop), not an error.
func (b *bridge) collect(circle, purpose, userID, memberName, device string, tsMs int64, body []byte) bool {
	tgt, mapped := b.cfg.targetFor(userID)
	if b.cfg.serverMode() {
		mapped = true
	}
	name := memberName
	if name == "" {
		name = "OpenFamily"
	}
	add := func(ts int64, lat, lon float64, acc, alt, spd, bat *float64) {
		if !mapped {
			b.rs.Stats.Dropped["unmapped_user"]++
			return
		}
		b.pending = append(b.pending, point{user: userID, circle: circle, kind: purpose, tgt: tgt, name: name, device: device, tsMs: ts, lat: lat, lon: lon,
			acc: okNum(acc), alt: okNum(alt), spd: okNum(spd), batt: okNum(bat)})
	}
	switch purpose {
	case "fix":
		var f fixBody
		if json.Unmarshal(body, &f) != nil || f.Lat == nil || f.Lon == nil || !validCoord(*f.Lat, *f.Lon) {
			return false
		}
		add(tsMs, *f.Lat, *f.Lon, f.Acc, f.Alt, f.Spd, f.Bat)
	case "history":
		var h struct {
			Pts [][]json.Number `json:"pts"`
		}
		if json.Unmarshal(body, &h) != nil {
			return false
		}
		good := 0
		for _, p := range h.Pts {
			if len(p) < 3 {
				continue
			}
			ts, e1 := p[0].Float64()
			lat, e2 := p[1].Float64()
			lon, e3 := p[2].Float64()
			if e1 != nil || e2 != nil || e3 != nil || !validCoord(lat, lon) || ts <= 0 || ts > 1e14 {
				continue
			}
			var acc *float64
			if len(p) > 3 {
				if a, err := p[3].Float64(); err == nil {
					acc = &a
				}
			}
			add(int64(ts), lat, lon, acc, nil, nil, nil)
			good++
		}
		if good == 0 && len(h.Pts) > 0 {
			return false
		}
	}
	return true
}
