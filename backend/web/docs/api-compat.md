# API compatibility policy

Users do not update the app straight away, and app-store review is slow. The
server therefore has to keep working for the apps people really run, not only
for the newest one. This page is the contract.

## Supported window

The server supports the **last 5 released minor versions** of the app (a
rolling window). When a new minor ships, the oldest one drops out.

* The list of released lines is `compat.Releases` in
  `backend/internal/compat/compat.go`. Add the new `x.y.0` there in the same
  commit that tags a release; the window and the minimum supported version
  follow automatically (as of v0.20.1: 0.16 to 0.20, minimum 0.16.0).
* `MIN_SUPPORTED_APP_VERSION` (env, e.g. `0.16.0`) pins the minimum instead.
* An admin can override the minimum in the admin panel (Settings, App
  versions). Precedence: admin override, then env, then the rolling window.
* Versions below the minimum are "outside the window": the server no longer
  promises that they work, and tells them so (below).
* A version 2 or more minors behind the latest release gets
  `upgrade_recommended` (it still works).

## How an app identifies itself

Every request from the app carries:

| Header | Value |
| --- | --- |
| `X-App-Version` | the app's `pubspec` version, e.g. `0.20.1` (build suffix `+45` and pre-release `-rc1` are ignored) |
| `X-App-Platform` | `android`, `ios` or `web` |

Apps up to and including v0.20.1 send **neither header**. The server treats
such clients as `unknown`: it never blocks them and never changes their
responses, because it cannot tell a v0.16 from a v0.20.1. They still appear to
the server through `devices.app_version`, which is only as good as the value
sent at registration. (The app now registers with its real version; before,
it sent the constant `0.1.0` unless built with a dart-define.)

The server records which versions each user runs in `app_client_versions`
(migration `000200`), written at most once per user, version and platform per
10 minutes, from the authenticated API groups. Retention: rows live as long as
the user.

## What the server tells an old app

* Every response to a client that sent `X-App-Version` carries
  `X-OpenFamily-Compat: ok | recommended | required`, plus
  `X-OpenFamily-Min-App-Version` and `X-OpenFamily-Latest-App-Version`.
* `GET /compat` (public, cheap) returns
  `{status, upgrade_required, upgrade_recommended, min_supported_version, latest_version, client_version, message}`
  for the version in `X-App-Version` (or `?v=`). `GET /config` embeds the same
  object as `compat`.
* `POST /locations` and `POST /locations/batch` answer **426** with
  `{"code":"upgrade_required","upgrade_required":true,"min_supported_version":...}`
  to a client below the minimum, only when the admin enabled enforcement
  (default off). Clients that sent no version are never refused.
* The app shows a banner for `required`, for a circle it cannot open, and a
  dismissible one for `recommended`, instead of silently showing "No location
  yet" or "Offline".

## Rules for API changes

1. **Additive only** inside the window. Add fields; do not rename, retype or
   remove one that an in-window app reads. A new field must be optional for
   old clients (`omitempty` or a default), and new request fields must be
   optional on the server.
2. **New enum values** (for example a new `e2ee_mode`) must not be sent to
   clients that cannot interpret them without a shim. Apps parse unknown enum
   values defensively (an unknown circle mode is shown as "needs a newer
   app", not as an empty circle).
3. **New required request fields, new auth steps and changed semantics** need
   a feature gate: add the feature to `compat.Features` with the first app
   version that supports it and branch on `compat.Supports(...)`.
4. **Removing** something an in-window app uses waits until it leaves the
   window. Deprecate first: keep serving it, document it here, drop it after
   the release that moves the last user of it out of the window.
5. The contract guard enforces rule 1: `backend/internal/compat/testdata/contract/<tag>.txt`
   lists every `Struct.jsontag` the handlers and models declared at each
   release. `TestContractAdditiveOnly` fails if a field from an in-window
   release disappears. An intentional removal goes in
   `allowed_removals.txt` with the reason. Record a new release with:

   ```
   git archive vX.Y.Z backend/internal/handlers backend/internal/models | tar -x -C /tmp/vX.Y.Z
   go run ./cmd/compat-contract /tmp/vX.Y.Z/backend > internal/compat/testdata/contract/vX.Y.Z.txt
   ```

   The guard sees named struct fields only; fields built with `map[string]any`
   are not covered, so keep those stable by review.

## Wire efficiency (feature `wire_v2`, apps 0.25 and newer use it)

Additive only, so apps 0.20-0.24 are unaffected: gzip responses, `ETag` /
`If-None-Match` on authenticated JSON GETs, `view=compact` / `fields=` and
`?since=` on `/family/members` and `/family/places`, `simplify` / `max_points`
on member history, `limit` / `before` on `/audit`, `GET /app/bootstrap`, and
`POST|QUERY /family/history/query`. A new app checks `features.wire_v2` in
`GET /compat` (or just handles 404 / a plain array) and falls back to the old
requests. See [API wire efficiency](developers/api-efficiency.md).

## Shims in place

| Situation | Who | What the server does |
| --- | --- | --- |
| Private (end-to-end encrypted) circle, app below 0.15.0 | reports a version | `GET /circles` appends "(update the app to open this private circle)" to the circle name (the only field every version renders) and sets `update_required`; every client gets `min_app_version` on a private circle |
| All circles private, app below 0.16.0 posts a plaintext location | reports a version | the existing 409 `e2ee_private_circle` carries "Update Orbitly to share location..." |
| Charging flag (feature `member_charging`, 0.26.14) | apps below 0.26.14 never send `charging`; older servers ignore it | the field is optional everywhere: a report without it stores "unknown" (NULL) and responses omit it; ingest decoding is not strict, so a new app talking to an older server is unaffected |
| Owner-approval key-log entry (action 12, feature `owner_approval`) | any client that does not send `GET /e2ee/log?owner_approval=1` (apps below 0.27, bridges) | the entry is served redacted (hash chain still verifiable), because older verifiers reject unknown action codes; the self-approval itself is an ordinary approval entry |
| Server key kept across an owner reset (action 13, feature `server_attach`, 0.26.27) | any client that does not send `GET /e2ee/log?server_attach=1` (apps below 0.26.27, bridges) | the attach entry is served redacted (hash chain still verifiable). `POST /e2ee/devices` takes an optional `keep_server` object on a reset and answers `server_kept: true` only when the server key was kept; a server that predates the field ignores it, revokes the key as before and the answer has no `server_kept`. `POST /e2ee/server-device/replace` is new (admin action, additive) |
| Required server processing (feature `required_server`, 0.26.27, capability `reqsrv1`) | apps below 0.26.27 cannot sign their own lane and seal nothing in a circle whose policy is `required_server` | the circle name carries "(update the app to keep sharing with this circle)" and `min_app_version` is set (the circle stays usable: `update_required` is not set); the owner's screen lists the member as needing the new app (from the `reqsrv1` capability). The relay now takes phone-line items in such a circle (a member who has not switched over yet is no longer refused), so a position is never dropped |

Findings from the audit of v0.10.0 to v0.20.1 (field-level): no JSON field
that a handler or model declared was removed in that range. The compatibility
risks are semantic, not structural: since v0.15.0 a Private circle never
returns plaintext positions to anyone (`circles.Authz` hides them), so an app
that cannot decrypt shows its members as "No location yet"; and since v0.16.0
an account whose circles are all Private gets 409 for plaintext uploads. Both
are covered by the shims above for clients that identify themselves.

## What is not covered

* Apps that predate the header are indistinguishable from each other, so no
  per-version shim can apply to them. The first release that sends the header
  starts the window for real.
* Old-APK behaviour is not tested against real APKs. The contract fixtures
  check the server's declared fields, not what each old build renders. Do a
  manual pass with an old APK from `apk/` or the GitHub release before
  dropping a version from the window.
* The headless background location isolate does not read the package version
  unless built with `--dart-define=OPENFAMILY_APP_VERSION`; those uploads send
  no version header (they are never refused).
