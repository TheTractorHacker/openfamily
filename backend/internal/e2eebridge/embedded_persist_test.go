package e2eebridge

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheTractorHacker/openfamily/backend/internal/e2ee"
)

const persistToken = "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-xx"

func openPersist(t *testing.T, dir, dataKey string) (*Embedded, error) {
	t.Helper()
	return OpenEmbedded(EmbeddedOptions{Dir: dir, DataKey: dataKey, BaseURL: "http://127.0.0.1:1", Token: persistToken, Log: slog.Default(),
		MintAccess: func(context.Context, string) (string, error) { return "x", nil }})
}

// The server's identity is created ONCE. Opening the device again on the same directory (a restart,
// a recreated container, a rebuilt image on the same volume) keeps the same key.
func TestEmbeddedKeyIsCreatedOnceAndKeptOnReopen(t *testing.T) {
	for _, dataKey := range []string{"", "a-data-key-of-some-length-0123456789"} {
		dir := t.TempDir()
		first, err := openPersist(t, dir, dataKey)
		if err != nil {
			t.Fatal(err)
		}
		a := first.Info()
		if a.DeviceID == "" || a.Fingerprint == "" {
			t.Fatalf("no identity: %+v", a)
		}
		// Registered and approved by a phone: the facts a restart must keep.
		first.id.f.UserID, first.id.f.RegisteredAt = "75e5320a-7604-4b93-832b-e641eb025ca5", "2026-11-07T22:14:20Z"
		first.id.f.ApprovedBy, first.id.f.ApproverEdPub = "11111111-1111-4111-8111-111111111111", "AAAA"
		if err := first.st.saveIdentity(first.id); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 3; i++ {
			again, err := openPersist(t, dir, dataKey)
			if err != nil {
				t.Fatal(err)
			}
			b := again.Info()
			if b.DeviceID != a.DeviceID || b.Fingerprint != a.Fingerprint || !b.Registered {
				t.Fatalf("data key set=%v: the server key changed on reopen: %+v -> %+v", dataKey != "", a, b)
			}
			if again.id.f.ApprovedBy != first.id.f.ApprovedBy {
				t.Fatal("the approving phone was lost on reopen")
			}
		}
		if m, _ := filepath.Glob(filepath.Join(dir, "archive", "*")); len(m) != 0 {
			t.Fatalf("a reopen archived or replaced a key: %v", m)
		}
	}
}

// An identity that cannot be read (wrong data key, damaged file) is an ERROR that leaves the file alone;
// it must never be answered with a freshly generated key.
func TestEmbeddedUnreadableIdentityIsNeverRegenerated(t *testing.T) {
	dir := t.TempDir()
	first, err := openPersist(t, dir, "a-data-key-of-some-length-0123456789")
	if err != nil {
		t.Fatal(err)
	}
	id := first.Info().DeviceID
	path := filepath.Join(dir, fileIdentity)
	before, _ := os.ReadFile(path)

	if e, err := openPersist(t, dir, "another-data-key-of-some-length-0123456"); err == nil {
		t.Fatalf("opened with the wrong data key: %+v", e.Info())
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Fatal("a failed open changed the identity file")
	}

	dir2 := t.TempDir()
	if _, err := openPersist(t, dir2, ""); err != nil {
		t.Fatal(err)
	}
	p2 := filepath.Join(dir2, fileIdentity)
	if err := os.WriteFile(p2, []byte(`{"v":1,"device_id":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := openPersist(t, dir2, ""); err == nil {
		t.Fatal("a damaged identity file was replaced by a new key")
	}
	if b, _ := os.ReadFile(p2); string(b) != `{"v":1,"device_id":` {
		t.Fatal("a damaged identity file was overwritten")
	}
	if again, err := openPersist(t, dir, "a-data-key-of-some-length-0123456789"); err != nil || again.Info().DeviceID != id {
		t.Fatalf("the right key no longer opens the identity: %v", err)
	}
}

func attachFixture(t *testing.T) (e *Embedded, dir string, userID string) {
	t.Helper()
	dir = t.TempDir()
	e, err := openPersist(t, dir, "")
	if err != nil {
		t.Fatal(err)
	}
	userID = "75e5320a-7604-4b93-832b-e641eb025ca5"
	e.id.f.UserID, e.id.f.RegisteredAt = userID, "2026-11-07T22:14:20Z"
	e.id.f.ApprovedBy, e.id.f.ApproverEdPub = "11111111-1111-4111-8111-111111111111", "b2xkLXBob25l"
	if err := e.st.saveIdentity(e.id); err != nil {
		t.Fatal(err)
	}
	return e, dir, userID
}

func newPhone(t *testing.T) (id string, pub ed25519.PublicKey, priv ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return "62a703aa-0000-4000-8000-000000000001", pub, priv
}

// An owner key reset that KEEPS the server key: the same keypair, the same circle keys, only the anchor
// moves to the new phone, and only on a statement that verifies over this device's own user, id and fingerprint.
func TestReattachKeepsTheKeyAndMovesOnlyTheAnchor(t *testing.T) {
	e, dir, uid := attachFixture(t)
	keysPath := filepath.Join(dir, fileKeys)
	if err := os.WriteFile(keysPath, []byte(`{"circle":{"1":"c2VjcmV0"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	before := e.Info()
	idBefore, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	var fb identityFile
	_ = json.Unmarshal(idBefore, &fb)

	phoneID, pub, priv := newPhone(t)
	sign := func(user, actor, subject string, fp []byte) []byte {
		m, err := e2ee.LogActionMessage(e2ee.ActServerAttach, user, actor, "", subject, 0, fp)
		if err != nil {
			t.Fatal(err)
		}
		return ed25519.Sign(priv, m)
	}
	// Negative: wrong user, wrong subject, wrong fingerprint, wrong action, short input, wrong signer: nothing moves.
	other := "00000000-0000-4000-8000-0000000000aa"
	badFP := bytes.Repeat([]byte{1}, 32)
	revokeMsg, _ := e2ee.LogActionMessage(e2ee.ActRevoke, uid, phoneID, "", e.id.f.DeviceID, 0, e.id.fp)
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	attachMsg, _ := e2ee.LogActionMessage(e2ee.ActServerAttach, uid, phoneID, "", e.id.f.DeviceID, 0, e.id.fp)
	bad := map[string]error{
		"wrong user":        e.Reattach(phoneID, pub, sign(other, phoneID, e.id.f.DeviceID, e.id.fp)),
		"wrong subject":     e.Reattach(phoneID, pub, sign(uid, phoneID, other, e.id.fp)),
		"wrong fingerprint": e.Reattach(phoneID, pub, sign(uid, phoneID, e.id.f.DeviceID, badFP)),
		"wrong action":      e.Reattach(phoneID, pub, ed25519.Sign(priv, revokeMsg)),
		"wrong signer":      e.Reattach(phoneID, pub, ed25519.Sign(otherPriv, attachMsg)),
		"other actor id":    e.Reattach(other, pub, sign(uid, phoneID, e.id.f.DeviceID, e.id.fp)),
		"short signature":   e.Reattach(phoneID, pub, []byte{1, 2, 3}),
		"short key":         e.Reattach(phoneID, pub[:5], sign(uid, phoneID, e.id.f.DeviceID, e.id.fp)),
		"bad actor id":      e.Reattach("nope", pub, sign(uid, phoneID, e.id.f.DeviceID, e.id.fp)),
	}
	for name, err := range bad {
		if err == nil {
			t.Errorf("%s: the attach was accepted", name)
		}
	}
	if e.id.f.ApprovedBy != "11111111-1111-4111-8111-111111111111" {
		t.Fatal("a refused attach moved the anchor")
	}

	if err := e.Reattach(phoneID, pub, sign(uid, phoneID, e.id.f.DeviceID, e.id.fp)); err != nil {
		t.Fatal(err)
	}
	after := e.Info()
	if after.DeviceID != before.DeviceID || after.Fingerprint != before.Fingerprint || !after.Registered {
		t.Fatalf("the server key changed: %+v -> %+v", before, after)
	}
	if e.id.f.ApprovedBy != phoneID || e.id.f.ApproverEdPub == "" {
		t.Fatalf("the anchor did not move: %+v", e.id.f)
	}
	// Persisted: a restart sees the new anchor and the same key; the circle keys are untouched; the seed box too.
	re, err := openPersist(t, dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if re.Info().DeviceID != before.DeviceID || re.id.f.ApprovedBy != phoneID {
		t.Fatalf("a restart lost the attach: %+v", re.id.f)
	}
	if b, _ := os.ReadFile(keysPath); string(b) != `{"circle":{"1":"c2VjcmV0"}}` {
		t.Fatal("the circle keys changed")
	}
	idAfter, _ := os.ReadFile(filepath.Join(dir, fileIdentity))
	var fa identityFile
	_ = json.Unmarshal(idAfter, &fa)
	sa, _ := json.Marshal(fa.Secret)
	sb, _ := json.Marshal(fb.Secret)
	if !bytes.Equal(sa, sb) || fa.Ed25519Pub != fb.Ed25519Pub {
		t.Fatal("the secret box or the public key changed")
	}
	if m, _ := filepath.Glob(filepath.Join(dir, "archive", "*")); len(m) != 0 {
		t.Fatalf("an attach archived a key: %v", m)
	}
	// Nothing secret in the public face.
	pubJSON, _ := json.Marshal(after)
	if strings.Contains(string(pubJSON), "seed") || strings.Contains(string(pubJSON), "secret") {
		t.Fatalf("secret material in the public info: %s", pubJSON)
	}
}

// A device that is not registered (or was revoked) cannot be attached.
func TestReattachNeedsARegisteredKey(t *testing.T) {
	e, err := openPersist(t, t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	phoneID, pub, priv := newPhone(t)
	m, _ := e2ee.LogActionMessage(e2ee.ActServerAttach, "75e5320a-7604-4b93-832b-e641eb025ca5", phoneID, "", e.id.f.DeviceID, 0, e.id.fp)
	if err := e.Reattach(phoneID, pub, ed25519.Sign(priv, m)); err == nil {
		t.Fatal("an unregistered key was attached")
	}
	e.id.f.UserID, e.id.f.RegisteredAt, e.id.f.RevokedAt = "75e5320a-7604-4b93-832b-e641eb025ca5", "2026-11-07T22:14:20Z", "2026-11-10T03:09:43Z"
	if err := e.Reattach(phoneID, pub, ed25519.Sign(priv, m)); err == nil {
		t.Fatal("a revoked key was attached")
	}
}
