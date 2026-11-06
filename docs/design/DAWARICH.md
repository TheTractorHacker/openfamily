# Dawarich export integration

Issue: #29 asked for a design document first (opt-in, secure credentials,
dedup, retention behaviour). The integration was subsequently built
(`backend/internal/handlers/dawarich.go`, migration `000105_dawarich_sync`,
per-user mapping added later). This document records the design **as built**,
checks it against the issue's four requirements, and lists the gaps that still
need a decision. Dawarich is a self-hosted location-history viewer
(https://dawarich.app); OpenFamily pushes points to its `POST /api/v1/points`.

## Behaviour

- **Direction:** one-way push from OpenFamily to Dawarich; nothing is read back.
- **Configuration (admin only):** `PUT /api/admin/dawarich` stores `base_url`, optional `local_url` (LAN fallback tried only when the public address is unreachable), the API key, `enabled`, `send_unmapped`, and `backfill_days`. Per-user mappings (`dawarich_user_map`) give a member their own Dawarich account/key.
- **Transport:** a background loop (`RunDawarichSync`, every minute) pushes batches of up to 500 points (max 20 batches per round) as GeoJSON `locations` with timestamp, accuracy, altitude, speed, battery, device name and device id, authenticated with `Authorization: Bearer <key>`.
- **Credentials:** API keys are sealed with a key derived from the server secret (`auth.SealSecret`, purpose `dawarich-api-key`) and never returned by the API (`api_key_set` boolean only). Stored errors and logs drop the request URL (`scrubDawarichErr`) so keys in URLs do not leak.
- **Dedup:** a per-device cursor (`dawarich_cursor.last_ts`, advanced with `GREATEST`) means each point is sent once, in timestamp order; the cursor moves only after Dawarich accepted the batch, so a failed batch is retried (at-least-once; Dawarich also dedups identical timestamp+coordinates on its side). Disabling or deleting the settings/mapping clears the cursor.
- **Retention behaviour:** sync starts at `since` (now, or now minus `backfill_days` when the admin chooses a backfill); older history is never pushed implicitly. Deleting points in OpenFamily does **not** delete them in Dawarich, and disabling sync does not recall already-sent data; this is intentional (Dawarich is the user's own archive) and must be stated to users.

## Check against the issue

| Requirement | Status |
|---|---|
| Opt-in | Yes at the server level: off by default, admin must configure and enable. |
| Secure credentials | Yes: encrypted at rest, write-only through the API, scrubbed errors. |
| Dedup | Yes: per-device cursor, at-least-once with destination-side dedup. |
| Retention behaviour | Defined above (one-way, no deletion propagation) |
| Explicit **user** authorization | **Gap.** The admin enables export for members (`send_unmapped`, per-user mapping). A member does not consent in-app. |
| Design reviewed before implementation | Not met historically (built first); this document is the retrospective review. |

## Open decisions (need the maintainer)

1. **Member consent:** require each member to accept (in-app toggle, default off, visible "my location is exported to <host>" indicator) before their points are sent; make `send_unmapped` default to off. Recommended: yes, since members' location leaves the system the family agreed to.
2. **Deletion propagation:** document only (recommended), or call Dawarich's delete API on account deletion.
3. **E2EE:** the server-side sync reads only the plaintext `locations` table and so **skips Private circles by construction** (test: `TestE2EEDawarichServerSyncSkipsPrivateCircles`). Private circles reach Dawarich through `backend/cmd/e2ee-bridge`, a separate program the user runs off the server host as an approved read-only `service` device member (see [E2EE.md](E2EE.md), phase 3, and the bridge README). The bridge has its own Dawarich config (URL, main key, `send_unmapped`, per-user keys keyed by OpenFamily user id), uses the same GeoJSON mapping and its own de-duplication, and its host can read the circle. A person who is in both a Private and a normal circle keeps being exported by the server for the normal circle, as before.
4. **Tests:** there are no Go tests for `dawarich.go`; add handler tests with an `httptest` Dawarich server (cursor advance on success, no advance on 5xx, key never in responses/errors) before changing behaviour.
