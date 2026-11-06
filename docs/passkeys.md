# Passkeys (WebAuthn) sign-in

Server side is implemented with `github.com/go-webauthn/webauthn`
(`backend/internal/handlers/passkeys.go`). The Flutter client and web admin
ceremonies are not built yet (see "Status").

## Enabling

Passkeys are off unless the server knows its public origin. Set
`PUBLIC_BASE_URL=https://family.example.com` (the relying party id and origin are
derived from it) or set explicitly `WEBAUTHN_RP_ID` and `WEBAUTHN_ORIGINS`
(comma separated). Plain http origins do not enable passkeys. Android app
origins (`android:apk-key-hash:...`) need a Digital Asset Links file on the
host and are not configured yet.

## API

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /auth/passkeys/register/begin` `{password, totp_code?}` | bearer | Step-up (password, plus TOTP when on) then returns `{challenge_id, options}` for `navigator.credentials.create` / Credential Manager. |
| `POST /auth/passkeys/register/finish?challenge_id=&name=` body = credential JSON | bearer | Verifies attestation, stores the credential. 201 `{id, name}`. |
| `POST /auth/passkeys/login/begin` | none | Usernameless (discoverable) sign-in options. |
| `POST /auth/passkeys/login/finish?challenge_id=` body = assertion JSON | none | Returns the normal token pair. |
| `GET /auth/passkeys` | bearer | Lists id, name, created, last used (no key material). |
| `DELETE /auth/passkeys/{id}` | bearer | Removes one of your passkeys. |

## Security decisions

- Enrolling needs the password (and TOTP): a stolen access token cannot add a
  passkey.
- User verification is required, so a passkey login is itself two-factor and
  does not prompt for TOTP.
- Challenges are stored server side (`passkey_challenges`), single use, valid 5
  minutes. Login/finish is rate limited like password login.
- The claimed user handle must own the credential; a sign counter that does not
  increase (cloned authenticator) is refused and audited.
- Attestation is not requested ("none"); we need possession, not device
  provenance.
- Recovery is unchanged: the password and admin/family reset codes keep working,
  and any passkey can be removed from a signed-in session. Max 10 per account.
- Credentials are deleted with the account (`ON DELETE CASCADE`).

## Status

Tests: `backend/internal/handlers/passkeys_test.go` run full register and login
ceremonies with a software authenticator (ES256, none attestation) against
Postgres, including wrong origin, replayed/expired challenge, forged signature,
foreign user handle, counter regression, cross-user finish and deletion.

Not done: the Android client (Credential Manager needs a vetted Flutter plugin
and an assetlinks.json for the host), iOS (needs an Apple account and
associated domains) and the web-admin UI. Those are required for the issue's
"enroll and login on both platforms" criterion.
