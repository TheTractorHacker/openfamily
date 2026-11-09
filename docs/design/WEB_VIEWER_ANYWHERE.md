# Design: open the web viewer from any browser ("account-bound viewer")

Status: **ACCEPTED and implemented** (owner decisions D1-D8 below, 2026-11-09): server routes, web screens, docs. User and operator guide: [Web access from any browser](../admin/web-access-anywhere.md). Not yet exercised on a live deployment or a physical phone.
Related: `E2EE.md` (phase 3, "Web viewer: keys and custody"), `PRIVACY_PROCESSING.md` (lanes, sections 8.9, 19.1, 23), `PRIVACY_MODEL_V1.md`.

## 0. The request and why it fails today

Owner: *"The admin should be able to sign in from ANY browser to view locations. It's not supposed to be tied to their computer. Our credentials vault has a master key per account; I want something similar."*

Today a browser reads a Private circle only as an **approved device member** (`device_keys.kind = 'web'`):

1. The browser makes a key pair (`web/src/e2ee/keystore.ts`) and shows a request code.
2. A phone of the same account pastes it in **Approve a viewer or bridge** (`app/lib/screens/viewer_approval_screen.dart`), compares digits, returns an approval code (a cross-signature, key-log action 1).
3. The browser registers its public key (`POST /e2ee/devices`, `kind:"web"`); the phone's pending queue later wraps every circle key to it; the browser unwraps.

The private key is kept **in that browser's IndexedDB** (`openfamily-e2ee-viewer`), in one of three custody modes: `device` (non-extractable WebCrypto keys, the default), `passphrase` (seed sealed with Argon2id, still in IndexedDB) or `session` (memory only). Also in IndexedDB: the pinned approving phone (`approver`, the own-account trust anchor) and the pinned key-log head. Nothing secret is on the server. So a second computer has no key, and getting one means a fresh pairing from a phone (a new key in the log, at most 5 web keys per account, a phone that must open the circle screen to wrap). That is the "tied to one computer" behaviour, and it is deliberate: it is the only custody that keeps a stolen server database useless.

What a signed-in admin already sees from any browser without any viewer key: members whose processing lane is **server** (`PRIVACY_PROCESSING.md` section 23: members are on the server lane by default; legacy trusted-server circles too). Their positions are in the plaintext tables and feed the admin map, history and trips. Only **phone-only** members (and strict Private circles with no server device) need the viewer key.

## 1. Threat model (short) and what is acceptable

* Setting: a family self-hosts. The **server operator is the owner**, who is also the admin who wants to view. A hostile operator is out of scope for this feature (it is already out of scope for any browser viewer: the operator ships the JavaScript, `E2EE.md` "Threat model of the web viewer").
* Must still hold: a **stolen database or backup** (or a leaked dump on a NAS) must not reveal positions without something the thief does not have; a **stolen session token or a stolen password alone** should not be enough either; a phone-only member's data must stay unreadable by the server process itself at rest.
* Acceptable: the owner's chosen secret (vault passphrase) protects the stored key; a weak secret plus a stolen database is a real risk, so the design must make the secret strong and the guessing slow, and say so.
* Not acceptable: any key that can decrypt circle data stored on the server unwrapped; any change that lets the server alone add a reader; any weakening of the log/approval checks.

## 2. Candidate designs

### (a) Account-bound viewer key ("viewer vault")

One web viewer identity per account. Its 32-byte seed (same derivation as phones) is sealed under a random data key (DEK); the DEK is wrapped by a key stretched (Argon2id) from a **vault passphrase** typed in the browser. The sealed blob is stored on the server as opaque bytes. Any browser that signs in (password + TOTP, or passkey) downloads the blob, asks for the vault passphrase, unwraps **in memory**, checks the seed against the registered key, then unwraps the circle keys from the server's existing wraps (they are already stored per device key) and runs exactly today's verification. A phone approves this identity **once**, with today's pairing flow.

### (b) Per-browser ephemeral viewer, phone approval every time

Every browser session makes a fresh `session`-custody key, shows a QR/code, a phone approves, the phone wraps circle keys, the key is revoked when done. Nothing is stored anywhere.

### (c) Server lane only

No viewer key. The admin sees, from any browser, only members whose lane is `server` (and legacy trusted-server circles). Phone-only members show as "keeps data on their phone". Works today.

### Comparison

| | (a) account-bound vault | (b) ephemeral per browser | (c) server lane only |
|---|---|---|---|
| Sign in from any browser | yes: password (+TOTP/passkey) then vault passphrase | yes, but needs a phone in hand every time | yes |
| Sees phone-only members | yes | yes | **no** |
| What the server learns | an opaque blob, its size, when and from which IP it is fetched; never the passphrase (it is never sent) | one more key per session in the log | everything of server-lane members (already) |
| Stolen DB + **strong** passphrase | nothing (Argon2id 64 MiB x3 over a 12+ character passphrase, plus the optional server pepper) | nothing | server-lane members' data (already today) |
| Stolen DB + **weak** passphrase | attacker guesses it offline, gets the viewer seed, unwraps every circle key wrapped to the viewer, reads all sealed ciphertext still in the DB (live 48 h, history per retention) and phone-only members' data. **This is the main new risk**; mitigations in 3.6 | nothing | as above |
| Stolen session token only | gets the blob (if fetch is not stepped up) for offline guessing; recommended: fetch requires step-up (password + TOTP) | nothing without a phone | server-lane data |
| Stolen password (+TOTP) only | blob, but still needs the vault passphrase. If the owner chose "same as my password" (decision D2): **full read** | nothing without a phone | server-lane data |
| Revocation | revoke the one viewer key from a phone (existing button) or from any unlocked browser; server deletes the blob; admin phone rotates epoch (existing). All browsers lose it at once; per-browser revoke is not possible in v1 | per session | n/a |
| Session length | unlocked keys live in the tab's memory; reload or idle timeout (decision D4) re-asks the passphrase; nothing secret persists in the browser | one tab | normal login |
| Multi-browser | yes, same key in several browsers at once (a read-only key: no sequence numbers to clash) | yes, one key each | yes |
| Password change | no effect (vault passphrase is separate) | none | none |
| Password **reset** (reset code by an admin) | no effect on the vault, and the person who reset it still needs the vault passphrase. Forgotten vault passphrase: "Set up web access again" from a phone (new key, old one revoked). The recovery phrase is **never typed into a browser** | none | none |
| TOTP / passkey | fetching the blob needs a step-up (password + TOTP, or a fresh passkey assertion). Optional later: unlock with a passkey (WebAuthn PRF) as a second unlocker | none | normal login |
| Key log / protocol | **no change**: the viewer is a `web` key registered with action 1 and cross-signed by a phone, as today. New: one server route family storing an opaque blob | heavy churn: one registration + revoke + re-key per session; the 5-web-key cap | none |
| App versions | none required (the phone flow is unchanged). Optional phone wording "Web access from any browser" | none | none |

**(b) is rejected**: each session is a log registration, a revoke and a new circle epoch, it hits the 5-web-key limit, and it needs a phone that is online and opens the circle screen to wrap. A variant where the phone hands circle keys straight to an unregistered browser key would need a new relay route and a change to the "recipient must be an approved key" rule, i.e. a protocol change. **(c) is the baseline** and already works; it is what the admin sees before unlocking the vault.

## 3. Recommendation: (a) with a separate vault passphrase, on top of (c)

The owner gets the vault experience: sign in anywhere, then unlock once per session with a vault passphrase. Before unlocking, the admin map shows server-lane members as today.

### 3.1 Keys and formats (implemented in `web/src/e2ee/accountVault.ts`)

All strings ASCII/UTF-8, ids lower-case UUIDs, integers big-endian, domains NUL-terminated (same conventions as `E2EE.md`).

```
seed        32 random bytes (browser CSPRNG); identity = deriveIdentity(seed) exactly as phones
DEK         32 random bytes
payload     JSON {seed:b64, approver:{deviceId, edPub:b64}, name, createdAt}
sealed      XChaCha20-Poly1305(DEK, nonce24, AAD_P, payload)
AAD_P       "OFE2EE-AVAULT1\0" || user_id || device_id || u32(1)

root        Argon2id(NFKC(passphrase), salt16, m=65536 KiB, t=3, p=1, 32 bytes)
pepper_u    HMAC-SHA256(server pepper file, "OFE2EE-AVAULT1-PEPPER\0" || user_id)   (released after step-up)
KEK         HKDF-SHA256(root, salt=pepper_u, info="OFE2EE-AVAULT1-KEK", 32)        (pep=1; pep=0 only in tests)
wrapped     XChaCha20-Poly1305(KEK, nonce24, AAD_K, DEK)                    (48 bytes)
AAD_K       "OFE2EE-AVAULT1-KEK\0" || user_id || device_id || "passphrase\0" || "argon2id\0"
            || u32(m) || u32(t) || u32(p) || u8(pep) || salt

blob (stored by the server, opaque):
{ "v":1, "user_id", "device_id",
  "unlockers":[{"kind":"passphrase","kdf":"argon2id","m","t","p":1,"pep":1,"salt","nonce","wrapped"}],
  "nonce", "sealed" }

pin record (log head, updated often, no Argon2 needed):
{ "v":1, "seq", "nonce", "sealed" = XChaCha20-Poly1305(DEK, nonce, "OFE2EE-AVAULT1-PIN\0"||user||device||u64(seq), {seq,hash}) }
```

Properties: the AADs bind account, device and the stretching parameters, so the server cannot move a blob to another account/device or quietly lower the Argon2 cost; changing the passphrase re-wraps only the DEK (the key and the log stay the same); more unlockers (passkey PRF, a phone escrow) can be added to the list later without touching the seed; on open the browser refuses parameters above 1 GiB / 10 passes (denial-of-service guard), refuses another account's blob, and requires that the seed derives exactly the public keys of an **active `web` key with that id** in `GET /e2ee/me`.

Pin: the browser takes the **higher** of its own remembered pin and the server's sealed pin. The server can only return an older genuine pin (it cannot forge one), so a brand-new browser starts from the newest pin the owner's browsers ever stored, which is strictly better than today's fresh browser (no pin at all). The approver anchor travels inside the sealed payload, so the own-account anchor rule (`E2EE.md` rule 6) is unchanged.

### 3.2 Server API (implemented: `backend/internal/handlers/e2ee_viewer_vault.go`, migration `000380_e2ee_viewer_vault`)

Switches: `E2EE_VIEWER_VAULT` (env, default `on`; `off` is the operator's hard switch) and the admin setting `app_theme_settings.e2ee_viewer_vault_enabled` (default on, Settings > Security). Usable only by **platform admins** (D7) and only while the pepper file is readable. Until an admin sets it up nothing is stored and nothing changes. Unavailable routes answer 404 with `code = viewer_vault_<reason>`.

| Route | Who | Body / reply | Rules |
|---|---|---|---|
| `GET /e2ee/viewer-vault` | any signed-in user | `{available, reason, exists, device_id, created_at, updated_at, last_opened_at, pepper_changed, key_active}` | never returns the blob; `reason` is `off_by_operator`, `off_in_settings`, `pepper_unavailable` or `admins_only` |
| `POST /e2ee/viewer-vault/unlock` | self, admin | `{password, totp_code, browser_id}` -> `{pepper, ticket, blob, pin, device_id}` (`blob` null before setup) | step-up (`stepUp`: password + TOTP/recovery code, throttled); 10/h/user; audit `e2ee.viewer_vault_opened`; 409 `viewer_vault_pepper_changed` / `viewer_vault_key_revoked`; first unlock from a browser id never seen (SHA-256 stored) audits `e2ee.viewer_vault_new_browser` and pushes "Private circles opened in a new browser" to the owner's phones (D5) |
| `PUT /e2ee/viewer-vault` | self, admin | `{ticket, blob}` | `ticket` = one-time, 10-minute, per-user grant from the last unlock (so one 2FA code covers set-up); `blob.v = 1`, `blob.user_id` = caller, `blob.device_id` = an **active `web` key of the caller**; compact JSON <= 8 KiB; audit `e2ee.viewer_vault_saved` |
| `PUT /e2ee/viewer-vault/pin` | self, admin | `{pin}` | `pin.seq` must exceed the stored seq; <= 1 KiB; 30/min |
| `DELETE /e2ee/viewer-vault` | self | `{}` -> `{deleted}` | works even when switched off; audit `e2ee.viewer_vault_deleted` |
| `GET/PUT /api/admin/settings/e2ee-viewer-vault` | platform admin | `{enabled}` -> `{enabled, off_by_operator, pepper_available, pepper_error, vaults}` | audit `admin.e2ee_viewer_vault_changed` |

Storage: `e2ee_viewer_vaults(user_id PK -> users ON DELETE CASCADE, device_id -> device_keys ON DELETE CASCADE, blob jsonb, pin jsonb, pin_seq, pepper_id, created_at, updated_at, last_opened_at)` and `e2ee_viewer_vault_browsers(user_id, browser sha256, first_seen, last_seen)`. Trigger `trg_e2ee_viewer_vault_on_revoke`: revoking the web key (from a phone or self) deletes the vault, so every browser loses it at once. `pepper_id` is a non-secret tag (`HMAC(pepper, "OFE2EE-AVAULT1-PEPPER-ID")`, 16 hex) so a lost or replaced pepper file is reported instead of a misleading "wrong passphrase". Replacing the blob with another key resets the pin history.

**Pepper (D3, implemented).** File `E2EE_VIEWER_VAULT_PEPPER_FILE`, default `/data/server-device/viewer-vault-pepper` (the `server_device` volume, not in the database and not in the database backups), 32 random bytes hex, 0600, created on first start. Per account the server derives `pepper_u` and returns it only after the step-up; the browser uses it as the HKDF salt of the KEK, and the unlocker records `pep = 1` inside the authenticated data, so the server cannot silently drop it. A thief with only the database or a database backup cannot test a single guess. Losing the file means every admin sets web access up again from a phone.

### 3.3 Protocol steps

**Set up (once, needs a phone):**
1. Admin web, Private circles, "Web access from any browser" (shown only when the flag is on). The browser makes `seed` and a new `device_id`, shows the usual request code (`buildRequestCode`, kind `web`, name e.g. "Web access (any browser)").
2. Phone: **Approve a viewer or bridge**, compare digits, approve (unchanged; in lanes circles the existing per-circle phone-key warning still applies).
3. Browser: paste the approval code, `registerViewer` (unchanged, `POST /e2ee/devices`), pin the approver (unchanged).
4. Browser asks for a vault passphrase (12+ characters, not the email or name, shown strength hint; refused if equal to the account password (D2)), seals the blob (3.1) and `PUT /e2ee/viewer-vault` with the ticket from a step-up. It keeps the DEK in memory for pin updates.
5. The phone wraps circle keys to the key on its next pending-queue run (unchanged).

**Unlock in any browser:**
1. Sign in normally (password + TOTP, or passkey). Map shows server-lane members (c).
2. "Unlock private circles": enter account password (+TOTP) for the step-up and the vault passphrase in one dialog. `POST /e2ee/viewer-vault/unlock`.
3. Browser: `openAccountVault` (wrong passphrase: "wrong vault passphrase", nothing sent anywhere), `GET /e2ee/me`, `accountIdentity` (seed must match the active web key), `newerPin(local, server)`, then `syncCircle` exactly as today (full log verification, wraps, commitments, item checks). After each successful sync, `PUT /e2ee/viewer-vault/pin` if the head advanced.
4. Lock: tab close, sign-out, idle timeout, or "Lock" clears the in-memory seed, DEK and circle keys.

**Change passphrase:** unlocked browser, `changeVaultPassphrase`, `PUT` with step-up. Note: someone who already copied the old blob and knows the old passphrase still has the key; if the passphrase leaked, use "Set up again" (new key, revoke old, new epoch), not just "change".

**Forgot passphrase / set up again:** revoke the old viewer key (phone or the web "Reset web access", which needs a phone approval for the new key anyway), the row is deleted, start over at "Set up". The recovery phrase is never entered in a browser: it controls the recovery identity, which can cross-sign new devices, and a browser page is the weakest place to type it.

**Revoke:** from the phone ("Connected viewers", Revoke) or self-revoke in an unlocked browser (`revokeSelf`). Existing behaviour: wraps deleted, circle flagged, admin phone publishes a new epoch; plus the vault row is deleted by trigger.

### 3.4 What does not change

Key-log actions and their meaning, the registration/cross-signature format, the approval chain, `AuthorizeWrap`/`AuthorizeSender`/`pinApprover`, wrap rules ("recipient must be an approved key"), the lanes rules (a web viewer gets the phone key only after the owner's per-circle confirmation), the existing `device`/`passphrase`/`session` custody modes (they stay; the account-bound mode is a fourth choice). No phone or bridge release is required; there is no compat window.

### 3.5 Session and browser hygiene

Unlocked secrets are extractable by script while the tab is unlocked (same as today's passphrase mode). The panel's CSP and the script-hash display stay. Recommend: idle lock after 30 minutes (D4), lock on sign-out, never in localStorage/sessionStorage/IndexedDB (only the non-secret pin is cached locally).

### 3.6 Mitigations for the weak-passphrase risk

Argon2id 64 MiB x 3 in the browser (about 1-3 s); minimum 12 characters and a simple policy (`passphraseProblem`); step-up before the blob is released (a stolen session cannot fetch it); rate limit and audit on `open`; phone notice on every unlock from a new browser; optional pepper (D3); revocation kills the blob. Rough guessing cost for a thief with the blob and no pepper: one GPU manages on the order of tens to a few hundred Argon2id-64MiB guesses per second, so a common-password list falls in hours, four random words do not fall in practice.

## 4. Migration plan

1. Ship slice 2 (server routes + migration) behind `E2EE_VIEWER_VAULT`, off.
2. Ship slice 3 (web UI) that reads the flag from a capability field (e.g. `GET /e2ee/server-device` or a new `GET /e2ee/viewer-vault/status` that returns `{enabled, exists}`).
3. Existing viewers keep working untouched. A browser with a `device`/`passphrase` viewer can offer "Make this viewer available in any browser": this needs the **seed**, which exists only in `passphrase` mode (device-mode keys are non-extractable by design, so those users set up a new account-bound viewer and revoke the old one).
4. Docs: `E2EE.md` phase-3 custody table gets the fourth mode; user guide "Open private circles from any browser"; `PRIVACY_MODEL_V1.md` lists the stored blob and the weak-passphrase risk.
5. Turn the flag on per instance by the owner. Nothing changes for other instances.

## 5. Test plan

* Client (done for slice 1, `web/test/accountVault.test.mjs`): blob is opaque (no seed/passphrase/key bytes); full flow in a fresh "browser" (open, check against the registered key, `syncCircle`, decrypt a member's fix, key anchored to own phone); wrong passphrase, another account, relabelled user/device, changed Argon2 parameters, flipped ciphertext, unknown version, absurd parameters all fail closed; revoked/wrong-kind/mismatched registered key refused; passphrase change keeps the key and kills the old passphrase; a wrong DEK cannot re-wrap; pin bound to account/device/seq; older server pin never moves a browser back; weak passphrase and weak parameters refused outside tests.
* Server (slice 2): flag off = 404 on all routes; self-only (another user's row is 404); step-up required on open and save (wrong password, missing TOTP, throttling); `device_id` must be the caller's active web key; size caps; pin seq only increases; revoke deletes the row (trigger); account deletion cascades; logs and audit contain no blob bytes (extend the existing log-scan test); authz matrix.
* Web UI (slice 3): unlock dialog, lock on idle/sign-out, second browser end to end against a dev server, Firefox/Safari/Chrome; Argon2 time on a low-end laptop.
* Manual: phone revoke while a browser is unlocked (browser stops at next sync, new epoch excludes it); password reset by an admin then unlock still needs the vault passphrase.

## 6. Decisions (owner approved all recommendations, 2026-11-09)

* **D1. Vault passphrase separate from the account password?** Decided (as recommended): **yes, separate** (it is never sent to the server, so a server compromise or a password reset does not open the vault).
* **D2. Allow "use my account password as the vault passphrase"?** Convenient, but then anyone with the password (and TOTP) reads phone-only members, and the server sees that password at every login. Decided (as recommended): **no** (or allow with a red warning).
* **D3. Server pepper** (a secret file outside the database mixed into the key)? Protects against a database-only/backup leak; losing the file means everyone re-pairs once. Decided (as recommended): **yes, if backups of the env/secret files are kept separately from DB backups**.
* **D4. Idle lock timeout.** Decided (as recommended): 30 minutes; reload always re-asks.
* **D5. Phone notice on each unlock from a new browser?** Decided (as recommended): **yes**.
* **D6. One account-bound viewer per account** (all browsers share it, revoke is all-or-nothing) vs per-browser sub-keys (each browser registers its own key vouched by the account viewer; needs the viewer to wrap circle keys to its own sub-keys, more log entries). Decided (as recommended): **one per account** for v1.
* **D7. Who may use it.** Decided (as recommended): platform admins only for now (the server enforces it); other accounts later, since it only reads what that account could read on its own phone.
* **D8. Passkey unlock later** (WebAuthn PRF as a second unlocker, so a synced passkey replaces typing the vault passphrase)? Decided (as recommended): later, after v1.

## 7. Slices

| Slice | Content | State |
|---|---|---|
| 1 | Client vault format (`web/src/e2ee/accountVault.ts`) with tests | done |
| 2 | Migration `000380`, routes, step-up, ticket, pepper file, trigger on revoke, new-browser push, admin switch, DB tests (`e2ee_viewer_vault_db_test.go`), config test | done |
| 3 | Web: `accountAccess.ts` (HTTP flow), controller account mode, Private circles page (set up, unlock, lock, change passphrase), shared controller with 30-minute idle lock (`lib/privateViewer.ts`), map header chip, Settings > Security card; tests `accountAccess.test.mjs` | done |
| 4 | Docs (`docs/admin/web-access-anywhere.md`), compose/env switches. Phone: no change needed; the existing "Approve a viewer or bridge" flow and wording ("Web viewer (browser)") already fit | done |

Not done / unverified: end to end on a live deployment with a real phone; WebCrypto/Argon2 timing in Safari and Firefox; the push text on iOS/Android.
