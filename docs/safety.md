# Safety alerts: what OpenFamily does

OpenFamily notifies your family. **It never contacts emergency services** (no
911/112/999 call, no dispatch). If someone is in danger, call your local
emergency number first.

## What happens

| Action | Family push | Family live (WebSocket) | SMS to the sender's emergency contacts |
|---|---|---|---|
| Check-in | yes | yes | no (opt-in: `ALERT_SMS_ON_CHECKIN`) |
| Help | yes | yes | no (opt-in: `ALERT_SMS_ON_CHECKIN`) |
| SOS | yes | yes | yes, up to the limits below |

- SMS goes only to emergency contacts the sender added themselves, never to
  phone numbers on other members' profiles, and only when Twilio is configured.
- The SMS says the family was notified and that emergency services have **not**
  been contacted. It never contains coordinates. If `PUBLIC_BASE_URL` is https it
  carries a temporary link to a no-script page showing the last known position;
  otherwise it carries no location.
- Push payloads never contain coordinates. Unless `VERBOSE_PUSH=true` they also
  omit the sender's name and the free-text note ("A family member sent SOS").
- The API response to the sender states: "Your family has been notified.
  Emergency services were not contacted."
- Every alert writes an `alert.<type>` audit entry, plus an `alert.fanout`
  summary (counts only).

## Delivery states

`GET /alerts/{id}` (sender or an admin of the sender's family) returns one row
per recipient and channel (`push`, `ws`, `sms`):

| State | Meaning |
|---|---|
| `queued` | accepted by the server, not yet handed to a provider |
| `sent` | the provider accepted it (ntfy/APNs for push, Twilio API for SMS). This is not proof the phone received it |
| `delivered` | queued onto the recipient's live WebSocket (`ws` only) |
| `failed` | see `error`: `invalid_phone`, `provider_error`, `rejected_by_provider`, `sms_not_configured`, or a `limit_*` code |
| `acknowledged` | the recipient confirmed with `POST /alerts/{id}/ack` |

Twilio delivery-status callbacks are not used, so SMS stops at `sent`/`failed`.
The first acknowledgement reaches the sender as a WebSocket frame
`{"type":"alert_ack", "alert_id", "user_id", "name", "acknowledged_at"}`. Acks are
idempotent. A `ws` row exists only for members who were connected.

`GET /alerts?limit=&before=` lists the caller's family history, newest first
(`limit` 1-100, default 20; `before` is the last id of the previous page;
`next_before` is empty on the last page). Coordinates appear only on active
alerts.

## Limits (environment variables)

| Variable | Default | Effect |
|---|---|---|
| `ALERT_SOS_COOLDOWN` | `2m` | gap between two SOS from one user (429) |
| `ALERT_COOLDOWN` | `1m` | gap between two check-in/help from one user |
| `ALERT_FAMILY_MAX_PER_HOUR` | `30` | check-in/help per family per hour (429). SOS is never refused |
| `ALERT_SMS_MAX_RECIPIENTS` | `5` | contacts texted per alert; the rest are `failed: limit_recipients_per_alert` |
| `ALERT_SMS_SENDER_PER_DAY` | `10` | SMS per sender per 24 h (counted in the database) |
| `ALERT_SMS_FAMILY_PER_HOUR` | `20` | SMS per family per hour |
| `ALERT_SMS_ON_CHECKIN` | `false` | also SMS contacts for check-in/help |
| `ALERT_SHARE_TTL` | `4h` | location-link lifetime, max 7 days |

The two cooldowns are in memory and reset on restart. A limit only suppresses
SMS; push and live delivery to the family always happen.

## Share links

128-bit random tokens, expire after `ALERT_SHARE_TTL`, can be turned off at any
time with `POST /alerts/{id}/share/revoke` (then HTTP 410), stop showing the
location once the alert is resolved, and are served with `no-store`, `noindex`,
`no-referrer` and a CSP that forbids scripts and third-party loads.
