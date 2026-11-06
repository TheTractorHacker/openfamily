# ADR: End-to-end encryption ("Private circle")

Status: **ACCEPTED** (supersedes the earlier "Proposed" text of this file, which recommended against E2EE).
Issue: #34. Phase 1 (this document + code) is implemented; phase 2 is specified here as binding requirements.

## Decision

The maintainer adopted end-to-end encryption so that the server can no longer read member locations in circles that opt in.
It is delivered in **phases and opt-in per circle** ("Private circle"):

| Phase | Scope | State |
|---|---|---|
| 1 | Cryptographic foundation and verification UX: device identity keys, circle key epochs, wrapped keys, key transparency log, recovery, safety numbers, server-record check, admin/CLI tooling. **No location data moves.** | implemented |
| 2 | Live fixes, history, places, arrival/departure events and SOS move into the encrypted channel; geofencing and trip logic run on the phones. | not started (requirements below are binding) |
| 3 | Optional: private-circle-aware web/desktop client, media (chat photos), push redesign leftovers. | future |

Existing circles keep working exactly as today. A circle switched to Private mode only gets keys in phase 1. The toggle is OFF by default,
admin-only, and the UI says honestly what changes now and what will be unavailable later.

## Threat model

In scope (the server is the adversary, the members are not):

| Adversary | Outcome with Private circles (after phase 2) |
|---|---|
| Server breach (RCE, SQL injection) | Attacker gets ciphertext, public keys and metadata, not positions |
| Stolen database or backup | Same |
| Curious operator | Same; the operator can still add a malicious public key (see "Honest limits") |
| Compelled operator | Can hand over ciphertext and metadata only |
| Network attacker | TLS as before; ciphertext additionally |

Out of scope: a hostile circle member (members are trusted by design and hold the circle key), a compromised phone (malware with
the user's session reads the same data the user can), traffic analysis by the network, and denial of service by the server.

## What does NOT work in a Private circle (phase 2) and how it is handled

| Feature | Why it needs plaintext today | In a Private circle |
|---|---|---|
| Place arrival/departure alerts (`geofence.go`, `place_presence.go`) | SQL evaluation of fixes against places | **Computed on the sender's phone**; it sends an encrypted "arrived at Home" event. Places are distributed encrypted. Server only relays. |
| Live map, history, day view | server serves rows | Phones decrypt; history is stored as ciphertext and decrypted on the phone |
| Trips, driving reports, crash scoring, weekly summary | server segments and aggregates fixes | **Computed on-device** and shared as encrypted summaries, or documented as unavailable. Server-side trips/driving/weekly summary are **unavailable** for Private circles |
| SOS with position | server pushes last position | Position travels in the encrypted payload. The server (and so the SMS/Twilio fallback) **cannot know the position**; SOS in a Private circle must say so in the UI. The wake-up push has no position |
| Admin map and device last-known positions | operator reads positions | **Unavailable** for Private circles (by design). Admin panel still lists accounts, devices, keys |
| Dawarich export | server forwards points | **Unavailable** for Private circles (could be a phone-side export later) |
| Server geocoded place names and address search | server reverse-geocodes | Geocoding moves to the phone (or an on-device lookup); the server never learns an address |
| Push text naming a place or person | server composes the text | Server sends a content-free wake-up; the app decrypts and raises a LOCAL notification |

**Downgrade rule (TODO hook for phase 2):** a Private circle must refuse unencrypted payload types. `circles.e2ee_mode = 'private'` is
the switch; every plaintext location/place/event endpoint must check it and answer 409 for a Private circle, and phones must never
fall back to plaintext after a failed encrypt. Phase 1 deliberately adds no such enforcement because no plaintext path has moved yet.

## Cryptographic design (frozen wire formats)

Library choice: the Dart package **`cryptography`** (pure Dart: Ed25519, X25519, XChaCha20-Poly1305, HKDF-SHA256, Argon2id, SHA-2) plus
**`bip39`** (wordlist and checksum). `sodium_libs`/libsodium would be faster and more widely audited, but it adds a native build
(FFI and prebuilt binaries per ABI) and could not be proven to compile in the available environment within the work budget;
`cryptography` builds everywhere, is widely used, and payloads here are tens of bytes where speed is irrelevant. Going native later is a
drop-in (`cryptography_flutter` accelerates the same API, or a libsodium backend can replace `E2ee`) because both sides are pinned by
cross-language test vectors. On the server, Go's standard `crypto/ed25519`, `crypto/ecdh`, and `golang.org/x/crypto`
(`chacha20poly1305`, `hkdf`, `argon2`).

All strings are ASCII; identifiers are lower-case UUIDs (36 bytes); integers are big-endian. Every hashed or signed message starts with
its own NUL-terminated domain string, so one signature or hash can never be replayed as another.

### Keys

* **Identity seed**: 32 random bytes generated on the phone. `ed25519_seed = HKDF-SHA256(seed, salt=none, info="OFE2EE1-IDENTITY-ED25519")`,
  `x25519_secret = HKDF-SHA256(seed, salt=none, info="OFE2EE1-IDENTITY-X25519")`. One Ed25519 signing key and one X25519 agreement key
  per device. The seed lives only in the Keystore-protected vault (below).
* **Device id**: random v4 UUID chosen by the phone (it is inside signed messages, so the server cannot rename a key).
* **Circle key**: 32 random bytes per circle per **epoch** (epoch >= 1, strictly increasing), generated on an admin's phone.
* **Recovery identity**: derived from the 24-word phrase (see Recovery); registered as `kind = 'recovery'`.

### Fingerprint, digits, safety number

* `fingerprint = SHA-256("OFE2EE1-FP\0" || ed25519_pub || x25519_pub)` (32 bytes, stored as hex).
* **Digits** (12 groups of 5, Signal style): `D = SHA-512("OFE2EE1-DIGITS\0" || fingerprint)`; group `i` = big-endian uint40 of `D[5i..5i+5]` mod 100000.
* **Short form**: first 8 fingerprint bytes as four upper-case hex groups (`5CA3 7A50 B2A2 396A`). A glance aid only.
* `userDigest = SHA-256("OFE2EE1-USER\0" || user_id || sorted distinct fingerprints)`.
* **Safety number** between two users: `SHA-512("OFE2EE1-SAFETY\0" || min(userDigestA,userDigestB) || max(...))` rendered as 12x5 digits. Symmetric; changes if either person's key set changes.

### Registration binding and the transparency-log action message

* `binding = Ed25519(sk, "OFE2EE1-BIND\0" || user_id || device_id || ed25519_pub || x25519_pub)` proves possession and binds both keys and the id to the account.
* Every state change is a **log action** signed by the acting device key:
  `"OFE2EE1-LOGACT\0" || action(1) || user_id || actor_device_id || circle_id|zeros || subject_id|zeros || epoch(4) || ref(32)|zeros`.
  Actions: 1 register (cross-signed), 2 rotate, 3 revoke, 4 recovery registered, 5 enable, 6 epoch, 7 disable, 8 reset (new root), 9 approve.
  `ref` is the new key's fingerprint, the revoked key's fingerprint, or the digest of the submitted wraps
  (`SHA-256("OFE2EE1-WRAPS\0" || (recipient_id || wrapped_key) ordered by recipient id)`).

### Sealed-box wrap of a circle key

`wrapped_key = 0x01 || epk(32) || nonce(24) || ciphertext(32) || tag(16)` (105 bytes). `epk` is a fresh ephemeral X25519 key;
`shared = X25519(esk, recipient_x25519_pub)` (an all-zero result is refused); `key = HKDF-SHA256(shared, salt = epk || recipient_pub,
info = "OFE2EE1-WRAP-KEY\0")`; XChaCha20-Poly1305 with a **random 24-byte nonce** and
`AAD = "OFE2EE1-WRAP-AAD\0" || circle_id || epoch || recipient_device_id || wrapper_device_id`. The wrapper signs
`"OFE2EE1-WRAP-SIG\0" || (circle, epoch, recipient, wrapper) || wrapped_key`. The AAD binds circle, epoch and both devices, so a wrap cannot
be replayed to another circle/epoch/device (rollback and substitution fail authentication).

### Circle payload format (for phase 2)

`payload = 0x01 || epoch(4) || nonce(24) || ciphertext || tag(16)`; `key = HKDF-SHA256(circle_key, salt = circle_id || epoch,
info = "OFE2EE1-MSG-KEY\0" || purpose)`; `AAD = "OFE2EE1-MSG-AAD\0" || circle_id || epoch || sender_device_id || len(purpose) || purpose`.
`purpose` ("loc", "place", "event", ...) gives key separation. Plaintext is padded first (`length(2) || data || zeros` to buckets of
256, 512, 1024, 4096, then multiples of 4096 bytes) to hide payload size inside a bucket. Nonces are random per message (24 bytes: no
practical collision); a nonce is never reused with a key, and wrap/seal helpers take an explicit nonce only for test vectors.

### Test vectors

`backend/internal/e2ee/testdata/vectors.json` is generated by Go (`UPDATE_VECTORS=1 go test ./internal/e2ee`) and read by the Dart tests
(`app/test/services/e2ee/e2ee_crypto_test.dart`). It covers identity derivation, fingerprints, digits, the safety number, the binding
signature, a wrap (AAD, blob, signature), a sealed payload, padding, a log action with its chained entry hash, and the recovery phrase
(a fixed BIP39 phrase to the exact seed and recovery key fingerprints, with and without passphrase).

## Server model (phase 1)

Migration `000150_e2ee` (idempotent, with a down file): tables `device_keys`, `circle_key_wraps`, `device_approvals`, `e2ee_log`; columns
`circles.e2ee_mode ('off'|'private', default off)`, `e2ee_epoch`, `e2ee_rekey_required`, `e2ee_updated_at`; triggers.
The server stores **public keys and ciphertext only**; no endpoint accepts a private key, recovery phrase or plaintext circle key.

| Route | Who | Purpose |
|---|---|---|
| `POST /e2ee/devices` | self | register a key (root, cross-signed, `reset`, or `kind=recovery`) |
| `POST /e2ee/devices/{id}/rotate`, `DELETE /e2ee/devices/{id}` | self | rotate (old key signs), revoke |
| `GET /e2ee/me` | self | the server's record of my keys (incl. revoked) |
| `GET /e2ee/users/{user_id}/devices` | self or co-member | active keys; others get 404 |
| `GET /circles/{id}/e2ee`, `/pending`, `/wraps?device_id=` | circle member | state with approval flags; queue of devices lacking a wrap (ciphertext/public data only); my own wraps |
| `POST /circles/{id}/e2ee/enable`, `/epoch`, `/disable`, `/approvals` | circle admin | enable (epoch = current+1), publish next epoch, disable, approve a replacement key |
| `POST /circles/{id}/e2ee/wraps` | circle member | add wraps (never overwrites) for epoch <= current |
| `GET /e2ee/log?after=N` | any user | the transparency log (redacted for unrelated people) |
| `GET /api/admin/e2ee/keys` | platform admin | public keys and circle epochs |

Enforced by the server: authentication, rate limits (register 10/h, rotate 5/h, wraps 30/min, admin ops 20/h, reads 120/min), key length/weak-key
checks (small-order Ed25519 and low-order X25519 points), binding signature, log-action signature of an **active key of the caller**, wrap
signature by the wrapper's registered key, wrapper = caller, recipient = approved active key of a live circle member, strictly increasing epoch
(`current+1` only; the counter is kept when a circle is switched off), admin-only epoch operations, IDOR-safe lookups (404 for non-members), one
active recovery key per user, max 10 active device keys, immutable log (UPDATE/DELETE blocked by trigger).
Triggers: removing a member deletes that member's wraps and sets `e2ee_rekey_required`; revoking a key deletes its wraps and sets the flag in all the owner's private circles. The server cannot re-key itself (it holds no key): an admin phone publishes the next epoch.
Audit log entries: `e2ee.device_registered|device_reset|recovery_registered|device_rotated|device_revoked|enabled|epoch_bumped|disabled|wraps_added|device_approved|rekey_required`.
Operator tools: `server e2ee-fingerprints [--all]` (each user's key fingerprints, circles and epochs) and `server e2ee-log-head` (verifies the whole log, hashes and signatures, prints the head); admin panel page "Encryption keys".

## Key distribution, approval, rotation

1. **First key** of an account is a root, trust-on-first-use. For a joiner the invite link/QR carries the **inviter's key fingerprint and circle id
   in the URL fragment** (never sent to the server by a browser), so the new phone checks the keys the server returns against a value that never came from the server (mismatch = loud alarm; match = inviter pinned as verified).
2. **A second phone** of the same account is **cross-signed** by an existing device (manual copy/paste codes, server not involved) or by the recovery key. Others see the chain (`registered_by_device_id`, signature) and verify it.
3. **A replacement root key** (reset, e.g. a lost phone without backup) is not cross-signed. The server accepts it but **refuses to store any wrap for it in a circle until a circle admin of another user approves it for that circle** (signed approval entry in the log, shown as "Waiting for approval"). The phone additionally prompts, after the owner compares the safety number out of band, before sharing a key with a replacement or a verified member's new device.
4. **Rotate epoch** on member removal and on key revoke/compromise: the server flags the circle; an admin phone generates a new key and wraps it only to remaining approved keys. Removed members keep what they already hold (unavoidable) but cannot read new epochs.
5. New epochs are wrapped to every member's recovery key too, so recovery keeps working.

## Verification model ("server record")

**Check server record** fetches the server's record of this phone's keys and compares it with the keys held on the phone, then shows MATCH or MISMATCH.
It proves **consistency, not authenticity**: the server is the adversary, and a dishonest server would pass this check. The UI and this ADR say so explicitly.
Authenticity is anchored **out of band**:

* safety-number comparison between two people (digits, copy, QR for reading on the other phone, typed-number compare), pinned locally as **Verified**;
* the inviter fingerprint in the invite;
* a loud, persistent alarm when a **verified** person's key set changes, when a member resets all keys, and when a circle epoch is published by someone this phone never verified;
* the **key transparency log**: an append-only, hash-chained log of every registration, revocation, approval and epoch change, each entry signed by the acting device. Phones pin the head, verify the chain/signatures on every sync and alarm on rollback, fork/rewrite, gaps or forged entries.
  Entries about people the viewer shares no circle with are redacted to hashes (the chain stays checkable, other tenants stay private).

## Recovery

* The 24 words are BIP39 (256-bit entropy, checksum validated). `recovery_seed = HKDF-SHA256(ikm = entropy, salt = "openfamily/e2ee/v1/recovery", info = "seed", 32 bytes)`.
  With the **optional passphrase**: `A = Argon2id(passphrase, salt = HKDF(entropy, "openfamily/e2ee/v1/recovery-argon2-salt", "salt", 16), 32 bytes, m = 32 MiB, t = 3, p = 1)` and `ikm = entropy || A`.
  Parameters are memory-hard and sized for phones (about 0.3-1 s native; the pure-Dart implementation takes longer and is the first thing to measure on a device).
* `recovery-ed25519` and `recovery-x25519` keys are derived from the seed with those exact labels (HKDF, same salt). The **recovery identity** is registered as `kind='recovery'`, cross-signed by a device, and flagged in the log (action 4).
* Circle keys of every epoch are **also wrapped to the recovery X25519 key**. The server stores the recovery PUBLIC key and wrapped ciphertext only. With 256 bits of phrase entropy there is nothing to brute-force offline.
* **Restore on a new phone:** enter the phrase (checksum validated, `FLAG_SECURE`, text cleared after use, never logged or copied); derive the recovery identity; register a NEW device key **cross-signed by the recovery key**; fetch the wraps addressed to the recovery identity; unwrap; wrap the keys to the new device. Recommended afterwards: an admin rotates the epoch.
* The phrase is shown once with a 3-word quiz and is never stored or sent. **Losing every phone and the phrase makes the encrypted data unrecoverable by anyone**, and the UI says so.
* **Member-assisted recovery** (no phrase): the new phone registers as a reset root; a circle admin sees who is asking, which circle, and the safety number, compares out of band, and approves for that circle only; the member's phone then asks for confirmation before wrapping. Only circles that both people belong to are affected (wraps are per circle and the server rejects non-members). Every approval is in the log.

## Android Keystore, stated precisely

Ed25519, X25519, XChaCha20-Poly1305, HKDF and Argon2id are **not hardware-backed**; they run in app memory. The Android Keystore protects exactly one thing: a
**non-extractable AES-256-GCM wrapping key** that encrypts the identity seed and cached circle keys before they are stored (`flutter_secure_storage` on top).
The key is created in StrongBox when the phone has it, otherwise in the TEE, `setUnlockedDeviceRequired(true)` on Android 9+, and an optional user-authentication-bound mode
(device credential or biometrics within a 30 s window) can be requested by recreating the key. The Encryption keys screen shows the real security level from `KeyInfo`
(StrongBox / TEE / software). If the Keystore key is invalidated, reads fail closed (`VaultInvalidatedException`) and the app asks for a recovery-phrase restore rather than minting a new identity. Backups are disabled (`allowBackup=false`), so keys are not in cloud backups.
Unverified: StrongBox/TEE reporting and the auth-bound mode have not been exercised on a physical device.

## Phase 2: binding requirements for the next implementation

1. Geofence, arrival/departure, "nearby" and driving state are computed **on the sender's phone** and sent as end-to-end encrypted events (purpose `event`) to authorised members. The server relays opaque payloads plus a **wake-up push that carries no location, name or place**; the receiving app decrypts and raises a **local** notification.
2. Android background limits: foreground service with the location type, Doze and App Standby buckets, OEM battery killers; follow the existing `docs/testing/PHYSICAL_DEVICES.md` evidence plan before relying on on-device geofencing.
3. Delivery: store-and-forward with per-sender **sequence numbers**, **idempotent event ids**, deduplication, and catch-up on app open; delayed or lost pushes must never lose an event.
4. Offline phones queue encrypted events with **signed timestamps** (Ed25519 by the device key); receivers tolerate **clock skew** and reorder by sequence number.
5. Events carry the **epoch**; phones keep previous epoch keys to decrypt backlog and accept events from an epoch only when its wrap chain is valid; ignore any epoch lower than the highest seen for a circle unless it is backlog from a held key.
6. Server rejects plaintext location/place/event writes for `e2ee_mode = 'private'` (downgrade rule above).
7. Sender authenticity inside a circle: all members share the key, so AEAD alone does not prove who sent a payload. Phase 2 should sign payloads with the sender device key (Ed25519) and carry the signature inside the plaintext.
8. Metadata minimisation (below) must be implemented with the first encrypted payload.

## Metadata: what the server still learns

Visible to the server even in a Private circle: who is a member of which circle, which accounts exist, key registrations and revocations (and times), that a phone is online,
when and how often it uploads, payload **sizes** (bucketed), and client IPs. A compromised or compelled server can serve a malicious **public key** to a NEW member (only the invite fingerprint, safety numbers and the log defend against that).

Mitigations: padded fixed-size ciphertext buckets (implemented as `Pad`/`Unpad` with vectors, to be applied by phase 2), batched and jittered uploads (phase 2), short retention for ciphertext (phase 2), push payloads and notification channels that never carry precise locations or place names in Private circles (phase 2), and no coordinates, ciphertext, keys, phrases or notes in server logs at any level (phase 1 has a regression test that scans captured logs and audit rows for key material; extend it to the first encrypted payloads).
The transparency log keeps only ids, hashes and signatures; it is append-only by design, so account deletion cannot remove those rows (document in PRIVACY.md before phase 2; truncate-by-operator remains possible and is detected as a rollback by phones).

## Honest limits and residual risks

* **Consistency is not authenticity** (see above). A malicious server can substitute a key for a never-verified person; only out-of-band verification or the invite fingerprint stops it.
* **Split view:** a server can show different people different logs. Phones only catch this when members compare log heads (in-app "Key log" screen, `number:hash` tokens) or safety numbers. A gossip protocol is out of scope.
* **First-use trust:** the first key of a member is accepted on first sight unless the invite carried the inviter's fingerprint.
* **Admin approval depends on the admin's care** and an admin cannot approve their own replacement key; a circle whose only admin loses everything needs the recovery phrase.
* **A hostile or compromised member** holds the circle key and can read and forge payloads from that moment (out of scope).
* **Removal is not revocation of the past:** a removed member keeps keys and data they already received.
* **Device compromise:** malware on the phone can read keys in memory. The Keystore wrapping key does not protect against code running as the app.
* **Pure-Dart crypto** is not constant-time hardened like libsodium; the main protection is that secrets are short-lived and the threat model is the server, not a local attacker with timing access. Comparisons of secret-derived values use constant-time helpers.
* **Argon2id in pure Dart** is slow on low-end phones; the passphrase is optional.
* **Passphrase normalisation:** the passphrase is used as typed UTF-8 (no NFKD); users should avoid non-ASCII characters.
* **No in-app QR scanner** (no vetted scanner plugin was already a dependency): the QR shows the numbers for reading with another phone's camera app, and numbers can be typed or pasted for comparison.
* The invite fingerprint travels in the link's fragment; whoever relays the link (a messenger, a QR photo) can alter it, so it is only as trustworthy as the channel; it is still independent of the server.

## Security review (phase 1)

Checked: constant-time comparisons for secrets and fingerprints (`ConstEq`, `constEq`), no key material or plaintext in logs/errors/audit (regression test), random 24-byte XChaCha20 nonces and fresh ephemeral keys per wrap, AAD binding of circle/epoch/device, epoch monotonicity (enforced by the server: `current+1` only; phase 2 clients must also ignore epochs below the highest seen), replay/rollback of wraps and epochs, low-order/small-order key rejection, signature domain separation, key substitution (TOFU + safety numbers + invite anchor + log), IDOR across circles and users (authz matrix and tests), rate limits, immutable log, cascading cleanup on removal/revoke, and secrets zeroed from UI controllers after use.
Not reviewed by an external cryptographer; the formats should be audited before they carry real locations (phase 2).

## Alternatives considered

The previous options (A status quo, B history only, C full E2EE, D client geofence + relay) are retained for history; the maintainer chose C/D, phased and opt-in per circle, accepting the feature loss listed above for circles that opt in.
