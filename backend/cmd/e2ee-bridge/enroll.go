package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

// requestCode is what the phone's "Approve a viewer or bridge" screen reads.
type requestCode struct {
	U string `json:"u"` // user id
	D string `json:"d"` // device id
	E string `json:"e"` // ed25519 pub (std base64)
	X string `json:"x"` // x25519 pub (std base64)
	B string `json:"b"` // binding signature (std base64)
	K string `json:"k"` // kind
	N string `json:"n"` // name, <= 40 chars
}

type approvalCode struct {
	A string `json:"a"` // approving phone device id
	S string `json:"s"` // std base64 Ed25519 signature
}

func truncRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

func (id *identity) requestCode(userID string) (string, error) {
	msg, err := e2ee.BindingMessage(userID, id.f.DeviceID, id.edPub, id.xPub)
	if err != nil {
		return "", err
	}
	std := base64.StdEncoding.EncodeToString
	b, err := json.Marshal(requestCode{U: userID, D: id.f.DeviceID, E: std(id.edPub), X: std(id.xPub),
		B: std(ed25519.Sign(id.edPriv, msg)), K: "service", N: truncRunes(id.f.Name, 40)})
	if err != nil {
		return "", err
	}
	return base64.URLEncoding.EncodeToString(b), nil
}

func parseApproval(code string) (approvalCode, error) {
	code = strings.Join(strings.Fields(code), "")
	raw, err := base64.URLEncoding.DecodeString(code)
	if err != nil {
		raw, err = base64.RawURLEncoding.DecodeString(strings.TrimRight(code, "="))
	}
	if err != nil {
		return approvalCode{}, errors.New("the approval code is not valid base64url")
	}
	var a approvalCode
	if err := json.Unmarshal(raw, &a); err != nil || e2ee.CheckID(a.A) != nil {
		return approvalCode{}, errors.New("the approval code is malformed")
	}
	if sig, err := base64.StdEncoding.DecodeString(a.S); err != nil || len(sig) != e2ee.SigLen {
		return approvalCode{}, errors.New("the approval code carries no valid signature")
	}
	return a, nil
}

// readPassword takes the OpenFamily password from the environment or one line of
// stdin (never from argv, never echoed).
func readPassword(env func(string) string, in io.Reader) (string, error) {
	if p := env("E2EE_BRIDGE_PASSWORD"); p != "" {
		return p, nil
	}
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && line == "" {
		return "", errors.New("no password: set E2EE_BRIDGE_PASSWORD or pipe it on stdin")
	}
	return strings.TrimRight(line, "\r\n"), nil
}

type enrollOpts struct {
	server, email, totp, name, approval string
	env                                 func(string) string
	stdin                               io.Reader
	out                                 io.Writer
}

// session returns a logged-in API client, using the stored refresh token when it
// still works and falling back to a fresh login when credentials were given.
func (a *app) enrollClient(ctx context.Context, o enrollOpts, id *identity) (*apiClient, string, error) {
	var sess session
	haveSess := a.st.readSecret(fileSession, &sess) == nil && sess.RefreshToken != ""
	server := strings.TrimRight(o.server, "/")
	if server == "" {
		server = sess.Server
	}
	if server == "" {
		return nil, "", errors.New("--server is required")
	}
	rotate := func(rt string) error {
		sess.Server, sess.RefreshToken = server, rt
		return a.st.writeSecret(fileSession, sess)
	}
	c := newAPIClient(server, "", rotate)
	c.bo = a.bo
	if haveSess && sess.Server == server && o.email == "" {
		c.refresh = sess.RefreshToken
		if err := c.refreshAccess(ctx, ""); err != nil {
			return nil, "", fmt.Errorf("%w (pass --email to log in again)", err)
		}
	} else {
		if o.email == "" {
			return nil, "", errors.New("--email is required to log in to OpenFamily")
		}
		pw, err := readPassword(o.env, o.stdin)
		if err != nil {
			return nil, "", err
		}
		if err := c.login(ctx, o.email, pw, o.totp); err != nil {
			return nil, "", err
		}
	}
	if sess.UserID == "" || sess.Server != server {
		var me struct {
			ID string `json:"id"`
		}
		if err := c.do(ctx, http.MethodGet, "/me", nil, &me); err != nil {
			return nil, "", err
		}
		sess.UserID = me.ID
		if err := rotate(c.refresh); err != nil {
			return nil, "", err
		}
	}
	if e2ee.CheckID(sess.UserID) != nil {
		return nil, "", errors.New("the server returned no usable user id")
	}
	return c, sess.UserID, nil
}

func printIdentity(out io.Writer, id *identity) {
	fmt.Fprintf(out, "Name:         %s\n", id.f.Name)
	fmt.Fprintf(out, "Device id:    %s\n", id.f.DeviceID)
	fmt.Fprintf(out, "Fingerprint:  %s\n", e2ee.ShortFingerprint(id.fp))
	fmt.Fprintf(out, "Digits:       %s\n", e2ee.DigitGroups(id.fp))
}

func (a *app) cmdEnroll(ctx context.Context, o enrollOpts) error {
	id, err := a.st.loadIdentity()
	if errors.Is(err, errNotFound) {
		name := o.name
		if name == "" {
			name = "Dawarich bridge"
		}
		id, err = a.st.createIdentity(truncRunes(name, 40))
	}
	if err != nil {
		return err
	}
	if id.f.RevokedAt != "" {
		return errors.New("this bridge key was revoked; use a new --state-dir to enroll a new one")
	}
	c, userID, err := a.enrollClient(ctx, o, id)
	if err != nil {
		return err
	}
	if id.f.UserID == "" || id.f.UserID != userID {
		if id.f.RegisteredAt != "" {
			return errors.New("this bridge is registered for another account; use a new --state-dir")
		}
		id.f.UserID = userID
		id.f.Server = c.base
		if err := a.st.saveIdentity(id); err != nil {
			return err
		}
	}
	if o.approval == "" {
		if id.f.RegisteredAt != "" {
			fmt.Fprintln(o.out, "This bridge is already registered. Nothing to do; run `e2ee-bridge status`.")
			return nil
		}
		code, err := id.requestCode(userID)
		if err != nil {
			return err
		}
		printIdentity(o.out, id)
		fmt.Fprintf(o.out, "\nREQUEST CODE (paste into the phone: Encryption keys > Approve a viewer or bridge):\n\n%s\n\n", code)
		fmt.Fprintln(o.out, "Compare the 12x5 digits on the phone with the digits above. Then run:")
		fmt.Fprintln(o.out, "  e2ee-bridge enroll --approval <APPROVAL CODE shown on the phone>")
		return nil
	}
	ap, err := parseApproval(o.approval)
	if err != nil {
		return err
	}
	sig, _ := base64.StdEncoding.DecodeString(ap.S)
	std := base64.StdEncoding.EncodeToString
	bind, err := e2ee.BindingMessage(userID, id.f.DeviceID, id.edPub, id.xPub)
	if err != nil {
		return err
	}
	req := map[string]any{
		"device_id": id.f.DeviceID, "kind": "service", "ed25519_pub": std(id.edPub), "x25519_pub": std(id.xPub),
		"signature": std(ed25519.Sign(id.edPriv, bind)), "label": truncRunes(id.f.Name, 60),
		"actor_device_id": ap.A, "log_signature": std(sig), "reset": false, "can_upload": false,
	}
	var rec e2ee.DeviceRecord
	if err := c.do(ctx, http.MethodPost, "/e2ee/devices", req, &rec); err != nil {
		var ae *apiError
		if errors.As(err, &ae) && ae.Status == http.StatusBadRequest {
			return fmt.Errorf("%w\nThe approval code does not match this request (wrong phone, wrong request code, or the code was made for another bridge).", err)
		}
		return err
	}
	if rec.DeviceID != id.f.DeviceID || rec.Fingerprint != fmt.Sprintf("%x", id.fp) || !e2ee.VerifyRegistration(rec) {
		return errors.New("the server's record of this bridge does not match its keys; not trusting it")
	}
	// Pin the approving phone's key: it is bound to the signature the user carried here.
	anchor, err := e2ee.PinApprover(rec, id.f.DeviceID, ap.A, sig)
	if err != nil {
		return err
	}
	id.f.ApproverEdPub = anchor.EdPub
	id.f.RegisteredAt = time.Now().UTC().Format(time.RFC3339)
	id.f.ApprovedBy = ap.A
	if err := a.st.saveIdentity(id); err != nil {
		return err
	}
	fmt.Fprintln(o.out, "Registered. The bridge key is now a `service` member key of your account.")
	fmt.Fprintln(o.out, "Next: open the circle's encryption screen on your phone so it wraps the circle keys")
	fmt.Fprintln(o.out, "to this bridge. Then run `e2ee-bridge run --config <file>`.")
	return nil
}

// cmdRevoke revokes the bridge's own key. The log action must be signed by an
// ACTIVE key of the same user; the bridge itself is one.
func (a *app) cmdRevoke(ctx context.Context, o enrollOpts) error {
	id, err := a.st.loadIdentity()
	if err != nil {
		return err
	}
	if id.f.RegisteredAt == "" {
		return errors.New("this bridge was never registered")
	}
	if id.f.RevokedAt != "" {
		fmt.Fprintln(o.out, "Already revoked.")
		return nil
	}
	c, userID, err := a.enrollClient(ctx, o, id)
	if err != nil {
		return err
	}
	msg, err := e2ee.LogActionMessage(e2ee.ActRevoke, userID, id.f.DeviceID, "", id.f.DeviceID, 0, id.fp)
	if err != nil {
		return err
	}
	body := map[string]string{"actor_device_id": id.f.DeviceID,
		"log_signature": base64.StdEncoding.EncodeToString(ed25519.Sign(id.edPriv, msg))}
	if err := c.do(ctx, http.MethodDelete, "/e2ee/devices/"+id.f.DeviceID, body, nil); err != nil {
		var ae *apiError
		if errors.As(err, &ae) && ae.Status == http.StatusNotFound {
			fmt.Fprintln(o.out, "The server has no active key with this id (already revoked elsewhere).")
		} else {
			return err
		}
	}
	id.f.RevokedAt = time.Now().UTC().Format(time.RFC3339)
	if err := a.st.saveIdentity(id); err != nil {
		return err
	}
	a.st.remove(fileKeys)
	a.st.remove(fileSession)
	fmt.Fprintln(o.out, "Revoked. The server deleted this key's wraps and flagged the circle for a new key epoch")
	fmt.Fprintln(o.out, "(an admin phone rotates it). Local circle keys and the login session were deleted.")
	return nil
}
