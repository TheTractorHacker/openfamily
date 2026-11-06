# ADR: End-to-end encryption of location vs server-side geofences

Status: **Proposed - recommendation below, needs maintainer sign-off before any implementation.**
Issue: #34. Date: 2026-11. Implementation is explicitly out of scope until accepted.

## Context

OpenFamily is self-hosted: the family (or one trusted operator) runs the server.
Today the server reads every location in plaintext (`locations` table, PostGIS
`geom`) because several features need it:

| Feature | Needs plaintext coordinates on the server because |
|---|---|
| Place arrival/departure alerts | `geofence.go`, `place_presence.go` evaluate fixes against places in SQL |
| Live map and history | server fans out WebSocket frames and serves history/day/trip queries |
| Driving reports, trips, crash alerts | server segments fixes into trips and scores them |
| SOS / check-in / "location request" | server pushes the sender's last position to members |
| Admin panel (maps, devices) | operator views members' positions |
| Dawarich export (#29) | server forwards raw points to a third-party instance |
| Address geocoding, weekly summaries | server-side reverse geocoding and aggregation |

The threat being addressed: a compromised or curious **server operator**, a
stolen database or backup, and a server breach. It is *not* the threat of a
hostile circle member (members are trusted by design).

## Threat model

| Adversary | Today | With E2EE |
|---|---|---|
| Network attacker | Mitigated by TLS | Same |
| Stolen backup / DB dump | Full location history exposed | History unreadable without member keys |
| Server breach (RCE, SQLi) | Live and historical positions exposed | Attacker sees ciphertext and metadata only |
| Malicious/curious operator | Sees everything | Sees metadata (who, when, size), not positions |
| Legal compulsion on the operator | Can hand over everything | Can hand over only ciphertext |
| Circle member | Intended access | Same |

In a self-hosted deployment the operator is usually a family member, so the
marginal protection is mostly against **breach and backup theft**, which are
already partly addressed by disk encryption, encrypted backups
(`docs/backup-restore.md`) and retention limits.

## Options

**A. No E2EE; document the threat model (status quo).** Keep TLS, disk
encryption, encrypted backups, retention limits, access logging. All features
keep working. Residual risk: server compromise leaks locations.

**B. E2EE for history only.** Live fixes stay plaintext in the hot path for
geofences/alerts/live map; history beyond a short window (for example 24 h) is
re-encrypted client-side into a blob the server cannot read. Limits breach
blast radius for old data. Costs: history/day/trip/driving reports/weekly
summaries must move to the client (they query history server-side today);
significant rewrite for modest gain, because the most sensitive current
position is still plaintext.

**C. Full E2EE with on-device geofence evaluation.** Phones encrypt each fix to
the circle key. The server stores/relays ciphertext. Each member's phone
decrypts and evaluates places; the *sender's* phone evaluates its own
arrival/departure and sends an encrypted event (see D). Costs: everything in the
table above that is server-side must be rebuilt client-side; the web admin map
needs member keys (the operator loses visibility, a feature for some, a
regression for others); trips/driving/crash/geocoding/Dawarich/weekly summary
all move or are dropped; push notifications cannot include a place name unless
the server knows it.

**D. Client-side geofencing with the server relaying encrypted events.** Subset
of C: the *sender's* phone evaluates places (it already runs 24/7 and knows the
place list, distributed to it encrypted) and emits "arrived at Home" events
encrypted to the circle; the server only relays and pushes an opaque "new
event" wake-up. Raw trail upload becomes optional and encrypted. This keeps
alerts working without the server reading coordinates, but needs the phone to
be reliable at geofencing (the physical-device work in
`docs/testing/PHYSICAL_DEVICES.md` is the evidence we do not yet have), and
iOS background limits make this harder than server-side evaluation.

## Key distribution, recovery, admin and Dawarich (if E2EE were adopted)

- **Keys:** one symmetric circle key per circle (XChaCha20-Poly1305 / AES-GCM),
  rotated on member removal; each member holds an X25519 keypair, the circle
  key is wrapped to each member's public key (sealed box). Multi-circle (#13)
  already gives one key per circle. Key exchange happens at invite acceptance
  in-person via the QR code (authenticated by the invite code), not trusting
  the server for public keys, or with a safety-number comparison.
- **Recovery:** losing a phone loses its private key. Recovery needs another
  circle member to re-wrap the circle key to the new device (and past history
  stays readable only to devices that held the key) or a user-held recovery
  phrase. A solo user with no other device has no recovery - this is the cost
  of E2EE and must be shown in the UI.
- **Admin features:** the admin map, device last-known positions, driving
  reports, trip lists and weekly summaries cannot work server-side. The admin
  panel would be limited to account/device administration, or become a client
  that holds member keys (then it is a member, not an admin).
- **Dawarich export:** the server could no longer forward points; export would
  have to run from a member's phone/desktop client or be dropped. Compatible
  only with option A/B (recent window).
- **Removal:** removing a member requires rotating the circle key and
  re-encrypting future fixes; past data the removed member already holds is not
  revocable.

## Comparison

| | A status quo | B history only | C full + on-device | D client geofence + relay |
|---|---|---|---|---|
| Server breach exposes live position | yes | yes | no | no |
| Server breach exposes history | yes | no | no | no |
| Geofence alerts reliable | yes | yes | depends on phone | depends on phone |
| Trips/driving/weekly summaries | yes | rewrite | rewrite or drop | rewrite or drop |
| Admin map | yes | partly | no | no |
| Dawarich | yes | recent only | no | no |
| Account recovery | normal | normal | needs another member | needs another member |
| Engineering cost | none | high | very high | very high |
| iOS/Android parity risk | none | low | high | high |

## Decision (recommended)

**Adopt Option A now, and keep Option B as a bounded future hardening; do not
implement C or D.**

Reasoning:

1. The product's value (reliable arrival alerts, driving reports, SOS with a
   current position, an admin map) all depend on server-side reading of
   coordinates. C/D would remove or rewrite most of the server feature set to
   protect against an operator who is, in self-hosted use, a family member.
2. The remaining realistic threats (stolen backup, disk theft, server breach)
   have cheaper mitigations that do not change the product: encrypted backups
   (done, #11), disk encryption, short retention for raw points, a hardened
   deployment (#6, #9), and rate/auth hardening.
3. Client-side geofencing is only as reliable as background execution on
   phones, which is unproven on physical devices (#24 is BLOCKED). Deciding on
   an architecture that depends on it without that evidence would risk the
   core safety feature.

Concrete follow-ups that capture most of the benefit (each its own issue, not
done here):

- Configurable retention for raw `locations` (auto-thin or delete after N days), with the policy documented in PRIVACY.md.
- Optionally encrypt history older than the live window at rest with a server-held key stored outside the database (envelope encryption), so a database-only leak is useless.
- Document the threat model in `SECURITY.md`/`PRIVACY.md`: the operator can read locations.
- Revisit B/D if a user base without a trusted operator (hosted service) ever appears, and after physical-device geofencing evidence exists.

Rejected: C and D for now (cost and feature loss exceed the marginal protection
in a self-hosted trust model). No prototype was built; the issue says to
prototype only if the decision is positive.

## Review

Requires maintainer decision (issue #34 acceptance: "decision recorded and
reviewed before any implementation"). Until then this ADR is a recommendation.
