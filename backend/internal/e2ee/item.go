package e2ee

// Phase 2: the signed item envelope carried inside a sealed circle payload.
//
//	envelope = 0x01 || seq(8 BE) || ts_ms(8 BE) || sig(64) || body (JSON, UTF-8)
//	sig      = Ed25519(sender device key,
//	             "OFE2EE2-ITEM\0" || circle_id || epoch(4) || device_id ||
//	             len(purpose)(1) || purpose || seq(8) || ts_ms(8) || body)
//	payload  = Seal(circleKey, ..., Pad(envelope))
//
// All circle members share the circle key, so AEAD alone does not say WHO sent an
// item. The signature binds circle, epoch, sender device, purpose, sequence number,
// time and body to the sender's device key. The server never parses any of this; it
// is the reference for the web viewer and the Dawarich bridge (docs/design/E2EE.md).

import (
	"crypto/ed25519"
	"encoding/binary"
	"errors"
)

const (
	// ItemVersion is the first byte of the envelope.
	ItemVersion = 1
	domItem     = "OFE2EE2-ITEM\x00"
)

var (
	ErrBadEnvelope  = errors.New("e2ee: malformed item envelope")
	ErrBadItemSig   = errors.New("e2ee: item signature does not verify")
	ErrItemSeqMatch = errors.New("e2ee: item seq does not match the server's")
)

// ItemSignedMessage is the byte string the sender device signs.
func ItemSignedMessage(circleID string, epoch uint32, deviceID, purpose string, seq uint64, tsMs uint64, body []byte) ([]byte, error) {
	if len(purpose) == 0 || len(purpose) > 64 {
		return nil, ErrBadPurpose
	}
	if err := CheckID(circleID); err != nil {
		return nil, err
	}
	if err := CheckID(deviceID); err != nil {
		return nil, err
	}
	eb, err := epochBytes(epoch)
	if err != nil {
		return nil, err
	}
	m := append([]byte(domItem), circleID...)
	m = append(m, eb...)
	m = append(m, deviceID...)
	m = append(m, byte(len(purpose)))
	m = append(m, purpose...)
	m = binary.BigEndian.AppendUint64(m, seq)
	m = binary.BigEndian.AppendUint64(m, tsMs)
	return append(m, body...), nil
}

// SealItem signs body as the sender device and seals it (padded) for the circle.
func SealItem(circleKey []byte, circleID string, epoch uint32, deviceID string, priv ed25519.PrivateKey,
	purpose string, seq, tsMs uint64, body []byte, nonce [NonceLen]byte) ([]byte, error) {
	msg, err := ItemSignedMessage(circleID, epoch, deviceID, purpose, seq, tsMs, body)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(priv, msg)
	env := []byte{ItemVersion}
	env = binary.BigEndian.AppendUint64(env, seq)
	env = binary.BigEndian.AppendUint64(env, tsMs)
	env = append(env, sig...)
	env = append(env, body...)
	padded, err := Pad(env)
	if err != nil {
		return nil, err
	}
	return SealWithNonce(circleKey, circleID, epoch, deviceID, purpose, padded, nonce)
}

// OpenItem decrypts a payload, verifies the sender signature with senderEdPub (the
// public key of the APPROVED device the server named; the caller checks approval)
// and returns the signed sequence number, timestamp and body. serverSeq is the
// sequence number the server relayed; a mismatch means the server renumbered.
func OpenItem(circleKey []byte, circleID, deviceID string, senderEdPub []byte, purpose string, serverSeq uint64, payload []byte) (seq, tsMs uint64, body []byte, err error) {
	padded, err := Open(circleKey, circleID, deviceID, purpose, payload)
	if err != nil {
		return 0, 0, nil, err
	}
	env, err := Unpad(padded)
	if err != nil {
		return 0, 0, nil, err
	}
	if len(env) < 1+8+8+SigLen || env[0] != ItemVersion {
		return 0, 0, nil, ErrBadEnvelope
	}
	seq = binary.BigEndian.Uint64(env[1:9])
	tsMs = binary.BigEndian.Uint64(env[9:17])
	sig := env[17 : 17+SigLen]
	body = env[17+SigLen:]
	if seq != serverSeq {
		return 0, 0, nil, ErrItemSeqMatch
	}
	epoch, err := PayloadEpoch(payload)
	if err != nil {
		return 0, 0, nil, err
	}
	msg, err := ItemSignedMessage(circleID, epoch, deviceID, purpose, seq, tsMs, body)
	if err != nil {
		return 0, 0, nil, err
	}
	if len(senderEdPub) != PubLen || !ed25519.Verify(senderEdPub, msg, sig) {
		return 0, 0, nil, ErrBadItemSig
	}
	return seq, tsMs, body, nil
}
