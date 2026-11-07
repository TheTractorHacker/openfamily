package e2eebridge

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// ------------------------------------------------------------------ identity

// identityFile keeps the public facts in clear (so `status` works without the
// passphrase) and the seed in a (possibly sealed) box.
type identityFile struct {
	V        int    `json:"v"`
	DeviceID string `json:"device_id"`
	UserID   string `json:"user_id,omitempty"`
	Name     string `json:"name"`
	// Kind is "service" (Dawarich bridge, default) or "server" (the OpenFamily
	// server's own device, docs/design/E2EE.md "Trusted-server mode").
	Kind         string `json:"kind,omitempty"`
	Server       string `json:"server,omitempty"`
	Ed25519Pub   string `json:"ed25519_pub"`
	X25519Pub    string `json:"x25519_pub"`
	Fingerprint  string `json:"fingerprint"`
	CreatedAt    string `json:"created_at"`
	RegisteredAt string `json:"registered_at,omitempty"`
	ApprovedBy   string `json:"approved_by_device,omitempty"`
	// ApproverEdPub is the approving phone's key, pinned from the approval signature the
	// user carried (e2ee.PinApprover). It is the root of trust for our own account.
	ApproverEdPub string `json:"approver_ed25519_pub,omitempty"`
	RevokedAt     string `json:"revoked_at,omitempty"`
	Secret        box    `json:"secret"`
}

type identitySecret struct {
	Seed string `json:"seed"` // base64 of the 32-byte identity seed
}

// identity is the unlocked device identity.
type identity struct {
	f       identityFile
	edPriv  ed25519.PrivateKey
	edPub   []byte
	xSecret []byte
	xPub    []byte
	fp      []byte
}

func newUUIDv4() string {
	var b [16]byte
	if _, err := io.ReadFull(rand.Reader, b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

func deriveIdentity(seed []byte) (*identity, error) {
	edSeed, xSecret, err := e2ee.DeriveIdentity(seed)
	if err != nil {
		return nil, err
	}
	priv := ed25519.NewKeyFromSeed(edSeed)
	xk, err := ecdh.X25519().NewPrivateKey(xSecret)
	if err != nil {
		return nil, err
	}
	id := &identity{edPriv: priv, edPub: priv.Public().(ed25519.PublicKey), xSecret: xSecret, xPub: xk.PublicKey().Bytes()}
	id.fp, err = e2ee.Fingerprint(id.edPub, id.xPub)
	return id, err
}

func (s *store) createIdentity(name string) (*identity, error) {
	seed := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, seed); err != nil {
		return nil, err
	}
	id, err := deriveIdentity(seed)
	if err != nil {
		return nil, err
	}
	sec, err := json.Marshal(identitySecret{Seed: base64.StdEncoding.EncodeToString(seed)})
	if err != nil {
		return nil, err
	}
	b, err := s.seal(fileIdentity, sec)
	if err != nil {
		return nil, err
	}
	std := base64.StdEncoding.EncodeToString
	id.f = identityFile{V: 1, DeviceID: newUUIDv4(), Name: name, Ed25519Pub: std(id.edPub), X25519Pub: std(id.xPub),
		Fingerprint: hex.EncodeToString(id.fp), CreatedAt: time.Now().UTC().Format(time.RFC3339), Secret: b}
	return id, s.saveIdentity(id)
}

func (s *store) saveIdentity(id *identity) error { return s.writeJSON(fileIdentity, id.f) }

// publicIdentity reads only the clear fields (no passphrase needed).
func (s *store) publicIdentity() (*identityFile, error) {
	var f identityFile
	if err := s.readJSON(fileIdentity, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

// loadIdentity unlocks the identity. If a passphrase is configured and the file
// is still plain it is re-saved sealed.
func (s *store) loadIdentity() (*identity, error) {
	f, err := s.publicIdentity()
	if err != nil {
		return nil, err
	}
	pt, err := s.open(fileIdentity, f.Secret)
	if err != nil {
		return nil, err
	}
	var sec identitySecret
	if err := json.Unmarshal(pt, &sec); err != nil {
		return nil, errBadPass
	}
	seed, err := base64.StdEncoding.DecodeString(sec.Seed)
	if err != nil {
		return nil, errBadPass
	}
	id, err := deriveIdentity(seed)
	if err != nil {
		return nil, err
	}
	if hex.EncodeToString(id.fp) != f.Fingerprint {
		return nil, errors.New("identity file is inconsistent (fingerprint does not match the seed)")
	}
	id.f = *f
	if f.Secret.Sealed == nil && len(s.pass) > 0 {
		if b, err := s.seal(fileIdentity, pt); err == nil {
			id.f.Secret = b
			_ = s.saveIdentity(id)
		}
	}
	return id, nil
}

// ------------------------------------------------------------------- circle keys

type circleKeys struct {
	s *store
	m map[string]map[string]string // circle -> epoch -> base64 key
}

func (s *store) loadCircleKeys() (*circleKeys, error) {
	k := &circleKeys{s: s, m: map[string]map[string]string{}}
	err := s.readSecret(fileKeys, &k.m)
	if errors.Is(err, errNotFound) {
		return k, nil
	}
	if k.m == nil {
		k.m = map[string]map[string]string{}
	}
	return k, err
}

func (k *circleKeys) get(circle string, epoch int) []byte {
	b, err := base64.StdEncoding.DecodeString(k.m[circle][strconv.Itoa(epoch)])
	if err != nil || len(b) != e2ee.KeyLen {
		return nil
	}
	return b
}

func (k *circleKeys) put(circle string, epoch int, key []byte) error {
	if k.m[circle] == nil {
		k.m[circle] = map[string]string{}
	}
	k.m[circle][strconv.Itoa(epoch)] = base64.StdEncoding.EncodeToString(key)
	return k.s.writeSecret(fileKeys, k.m)
}

func (k *circleKeys) epochs(circle string) []int {
	var out []int
	for e := range k.m[circle] {
		if n, err := strconv.Atoi(e); err == nil {
			out = append(out, n)
		}
	}
	return out
}

// ------------------------------------------------------------------- session

// session holds the long-lived credential: the rotating refresh token.
type session struct {
	Server       string `json:"server"`
	RefreshToken string `json:"refresh_token"`
	UserID       string `json:"user_id"`
}

// ------------------------------------------------------------------- run state

type epochSeen struct {
	Epoch int   `json:"epoch"`
	AtMs  int64 `json:"at_ms"`
}

// devState is the receiver state per (circle, sender device), as the phone's
// ChannelReceiver keeps it.
type devState struct {
	HighSeq int64   `json:"hw"`
	Epoch   int     `json:"epoch"`
	Window  []int64 `json:"win"` // newest 512 seqs seen
}

// recvState is rolled back when a page fails, so a half-processed page is
// re-processed (never lost).
type recvState struct {
	Cursor    map[string]int64      `json:"cursor"`
	Dev       map[string]*devState  `json:"dev"`
	EpochSeen map[string]*epochSeen `json:"epoch_seen"`
	Deferred  map[string]int64      `json:"deferred"` // "circle/dev/seq" -> first deferred (ms)
	// SKGuard is the per-line (server line) rollback state per circle (lanes).
	SKGuard map[string]*e2ee.RollbackState `json:"sk_guard,omitempty"`
}

// sentState survives a rollback: points already delivered must never be
// delivered again (the high-water mark per sender device).
type sentState struct {
	LastTsMs map[string]int64 `json:"last_ts_ms"` // "circle/dev" -> newest delivered point
}

type stats struct {
	Sent     int64            `json:"points_sent"`
	Accepted int64            `json:"items_accepted"`
	Rejected map[string]int64 `json:"items_rejected"`
	Dropped  map[string]int64 `json:"points_dropped"`
	LastSync string           `json:"last_sync,omitempty"`
}

type runState struct {
	V       int       `json:"v"`
	LogSeq  int64     `json:"log_pinned_seq"`
	LogHash string    `json:"log_pinned_hash"`
	Recv    recvState `json:"recv"`
	Sent    sentState `json:"sent"`
	Stats   stats     `json:"stats"`
}

func newRunState() *runState {
	rs := &runState{V: 1}
	rs.normalize()
	return rs
}

func (rs *runState) normalize() {
	if rs.Recv.Cursor == nil {
		rs.Recv.Cursor = map[string]int64{}
	}
	if rs.Recv.Dev == nil {
		rs.Recv.Dev = map[string]*devState{}
	}
	if rs.Recv.EpochSeen == nil {
		rs.Recv.EpochSeen = map[string]*epochSeen{}
	}
	if rs.Recv.Deferred == nil {
		rs.Recv.Deferred = map[string]int64{}
	}
	if rs.Recv.SKGuard == nil {
		rs.Recv.SKGuard = map[string]*e2ee.RollbackState{}
	}
	if rs.Sent.LastTsMs == nil {
		rs.Sent.LastTsMs = map[string]int64{}
	}
	if rs.Stats.Rejected == nil {
		rs.Stats.Rejected = map[string]int64{}
	}
	if rs.Stats.Dropped == nil {
		rs.Stats.Dropped = map[string]int64{}
	}
}

func (s *store) loadRunState() (*runState, error) {
	rs := newRunState()
	err := s.readJSON(fileState, rs)
	if errors.Is(err, errNotFound) {
		return newRunState(), nil
	}
	if err != nil {
		return nil, fmt.Errorf("state.json: %w", err)
	}
	rs.normalize()
	return rs, nil
}

func (s *store) saveRunState(rs *runState) error { return s.writeJSON(fileState, rs) }

func (rs *runState) cloneRecv() recvState {
	b, _ := json.Marshal(rs.Recv)
	var out recvState
	_ = json.Unmarshal(b, &out)
	tmp := &runState{Recv: out}
	tmp.normalize()
	return tmp.Recv
}

func hexBytes(s string) ([]byte, error) { return hex.DecodeString(s) }
