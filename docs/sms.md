# SMS providers

SMS is optional. With no provider configured the app works fully: alerts go
in-app (WebSocket and push) and nothing is sent by SMS. Phone numbers are
optional on every account.

Pick a provider with `SMS_PROVIDER` (default `twilio`, so existing `TWILIO_*`
deployments are unchanged). Credentials use the same three variables for every
provider (`SMS_ACCOUNT_ID`, `SMS_AUTH_TOKEN`, `SMS_FROM` are provider-neutral
aliases of `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM`):

| Provider | `SMS_PROVIDER` | `*_ACCOUNT_ID` | `*_AUTH_TOKEN` | `*_FROM` | Extra |
|---|---|---|---|---|---|
| Twilio | `twilio` | Account SID | Auth token | sender number | |
| Telnyx | `telnyx` | unused | API key (v2) | sender number | |
| Plivo | `plivo` | Auth ID | Auth token | source number / sender id | |
| Amazon SNS | `sns` | access key id | secret access key | optional sender id | `SMS_REGION` (e.g. `us-east-1`) |

The admin Settings screen edits the credential fields; provider and region come
from the environment. Unknown providers or missing credentials disable SMS.

Code: `backend/internal/sms` (`Dispatcher` interface, `providers.go`, tests with
fake HTTP servers in `providers_test.go`).

## Abuse limits

Emergency contacts must be verified-by-opt-in in practice: SMS fan-out is
capped per sender per day, per recipient and per family per hour
(`ALERT_SMS_*`, see `docs/safety.md`), and check-ins do not SMS by default.

## A2P / compliance notes

- US 10DLC and toll-free numbers require carrier registration (A2P) before
  messages are reliably delivered; unregistered traffic is filtered. Register
  the brand and campaign with your provider.
- Messages are transactional safety alerts to people a family member named as a
  contact. Honour STOP/HELP keywords (providers do this on the sender number).
- Messages never contain coordinates; they link to an expiring share page and
  never claim that emergency services were called.
- Amazon SNS needs a sandbox exit and an origination identity in many regions.
