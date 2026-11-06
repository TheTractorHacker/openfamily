package handlers

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheTractorHacker/openfamily/backend/internal/auth"
	"github.com/TheTractorHacker/openfamily/backend/internal/middleware"
	"github.com/TheTractorHacker/openfamily/backend/internal/sms"
	"github.com/go-chi/chi/v5"
	"github.com/go-webauthn/webauthn/protocol/webauthncbor"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	testRPID   = "family.example.com"
	testOrigin = "https://family.example.com"
)

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// virtualAuthenticator is a software authenticator (ES256, "none"
// attestation, resident key, user verified) used to exercise the ceremonies.
type virtualAuthenticator struct {
	key     *ecdsa.PrivateKey
	credID  []byte
	counter uint32
}

func newVirtualAuthenticator(t *testing.T) *virtualAuthenticator {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	id := make([]byte, 32)
	_, _ = rand.Read(id)
	return &virtualAuthenticator{key: k, credID: id}
}

func rpHash() []byte { h := sha256.Sum256([]byte(testRPID)); return h[:] }

func clientData(typ, challenge, origin string) []byte {
	b, _ := json.Marshal(map[string]any{"type": typ, "challenge": challenge, "origin": origin, "crossOrigin": false})
	return b
}

func (v *virtualAuthenticator) register(t *testing.T, challenge, origin string) []byte {
	t.Helper()
	x := v.key.PublicKey.X.FillBytes(make([]byte, 32))
	y := v.key.PublicKey.Y.FillBytes(make([]byte, 32))
	cose, err := webauthncbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
	if err != nil {
		t.Fatal(err)
	}
	var ad bytes.Buffer
	ad.Write(rpHash())
	ad.WriteByte(0x01 | 0x04 | 0x40) // UP | UV | AT
	_ = binary.Write(&ad, binary.BigEndian, uint32(0))
	ad.Write(make([]byte, 16)) // aaguid
	_ = binary.Write(&ad, binary.BigEndian, uint16(len(v.credID)))
	ad.Write(v.credID)
	ad.Write(cose)
	att, err := webauthncbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": ad.Bytes()})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{
		"id": b64(v.credID), "rawId": b64(v.credID), "type": "public-key",
		"response": map[string]any{
			"clientDataJSON":    b64(clientData("webauthn.create", challenge, origin)),
			"attestationObject": b64(att),
		},
	})
	return body
}

func (v *virtualAuthenticator) assert(t *testing.T, challenge, origin, userHandle string, counter uint32) []byte {
	t.Helper()
	var ad bytes.Buffer
	ad.Write(rpHash())
	ad.WriteByte(0x01 | 0x04)
	_ = binary.Write(&ad, binary.BigEndian, counter)
	cd := clientData("webauthn.get", challenge, origin)
	cdh := sha256.Sum256(cd)
	digest := sha256.Sum256(append(append([]byte{}, ad.Bytes()...), cdh[:]...))
	sig, err := ecdsa.SignASN1(rand.Reader, v.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{
		"id": b64(v.credID), "rawId": b64(v.credID), "type": "public-key",
		"response": map[string]any{
			"clientDataJSON":    b64(cd),
			"authenticatorData": b64(ad.Bytes()),
			"signature":         b64(sig),
			"userHandle":        b64([]byte(userHandle)),
		},
	})
	return body
}

func TestWebAuthnConfig(t *testing.T) {
	if wa, err := NewWebAuthn("", "", nil); wa != nil || err != nil {
		t.Fatalf("empty config must disable passkeys: %v %v", wa, err)
	}
	if wa, err := WebAuthnFromPublicURL("http://insecure.example.com", "", ""); wa != nil || err != nil {
		t.Fatalf("plain http must not enable passkeys: %v %v", wa, err)
	}
	wa, err := WebAuthnFromPublicURL("https://family.example.com/", "", "")
	if err != nil || wa == nil || wa.Config.RPID != "family.example.com" {
		t.Fatalf("derive from public url: %v %v", wa, err)
	}
}

func TestPasskeyEndpointsDisabledAndUnauthenticated(t *testing.T) {
	s := acctServer() // no WebAuthn, nil Pool: must answer before any DB access
	cases := []struct {
		name string
		h    http.HandlerFunc
		req  *http.Request
		want int
	}{
		{"login begin disabled", s.PasskeyLoginBegin, httptest.NewRequest("POST", "/", nil), 404},
		{"login finish disabled", s.PasskeyLoginFinish, httptest.NewRequest("POST", "/", nil), 404},
		{"register begin disabled", s.PasskeyRegisterBegin, authedReq("POST", "/", `{}`), 404},
		{"register begin unauthenticated", s.PasskeyRegisterBegin, httptest.NewRequest("POST", "/", nil), 401},
		{"register finish unauthenticated", s.PasskeyRegisterFinish, httptest.NewRequest("POST", "/", nil), 401},
		{"list unauthenticated", s.ListPasskeys, httptest.NewRequest("GET", "/", nil), 401},
		{"delete unauthenticated", s.DeletePasskey, httptest.NewRequest("DELETE", "/", nil), 401},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		c.h(rec, c.req)
		if rec.Code != c.want {
			t.Errorf("%s: status %d, want %d", c.name, rec.Code, c.want)
		}
	}
	// With passkeys on, register-begin still demands the password first.
	wa, _ := NewWebAuthn(testRPID, "", []string{testOrigin})
	s.WebAuthn = wa
	rec := httptest.NewRecorder()
	s.PasskeyRegisterBegin(rec, authedReq("POST", "/", `{}`))
	if rec.Code != 400 {
		t.Errorf("register begin without password: %d", rec.Code)
	}
}

func TestUUIDParse(t *testing.T) {
	if _, err := uuidParse("0b9c9b3e-0d4e-4a8f-9c11-2f7e3a1b5d90"); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "x", "0b9c9b3e-0d4e-4a8f-9c11-2f7e3a1b5d9g", "0b9c9b3e0d4e4a8f9c112f7e3a1b5d90xxxx"} {
		if _, err := uuidParse(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// TestPasskeyFlowPG drives register and login ceremonies with a virtual
// authenticator against a real Postgres (TEST_DATABASE_URL).
func TestPasskeyFlowPG(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{
		Pool:      pool,
		TM:        auth.NewTokenManager("test-secret-at-least-32-bytes-long!", time.Minute, time.Hour),
		AuthLimit: sms.NewLimiter(),
	}
	s.WebAuthn, err = NewWebAuthn(testRPID, "", []string{testOrigin})
	if err != nil {
		t.Fatal(err)
	}

	mkUser := func(tag string) string {
		hash, _ := auth.HashPassword("correct-horse-1")
		var uid string
		email := "pk-" + tag + time.Now().Format("150405.000000") + "@example.com"
		if err := pool.QueryRow(ctx, `INSERT INTO users (email,name,password_hash) VALUES ($1,'t',$2) RETURNING id`, email, hash).Scan(&uid); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, uid) })
		return uid
	}
	alice, bob := mkUser("a"), mkUser("b")

	call := func(h http.HandlerFunc, method, target, uid string, body []byte, urlParams map[string]string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, target, bytes.NewReader(body))
		if uid != "" {
			req = req.WithContext(middleware.ContextWithClaims(req.Context(), &auth.Claims{UserID: uid}))
		}
		if len(urlParams) > 0 {
			rc := chi.NewRouteContext()
			for k, v := range urlParams {
				rc.URLParams.Add(k, v)
			}
			req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rc))
		}
		rec := httptest.NewRecorder()
		h(rec, req)
		return rec
	}
	type beginResp struct {
		ChallengeID string `json:"challenge_id"`
		Options     struct {
			PublicKey struct {
				Challenge string `json:"challenge"`
			} `json:"publicKey"`
		} `json:"options"`
	}
	begin := func(h http.HandlerFunc, uid string, body string) beginResp {
		t.Helper()
		rec := call(h, "POST", "/", uid, []byte(body), nil)
		if rec.Code != 200 {
			t.Fatalf("begin: %d %s", rec.Code, rec.Body)
		}
		var b beginResp
		if err := json.Unmarshal(rec.Body.Bytes(), &b); err != nil || b.ChallengeID == "" || b.Options.PublicKey.Challenge == "" {
			t.Fatalf("begin body: %s", rec.Body)
		}
		return b
	}

	dev := newVirtualAuthenticator(t)

	// Wrong password cannot start enrollment.
	if rec := call(s.PasskeyRegisterBegin, "POST", "/", alice, []byte(`{"password":"nope-nope-1"}`), nil); rec.Code == 200 {
		t.Fatalf("enrollment without the password must fail: %d", rec.Code)
	}

	reg := begin(s.PasskeyRegisterBegin, alice, `{"password":"correct-horse-1"}`)

	// Another user cannot finish alice's ceremony.
	rec := call(s.PasskeyRegisterFinish, "POST", "/?challenge_id="+reg.ChallengeID, bob,
		dev.register(t, reg.Options.PublicKey.Challenge, testOrigin), nil)
	if rec.Code != 400 {
		t.Fatalf("cross-user finish: %d", rec.Code)
	}
	// ...and that attempt consumed the challenge (single use).
	reg = begin(s.PasskeyRegisterBegin, alice, `{"password":"correct-horse-1"}`)
	// A response bound to the wrong origin is rejected.
	rec = call(s.PasskeyRegisterFinish, "POST", "/?challenge_id="+reg.ChallengeID, alice,
		dev.register(t, reg.Options.PublicKey.Challenge, "https://evil.example.com"), nil)
	if rec.Code != 400 {
		t.Fatalf("wrong origin must be rejected: %d %s", rec.Code, rec.Body)
	}
	reg = begin(s.PasskeyRegisterBegin, alice, `{"password":"correct-horse-1"}`)
	rec = call(s.PasskeyRegisterFinish, "POST", "/?name=Pixel&challenge_id="+reg.ChallengeID, alice,
		dev.register(t, reg.Options.PublicKey.Challenge, testOrigin), nil)
	if rec.Code != 201 {
		t.Fatalf("register: %d %s", rec.Code, rec.Body)
	}
	var created struct{ ID string }
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	// Replaying the same challenge fails.
	rec = call(s.PasskeyRegisterFinish, "POST", "/?challenge_id="+reg.ChallengeID, alice,
		dev.register(t, reg.Options.PublicKey.Challenge, testOrigin), nil)
	if rec.Code != 400 {
		t.Fatalf("challenge replay: %d", rec.Code)
	}

	// Listing shows the passkey, and only to its owner.
	rec = call(s.ListPasskeys, "GET", "/", alice, nil, nil)
	if !strings.Contains(rec.Body.String(), "Pixel") {
		t.Fatalf("list: %s", rec.Body)
	}
	if rec = call(s.ListPasskeys, "GET", "/", bob, nil, nil); strings.Contains(rec.Body.String(), "Pixel") {
		t.Fatalf("bob sees alice's passkey: %s", rec.Body)
	}

	// Sign in (usernameless) with the passkey.
	login := begin(s.PasskeyLoginBegin, "", ``)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 1), nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "access_token") {
		t.Fatalf("login: %d %s", rec.Code, rec.Body)
	}

	// A bad signature and a replayed challenge are rejected.
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 2), nil)
	if rec.Code != 401 {
		t.Fatalf("login challenge replay: %d", rec.Code)
	}
	other := newVirtualAuthenticator(t)
	other.credID = dev.credID // same credential id, different key
	login = begin(s.PasskeyLoginBegin, "", ``)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		other.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 3), nil)
	if rec.Code != 401 {
		t.Fatalf("forged signature: %d", rec.Code)
	}
	// A claimed user handle that does not own the credential is rejected.
	login = begin(s.PasskeyLoginBegin, "", ``)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, bob, 4), nil)
	if rec.Code != 401 {
		t.Fatalf("foreign user handle: %d", rec.Code)
	}
	// A non-increasing sign counter (cloned authenticator) is refused.
	login = begin(s.PasskeyLoginBegin, "", ``)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 1), nil)
	if rec.Code != 401 {
		t.Fatalf("counter regression: %d %s", rec.Code, rec.Body)
	}

	// Bob cannot delete alice's passkey; alice can; afterwards sign-in fails.
	if rec = call(s.DeletePasskey, "DELETE", "/", bob, nil, map[string]string{"id": created.ID}); rec.Code != 404 {
		t.Fatalf("foreign delete: %d", rec.Code)
	}
	if rec = call(s.DeletePasskey, "DELETE", "/", alice, nil, map[string]string{"id": created.ID}); rec.Code != 204 {
		t.Fatalf("delete: %d", rec.Code)
	}
	login = begin(s.PasskeyLoginBegin, "", ``)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 9), nil)
	if rec.Code != 401 {
		t.Fatalf("login with removed passkey: %d", rec.Code)
	}

	// Expired challenges are refused.
	login = begin(s.PasskeyLoginBegin, "", ``)
	pool.Exec(ctx, `UPDATE passkey_challenges SET expires_at = now() - interval '1 second' WHERE id = $1`, login.ChallengeID)
	rec = call(s.PasskeyLoginFinish, "POST", "/?challenge_id="+login.ChallengeID, "",
		dev.assert(t, login.Options.PublicKey.Challenge, testOrigin, alice, 10), nil)
	if rec.Code != 401 {
		t.Fatalf("expired challenge: %d", rec.Code)
	}
}
