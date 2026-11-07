# API overview

The HTTP API is documented in the **API reference** section of the
[root README](../../README.md#api-reference): every route, its parameters and
errors. This page adds the conventions.

- **Auth:** `POST /auth/login` returns an access token (15 min) and a refresh
  token. Send `Authorization: Bearer <access>`. Phones may also use a device
  ingest key for location uploads. Platform-admin routes live under
  `/api/admin/*` and re-check the admin flag in the database on every call.
- **Versions:** the app sends `X-App-Version` and `X-App-Platform`; the server
  answers with `X-OpenFamily-Compat`. `GET /compat` returns the policy for the
  caller: status, minimum and latest version, supported `window`, the server
  version and the minimum app version per feature. See [Compatibility](compatibility.md).
- **Docs:** `GET /api/docs/manifest.json` and `GET /api/docs/<path>` return the
  embedded documentation to any signed-in user (read-only).
- **Additive changes only:** fields are never removed or renamed for a version
  still inside the support window; a test enforces it.
- **Topic pages:** [chat](../chat.md), [safety](../safety.md), [share links](../share-links.md),
  [check-ins](../checkin-sharing.md), [bubbles](../bubbles.md), [driving](../driving.md),
  [push](../push.md), [SMS](../sms.md), [passkeys](../passkeys.md),
  [Home Assistant](../integrations/home-assistant.md).
