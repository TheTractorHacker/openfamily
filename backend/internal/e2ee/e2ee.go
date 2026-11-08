// Package e2ee holds the server-side half of Orbitly's end-to-end
// encryption foundation (docs/design/E2EE.md).
//
// The server NEVER holds private keys or circle keys. It uses this package to
//
//   - validate and fingerprint the PUBLIC keys a phone registers,
//   - verify the self-signature that binds a device's Ed25519 and X25519 keys
//     to one user account,
//   - verify the signature on a wrapped circle key (it cannot read the key),
//   - and, in tests only, to produce and check the cross-language vectors that
//     the Dart client must reproduce byte for byte.
//
// Wire formats are fixed by the constants and domain-separation strings below;
// changing any of them is a breaking change and needs a new version byte.
package e2ee

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const (
	PubLen   = 32 // Ed25519 and X25519 public keys
	SigLen   = 64 // Ed25519 signature
	KeyLen   = 32 // circle key (XChaCha20-Poly1305)
	NonceLen = chacha20poly1305.NonceSizeX
	TagLen   = chacha20poly1305.Overhead

	// WrapVersion is the first byte of a wrapped-key blob.
	WrapVersion = 1
	// WrapBlobLen = version(1) || ephemeral X25519 public key(32) || nonce(24) ||
	// ciphertext(32) || tag(16).
	WrapBlobLen = 1 + PubLen + NonceLen + KeyLen + TagLen

	// MsgVersion is the first byte of an encrypted circle payload.
	MsgVersion = 1

	// UUIDLen is the length of a canonical lower-case textual UUID.
	UUIDLen = 36
)

// Domain separation strings. Each ends in a NUL so a prefix of one can never be
// parsed as another, and every signed/hashed message has fixed-length fields.
const (
	domFingerprint  = "OFE2EE1-FP\x00"
	domDigits       = "OFE2EE1-DIGITS\x00"
	domSafety       = "OFE2EE1-SAFETY\x00"
	domBind         = "OFE2EE1-BIND\x00"
	domServerCons   = "OFE2EE1-SERVERCONSENT\x00"
	domLogAct       = "OFE2EE1-LOGACT\x00"
	domLog          = "OFE2EE1-LOG\x00"
	domCommit       = "OFE2EE1-KEY-COMMIT\x00"
	domWrapKey      = "OFE2EE1-WRAP-KEY\x00"
	domWrapAAD      = "OFE2EE1-WRAP-AAD\x00"
	domWrapSig      = "OFE2EE1-WRAP-SIG\x00"
	domMsgKey       = "OFE2EE1-MSG-KEY\x00"
	domMsgAAD       = "OFE2EE1-MSG-AAD\x00"
	domUserDigest   = "OFE2EE1-USER\x00"
	domOwnerApprove = "OFE2EE4-OWNER-APPROVAL\x00"
	digitGroups     = 12
	digitsPerGroup  = 5
	fingerprintSize = sha256.Size
)

var (
	ErrKeyLength   = errors.New("e2ee: public key must be 32 bytes")
	ErrWeakKey     = errors.New("e2ee: weak or malformed public key")
	ErrBadID       = errors.New("e2ee: identifier must be a canonical lower-case UUID")
	ErrBadSig      = errors.New("e2ee: signature does not verify")
	ErrBadBlob     = errors.New("e2ee: malformed wrapped key")
	ErrDecrypt     = errors.New("e2ee: decryption failed")
	ErrBadEpoch    = errors.New("e2ee: epoch out of range")
	ErrBadPurpose  = errors.New("e2ee: purpose must be 1..64 bytes")
	ErrShortCipher = errors.New("e2ee: ciphertext too short")
)

// CheckID requires a canonical lower-case textual UUID (36 bytes). Identifiers
// enter signed messages as ASCII, so there is exactly one encoding of each.
func CheckID(id string) error {
	if len(id) != UUIDLen {
		return ErrBadID
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return ErrBadID
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return ErrBadID
			}
		}
	}
	return nil
}

// smallOrderEd lists the canonical encodings of the small-order Ed25519 points
// (and the all-zero string). A key equal to one of them verifies forged
// signatures for any message, so registration refuses them.
var smallOrderEd = mustHexList(
	"0000000000000000000000000000000000000000000000000000000000000000",
	"0100000000000000000000000000000000000000000000000000000000000000",
	"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	"0000000000000000000000000000000000000000000000000000000000000080",
	"0100000000000000000000000000000000000000000000000000000000000080",
	"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
	"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
	"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
	"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
)

func mustHexList(in ...string) [][]byte {
	out := make([][]byte, len(in))
	for i, h := range in {
		b, err := hex.DecodeString(h)
		if err != nil {
			panic(err)
		}
		out[i] = b
	}
	return out
}

// ValidateEd25519Pub rejects wrong-length and small-order keys.
func ValidateEd25519Pub(pub []byte) error {
	if len(pub) != PubLen {
		return ErrKeyLength
	}
	for _, w := range smallOrderEd {
		if bytes.Equal(pub, w) {
			return ErrWeakKey
		}
	}
	return nil
}

// ValidateX25519Pub rejects wrong-length keys and low-order points: an ECDH of
// a fresh scalar against such a point yields the all-zero secret, which Go
// reports as an error.
func ValidateX25519Pub(pub []byte) error {
	if len(pub) != PubLen {
		return ErrKeyLength
	}
	pk, err := ecdh.X25519().NewPublicKey(pub)
	if err != nil {
		return ErrWeakKey
	}
	probe, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if _, err := probe.ECDH(pk); err != nil {
		return ErrWeakKey
	}
	return nil
}

// Fingerprint is SHA-256("OFE2EE1-FP\0" || ed25519_pub || x25519_pub).
func Fingerprint(edPub, xPub []byte) ([]byte, error) {
	if len(edPub) != PubLen || len(xPub) != PubLen {
		return nil, ErrKeyLength
	}
	h := sha256.New()
	h.Write([]byte(domFingerprint))
	h.Write(edPub)
	h.Write(xPub)
	return h.Sum(nil), nil
}

// FingerprintHex is the lower-case hex form stored in device_keys.fingerprint.
func FingerprintHex(fp []byte) string { return hex.EncodeToString(fp) }

// digits renders 12 groups of 5 decimal digits from a 64-byte SHA-512 digest:
// group i = big-endian uint40 of digest[5i:5i+5] mod 100000.
func digits(sum [64]byte) string {
	groups := make([]string, digitGroups)
	for i := 0; i < digitGroups; i++ {
		var v uint64
		for _, b := range sum[i*5 : i*5+5] {
			v = v<<8 | uint64(b)
		}
		groups[i] = fmt.Sprintf("%0*d", digitsPerGroup, v%100000)
	}
	return strings.Join(groups, " ")
}

// DigitGroups is the human display form of one fingerprint: 12 groups of 5
// digits derived as SHA-512("OFE2EE1-DIGITS\0" || fingerprint).
func DigitGroups(fp []byte) string {
	h := sha512.New()
	h.Write([]byte(domDigits))
	h.Write(fp)
	var sum [64]byte
	copy(sum[:], h.Sum(nil))
	return digits(sum)
}

// ShortFingerprint is the compact glance form: first 8 fingerprint bytes as 4
// upper-case hex groups ("A1B2 C3D4 E5F6 0718"). Not a substitute for the full
// digits when verifying a person.
func ShortFingerprint(fp []byte) string {
	h := strings.ToUpper(hex.EncodeToString(fp[:8]))
	return h[0:4] + " " + h[4:8] + " " + h[8:12] + " " + h[12:16]
}

// UserDigest is the per-user part of a safety number: SHA-256 over the user id
// and the sorted, de-duplicated set of that user's active fingerprints.
func UserDigest(userID string, fps [][]byte) []byte {
	cp := make([][]byte, len(fps))
	copy(cp, fps)
	sort.Slice(cp, func(i, j int) bool { return bytes.Compare(cp[i], cp[j]) < 0 })
	h := sha256.New()
	h.Write([]byte(domUserDigest))
	h.Write([]byte(userID))
	var prev []byte
	for _, f := range cp {
		if prev != nil && bytes.Equal(prev, f) {
			continue
		}
		h.Write(f)
		prev = f
	}
	return h.Sum(nil)
}

// SafetyNumber is symmetric in its two users: SHA-512("OFE2EE1-SAFETY\0" ||
// lo || hi) over the two UserDigests ordered bytewise, rendered as 12x5 digits.
func SafetyNumber(userA string, fpsA [][]byte, userB string, fpsB [][]byte) string {
	a, b := UserDigest(userA, fpsA), UserDigest(userB, fpsB)
	if bytes.Compare(a, b) > 0 {
		a, b = b, a
	}
	h := sha512.New()
	h.Write([]byte(domSafety))
	h.Write(a)
	h.Write(b)
	var sum [64]byte
	copy(sum[:], h.Sum(nil))
	return digits(sum)
}

// BindingMessage is what a device signs with its Ed25519 key at registration:
// "OFE2EE1-BIND\0" || user_id(36) || device_id(36) || ed25519_pub(32) ||
// x25519_pub(32). It proves possession of the Ed25519 key and binds both keys
// and the (client-chosen) device id to one account.
func BindingMessage(userID, deviceID string, edPub, xPub []byte) ([]byte, error) {
	if err := CheckID(userID); err != nil {
		return nil, err
	}
	if err := CheckID(deviceID); err != nil {
		return nil, err
	}
	if len(edPub) != PubLen || len(xPub) != PubLen {
		return nil, ErrKeyLength
	}
	m := make([]byte, 0, len(domBind)+2*UUIDLen+2*PubLen)
	m = append(m, domBind...)
	m = append(m, userID...)
	m = append(m, deviceID...)
	m = append(m, edPub...)
	m = append(m, xPub...)
	return m, nil
}

// VerifyBinding checks the registration self-signature.
func VerifyBinding(userID, deviceID string, edPub, xPub, sig []byte) error {
	if err := ValidateEd25519Pub(edPub); err != nil {
		return err
	}
	if err := ValidateX25519Pub(xPub); err != nil {
		return err
	}
	if len(sig) != SigLen {
		return ErrBadSig
	}
	m, err := BindingMessage(userID, deviceID, edPub, xPub)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(edPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

// Action codes of the key transparency log. The code is part of the signed
// message, so a signature for one action can never be replayed as another.
const (
	ActRegister byte = 1 // new device key, cross-signed by an existing key of the user
	ActRotate   byte = 2 // old key vouches for its replacement
	ActRevoke   byte = 3
	ActRecovery byte = 4 // recovery identity registered (kind='recovery')
	ActEnable   byte = 5 // circle switched to Private, epoch 1+
	ActEpoch    byte = 6 // next circle key epoch published
	ActDisable  byte = 7
	ActReset    byte = 8 // new ROOT key replacing all of the user's keys (no cross-signature possible)
	ActApprove  byte = 9 // circle admin approves a replacement device for that circle
	// Processing lanes (docs/design/PRIVACY_PROCESSING.md section 5.3). The
	// signed statement itself is ProcessingPrefMessage / ProcessingPolicyMessage;
	// the log entry's ref is the SHA-256 of that statement.
	ActProcessingPref   byte = 10 // a member's own lane choice (also the per-member server consent)
	ActProcessingPolicy byte = 11 // circle admin: server assistance on/off, default, SK generation + commitment
	// ActOwnerApproval switches the circle's "owner may approve their own
	// replacement device" policy (docs/design/E2EE.md "Owner approval"). The
	// ref is OwnerApprovalRef(circle, user, on). Served only to apps that ask
	// for it (GET /e2ee/log?owner_approval=1); older apps see it redacted.
	ActOwnerApproval byte = 12
	zeroUUID              = "00000000-0000-0000-0000-000000000000"
)

// LogActionMessage is signed by the ACTING device's Ed25519 key for every
// state change that is entered in the transparency log:
//
//	"OFE2EE1-LOGACT\0" || action(1) || user_id(36) || actor_device_id(36) ||
//	circle_id(36, zero UUID if none) || subject_id(36, zero UUID if none) ||
//	epoch(4 BE, 0 if none) || ref(32, zeros if none)
//
// ref is the new key's fingerprint (register/rotate/recovery/reset) or the
// SHA-256 digest of the submitted wraps (enable/epoch). For a registration the
// signature doubles as the cross-signature of the new key by an existing key.
func LogActionMessage(action byte, userID, actorDeviceID, circleID, subjectID string, epoch uint32, ref []byte) ([]byte, error) {
	if circleID == "" {
		circleID = zeroUUID
	}
	if subjectID == "" {
		subjectID = zeroUUID
	}
	for _, id := range []string{userID, actorDeviceID, circleID, subjectID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	if ref == nil {
		ref = make([]byte, 32)
	}
	if len(ref) != 32 || action < ActRegister || action > ActOwnerApproval {
		return nil, ErrBadBlob
	}
	m := append([]byte(domLogAct), action)
	m = append(m, userID...)
	m = append(m, actorDeviceID...)
	m = append(m, circleID...)
	m = append(m, subjectID...)
	var eb [4]byte
	binary.BigEndian.PutUint32(eb[:], epoch)
	m = append(m, eb[:]...)
	return append(m, ref...), nil
}

// VerifyLogAction verifies an actor's signature over LogActionMessage.
func VerifyLogAction(actorEdPub []byte, action byte, userID, actorDeviceID, circleID, subjectID string, epoch uint32, ref, sig []byte) error {
	m, err := LogActionMessage(action, userID, actorDeviceID, circleID, subjectID, epoch, ref)
	if err != nil {
		return err
	}
	if len(actorEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(ed25519.PublicKey(actorEdPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

// OwnerApprovalRef is the 32-byte `ref` of an ActOwnerApproval log entry:
//
//	SHA-256("OFE2EE4-OWNER-APPROVAL\0" || circle(36) || admin_user(36) || on(1: 0 off, 1 on))
//
// The log entry (signed by the admin's key) is the whole statement: a phone
// recomputes the ref for on and for off and learns which one was signed.
func OwnerApprovalRef(circleID, adminUserID string, on bool) ([]byte, error) {
	for _, id := range []string{circleID, adminUserID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	b := byte(0)
	if on {
		b = 1
	}
	h := sha256.New()
	h.Write([]byte(domOwnerApprove))
	h.Write([]byte(circleID))
	h.Write([]byte(adminUserID))
	h.Write([]byte{b})
	return h.Sum(nil), nil
}

// GenesisHash is the prev hash of log entry 1.
var GenesisHash = make([]byte, 32)

// LogEntryHash chains the log: SHA-256("OFE2EE1-LOG\0" || prev(32) || seq(8 BE)
// || actionMessage || signature(64)). Editing, dropping or reordering any
// entry changes every later hash.
func LogEntryHash(prev []byte, seq uint64, actionMsg, sig []byte) []byte {
	var sb [8]byte
	binary.BigEndian.PutUint64(sb[:], seq)
	h := sha256.New()
	h.Write([]byte(domLog))
	h.Write(prev)
	h.Write(sb[:])
	h.Write(actionMsg)
	h.Write(sig)
	return h.Sum(nil)
}

func epochBytes(epoch uint32) ([]byte, error) {
	if epoch == 0 {
		return nil, ErrBadEpoch
	}
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], epoch)
	return b[:], nil
}

// WrapAAD binds a wrapped key to its circle, epoch, recipient device and
// wrapper device: "OFE2EE1-WRAP-AAD\0" || circle(36) || epoch(4 BE) ||
// recipient_device(36) || wrapper_device(36).
func WrapAAD(circleID string, epoch uint32, recipientDeviceID, wrapperDeviceID string) ([]byte, error) {
	for _, id := range []string{circleID, recipientDeviceID, wrapperDeviceID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	e, err := epochBytes(epoch)
	if err != nil {
		return nil, err
	}
	a := append([]byte(domWrapAAD), circleID...)
	a = append(a, e...)
	a = append(a, recipientDeviceID...)
	return append(a, wrapperDeviceID...), nil
}

// WrapSigMessage is what the wrapper signs: "OFE2EE1-WRAP-SIG\0" || (the same
// circle/epoch/recipient/wrapper fields as the AAD) || blob.
func WrapSigMessage(circleID string, epoch uint32, recipientDeviceID, wrapperDeviceID string, blob []byte) ([]byte, error) {
	if len(blob) != WrapBlobLen {
		return nil, ErrBadBlob
	}
	aad, err := WrapAAD(circleID, epoch, recipientDeviceID, wrapperDeviceID)
	if err != nil {
		return nil, err
	}
	m := append([]byte(domWrapSig), aad[len(domWrapAAD):]...)
	return append(m, blob...), nil
}

// VerifyWrapSignature is the check the server performs on every submitted wrap.
// It proves who produced the blob, not what is inside.
func VerifyWrapSignature(wrapperEdPub []byte, circleID string, epoch uint32, recipientDeviceID, wrapperDeviceID string, blob, sig []byte) error {
	m, err := WrapSigMessage(circleID, epoch, recipientDeviceID, wrapperDeviceID, blob)
	if err != nil {
		return err
	}
	if len(wrapperEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(ed25519.PublicKey(wrapperEdPub), m, sig) {
		return ErrBadSig
	}
	return nil
}

func wrapKey(shared, epk, recipientX []byte) ([]byte, error) {
	salt := append(append([]byte{}, epk...), recipientX...)
	r := hkdf.New(sha256.New, shared, salt, []byte(domWrapKey))
	k := make([]byte, KeyLen)
	if _, err := io.ReadFull(r, k); err != nil {
		return nil, err
	}
	return k, nil
}

// WrapWithRandomness is Wrap with the ephemeral X25519 secret and the XChaCha20
// nonce supplied by the caller. It exists for deterministic test vectors; real
// callers use Wrap, which draws both from crypto/rand. NEVER reuse an
// (ephemeral secret, nonce) pair outside tests.
func WrapWithRandomness(circleKey, recipientX, aad []byte, ephemeralSecret [32]byte, nonce [NonceLen]byte) ([]byte, error) {
	if len(circleKey) != KeyLen {
		return nil, errors.New("e2ee: circle key must be 32 bytes")
	}
	rpub, err := ecdh.X25519().NewPublicKey(recipientX)
	if err != nil {
		return nil, ErrWeakKey
	}
	esk, err := ecdh.X25519().NewPrivateKey(ephemeralSecret[:])
	if err != nil {
		return nil, err
	}
	shared, err := esk.ECDH(rpub)
	if err != nil {
		return nil, ErrWeakKey
	}
	epk := esk.PublicKey().Bytes()
	k, err := wrapKey(shared, epk, recipientX)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	blob := make([]byte, 0, WrapBlobLen)
	blob = append(blob, WrapVersion)
	blob = append(blob, epk...)
	blob = append(blob, nonce[:]...)
	return aead.Seal(blob, nonce[:], circleKey, aad), nil
}

// Wrap seals circleKey to the recipient's X25519 public key (sealed box:
// ephemeral X25519 + HKDF-SHA256 + XChaCha20-Poly1305 with a random nonce).
func Wrap(circleKey, recipientX, aad []byte) ([]byte, error) {
	var esk [32]byte
	var nonce [NonceLen]byte
	if _, err := io.ReadFull(rand.Reader, esk[:]); err != nil {
		return nil, err
	}
	if _, err := io.ReadFull(rand.Reader, nonce[:]); err != nil {
		return nil, err
	}
	return WrapWithRandomness(circleKey, recipientX, aad, esk, nonce)
}

// Unwrap opens a blob with the recipient's X25519 private and public key. The
// server never calls this; it exists so Go tests can prove the Dart client's
// output decrypts and so operators' tooling can be written against it.
func Unwrap(blob, recipientXSecret, recipientXPub, aad []byte) ([]byte, error) {
	if len(blob) != WrapBlobLen || blob[0] != WrapVersion {
		return nil, ErrBadBlob
	}
	epk := blob[1 : 1+PubLen]
	nonce := blob[1+PubLen : 1+PubLen+NonceLen]
	ct := blob[1+PubLen+NonceLen:]
	sk, err := ecdh.X25519().NewPrivateKey(recipientXSecret)
	if err != nil {
		return nil, ErrDecrypt
	}
	pk, err := ecdh.X25519().NewPublicKey(epk)
	if err != nil {
		return nil, ErrDecrypt
	}
	shared, err := sk.ECDH(pk)
	if err != nil {
		return nil, ErrDecrypt
	}
	k, err := wrapKey(shared, epk, recipientXPub)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	pt, err := aead.Open(nil, nonce, ct, aad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return pt, nil
}

func msgKey(circleKey []byte, circleID string, epoch []byte, purpose string) ([]byte, error) {
	salt := append(append([]byte{}, circleID...), epoch...)
	r := hkdf.New(sha256.New, circleKey, salt, append([]byte(domMsgKey), purpose...))
	k := make([]byte, KeyLen)
	if _, err := io.ReadFull(r, k); err != nil {
		return nil, err
	}
	return k, nil
}

func msgAAD(circleID string, epoch []byte, senderDeviceID, purpose string) []byte {
	a := append([]byte(domMsgAAD), circleID...)
	a = append(a, epoch...)
	a = append(a, senderDeviceID...)
	a = append(a, byte(len(purpose))) // length byte then purpose: unambiguous
	return append(a, purpose...)
}

// SealWithNonce is the phase-2 payload format with an explicit nonce (vectors).
// Output: version(1) || epoch(4 BE) || nonce(24) || ciphertext||tag.
// The key is HKDF(circleKey, salt=circle||epoch, info=domain||purpose), so a
// payload of one purpose ("loc", "place", ...) never decrypts as another.
func SealWithNonce(circleKey []byte, circleID string, epoch uint32, senderDeviceID, purpose string, plaintext []byte, nonce [NonceLen]byte) ([]byte, error) {
	if len(purpose) == 0 || len(purpose) > 64 {
		return nil, ErrBadPurpose
	}
	if err := CheckID(circleID); err != nil {
		return nil, err
	}
	if err := CheckID(senderDeviceID); err != nil {
		return nil, err
	}
	eb, err := epochBytes(epoch)
	if err != nil {
		return nil, err
	}
	k, err := msgKey(circleKey, circleID, eb, purpose)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	out := []byte{MsgVersion}
	out = append(out, eb...)
	out = append(out, nonce[:]...)
	aad := msgAAD(circleID, eb, senderDeviceID, purpose)
	return aead.Seal(out, nonce[:], plaintext, aad), nil
}

// Seal encrypts a circle payload with a fresh random 24-byte nonce.
func Seal(circleKey []byte, circleID string, epoch uint32, senderDeviceID, purpose string, plaintext []byte) ([]byte, error) {
	var n [NonceLen]byte
	if _, err := io.ReadFull(rand.Reader, n[:]); err != nil {
		return nil, err
	}
	return SealWithNonce(circleKey, circleID, epoch, senderDeviceID, purpose, plaintext, n)
}

// Open decrypts a circle payload. The caller learns the epoch from the header
// (PayloadEpoch) to pick the right key before calling.
func Open(circleKey []byte, circleID string, senderDeviceID, purpose string, payload []byte) ([]byte, error) {
	if len(payload) < 1+4+NonceLen+TagLen {
		return nil, ErrShortCipher
	}
	if payload[0] != MsgVersion {
		return nil, ErrBadBlob
	}
	eb := payload[1:5]
	k, err := msgKey(circleKey, circleID, eb, purpose)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	aad := msgAAD(circleID, eb, senderDeviceID, purpose)
	pt, err := aead.Open(nil, payload[5:5+NonceLen], payload[5+NonceLen:], aad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return pt, nil
}

// PayloadEpoch reads the epoch from a payload header without decrypting.
func PayloadEpoch(payload []byte) (uint32, error) {
	if len(payload) < 5 || payload[0] != MsgVersion {
		return 0, ErrBadBlob
	}
	return binary.BigEndian.Uint32(payload[1:5]), nil
}

// ConstEq compares two byte strings in constant time.
func ConstEq(a, b []byte) bool { return subtle.ConstantTimeCompare(a, b) == 1 }

// DeriveIdentity expands the 32-byte device identity seed into the Ed25519
// seed and the X25519 secret: HKDF-SHA256(ikm=seed, salt=none, info=label).
// The seed is generated on the phone and is what the recovery phrase encodes;
// the server never sees it. Provided here so the vectors cover the derivation.
func DeriveIdentity(seed []byte) (edSeed, xSecret []byte, err error) {
	if len(seed) != 32 {
		return nil, nil, errors.New("e2ee: identity seed must be 32 bytes")
	}
	read := func(label string) ([]byte, error) {
		k := make([]byte, 32)
		_, err := io.ReadFull(hkdf.New(sha256.New, seed, nil, []byte(label)), k)
		return k, err
	}
	if edSeed, err = read("OFE2EE1-IDENTITY-ED25519"); err != nil {
		return nil, nil, err
	}
	xSecret, err = read("OFE2EE1-IDENTITY-X25519")
	return edSeed, xSecret, err
}

// ---------------------------------------------------------------- recovery

// Recovery argon2id parameters (only used when the user sets a passphrase).
// 32 MiB, 3 passes, 1 lane: memory-hard, roughly 0.3-1 s on a recent phone with
// native code and several seconds in pure Dart, which is why the client runs it
// in a background isolate. The 24 words alone carry 256 bits of entropy; the
// passphrase is an optional second factor, never a substitute.
const (
	Argon2MemKiB = 32 * 1024
	Argon2Iter   = 3
	Argon2Lanes  = 1
)

const (
	recoverySalt = "openfamily/e2ee/v1/recovery"
	argonSalt    = "openfamily/e2ee/v1/recovery-argon2-salt"
)

// RecoverySeed = HKDF-SHA256(ikm, salt="openfamily/e2ee/v1/recovery", info="seed", 32).
// Without a passphrase ikm is the 32-byte BIP39 entropy. With a passphrase:
//
//	A   = Argon2id(passphrase, salt = HKDF(entropy, "...argon2-salt", 16), 32 bytes)
//	ikm = entropy || A
//
// so neither the words nor the passphrase alone determine the seed.
func RecoverySeed(entropy []byte, passphrase string) ([]byte, error) {
	if len(entropy) != 32 {
		return nil, errors.New("e2ee: recovery entropy must be 32 bytes (24 words)")
	}
	ikm := append([]byte{}, entropy...)
	if passphrase != "" {
		salt := make([]byte, 16)
		if _, err := io.ReadFull(hkdf.New(sha256.New, entropy, []byte(argonSalt), []byte("salt")), salt); err != nil {
			return nil, err
		}
		a := argon2.IDKey([]byte(passphrase), salt, Argon2Iter, Argon2MemKiB, Argon2Lanes, 32)
		ikm = append(ikm, a...)
	}
	seed := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, ikm, []byte(recoverySalt), []byte("seed")), seed); err != nil {
		return nil, err
	}
	return seed, nil
}

// RecoveryIdentity derives the recovery identity's Ed25519 seed and X25519
// secret from the recovery seed with distinct labels.
func RecoveryIdentity(recoverySeed []byte) (edSeed, xSecret []byte, err error) {
	read := func(label string) ([]byte, error) {
		k := make([]byte, 32)
		_, err := io.ReadFull(hkdf.New(sha256.New, recoverySeed, []byte(recoverySalt), []byte(label)), k)
		return k, err
	}
	if edSeed, err = read("recovery-ed25519"); err != nil {
		return nil, nil, err
	}
	xSecret, err = read("recovery-x25519")
	return edSeed, xSecret, err
}

// ----------------------------------------------------------------- padding

// PadBucket returns the padded plaintext length for n bytes of payload: the
// smallest of 256, 512, 1024, 4096 that fits, else the next multiple of 4096.
// Padded layout: length(2 BE, so max 65535) || payload || zero bytes. It hides
// the payload size from the server within a bucket (metadata minimisation).
func PadBucket(n int) int {
	need := n + 2
	for _, b := range []int{256, 512, 1024, 4096} {
		if need <= b {
			return b
		}
	}
	return (need + 4095) / 4096 * 4096
}

// Pad pads a payload to its bucket.
func Pad(p []byte) ([]byte, error) {
	if len(p) > 0xffff {
		return nil, errors.New("e2ee: payload too large")
	}
	out := make([]byte, PadBucket(len(p)))
	binary.BigEndian.PutUint16(out, uint16(len(p)))
	copy(out[2:], p)
	return out, nil
}

// Unpad reverses Pad and checks the padding is all zero.
func Unpad(p []byte) ([]byte, error) {
	if len(p) < 2 {
		return nil, ErrShortCipher
	}
	n := int(binary.BigEndian.Uint16(p))
	if 2+n > len(p) || PadBucket(n) != len(p) {
		return nil, ErrBadBlob
	}
	for _, b := range p[2+n:] {
		if b != 0 {
			return nil, ErrBadBlob
		}
	}
	return p[2 : 2+n], nil
}

// KeyCommitment binds an epoch to its circle key without revealing it:
// HKDF-SHA256(ikm = circle_key, salt = circle_id || epoch(4 BE),
// info = "OFE2EE1-KEY-COMMIT\0", 32 bytes). The publisher signs it as the `ref`
// of the enable/epoch log action; every phone recomputes it from the key it just
// unwrapped and rejects the key on a mismatch, so a bogus or substituted wrap can
// never be accepted.
func KeyCommitment(circleKey []byte, circleID string, epoch uint32) ([]byte, error) {
	if len(circleKey) != KeyLen {
		return nil, errors.New("e2ee: circle key must be 32 bytes")
	}
	if err := CheckID(circleID); err != nil {
		return nil, err
	}
	eb, err := epochBytes(epoch)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 32)
	salt := append([]byte(circleID), eb...)
	if _, err := io.ReadFull(hkdf.New(sha256.New, circleKey, salt, []byte(domCommit)), out); err != nil {
		return nil, err
	}
	return out, nil
}

// ServerConsentMessage is what a member's phone signs to let the Orbitly
// server (a `server` device) read ONE circle: domServerCons || circle_id(36) ||
// user_id(36) || server_device_id(36) || server_fingerprint(32). The signature
// names the circle, the person and the exact server key, so it cannot be moved
// to another circle, another person or another server key.
func ServerConsentMessage(circleID, userID, serverDeviceID string, serverFingerprint []byte) ([]byte, error) {
	for _, id := range []string{circleID, userID, serverDeviceID} {
		if err := CheckID(id); err != nil {
			return nil, err
		}
	}
	if len(serverFingerprint) != 32 {
		return nil, ErrKeyLength
	}
	m := make([]byte, 0, len(domServerCons)+3*UUIDLen+32)
	m = append(m, domServerCons...)
	m = append(m, circleID...)
	m = append(m, userID...)
	m = append(m, serverDeviceID...)
	m = append(m, serverFingerprint...)
	return m, nil
}

// VerifyServerConsent checks a consent signature made by a member's phone key.
func VerifyServerConsent(approverEdPub []byte, circleID, userID, serverDeviceID string, serverFingerprint, sig []byte) error {
	msg, err := ServerConsentMessage(circleID, userID, serverDeviceID, serverFingerprint)
	if err != nil {
		return err
	}
	if len(approverEdPub) != PubLen || len(sig) != SigLen || !ed25519.Verify(approverEdPub, msg, sig) {
		return ErrBadSig
	}
	return nil
}
