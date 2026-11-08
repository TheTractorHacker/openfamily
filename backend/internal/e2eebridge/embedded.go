package e2eebridge

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// The built-in server device (docs/design/PRIVACY_PROCESSING.md section 22).
//
// The API process owns ONE device key of kind "server", created the first time it
// starts and kept in a state directory (a docker volume, files 0600, sealed with
// OPENFAMILY_DATA_KEY when that is set). It is registered like any other server
// device: a phone of a platform admin approves it (the same signature, the same
// fingerprint comparison as `enroll --kind server`). From then on the same bridge
// loop as the sidecar runs inside the API process and reads ONLY the server key
// line SK, never a circle key CK, and only members whose own signed lane is
// "server". The API trades the secure separation of the sidecar for a working
// default: the server's private key now lives next to the database.

// EmbeddedState says what the built-in device is doing, for the admin screens.
type EmbeddedState string

const (
	StateWaitingApproval EmbeddedState = "waiting_for_approval" // key exists, no phone approved it yet
	StateRunning         EmbeddedState = "running"              // approved, loop active, at least one circle reads through it
	StateIdle            EmbeddedState = "idle"                 // approved, no circle uses the server (policy off everywhere)
	StateStopped         EmbeddedState = "stopped"              // security alarm, log mismatch or revoked: needs the admin
	StateError           EmbeddedState = "error"                // state directory unreadable (wrong data key...)
)

// EmbeddedInfo is the public face of the built-in device.
type EmbeddedInfo struct {
	DeviceID     string        `json:"device_id"`
	Name         string        `json:"name"`
	Fingerprint  string        `json:"fingerprint"` // hex, 32 bytes
	Short        string        `json:"short"`       // 4 groups
	Digits       string        `json:"digits"`      // 12 groups of 5 digits
	Registered   bool          `json:"registered"`
	Revoked      bool          `json:"revoked"`
	UserID       string        `json:"user_id,omitempty"`
	State        EmbeddedState `json:"state"`
	StateDetail  string        `json:"state_detail,omitempty"`
	Sealed       bool          `json:"sealed"` // key file sealed with the data key
	LastSync     string        `json:"last_sync,omitempty"`
	PointsStored int64         `json:"points_sent"`
}

// JoinRequest is what an admin's phone needs to approve the server's key for
// ITS account: the key material and the server's binding signature for that user.
type JoinRequest struct {
	DeviceID    string `json:"device_id"`
	UserID      string `json:"user_id"`
	Ed25519Pub  string `json:"ed25519_pub"`
	X25519Pub   string `json:"x25519_pub"`
	Binding     string `json:"binding_signature"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Fingerprint string `json:"fingerprint"`
	Short       string `json:"short"`
	Digits      string `json:"digits"`
	// Code is the same string `enroll` prints, so the existing "Approve a viewer or bridge" screen accepts it too.
	Code string `json:"request_code"`
}

// EmbeddedOptions wires the device to its host process.
type EmbeddedOptions struct {
	Dir      string // state directory (/data/server-device)
	DataKey  string // OPENFAMILY_DATA_KEY: seals the key file at rest when non-empty
	BaseURL  string // loopback URL of the API itself
	Insecure bool   // BaseURL is https with the server's own (possibly self-signed) certificate
	Token    string // ingest token shared with the handlers
	// MintAccess returns a short-lived access token for userID (the account the
	// server key is registered under).
	MintAccess func(ctx context.Context, userID string) (string, error)
	// MintEvery renews the minted token before it is this old (default
	// [defaultMintEvery]; must stay below the access-token lifetime).
	MintEvery time.Duration
	Poll      time.Duration
	Log       *slog.Logger
}

// defaultMintEvery is well below the shortest sensible ACCESS_TOKEN_TTL.
const defaultMintEvery = 5 * time.Minute

// Embedded is the built-in server device.
type Embedded struct {
	opt EmbeddedOptions
	st  *store
	log *slog.Logger

	mu     sync.Mutex
	id     *identity
	state  EmbeddedState
	detail string
	pass   bool
}

// OpenEmbedded opens (creating once) the server's own device key.
func OpenEmbedded(opt EmbeddedOptions) (*Embedded, error) {
	if opt.Log == nil {
		opt.Log = slog.Default()
	}
	if opt.Poll <= 0 {
		opt.Poll = 15 * time.Second
	}
	if len(opt.Token) < 32 {
		return nil, errors.New("the ingest token must be at least 32 characters")
	}
	var pass []byte
	if opt.DataKey != "" {
		pass = []byte(opt.DataKey)
	}
	if err := os.MkdirAll(opt.Dir, 0o700); err != nil {
		return nil, err
	}
	st, err := openStore(opt.Dir, pass)
	if err != nil {
		return nil, err
	}
	e := &Embedded{opt: opt, st: st, log: opt.Log.With("component", "server-device"), state: StateWaitingApproval, pass: len(pass) > 0}
	id, err := st.loadIdentity()
	if errors.Is(err, errNotFound) {
		id, err = st.createIdentity("Orbitly server")
		if err == nil {
			id.f.Kind = "server"
			err = st.saveIdentity(id)
		}
		if err == nil {
			e.log.Info("created the server's own device key; waiting for an admin phone to approve it", "device", id.f.DeviceID[:8])
		}
	}
	if err != nil {
		e.state, e.detail = StateError, "cannot open the server device key: "+err.Error()
		return e, err
	}
	e.id = id
	e.refreshState()
	return e, nil
}

func (e *Embedded) refreshState() {
	if e.id.f.RevokedAt != "" {
		e.state, e.detail = StateStopped, "The server key was revoked. Remove /data/server-device to create a new one."
	} else if e.id.f.RegisteredAt == "" {
		e.state, e.detail = StateWaitingApproval, ""
	}
}

// Info returns the public state. Safe for concurrent use.
func (e *Embedded) Info() EmbeddedInfo {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.infoLocked()
}

func (e *Embedded) infoLocked() EmbeddedInfo {
	in := EmbeddedInfo{State: e.state, StateDetail: e.detail, Sealed: e.pass}
	if e.id == nil {
		return in
	}
	in.DeviceID, in.Name, in.Fingerprint = e.id.f.DeviceID, e.id.f.Name, e.id.f.Fingerprint
	in.Short, in.Digits = e2ee.ShortFingerprint(e.id.fp), e2ee.DigitGroups(e.id.fp)
	in.Registered, in.Revoked, in.UserID = e.id.f.RegisteredAt != "" && e.id.f.RevokedAt == "", e.id.f.RevokedAt != "", e.id.f.UserID
	if rs, err := e.st.loadRunState(); err == nil {
		in.LastSync, in.PointsStored = rs.Stats.LastSync, int64(rs.Stats.Sent)
	}
	return in
}

// JoinRequestFor builds the request for the admin userID. Anyone holding the
// server's private key can sign the binding, so only the server itself can.
func (e *Embedded) JoinRequestFor(userID string) (JoinRequest, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.id == nil {
		return JoinRequest{}, errors.New("the server device is not available")
	}
	if e2ee.CheckID(userID) != nil {
		return JoinRequest{}, errors.New("bad user id")
	}
	if e.id.f.RegisteredAt != "" {
		return JoinRequest{}, errors.New("the server key is already registered")
	}
	msg, err := e2ee.BindingMessage(userID, e.id.f.DeviceID, e.id.edPub, e.id.xPub)
	if err != nil {
		return JoinRequest{}, err
	}
	std := base64.StdEncoding.EncodeToString
	code, err := e.id.requestCode(userID)
	if err != nil {
		return JoinRequest{}, err
	}
	return JoinRequest{DeviceID: e.id.f.DeviceID, UserID: userID, Ed25519Pub: std(e.id.edPub), X25519Pub: std(e.id.xPub),
		Binding: std(ed25519.Sign(e.id.edPriv, msg)), Kind: "server", Name: e.id.f.Name,
		Fingerprint: e.id.f.Fingerprint, Short: e2ee.ShortFingerprint(e.id.fp), Digits: e2ee.DigitGroups(e.id.fp), Code: code}, nil
}

func (e *Embedded) client(userID string) *apiClient {
	c := newAPIClient(e.opt.BaseURL, "", nil)
	c.mint = func(ctx context.Context) (string, error) { return e.opt.MintAccess(ctx, userID) }
	// The API's access tokens live ACCESS_TOKEN_TTL (15 min by default). Without a
	// renewal ahead of time every poll after the expiry got a 401 first (logged as
	// "the server answered its own device with an error" every ~15 min), and only
	// the retry with a new token went through.
	c.mintMaxAge = e.opt.MintEvery
	if c.mintMaxAge <= 0 {
		c.mintMaxAge = defaultMintEvery
	}
	c.onStatus = func(method, path string, status int) {
		e.log.Warn("the server answered its own device with an error", "method", method, "path", path, "status", status)
	}
	if e.opt.Insecure {
		c.http = &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}} //nolint:gosec // loopback to ourselves only
	}
	return c
}

// Approve registers the server key as userID's device, using the approval the
// admin's phone signed (its device id and log signature, std base64). The API
// validates the signature exactly as for a sidecar.
func (e *Embedded) Approve(ctx context.Context, userID, actorDeviceID, logSignature string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.id == nil {
		return errors.New("the server device is not available")
	}
	if e.id.f.RevokedAt != "" {
		return errors.New("the server key was revoked")
	}
	if e.id.f.RegisteredAt != "" {
		return nil // idempotent
	}
	if e2ee.CheckID(userID) != nil || e2ee.CheckID(actorDeviceID) != nil {
		return errors.New("malformed approval")
	}
	if sig, err := base64.StdEncoding.DecodeString(logSignature); err != nil || len(sig) != e2ee.SigLen {
		return errors.New("the approval carries no valid signature")
	}
	e.id.f.UserID, e.id.f.Server = userID, e.opt.BaseURL
	if err := e.st.saveIdentity(e.id); err != nil {
		return err
	}
	if err := e.st.registerApproved(ctx, e.id, e.client(userID), userID, approvalCode{A: actorDeviceID, S: logSignature}); err != nil {
		e.id.f.UserID, e.id.f.Server = "", ""
		_ = e.st.saveIdentity(e.id)
		return err
	}
	e.state, e.detail = StateIdle, ""
	e.log.Info("the server key was approved by an admin phone", "device", e.id.f.DeviceID[:8], "approver", actorDeviceID[:8])
	return nil
}

func (e *Embedded) set(s EmbeddedState, detail string) {
	e.mu.Lock()
	e.state, e.detail = s, detail
	e.mu.Unlock()
}

// Run drives the bridge loop until ctx ends. It waits for the approval, then
// keeps the loop alive: a circle that turns server assistance off is not an error
// (idle), a security alarm or a log mismatch stops it until an admin looks.
func (e *Embedded) Run(ctx context.Context) {
	for ctx.Err() == nil {
		e.mu.Lock()
		ready := e.id != nil && e.id.f.RegisteredAt != "" && e.id.f.RevokedAt == ""
		e.mu.Unlock()
		if !ready {
			if sleepCtx(ctx, 3*time.Second) != nil {
				return
			}
			continue
		}
		code := e.runOnce(ctx)
		switch code {
		case exitOK:
			return
		case exitAlarm, exitLog:
			return // state already says stopped
		}
		if sleepCtx(ctx, 30*time.Second) != nil {
			return
		}
	}
}

func (e *Embedded) runOnce(ctx context.Context) int {
	e.mu.Lock()
	id := e.id
	e.mu.Unlock()
	cfg := &config{Mode: "server", Ingest: ingestCfg{URL: e.opt.BaseURL, token: e.opt.Token}, PollSeconds: int(e.opt.Poll / time.Second)}
	api := e.client(id.f.UserID)
	api.bo = defaultBackoff()
	b, err := newBridge(e.st, id, api, cfg, e.log)
	if err != nil {
		e.set(StateError, err.Error())
		e.log.Error("cannot start the server device", "err", err)
		return exitError
	}
	if ss, ok := b.sink.(*serverSink); ok {
		if e.opt.Insecure {
			ss.http = api.http
		}
		if err := ss.pin(ctx); err != nil {
			e.log.Warn("could not register the server key with the API yet", "err", err)
			return exitError
		}
	}
	e.set(StateIdle, "")
	b.quiet = true
	b.onCycle = func(active int) {
		if active > 0 {
			e.set(StateRunning, "")
		} else {
			e.set(StateIdle, "")
		}
	}
	code := b.loop(ctx, e.opt.Poll, false)
	switch code {
	case exitAlarm:
		e.set(StateStopped, "Security alarm: the server handed this key a circle key. Look at the server log.")
	case exitLog:
		e.set(StateStopped, "The key log did not verify. Look at the server log.")
	case exitRevoked:
		e.set(StateIdle, "No circle uses the server right now.")
	}
	return code
}
