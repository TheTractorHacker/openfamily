package e2ee

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// The consent message is a frozen wire format shared with the phone (Dart). The
// vector is deterministic (Ed25519 is), so both sides check the same bytes.
const consentVectorPath = "testdata/server_consent.json"

type consentVector struct {
	Note        string `json:"note"`
	SeedHex     string `json:"approver_seed_hex"`
	PubHex      string `json:"approver_ed25519_pub_hex"`
	CircleID    string `json:"circle_id"`
	UserID      string `json:"user_id"`
	ServerDev   string `json:"server_device_id"`
	FingerHex   string `json:"server_fingerprint_hex"`
	MessageHex  string `json:"message_hex"`
	SignatureHx string `json:"signature_hex"`
}

func buildConsentVector(t *testing.T) consentVector {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	fp := make([]byte, 32)
	for i := range fp {
		fp[i] = byte(0xa0 + i)
	}
	v := consentVector{
		Note:      "Server consent (trusted-server mode). message = OFE2EE1-SERVERCONSENT\\0 || circle || user || server device || fingerprint; signature = Ed25519 over message.",
		SeedHex:   hex.EncodeToString(seed),
		PubHex:    hex.EncodeToString(priv.Public().(ed25519.PublicKey)),
		CircleID:  "11111111-1111-4111-8111-111111111111",
		UserID:    "22222222-2222-4222-8222-222222222222",
		ServerDev: "33333333-3333-4333-8333-333333333333",
		FingerHex: hex.EncodeToString(fp),
	}
	msg, err := ServerConsentMessage(v.CircleID, v.UserID, v.ServerDev, fp)
	if err != nil {
		t.Fatal(err)
	}
	v.MessageHex = hex.EncodeToString(msg)
	v.SignatureHx = hex.EncodeToString(ed25519.Sign(priv, msg))
	return v
}

func TestServerConsentVector(t *testing.T) {
	v := buildConsentVector(t)
	if os.Getenv("UPDATE_VECTORS") == "1" {
		b, _ := json.MarshalIndent(v, "", "  ")
		if err := os.WriteFile(consentVectorPath, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(consentVectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var got consentVector
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got != v {
		t.Fatal("server consent vector changed; the wire format is frozen")
	}
}

func TestServerConsentBindsEverything(t *testing.T) {
	v := buildConsentVector(t)
	pub, _ := hex.DecodeString(v.PubHex)
	fp, _ := hex.DecodeString(v.FingerHex)
	sig, _ := hex.DecodeString(v.SignatureHx)
	if err := VerifyServerConsent(pub, v.CircleID, v.UserID, v.ServerDev, fp, sig); err != nil {
		t.Fatal(err)
	}
	other := strings.Repeat("4", 8) + "-4444-4444-8444-444444444444"
	for name, f := range map[string]func() error{
		"circle":      func() error { return VerifyServerConsent(pub, other, v.UserID, v.ServerDev, fp, sig) },
		"user":        func() error { return VerifyServerConsent(pub, v.CircleID, other, v.ServerDev, fp, sig) },
		"server":      func() error { return VerifyServerConsent(pub, v.CircleID, v.UserID, other, fp, sig) },
		"fingerprint": func() error { return VerifyServerConsent(pub, v.CircleID, v.UserID, v.ServerDev, make([]byte, 32), sig) },
		"short sig":   func() error { return VerifyServerConsent(pub, v.CircleID, v.UserID, v.ServerDev, fp, sig[:10]) },
		"bad id":      func() error { return VerifyServerConsent(pub, "x", v.UserID, v.ServerDev, fp, sig) },
	} {
		if f() == nil {
			t.Errorf("consent verified although the %s differs", name)
		}
	}
}
