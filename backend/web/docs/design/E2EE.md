# ADR: End-to-end encryption ("Private circle")

Status: **ACCEPTED** (supersedes the earlier "Proposed" text of this file, which recommended against E2EE).
Issue: #34. Phase 1 (keys and verification) and phase 2 (the encrypted channel) are implemented. Phase 3 (web viewer and Dawarich bridge as approved read-only device members) is implemented; see "Phase 3" below. Chat, media and phone-side trips are still future. An **optional trusted-server mode** (the Orbitly server as an approved member device, owner's decision) is described in "Trusted-server mode" below.

## Decision

The maintainer adopted end-to-end encryption so that the server can no longer read member locations in circles that opt in.
It is delivered in **phases and opt-in per circle** ("Private circle"):

| Phase | Scope | State |
|---|---|---|
| 1 | Cryptographic foundation and verification UX: device identity keys, circle key epochs, wrapped keys, key transparency log, recovery, safety numbers, server-record check, admin/CLI tooling. **No location data moves.** | implemented |
| 2 | Live fixes, history, places, arrival/departure events and SOS positions move into the encrypted channel; place evaluation runs on the phones. Server-side trips, driving report and weekly summary are unavailable in a Private circle. | implemented; phone background behaviour not yet verified on devices (see phase-2 section) |
| 3 | Web viewer and Dawarich bridge as approved read-only *device members* (API contract below). | implemented (browser viewer, `e2ee-bridge`, phone approval screen); not yet exercised against a live Dawarich or on a physical phone |
| 3b | Optional **trusted-server mode**: the Orbitly server as an approved, per-member-consented device so the server can read (and store plaintext for) a circle again. Off by default. | implemented; not exercised on a physical phone or a live deployment (see "Trusted-server mode") |
| 4 | Media (chat photos); encrypted chat; phone-side trips. | encrypted chat and its photos: implemented, see `E2EE_CHAT.md`; phone-side trips: future |

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
| SOS with position | server pushes last position | Position travels in the encrypted payload. The server does not store it and the SMS/Twilio fallback cannot be told it; SOS in a Private circle must say so in the UI. The wake-up push has no position. **Known gap (PRIVACY_MODEL_V1 L1):** the app still includes the coordinates in the plaintext alert request, which the server discards, so a malicious server or a TLS-terminating proxy can see them (backlog B3) |
| Admin map and device last-known positions | operator reads positions | **Unavailable** for Private circles (by design), except circles in trusted-server mode (below), where the server holds the plaintext it ingested. Admin panel still lists accounts, devices, keys |
| Dawarich export | server forwards points | **Server-side sync skips Private circles** (it reads only the plaintext table). Use the `e2ee-bridge` (phase 3), a `service` device member that you run off the server host. **Exception:** with the opt-in trusted-server mode (below) the built-in sync works again for the circles whose members all consented |
| Server geocoded place names and address search | server reverse-geocodes | Intended: geocoding moves to the phone (or an on-device lookup) so the server never learns an address. **Known gap (PRIVACY_MODEL_V1 L2):** the place picker still asks the server to reverse-geocode the pin and to search typed addresses (backlog B4) |
| Push text naming a place or person | server composes the text | Server sends a content-free wake-up; the app decrypts and raises a LOCAL notification |

**Downgrade rule (implemented in phase 2, see "Enforcement"):** `circles.e2ee_mode = 'private'` is the switch. The server refuses or drops plaintext
positions and places for a Private circle, a database trigger backs that up, and phones never fall back to plaintext after a failed seal.

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
  `ref` is the new key's fingerprint, the revoked key's fingerprint, or, for enable/epoch, the **key commitment** (below).

### Sealed-box wrap of a circle key

`wrapped_key = 0x01 || epk(32) || nonce(24) || ciphertext(32) || tag(16)` (105 bytes). `epk` is a fresh ephemeral X25519 key;
`shared = X25519(esk, recipient_x25519_pub)` (an all-zero result is refused); `key = HKDF-SHA256(shared, salt = epk || recipient_pub,
info = "OFE2EE1-WRAP-KEY\0")`; XChaCha20-Poly1305 with a **random 24-byte nonce** and
`AAD = "OFE2EE1-WRAP-AAD\0" || circle_id || epoch || recipient_device_id || wrapper_device_id`. The wrapper signs
`"OFE2EE1-WRAP-SIG\0" || (circle, epoch, recipient, wrapper) || wrapped_key`. The AAD binds circle, epoch and both devices, so a wrap cannot
be replayed to another circle/epoch/device (rollback and substitution fail authentication).

### Key commitment (epoch integrity)

`commitment = HKDF-SHA256(ikm = circle_key, salt = circle_id || epoch(4 BE), info = "OFE2EE1-KEY-COMMIT\0", 32 bytes)`. The publishing admin signs it as the `ref` of the
enable/epoch log action. The server returns, per epoch, the signed record (publisher user/device/key, commitment, signature) in the circle state; **every phone verifies that
signature and, after unwrapping, recomputes the commitment from the key and rejects the key on any mismatch (fail closed if there is no record)**. A bogus or substituted
wrap therefore can never be accepted, whoever managed to store it. (The v1 formats were never released, so this changed the meaning of `ref` for actions 5/6 in place and the vectors were regenerated.)

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
| `POST /circles/{id}/e2ee/wraps` | epoch publisher, or anyone for their OWN other keys | add or replace wraps for epoch <= current |
| `GET /e2ee/log?after=N` | any user | the transparency log (redacted for unrelated people) |
| `GET /api/admin/e2ee/keys` | platform admin | public keys and circle epochs |

Enforced by the server (migrations 000150 and 000151): authentication, rate limits (register 10/h, rotate 5/h, wraps 30/min, admin ops 20/h, reads 120/min), key length/weak-key
checks (small-order Ed25519 and low-order X25519 points), binding signature, log-action signature of an **active key of the caller**, wrap
signature by the wrapper's registered key, wrapper = caller, recipient = **transitively approved** active key of a live circle member (below),
**only the epoch's publisher (the user recorded in that epoch's signed enable/epoch log entry) may wrap a key for other members; anyone may wrap only to their own other keys** (new phone, recovery identity),
a later wrap from the publisher or the owner replaces an earlier one (a bad first submission cannot block the real one), strictly increasing epoch
(`current+1` only; the counter is kept when a circle is switched off), admin-only epoch operations, IDOR-safe lookups (404 for non-members), one
active recovery key per user, max 10 active device keys, immutable log (UPDATE/DELETE blocked by trigger).
Triggers: removing a member deletes that member's wraps and sets `e2ee_rekey_required`; revoking a key deletes its wraps and sets the flag in all the owner's private circles. The server cannot re-key itself (it holds no key): an admin phone publishes the next epoch.
Audit log entries: `e2ee.device_registered|device_reset|recovery_registered|device_rotated|device_revoked|enabled|epoch_bumped|disabled|wraps_added|device_approved|rekey_required`.
Operator tools: `server e2ee-fingerprints [--all]` (each user's key fingerprints, circles and epochs) and `server e2ee-log-head` (verifies the whole log, hashes and signatures, prints the head); admin panel page "Encryption keys".

## Key distribution, approval, rotation

1. **First key** of an account is a root, trust-on-first-use. For a joiner the invite link/QR carries the **inviter's key fingerprint and circle id
   in the URL fragment** (never sent to the server by a browser), so the new phone checks the keys the server returns against a value that never came from the server (mismatch = loud alarm; match = inviter pinned as verified).
2. **A second phone** of the same account is **cross-signed** by an existing device (manual copy/paste codes, server not involved) or by the recovery key. Others see the chain (`registered_by_device_id`, signature) and verify it.
3. **A replacement root key** (reset, e.g. a lost phone without backup) is not cross-signed. The server accepts it but **refuses to store any wrap for it in a circle until a circle admin of another user approves it for that circle**.
   Approval is **transitive** (`e2ee_device_approved`): a key counts as approved in a circle only if it, or any ancestor in its `registered_by` chain (cross-signatures, rotations, recovery registrations), is the user's *first key ever* or was approved for that circle. A key signed or rotated by an unapproved key stays unapproved; approving a root covers its descendants; approving a middle key covers it and its descendants; approval is per circle; revoking a signer neither approves nor un-approves anyone (revoked rows stay in the chain). An attacker holding only a session token cannot cross-sign (it has no signing key) and a reset root needs an in-app admin approval in every circle (signed approval entry in the log, shown as "Waiting for approval"). The phone additionally prompts, after the owner compares the safety number out of band, before sharing a key with a replacement or a verified member's new device.
4. **Rotate epoch** on member removal and on key revoke/compromise: the server flags the circle; an admin phone generates a new key and wraps it only to remaining approved keys. Removed members keep what they already hold (unavoidable) but cannot read new epochs.
5. New epochs are wrapped to every member's recovery key too, so recovery keeps working.
6. Availability trade-off: because only the epoch publisher can issue a key to a *new member*, a new member waits until that admin's phone is online (any admin can publish a fresh epoch, becoming the publisher). A member's own new phone never waits: it wraps to itself from the recovery key or an existing own device.

## Verification model ("server record")

**Check server record** fetches the server's record of this phone's keys and compares it with the keys held on the phone, then shows MATCH or MISMATCH.
It proves **consistency, not authenticity**: the server is the adversary, and a dishonest server would pass this check. The UI and this ADR say so explicitly.
Authenticity is anchored **out of band**:

* safety-number comparison between two people (digits, copy, QR for reading on the other phone, typed-number compare), pinned locally as **Verified**;
* the inviter fingerprint in the invite;
* a loud, persistent alarm when a **verified** person's key set changes, when a member resets all keys, and when a circle epoch is published by someone this phone never verified;
* the **key transparency log**: an append-only, hash-chained log of every registration, revocation, approval and epoch change, each entry signed by the acting device. Phones pin the head, verify the chain/signatures on every sync and alarm on rollback, fork/rewrite, gaps or forged entries.
  An entry is returned in full only if the viewer shares a circle with its user **and** (for circle-scoped entries) is a member of that entry's circle **and** (for an approval) can see the approved key's owner. Otherwise it is redacted to `seq`, `prev_hash`, `entry_hash`: no user, circle, subject, epoch or action (the chain stays checkable, other tenants and other circles stay private).

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
The key is created in StrongBox when the phone has it, otherwise in the TEE. It does **not** use `setUnlockedDeviceRequired` (since 0.24.2, alias `openfamily_e2ee_wrap_v2`): a phone in a pocket is the normal case for a location tracker, and the background service must seal and upload positions while the screen is locked. Versions up to 0.24.1 used `setUnlockedDeviceRequired(true)` (alias `..._v1`), which made every locked-phone fix wait for the next unlock; that is what this replaced. The strict, user-authentication-bound mode (device credential or biometrics within a 30 s window, which also sets `setUnlockedDeviceRequired`) remains available by recreating the key, but it cannot work for background sealing and is off by default.

**What this changes, stated honestly.** Before, the wrapping key could not be used by anything while the screen was locked. Now an attacker who already has root-level code execution (or a forensic exploit running as the app) on a powered-on phone that was unlocked once since boot but is currently locked can ask the Keystore to decrypt the vault, as the app itself can. What does not change: the key is hardware-backed (StrongBox or TEE where present, reported by `KeyInfo`), non-exportable, bound to this device, never in backups (`allowBackup=false`), and the stored secrets are wrapped at rest. An attacker with only the stolen powered-off or never-unlocked phone, or with a disk image, still gets nothing. Anyone who can unlock the phone could always read everything. Genuinely sensitive actions (showing the recovery phrase, approving a new device) are gated by the app's own confirmation steps, not by the Keystore key.

**Migration.** On the first foreground start after the update, `SecureVault.migrateLegacy()` decrypts each blob with the v1 key (possible only while unlocked), re-wraps it with the v2 key, reads it back and compares, and only after every blob is verified deletes the v1 key. A locked phone just means "try again at the next start"; any failure leaves all blobs and the v1 key untouched; nothing is ever regenerated, so the identity cannot be lost or silently replaced. Blobs carry a flag byte: `2` = v2, `1` = written by an older version. The Encryption keys screen shows the real security level from `KeyInfo`
(StrongBox / TEE / software). If the Keystore key is invalidated, reads fail closed (`VaultInvalidatedException`) and the app asks for a recovery-phrase restore rather than minting a new identity. Backups are disabled (`allowBackup=false`), so keys are not in cloud backups.
Unverified: StrongBox/TEE reporting and the auth-bound mode have not been exercised on a physical device.

## iOS: what is different (written, not yet run on an iPhone)

The Dart code and the method channel `app.openfamily/keystore` are shared with Android; only the
native side differs (`app/ios/Runner/SecureKeyChannel.swift`). Nothing in this section has been
compiled or run: no Mac or Apple account was available (see `IOS_RELEASE.md`, "Verification status").

* **Secure Enclave limits.** The Secure Enclave can generate and hold only NIST P-256 keys, and
  only sign/key-agree with them. It cannot hold Ed25519 or X25519, and it does no symmetric
  encryption of bulk data. So, exactly like Android, the identity seed and the circle keys live
  in app memory while in use. What the Enclave protects is **one non-extractable P-256 wrapping
  key**. Secrets are wrapped with ECIES (`eciesEncryptionCofactorVariableIVX963SHA256AESGCM`,
  `SecKeyCreateEncryptedData`) under its public half and unwrapped with `SecKeyCreateDecryptedData`,
  an operation performed inside the Enclave. The wrapped blob is stored in the Keychain by
  `flutter_secure_storage` as before.
* **Honest level reporting.** `status` reads the key's real attributes: `secure_enclave` when the
  key's token is the Enclave, `keychain` when it is a software key (the Simulator, or an Enclave
  key generation that failed). The Encryption keys screen prints "Secure Enclave (dedicated security
  chip)" or "iOS Keychain, software key (no Secure Enclave)". There is **no StrongBox equivalent
  label**: Apple does not distinguish chip classes, and the app never claims "StrongBox" on iOS.
* **Keychain accessibility versus background uploads.** The location background mode seals and
  uploads fixes while the phone is locked. Encrypting needs only the public key, which needs no
  unlock. Decrypting the seed needs the private key. So the wrapping key and the wrapped blobs use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (usable after the first unlock since boot,
  also while locked), **not** `WhenUnlocked`. The trade-off is stated plainly: while the phone is
  locked but has been unlocked once since boot, code running as the app (and a forensic tool with
  the passcode-derived class key) can use the key. Before the first unlock after a reboot nothing
  can be read; background sealing then fails closed and fixes are parked, never sent in plaintext.
  The stricter mode, `recreateKey(requireUserAuth: true)`, uses `WhenUnlockedThisDeviceOnly` plus
  `.userPresence` (Face ID/Touch ID or passcode on every use). It cannot work for background
  sealing, which is why it is opt-in and off by default.
* **No iCloud, no backup, no new-phone migration.** Everything is `ThisDeviceOnly` and
  `kSecAttrSynchronizable = false`. A restored backup or a new phone does **not** carry the
  wrapping key; the wrapped blobs then cannot be decrypted, `decrypt` reports `invalidated`, and
  the app fails closed and asks for the recovery phrase (same as Android). The vault uses its own
  Keychain service (`openfamily_e2ee`), so `names()` never lists tokens.
* **Reinstall.** iOS keeps Keychain items when an app is deleted. On the first launch of a fresh
  install (no marker in `UserDefaults`, which are deleted with the app, and only once protected data
  is available) the app deletes the wrapping key and its own Keychain services, so a reinstalled
  app starts clean instead of inheriting the old identity.
* **Screen protection is weaker than Android.** Android's `FLAG_SECURE` blocks screenshots and
  the recents thumbnail. iOS lets an app do neither for screenshots. `ScreenProtector.swift`
  hides the window behind a blur while the screen is being recorded, mirrored or AirPlayed
  (`UIScreen.isCaptured`) and when the app goes to the app switcher. A plain screenshot of the
  recovery phrase is possible on iPhone; the phrase screen already tells the user to write the
  words on paper.
* **APNs wake-ups are best effort.** The content-free `e2ee_wake` is a silent `content-available`
  push. iOS throttles these, ignores them after the user force-quits the app and in Low Power
  Mode, and gives no delivery guarantee. Correctness does not depend on it (pull on open,
  sequence numbers, idempotent ids); only the latency of event notifications does. There are no
  background-fetch or BGTask jobs to compensate.
* **Unverified:** key creation in the Enclave, the access-control flags, ECIES round trips and the
  `auth`/`locked`/`invalidated` error mapping, the Face ID/passcode mode, the reinstall wipe and
  the blur have not run on any device or Simulator. The Simulator test (`RunnerTests.swift`) will
  cover only the software-key path once the macOS CI job runs.

## Phase 2 requirements (original list; all are implemented, see the next section)

1. Geofence, arrival/departure, "nearby" and driving state are computed **on the sender's phone** and sent as end-to-end encrypted events (purpose `event`) to authorised members. The server relays opaque payloads plus a **wake-up push that carries no location, name or place**; the receiving app decrypts and raises a **local** notification.
2. Android background limits: foreground service with the location type, Doze and App Standby buckets, OEM battery killers; follow the existing `docs/testing/PHYSICAL_DEVICES.md` evidence plan before relying on on-device geofencing.
3. Delivery: store-and-forward with per-sender **sequence numbers**, **idempotent event ids**, deduplication, and catch-up on app open; delayed or lost pushes must never lose an event.
4. Offline phones queue encrypted events with **signed timestamps** (Ed25519 by the device key); receivers tolerate **clock skew** and reorder by sequence number.
5. Events carry the **epoch**; phones keep previous epoch keys to decrypt backlog and accept events from an epoch only when its wrap chain is valid; ignore any epoch lower than the highest seen for a circle unless it is backlog from a held key.
6. Server rejects plaintext location/place/event writes for `e2ee_mode = 'private'` (downgrade rule above).
7. Sender authenticity inside a circle: all members share the key, so AEAD alone does not prove who sent a payload. Phase 2 should sign payloads with the sender device key (Ed25519) and carry the signature inside the plaintext.
8. Metadata minimisation (below) must be implemented with the first encrypted payload.

## Phase 2: the encrypted channel (implemented)

Migration `000155_e2ee_channel`. Code: `backend/internal/handlers/e2ee_channel.go`, `backend/internal/e2ee/item.go` (reference implementation of the item envelope),
app `app/lib/services/e2ee/private_{channel,places,history,runtime}.dart`.

### Item format (frozen, vectors in `testdata/vectors.json` section `item`)

```
body     = JSON (UTF-8), purpose specific (below)
envelope = 0x01 || seq(8 BE) || ts_ms(8 BE) || sig(64) || body
sig      = Ed25519(sender DEVICE key, "OFE2EE2-ITEM\0" || circle_id || epoch(4) || device_id ||
                   len(purpose)(1) || purpose || seq(8) || ts_ms(8) || body)
payload  = Seal(circle_key, circle_id, epoch, device_id, purpose, Pad(envelope))     (phase-1 format 0x01||epoch||nonce(24)||ct||tag)
```

* All members share the circle key, so AEAD only proves "a member". The signature proves WHICH approved device sent it, and it covers circle, epoch, device, purpose, `seq`, time and body, so a member cannot forge a position from somebody else's phone, and the server cannot renumber, re-purpose or re-epoch an item.
* `seq` is per (circle, sender device), starts at 1 and only grows. `ts_ms` is the sender's clock (UTC ms); the server never sees it.
* Padding uses `Pad` buckets: 256, 512, 1024, 4096, then multiples of 4096. A normal fix is exactly 256 bytes of plaintext, 301 bytes of ciphertext.
* Nonces are random 24 bytes per item; the HKDF subkey is per (circle key, circle, epoch, purpose), so a purpose can never decrypt as another.

Bodies (keys are short on purpose; unknown keys are ignored):

| purpose | body | notes |
|---|---|---|
| `fix` | `{lat, lon, acc?, alt?, spd?, hdg?, bat?, mo?}` | live position. Cap: bucket 1024 |
| `event` | `{k:"place", a:"enter"|"exit", pid, name, at}` | arrival/departure from the sender's phone. Bucket 1024 |
| `place` | `{id, name, lat, lon, r, type, addr, en, ex, del}` | newest signed `ts` per `id` wins; `del:true` is a tombstone. Bucket 4096, at most 2000 per circle |
| `history` | `{pts:[[ts_ms, lat, lon, acc?], ...]}` | sealed track chunks for retention and re-install. Up to bucket 69632 |
| `checkin` | `{k:"sos"|"help"|"checkin", lat?, lon?, note?}` | position of an alert, which the server withholds from its plaintext alert. Bucket 1024 |
| `chat` | implemented: sealed chat, see `E2EE_CHAT.md` | phone key line only, bucket up to 8192, TTL 30 days (`E2EE_CHAT_TTL_DAYS`) |

### Server API (ciphertext only)

| Route | Who | Purpose |
|---|---|---|
| `POST /circles/{id}/e2ee/batch` | live member, own approved uploader device. Also accepts the device ingest key (`X-Device-Key`) so the headless background reporter can upload | body `{sender_device_id, items:[{seq, purpose, epoch, size_bucket, ciphertext(b64)}]}`, 1-50 items. Reply `{results:[{seq, status:"stored"|"duplicate"|"rejected", id?, error?}]}`; 201 if anything stored, else 200 |
| `GET /circles/{id}/e2ee/items?after=&purpose=a,b&limit=&device_id=&as_device=` | live member owning at least one ACTIVE, APPROVED key in the circle (any kind) | `{items:[{circle_id,id,device_id,seq,purpose,epoch,size_bucket,ciphertext,received_at}], next_cursor, has_more}`. `limit` 1-500 (default 100). `as_device` makes the check use that key only (a revoked or foreign key id is 403) |
| `DELETE /circles/{id}/e2ee/items?scope=mine|circle&purpose=&before=` | member (own uploads); `scope=circle` circle admin | erase ciphertext |
| `POST /circles/{id}/e2ee/purge-plaintext` | circle admin, private circles | delete the legacy plaintext places/geofences/bubbles after the admin phone re-sealed them |
| WebSocket `/ws/stream` | any member | frame `{"type":"e2ee_item", ...same fields as an item above...}` for every stored item of the member's circles (including the sender's other phones) |
| `GET /circles` | member | additive `e2ee_mode` and `e2ee_epoch` per circle |

Server rules: sender device must belong to the caller (anything else is 404, no probing), be active, `can_upload` (phones always; `web`/`service` keys only if registered with `can_upload:true`; the recovery kind never) and approved in the circle (transitive approval, `e2ee_device_approved`).
Per item: purpose known, `1 <= epoch <= circle epoch` (older epochs are allowed so queued backlog can still be delivered), `seq` in `1..2^53`, `size_bucket` a Pad bucket within the purpose cap, ciphertext length exactly `1+4+24+bucket+16`, header version and epoch equal to the declared epoch.
Idempotency: `UNIQUE (circle_id, device_id, seq)`, a repeated upload answers `duplicate`. Inserts for one circle are serialised by an advisory lock so cursor ids become visible in order (a poller never skips an id).
Rate limits: 120 batches/min and 240 pulls/min per user, 50 items/batch, 2 MiB body, 2000 sealed places per circle.
Metadata minimisation: `received_at` is truncated to the minute; no user id is returned (only the device id; the client maps it to a person through the verified key log); no coordinate, name or size finer than a bucket exists in any column; request and audit logs record counts only (regression test scans captured logs and audit rows for coordinates, ciphertext and key bytes).
Device kinds: `device_keys.kind` is now `device | recovery | web | service`. `web` and `service` keys must be cross-signed by an existing key of the same user (never a root), at most 5 per user, and go through the same approval chain, so a replacement/unvouched viewer waits for a circle admin exactly like a replacement phone.

Retention: `fix` and `event` expire after the live window (default 48 h, `E2EE_LIVE_TTL_HOURS` 1-720); `history` after the sender's personal location retention (`users.location_retention_days`, else the deployment `LOCATION_RETENTION_DAYS`); `checkin` after 30 days; `place` never (until erased or the circle is switched off). Expired rows are invisible immediately and purged every 15 minutes. Personal retention changes also purge sealed history older than the window (by coarse receive time). "Delete my location history" (`DELETE /me/locations`) also erases the caller's sealed items in every circle (places stay). Switching a circle off deletes all of its items. Removing a member does not delete what they uploaded (it is the circle's history), but they lose pull access at once.

### Enforcement (downgrade protection)

* A user whose live circles are ALL private cannot send plaintext locations: `POST /locations`, `POST /locations/batch` and `POST /trips/sensor-events` (events) answer 409 `{code:"e2ee_private_circle"}` before anything is written.
* Server geofencing, bubbles and place presence skip a private circle. `POST/PATCH /family/places`, geofence create/update answer 409 for a private circle, and a database trigger (`e2ee_refuse_plaintext` on `places`, `geofences`, `bubbles`) refuses any other path. Deletes stay allowed (`purge-plaintext`).
* SOS / help / crash alerts of a private family circle are still created and pushed (they must not fail), but WITHOUT coordinates and without the `member_positions` fallback; the reply carries `position_withheld:true`. A check-in-to whose recipients do not all share a standard circle with the sender is stored without coordinates (`X-Position-Withheld: 1`). The phone sends the position as a sealed `checkin` item. The SMS/Twilio contacts therefore cannot be told the position.
* Push for Private circles is a content-free wake-up: silent command `{"type":"e2ee_wake","circle_id":"..."}`, throttled to one per circle per 10 s, only for `event`, `checkin` and `chat`. The app pulls, decrypts and raises a LOCAL notification ("Alex arrived at Home"). Live `fix` items are not pushed.
* `circles.Authz` (`SharedWith`, `SharingCircles`, `OwnAndSharingCircles`, `LocationVisibility`, `MemberCircles`) treats a private circle as "not sharing plaintext", so a private circle is never a path to anyone's plaintext position, in REST snapshots or WebSocket fan-out.

### Several circles: the multi-circle rule

A location belongs to the person, not to a circle, and the legacy plaintext tables are per user. The rule, enforced by the server and followed by the app (`uplinkModeFor`):

| User's circles | Phone sends | Server accepts plaintext? |
|---|---|---|
| none private | plaintext only (exactly as before) | yes |
| all private | sealed copy per private circle, NO plaintext | no, 409 |
| both | plaintext (feeds the standard circles only) AND one sealed copy per private circle | yes, but it is never visible through a private circle |

So a private circle's data is never written in plaintext, but a person who also sits in a standard circle still has a plaintext position there (and the platform admin map and Dawarich see that person through the standard circle). To keep a person entirely out of plaintext, all of their circles must be private. The Private-circle screen says this.

### What is available in a Private circle

| Feature | Private circle |
|---|---|
| Live map, member list, battery, motion | yes (phones decrypt `fix`) |
| Day history / trail | yes, from the phone's decrypted store (7 days, sealed `history` chunks rebuild it after a re-install) |
| Places and arrival/departure alerts | yes, evaluated on the sender's phone (accuracy gate 100 m, 60 s debounce, pending/reversal rules ported from `geofence_eval.go`) |
| Check-in, help, SOS | yes; position travels sealed; the server and SMS contacts do not learn it |
| Chat | end-to-end encrypted on the phone key line, for every member whatever their processing lane (`E2EE_CHAT.md`) |
| Trips, driving report, weekly summary | NOT available (explicit placeholder) |
| Admin map, device last-known positions | NOT available from the server (it holds none). A member (including a platform admin who is a member) can read them in the browser viewer after one of their own phones approved that browser |
| Dawarich export | Through the `e2ee-bridge` only (phase 3); the built-in server export skips Private circles |
| Server place names / geocoding, crash scoring, live-share links, "request location" | NOT available (the server cannot read positions) |
| Bubbles | NOT available |

### App behaviour

* Sealing: `ChannelSealer` takes the newest held epoch key (never falls back to plaintext; no key means nothing is sent for that circle), allocates `seq` persistently, signs, pads, seals. Items are queued sealed (`SealedQueue`, 2000 items, ordered, 48 h except events/places), uploaded in batches of 50 with jitter, idempotent on retry.
* Receiving (`ChannelReceiver`): header epoch must match the declared one; key for the epoch must be held; AEAD; padding; the signed `seq` must equal the relayed one; the sender device must be a known, ACTIVE (or, for older items, once active) and APPROVED, non-recovery device of a current member (refreshing the circle state once); Ed25519 signature; signed time at most 10 min in the future; duplicates dropped by a per-device window (512); **epoch rollback**: a device never returns to an older epoch for fresh items, and circle-wide an item sealed under an epoch below the highest seen is refused after a 10-minute grace unless its signed time precedes the moment the newer epoch was first seen (backlog). Items whose key or sender record is not here yet are kept (deferred, 200) and retried after the next key sync.
* Epoch changes mid-flight: old keys are kept, so queued backlog opens; new items use the new epoch; the server accepts any epoch up to the current one.
* Catch-up: cursor per circle (`catchUp`) on app open, resume, push wake-up and socket reconnect; the cursor only advances after a page was handled.
* Battery: fixes reuse the existing adaptive cadence; sealing adds one signature and one AEAD per fix; uploads are batched (2 s + jitter) and `history` is cut every 300 points or 20 minutes; no extra wake-ups.
* Background isolate: the headless isolate seals with the vault when it can and uploads with the ingest key; if the vault is unreachable there, fixes are parked in app-private storage (like the existing location outbox) and sealed with their original timestamps when the app next runs. They are never sent in plaintext.

### API contract for phase 3 (web viewer and Dawarich bridge)

Both are *device members*, not special server roles.

1. The owner (a member) registers the key: `POST /e2ee/devices` with `kind:"web"` or `kind:"service"`, cross-signed by one of the owner's phones (`actor_device_id`, `log_signature`), optional `can_upload:true` for a bridge that must write. It is approved by the existing transitive rule; a circle admin approval (`POST /circles/{id}/e2ee/approvals`) is needed if the owner's chain is not approved.
2. A phone of the owner (or any admin phone, as publisher) wraps the circle key of each epoch to the new key like to any device (`POST /circles/{id}/e2ee/wraps`); the viewer/bridge unwraps with its X25519 key (`GET /circles/{id}/e2ee/wraps?device_id=`). The server never sees a key.
3. The device authenticates as the owner's account (session or API token) and pulls: `GET /circles/{id}/e2ee/items?after=<cursor>&as_device=<its key id>&purpose=fix,history,event,place&limit=500`, persisting `next_cursor`. For live data it subscribes to `/ws/stream` and handles `e2ee_item` frames; on reconnect it resumes from its cursor. The pull is ciphertext only.
4. It verifies each item with `OpenItem` (Go, `internal/e2ee/item.go`) or the Dart equivalent: AEAD, signed `seq` equals the relayed `seq`, signature by the sender device's Ed25519 key taken from `GET /circles/{id}/e2ee` (`members[].devices[]`, `approved:true`) and checked against the key log (`GET /e2ee/log`). It applies the same epoch/duplicate rules as `ChannelReceiver`.
5. A read-only viewer never uploads (the server answers 403 `device_read_only`). A bridge that exports to Dawarich decrypts `fix` and `history` locally; the plaintext leaves the bridge only toward the user's own Dawarich.
6. Erasing: `DELETE /circles/{id}/e2ee/items` as above; revoking a key (`DELETE /e2ee/devices/{id}`) removes its wraps and flags the circle for a new epoch (an admin phone rotates).

## Phase 3: web viewer and Dawarich bridge (implemented)

Goal: let the admin web panel keep showing a Private circle and let Dawarich keep receiving points, **without the server ever seeing a plaintext**.
Both are device members under exactly the phase-2 rules (see the API contract above); the server needed no new routes. What changed:

| Part | Where |
|---|---|
| Browser viewer (JS crypto, key log verification, decrypt, map) | `web/src/e2ee/{core,verify,keystore,viewer,controller}.ts`, page `web/src/pages/PrivateCirclesPage.tsx` ("Private circles" in the sidebar), tests `web/test/*.test.mjs` |
| Dawarich bridge | `backend/cmd/e2ee-bridge/` (README there), `backend/internal/e2ee/verify.go`, `deploy/e2ee-bridge/` |
| Phone approval and revoke | `app/lib/screens/viewer_approval_screen.dart` (Private circle settings, "Approve a viewer or bridge") |
| Server | admin "Encryption keys" page labels web viewers and bridges; tests in `handlers/e2ee_phase3_db_test.go`. No new route, so no new authz-matrix entry |

### Pairing (QR/paste, no camera scanner)

1. The viewer/bridge creates its keys and shows a **request code**: padded base64url of JSON `{u, d, e, x, b, k, n}` (account id, device id, Ed25519 and X25519 public keys, binding signature, kind `web`|`service`, name). This is the "link another phone" request plus `k` and `n`.
2. On a phone of the same account: Private circle, **Approve a viewer or bridge**, paste the code. The phone shows name, kind, short fingerprint and the 12x5 digits; the user compares them with the viewer's screen and approves. The phone returns an **approval code** `{a: phone device id, s: Ed25519 signature}` (the existing cross-signature over the register log action).
3. The viewer pastes the approval code and registers its PUBLIC keys (`POST /e2ee/devices`, `kind:"web"|"service"`, `can_upload:false`). The kind is not part of the signed log action (frozen format), so the phone and the viewer both display it, but it is not cryptographically bound; a web key cannot upload anyway unless registered with `can_upload`.
4. The phone's existing pending-queue logic wraps every held circle key to the new key automatically (it is cross-signed by the user's own phone), on the next time that phone opens the circle encryption screen. The viewer then unwraps with its X25519 key. **An approved viewer therefore receives all Private circles of that account**, current and previous epochs held by that phone. The approval screen says so.
5. Revoking: from the phone ("Connected viewers", then Revoke, then an admin phone rotates the epoch automatically) or from the viewer itself ("Revoke this viewer", self-signed). Revocation removes its wraps and flags the circle; **a new epoch is needed before it stops being able to read new data**, and data it already received stays readable by it.

Note (documented, unchanged phase-1 behaviour): the circle's publisher phone wraps to **another member's** cross-signed web/service key automatically, the same as for that member's second phone. Admins can see all members' viewers in the circle screen.

### Web viewer: keys and custody

Library: **`@noble/curves`, `@noble/ciphers`, `@noble/hashes`** (MIT, no dependencies, audited, widely deployed, pure JS so it runs in any browser and in Node for the tests). Alternatives: libsodium.js (ISC, WASM, larger, an extra supply-chain surface and a CSP `wasm-unsafe-eval` for no benefit at 300-byte payloads) and WebCrypto alone (has no XChaCha20-Poly1305, no Argon2). WebCrypto is used where it can add protection: Ed25519 and X25519 private keys. License check: MIT is AGPL-compatible (`docs/THIRD_PARTY_LICENSES.md`). Not yet covered by an external review of this integration.

| Mode | Private key | Circle keys at rest | Trade-off |
|---|---|---|---|
| `device` (default when the browser supports WebCrypto Ed25519/X25519) | generated as **non-extractable** `CryptoKey`s, stored as such in IndexedDB; script can sign/agree but cannot read the bytes | AES-GCM with a non-extractable `CryptoKey` | someone with access to the browser profile on disk may be able to copy the opaque key store; script running in the page can still *use* the key while the page is open |
| `passphrase` | 32-byte seed (same derivation as phones) sealed with XChaCha20-Poly1305 under a key from **Argon2id** (64 MiB, 3 passes, p=1) of the passphrase | same, with a second key from the same Argon2 output | unlocked keys are extractable by script while the page is unlocked; strength depends on the passphrase |
| `session` | memory only | memory only | disposable viewer, nothing persists; revoke it afterwards |

Never: private keys or circle keys in `localStorage`/`sessionStorage`, in a URL, or sent to the server. Decrypted positions are held in page memory only (nothing decrypted is written to storage); the retention windows (`fix` 48 h, `history` per personal retention) bound what a fresh page load can pull back. The admin panel CSP (`script-src 'self'`, no inline/eval) applies to the viewer.

### What the browser verifies

`core.ts`/`verify.ts` are line-by-line ports of the Go reference and of `e2ee_trust.dart`, tested against the **same** `testdata/vectors.json` (identities, fingerprints, digits, binding, wrap blob and signature, commitment, sealed payload, padding, log action and entry hash, item payload) plus negative tests. The recovery-phrase vectors are not ported (a browser viewer has no recovery identity), and the safety-number vector is not used (a viewer does not compare people). Per sync the viewer: verifies the whole transparency log from a pinned head (hash chain, genesis, signatures, redacted entries, rollback/fork/gap; the head is pinned in IndexedDB and a failure stops the viewer with a loud error), verifies each wrap (wrapper signature, signed epoch record, AAD, key commitment) and each item (AEAD, relayed seq equals signed seq, approved non-recovery sender whose registration chain verifies, Ed25519 signature, signed time not 10 minutes in the future, per-device duplicate window, epoch rollback). Items whose key or sender is not known yet are deferred and retried after the next sync.

### Dawarich bridge

A `service` device member run **off the server host** (`backend/cmd/e2ee-bridge/README.md`): `enroll` prints name + fingerprint and a request code, the user approves on the phone, `enroll --approval` registers, `run` pulls ciphertext (`as_device`), verifies and decrypts like a phone and POSTs to Dawarich with the same GeoJSON mapping and per-user key semantics as the server-side export. It keeps its own cursors and de-duplication (per-device last sent point and a startup query of Dawarich's newest point), stops cleanly (exit 3) when its key is revoked or no longer approved, and never logs coordinates. **Whoever can read the bridge's key file or memory can read the circle**: the bridge host is inside the trust boundary.

### Threat model of the web viewer (honest)

* **Defends against:** a stolen or breached database, a curious operator who does not modify the web app, a network observer, and the server inventing viewers (a viewer needs a phone's cross-signature and a wrap from a member's phone; the server cannot produce either).
* **Does not defend against a malicious or compromised origin.** The viewer is JavaScript delivered by the same server whose database it is meant to distrust. An operator (or anyone who can alter the files in `backend/web/dist`, the TLS terminator, a CDN or a compromised update path) can ship a viewer that exfiltrates keys or plaintext. The same holds for XSS in the admin panel, a malicious browser extension, and malware in the browser. This is the fundamental limitation of browser E2EE; the phone app's code is signed and installed, the web app's is fetched every time.
* **Mitigations present:** strict CSP without inline or eval scripts; keys non-extractable in `device` mode; passphrase and session modes; the page shows SHA-256 hashes of the scripts and styles it is running so a careful user can compare them with `sha256sum` of a release they obtained elsewhere (this is computed by the page itself, so it is only a check if the comparison value comes from outside the server); the viewer is a visible, revocable entry in the key list on every phone and in the admin "Encryption keys" page, and is in the key log. Not present: subresource-integrity pinning of the entry document, a reproducible-build attestation, a separately hosted viewer origin. If your threat model includes a hostile operator, **use the phone app only and do not approve a browser viewer**; a self-hosting operator who is also the only user is the case where the viewer's trust is reasonable.
* **ADMIN_LOCATION_ACCESS is unchanged.** A platform admin sees no location of a Private circle unless THEIR OWN account is a member and THEIR OWN browser key was approved by THEIR OWN phone; the server cannot grant that. The server-side admin map and history endpoints still return nothing for private circles (the server holds nothing).
* **Bridge host:** see above; additionally the bridge holds an Orbitly refresh token for the account, which gives API access with the account's rights (not the circle key).

### How viewers and the bridge check devices against the log (authorization rules)

The circle state is served by the adversary, so a viewer or bridge accepts a wrapper, an epoch publisher or an item sender only when ALL of these hold (Go: `AuthorizeSender`/`AuthorizeWrap` in `internal/e2ee/verify.go`; JS: `web/src/e2ee/verify.ts`; both fail closed and are tested in parallel):

1. the device is listed in the state with the same Ed25519 key, owned by the member it is listed under (`device.user_id == member.user_id`), approved, not revoked, not a recovery key, and its registration signatures and binding verify;
2. the whole log is verified from entry 1 (hash chain, signatures, pinned head: rollback/fork), and the device's registration appears in it field for field;
3. **key binding in the voucher chain.** A log entry only proves that *some* key signed it. The index therefore records the one Ed25519 key each acting device id has used; a device id that appears with two keys, or is registered twice, makes the whole log untrusted. Every hop of the chain must use the voucher's real key: the key in the hop equals the logged key of that device id and the key the state lists for it. **Every voucher, root included, must be listed in the state**, belong to the same user, have a registration that verifies (so its listed key hashes to its fingerprint) and have that registration in the log field for field (so the fingerprint is the one recorded when it was really registered). A chain through a voucher that is no longer listed is refused. Consequence: if a middle device (for example a second phone) is removed, viewers it vouched for stop being trusted until re-approved. That is deliberate (fail closed);
4. **retired vouchers cannot mint devices.** The log retires a key by an explicit revoke, by a rotation (the rotate entry retires its actor, the OLD key; the server writes no separate revoke), or by a reset (a reset root retires every earlier key of that user; likewise no separate entries). A voucher retired at a sequence number *before* the vouched registration invalidates the chain; a registration that predates the retirement stays valid (but an honest state no longer lists the retired voucher, so it fails closed as in 3). A device retired in the log is refused even if the state still lists it;
5. the epoch publisher is a circle admin whose enable/epoch entry is in the log; the wrapper is the publisher's user or the recipient's own device;
6. **own-account anchor.** At pairing the viewer/bridge pins the approving phone's key from the approval signature the user carried from the phone (`PinApprover` / `pinApprover`: the server's registration record must reproduce that exact signature under the key it reports, so the key cannot be one the server chose). Every device of the verifier's OWN account that acts as sender or wrapper must chain to that phone (the phone is on its chain, or both chains end at the same root); with no pin they are refused. A circle key wrapped by such a device is `anchored` (that phone verified the epoch record and commitment before wrapping). A key wrapped straight by another member's admin is accepted as `member`-trusted and flagged in the UI/logs: that person's first key is trusted on first use.

**Trust audit: what is bound by what.** Every field that influences a trust decision, and where its authenticity comes from. "Signed" means covered by an Ed25519 signature or a hash the verifier recomputes; "server" means only asserted by the server.

| Field | Used for | Bound by | Residual |
|---|---|---|---|
| Item: circle, epoch, sender device, purpose, seq, ts, body | everything shown | AEAD key + AAD, and the sender's Ed25519 signature | none beyond the circle key holders |
| Item: `id`, `size_bucket`, `received_at` | cursor/paging only | server | no trust decision |
| Sender's Ed25519 key | verifying items | listed key = fingerprint-bound by its registration; registration in the log; chain to a self-registered root with every voucher listed, same user, logged, key-consistent; own account: chain to the pinned approver | other members' roots: first use |
| `approved` flag on a device | accept sender/wrapper | **server** (transitive approval is computed server-side; the matching admin approval entries are in the log but not re-derived in the client) | a hostile server can mark an unapproved key approved; without the circle key it cannot forge items, so the residual is a malicious member whose replacement key an admin should have approved |
| `kind`, `label`, `initial`, `created_at` | display; `kind=recovery` rejection | **server** (kind is not in the signed log action) | a recovery key could be labelled `device`; it still needs a log registration and a chain |
| `role` (admin) of the publisher | accept an epoch | **server** | a non-admin member the server calls admin could publish an epoch; it must still be a member whose key chains, and the circle key is what protects data |
| Membership (who is in the circle) | which devices are looked at | **server** | a fake member must still present a chained, logged key; it cannot read data without the circle key |
| Registration: ed/x keys, fingerprint, binding signature, vouching signature, action, voucher id | chain walk | fingerprint hash of keys; binding signature; vouching signature over (action, user, voucher, subject, fingerprint); log entry equality | none |
| `registered_by_ed25519_pub` | verify the vouching signature | **server field, but** must equal the one key the log ever shows for that voucher id and the listed, fingerprint-bound key of that voucher | none while the log is consistent |
| Log entry: action, user, actor id, circle, subject, epoch, ref, signature | all of it | signature and hash chain; pinned head (rollback/fork) | split view; redaction (below) |
| Log entry `actor_ed25519_pub` | verify its signature | **not in the signed message**; bound by one-key-per-device-id across the log plus the voucher/listed checks | a device id seen for the first time in the log is taken at its logged key |
| Epoch record: publisher ids/key, commitment, signature | accept a key epoch | signed log action; equality with the log entry; commitment recomputed from the unwrapped key | publisher is TOFU unless the wrap came from our own account |
| Wrap: epoch, recipient, wrapper ids, blob, signature | open a circle key | AAD binds circle/epoch/recipient/wrapper; wrapper signature; commitment check | `wrapper_ed25519_pub` is checked against the listed key |
| Approver (our own phone) | root of trust for our account | approval signature carried by the user, reproduced by the server's record | none for our account |

Closed in this pass: a listed voucher is now bound to its logged fingerprint; rotation and reset retire keys; own-account devices are anchored to the approving phone (the server alone could previously add a second root to the user's own account). **Not closed:** other members' first keys (first use, as on a phone before safety numbers are compared; the viewer has no out-of-band verification UI), the server-asserted `approved`/`role`/membership flags above, split-view logs, and redacted revocations.

**Redaction and withheld revocations (honest limit).** The log redacts entries of people the reader shares no circle with. The server never redacts a revoke of a co-member's device for an honest reader (test: `TestE2EELogNeverRedactsCoMemberRevokes`), but a *malicious* server can redact anything, and a verifier cannot tell a redacted revoke from a redacted unrelated entry. What the design does and does not prevent: the hash chain and the pinned head make the history immutable (a redaction is the same entry hash in every view, so it cannot be applied selectively over time without a fork a pinned reader sees); they do NOT show what a redacted entry contained, and a verifier cannot prove the absence of a hidden revoke. A positive proof of "still trusted" does not exist in this log format. The residual effect is bounded: a device whose revoke is hidden is still accepted as a *sender* by that verifier, but it was removed from the next epoch (the revoke sets a re-key flag and honest phones do not wrap new epochs to it), so it cannot produce items under a new epoch key; it can only forge under keys it already held, for as long as a verifier keeps accepting that old epoch (epoch-rollback rules apply). Closing this fully needs an authenticated "revocation list" feed or log gossip, which is out of scope.

### Phase-3 limits and unverified items

* Items from a phone key that was revoked before a viewer/bridge first looked cannot be verified (the circle state lists active keys only) and are dropped.
* The viewer is a snapshot-and-stream tool: it does not persist decrypted history, and `history` chunks are limited by the sender's retention.
* Not exercised: a real Dawarich instance, a physical phone, the browser pages in several real browsers (Node 22 and the bundle build were exercised; the UI was not click-tested), and WebCrypto Ed25519/X25519 in Safari/Firefox ESR. Browsers without them fall back to the passphrase mode.
* The viewer cannot upload; a read-only web key cannot send positions. The viewer does not show chat (encrypted chat is read in the phone app, `E2EE_CHAT.md`).

## Trusted-server mode (the Orbitly server as a member device)

Status: implemented as an **opt-in** per instance (token) and per circle (every member's signed consent). Off by default; a default install, and every Private circle without an approved server device, behaves exactly as in phase 2.

### Why this exists, and what it is NOT

The instance owner decided: *"make the server part of the encryption; the Dawarich server is on the same network so it doesn't matter."* The owner trusts their own server host, and wants the admin map, history, Dawarich export and server place alerts back for Private circles.

This mode therefore **gives up** the central phase-2 promise for the circles that use it: **the server can read their locations and keeps plaintext copies in its database.**
The circle is labelled "Server can read (trusted server)" in the app instead of "End-to-end encrypted", and every dialog says so.

What it still protects against: a leaked or stolen **database dump or backup of ciphertext/keys-less data**, a **network observer** (the channel stays sealed end to end up to the server device), and any **un-consented** use (the server reads a circle only while every member's phone has signed for it). Note that plaintext copies in the database are *also* in dumps and backups: for these circles that protection no longer exists for the data the server already ingested. It does **not** protect against a compromised server host, its operator, its administrators with database or file access, or its backups of the plaintext tables.

### Design

The server is a **device member**, not a special role, using the same machinery as the web viewer and the Dawarich bridge:

* A new device kind `server` ("Orbitly server"). It is registered with `POST /e2ee/devices` like a bridge: cross-signed by a phone key of its owner's account, never `can_upload`, never rotatable (revoke and enroll again).
* It runs as a **sidecar process**, `e2ee-bridge` in server mode (`backend/cmd/e2ee-bridge`, compose service `e2ee-server-device`, profile `e2ee-server`), **not** inside the API process and **not** in Postgres. Its identity seed and the circle keys live in a `0600` file in a Docker volume (optionally sealed with Argon2id + XChaCha20-Poly1305 under `E2EE_SERVER_DEVICE_PASSPHRASE`). The database only ever holds its public key.
* The sidecar reuses the bridge's verified-trust engine unchanged: key log verification and pinning, `AuthorizeWrap`/`AuthorizeSender`/`PinApprover`, wrap and key-commitment checks, item AEAD + signature + sequence/replay/rollback rules. A circle whose log does not verify stops the sidecar (exit 4), as for the bridge.
* It hands each verified plaintext position to `POST /internal/e2ee/ingest`. That endpoint is **not a user route**: it needs the server-device bearer token (`E2EE_SERVER_INGEST_TOKEN`, at least 32 characters, shared only between the API and the sidecar; compared in constant time; `404` while unset). A user JWT never works there.
* The ingest writes into the **normal tables** (`locations`, `member_positions`) tagged `source='e2ee_server'` and `locations.e2ee_circle_id`, then triggers the same post-commit work as a plaintext fix (geofence/bubble evaluation, battery alerts, live fan-out). Admin map, history, trips, the driving report, the weekly summary and the server-side Dawarich sync therefore work without further changes.

### What binds the server device to the phones' consent

`circles.e2ee_server_member` is **not a stored toggle**. It is the SQL function `e2ee_server_member(circle)` (migration 000165), true only while ALL hold:

1. the circle is Private;
2. the pinned server key (`e2ee_server_device`, set only with the ingest token, only for an already registered `server`-kind key) is active, and approved by the existing transitive rule (its registration was cross-signed by a phone);
3. that key holds a **wrap of the circle's current epoch** (only a phone can produce a wrap; phones issue it only as described below);
4. its owner is a live member;
5. **every live member has a consent row** whose approver is an active phone key of that member (a member without a phone key cannot consent, so such a circle is never a server member);
6. **no key rotation is pending** (`e2ee_rekey_required` is false): a member leaving, a key being revoked or a consent being withdrawn closes the circle until an admin phone publishes a new epoch and the server key is wrapped again.

A consent is `PUT /circles/{id}/e2ee/server-consent` carrying an **Ed25519 signature made by the member's phone** over `"OFE2EE1-SERVERCONSENT\0" || circle || user || server device || server fingerprint` (frozen vector `backend/internal/e2ee/testdata/server_consent.json`, checked by Go and Dart). It names the circle, the person and the exact server key, so it cannot be moved to another circle, person or key. A session token alone cannot grant it. Withdrawing deletes the row and requests a new key epoch; a member leaving, a phone key being revoked, the server key being revoked (its wraps are deleted by the existing trigger), the circle going back to normal mode (consents are deleted by a trigger), or a new member joining (before they consent) each make the function false **at once**.

Defence in depth, so a stored row is not enough: the ingest endpoint re-derives the state and **re-verifies every consent signature in Go** against the member's phone key before writing; the sidecar independently verifies the consents it is shown against the key log (a consent only counts if its approver is a phone key that `AuthorizeSender` accepts) and does not even pull a circle until every member's consent verifies; the phones verify the same thing themselves before wrapping.

### "Trust this server by default" (admin recommendation)

An admin can switch on **Settings > Trust this server by default** (`PUT /api/admin/settings/e2ee-trusted-default`, audit-logged as `admin.e2ee_trusted_default_changed`; stored as `app_theme_settings.e2ee_trusted_server_default`, default off, no migration needed). It is **a recommendation only**:

* signed-in clients read it as `trusted_server_default` in `GET /e2ee/server-device`, and it is `true` only while the ingest token is set AND a server key is pinned;
* the app then preselects "Server can read (trusted)" when a circle is made Private (the honest warning stays visible, strict end-to-end is one tap away) and shows a dismissible, remembered-per-circle notice to members who have not consented, leading to the Trusted server screen;
* it **never** consents for anyone, never changes `e2ee_server_member()`, never touches the wrap rules: every member must still sign on their own phone and can decline or withdraw. Choosing "trusted" at turn-on only opens the Trusted server screen afterwards.

### Phone behaviour (Flutter)

* **Approve a viewer or bridge** shows a `server` request distinctly ("Orbitly server (can read the circle)") with its own warning. Approving only registers the key; it grants nothing.
* **Encryption keys > circle > Trusted server** shows the server key's name and fingerprint (compare it with the enroll command's output), who has allowed it (each signature re-verified on the phone), and the buttons *Allow the server to read this circle* (an explicit destructive-styled confirmation with the warning text), *Withdraw my consent*, *Give the server the circle key* (circle-key publisher, enabled only when every consent verifies locally) and *Delete my copies / all copies*.
* The server key is **never wrapped automatically**: `processPending` skips it, `confirmWrap` refuses it, and `_recipients` (epoch rotation) includes it only while `allowedServerKey` holds (pinned key, matching fingerprint, every consent verified). After a withdrawal the next epoch excludes it.
* The circle badge reads **"Server can read"** and the circle's toggle subtitle says so. The turn-on dialog of Private mode mentions the option and what it costs.
* Trips, the weekly summary and the other "server needs plaintext" screens are available again for a server-member primary circle.

### Lanes circles (per-member processing lanes)

For circles with per-member lanes (`docs/design/PRIVACY_PROCESSING.md`) the sidecar, and the Dawarich bridge in a circle with server assistance on, read only the **server line**: they hold the server key SK and never a circle key CK, ingest/forward only members whose own signed lane (checked against the key log) is `server`, and treat a CK wrap or an SK that reuses a CK as a security alarm (exit 7). The all-members consent of this section applies only to legacy circles. Details: `backend/cmd/e2ee-bridge/README.md`, "Lanes circles", and PRIVACY_PROCESSING.md section 20.

### Phase-2 enforcement, relaxed only where the server can read

`e2ee_plaintext_blocked(circle) = private AND NOT e2ee_server_member(circle)` replaces "private" in: the 409 on plaintext positions (`circleModes`), place/geofence/bubble handlers and the DB triggers, the geofence/bubble evaluators, the SOS/check-in position rules, and every `circles.Authz` visibility query. A circle **without** an approved server device is unchanged (the whole phase-2 test suite passes untouched, plus new negative tests). The legacy-plaintext purge refuses a server-member circle (its places are legitimate).

### Source of truth for place alerts (one per circle)

Places of a Private circle are sealed items that the phones evaluate on-device (unchanged). **The phones remain the single source of truth for arrival/departure alerts in a server-member circle.** The server evaluates geofences only for places that exist as *server* places (created through the admin web or API, which are allowed again). Do not define the same place in both worlds or you get two notifications. The sidecar does not import sealed places.

### One user, several circles

Positions are stored per user, not per circle, so the ingest is deliberately conservative: it stores a member's position only if the member has **no normal circle** (otherwise their phone already uploads plaintext to that circle and an ingest would leak a position the user shared in the Private circle into the plaintext table), only while they are sharing in this circle and not paused, only from an active, approved phone key of that user, and never from a user the endpoint cannot tie to the sending key.

### Revoking and purging

Revoking the server key (`e2ee-bridge revoke` or the phone) deletes its wraps, so the circle stops being a server member at once; ingest answers 403 immediately; the circle is flagged for a new epoch. Withdrawing a consent does the same without revoking the key. **The plaintext copies stay until purged**: `DELETE /circles/{id}/e2ee/server-copies?scope=mine|circle` (circle scope: admin) removes the tagged `locations` rows; a person's last-known position is changed only if it is exactly one of the purged points, and is then recomputed from their newest remaining location of any source (another server-member circle, a plaintext circle) or removed if none remains. Derived data that is not tagged (trips already built, geofence events, notifications already sent, history exported to Dawarich, backups) is not removed; Dawarich keeps what it received.

### Adversarial pass on the new trust path

| Question | Result |
|---|---|
| Can a circle admin, platform admin or any user session turn a circle into a server-member circle? | No toggle or admin endpoint exists. Needs the token-pinned key, a phone-made wrap and every member's phone-signed consent. Tests: `TestServerMemberNeedsPinWrapAndEveryConsent`, `TestServerMemberKeyBelongsOnlyToTokenHolder`, `TestServerMemberOneMissingConsentKeepsPhase2`. |
| Can a malicious member register their own `server` key? | They can register one (cross-signed by their own phone), but it is not the pinned device, so consent for it is refused (409), ingest refuses it (403), and phones never wrap it. A second `server` key cannot displace the pinned one while it is active. |
| Can the server (DB writer) forge consents? | It cannot produce a valid signature. It can plant rows: then the SQL function says yes (relaxing plaintext rules), but `TestServerIngestRejectsPlantedConsentRows` shows ingest still refuses, the sidecar ignores it, and phones do not wrap. **Residual:** a DB writer who also plants the pin and a wrap row can make the *visibility* rules treat a circle as server-member and can forge plaintext location rows for it (integrity, not confidentiality: it learns nothing it could not already learn from a server that holds the plaintext). This mode already trusts the server host. |
| Can a stolen ingest token read anything? | It reads nothing (the endpoint is write-only). With the token an attacker can inject positions for consenting members of server-member circles, and pin a registered `server` key. Treat the token like a database password (file or secret, 0600). Signing ingest requests with the device key would shrink this; not done, see decisions. |
| Can the sidecar be tricked into reading a circle without consent? | It verifies consents from the log-vouched phone keys itself and pulls nothing until all members' verify (`TestServerModeReadsOnlyAfterEveryMemberConsented`, `...IgnoresForgedAndMisboundConsents`). A hostile server hiding a member only makes that member's items unattributable (dropped). |
| Consent replay across circles, people, keys, or after re-enable? | Message binds circle, user, server device id and fingerprint (`TestServerConsentBindsEverything`, `TestServerConsentCannotBeForgedOrMoved`); the primary key includes the server device; consents are deleted when private mode ends or the member leaves (`TestServerConsentsEndWhenPrivateModeEnds`). |
| Does it leak a Private-circle position into a standard circle? | Not by the ingest: members of any normal circle are skipped (`TestServerIngestSkipsMembersOfStandardCircles`). |
| Logs and audit | Counts only, no coordinates, no token, no keys (`TestServerIngestLogsNoPlaintext`, `TestServerModeLogsHaveNoCoordinatesOrTokens`). |
| Does a default install change? | The token is empty, every new endpoint answers 404, `kind:"server"` registration answers 403, and the functions return false. The whole existing suite passes. |

Residual risks of this mode (in addition to the sections below):

* **Plaintext at rest** on the server (database, dumps, backups, replicas) for the consenting circles, for as long as the retention windows keep it; deleting it needs the purge.
* **The sidecar runs as the owner's account**: its login refresh token and its key are in the state volume. Whoever takes that volume (and the passphrase, if any) can read every consenting circle and act as that account until the key is revoked.
* **First-use trust of the fingerprint**: a member's consent is only as good as the comparison between the fingerprint on the phone and the one printed on the server host. The phone says so; it cannot check it for the user.
* **Consent is all-or-nothing per circle**: one member who does not consent keeps the whole circle sealed; one who withdraws closes it for everyone.
* A server-member circle's integrity rests on the database and on the token (see the table).
* Not exercised: a physical phone, a real Dawarich instance, a long-running docker deployment, background behaviour on Android.

## Security review (phase 2)

Checked:
* **Nonce reuse**: 24-byte random nonce per item from the OS CSPRNG; the subkey depends on (key, circle, epoch, purpose); a retransmission sends the same stored ciphertext, never a re-encryption under the same nonce with different data. Sequence numbers are never reused (persistent counter, allocated before sealing; a crash after allocation only leaves a gap).
* **AAD binding**: circle, epoch, sender device and purpose are in the AAD; the signature additionally binds seq, time and body. Tests: purpose swap, device swap, epoch rebind, seq renumber, tampered ciphertext, forged sender.
* **Replay**: duplicate window per device plus the high-water mark; a replayed old item is either a known duplicate or a genuinely late item with its original signed time (the map only moves forward by `ts`).
* **Downgrade**: server refuses plaintext for private-only users (409), drops coordinates from alerts, never stores places/geofences/bubbles for a private circle (trigger), excludes private circles from every visibility helper. The app never sends plaintext when sealing fails. Residual: a mixed user's plaintext exists on the server for the standard circles (by design, documented).
* **Metadata**: coarse timestamps, buckets, no user ids in items, no coordinates in logs or audit (tested), wake-up push carries only the circle id. The server still sees who uploads to which circle, how often and when (minute resolution), and bucket sizes.
* **Key handling**: no new key material; the Ed25519 seed is read from the vault only for the duration of a seal call and is never persisted by the new code; the on-device history, the history buffer and parked fixes are plaintext in app-private preferences, exactly like the existing location outbox (backups are disabled).
* **IDOR**: every route authorizes membership first (404 for non-members), sender devices must belong to the caller (404), pulls need an approved key (403). Tests cover foreign circle, foreign device, removed member, unapproved reset key, revoked key, read-only kinds. The authz matrix covers the new routes.
* **Abuse**: rate limits, item and body caps, place cap, size buckets per purpose; poison batches are dropped client-side after 20 failures.

Residual risks (new in phase 2):
* **A compromised or malicious member** (or a stolen unlocked phone) reads all positions and can send arbitrary signed items from its own device, including false place records or false arrival events for itself. Place definitions are not admin-only: any member can add or delete a sealed place (like the standard circle's rule for managers).
* **The server can withhold or delay** items, replay old ones (receivers dedupe and order by signed time) and drop the newest epoch; it cannot forge or alter them. Traffic analysis of upload times and sizes is possible.
* **Epoch rollback detection is heuristic** (per-device monotonic rule plus a 10-minute grace circle-wide): a slow honest phone that never fetched the new key for more than 10 minutes has its live items refused until it syncs.
* **A removed member** keeps old keys and everything already downloaded; a new epoch is required (the server flags it), and new members cannot read older epochs unless an admin phone re-wraps them (the app wraps all held epochs to new devices).
* **Mixed users** are visible in plaintext to the server through their standard circles.
* **Chat** in a Private circle is end-to-end encrypted (`E2EE_CHAT.md`), photos included. Chat in other circles is plaintext.
* **On-device plaintext** (history store, parked fixes) is protected only by the OS app sandbox.
* **Background execution** (Doze, OEM task killers, the vault in a headless isolate, push wake-up reaching a session-less isolate) is unverified on real devices.
* Phase-2 formats (like phase 1) are not reviewed by an external cryptographer.

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
* **A hostile or compromised member** holds the circle key and can read and forge payloads from that moment (out of scope). They cannot, however, block or substitute another member's wrap (publisher-only wrapping plus commitment check).
* **A compromised admin/publisher** can issue keys to anyone approved and can approve replacement keys; the log makes this visible after the fact, not impossible.
* **Removal is not revocation of the past:** a removed member keeps keys and data they already received.
* **Device compromise:** malware on the phone can read keys in memory. The Keystore wrapping key does not protect against code running as the app.
* **Pure-Dart crypto** is not constant-time hardened like libsodium; the main protection is that secrets are short-lived and the threat model is the server, not a local attacker with timing access. Comparisons of secret-derived values use constant-time helpers.
* **Argon2id in pure Dart** is slow on low-end phones; the passphrase is optional.
* **Passphrase normalisation:** the passphrase is used as typed UTF-8 (no NFKD); users should avoid non-ASCII characters.
* **No in-app QR scanner** (no vetted scanner plugin was already a dependency): the QR shows the numbers for reading with another phone's camera app, and numbers can be typed or pasted for comparison.
* The invite fingerprint travels in the link's fragment; whoever relays the link (a messenger, a QR photo) can alter it, so it is only as trustworthy as the channel; it is still independent of the server.

## Security review (phase 1)

Checked: constant-time comparisons for secrets and fingerprints (`ConstEq`, `constEq`), no key material or plaintext in logs/errors/audit (regression test), random 24-byte XChaCha20 nonces and fresh ephemeral keys per wrap, AAD binding of circle/epoch/device, epoch monotonicity (enforced by the server: `current+1` only; phase 2 clients must also ignore epochs below the highest seen), replay/rollback of wraps and epochs, low-order/small-order key rejection, signature domain separation, key substitution (TOFU + safety numbers + invite anchor + log), IDOR across circles and users (authz matrix and tests), rate limits, immutable log, transitive per-circle approval, publisher-only wrapping, key commitments, circle-scoped log redaction, cascading cleanup on removal/revoke, and secrets zeroed from UI controllers after use.
Not reviewed by an external cryptographer; the formats should be audited before they carry real locations (phase 2).

## Alternatives considered

The previous options (A status quo, B history only, C full E2EE, D client geofence + relay) are retained for history; the maintainer chose C/D, phased and opt-in per circle, accepting the feature loss listed above for circles that opt in.

## Update: per-member processing lanes (server side implemented)

The trusted-server mode described above is now the **legacy** mode. Circles that were already in it stay in it until their admin runs "Upgrade privacy controls" (`POST /circles/{id}/e2ee/processing-upgrade`); every other circle uses per-member lanes with a phone key (never wrapped to the server) and a server key, see `docs/design/PRIVACY_PROCESSING.md` sections 17 and 18. The server device is never again wrapped the phone key in a non-legacy circle.
