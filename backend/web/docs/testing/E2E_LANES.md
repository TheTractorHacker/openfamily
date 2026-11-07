# Real-server interop test of the processing lanes

`scripts/e2e-lanes.sh` proves that the real Dart phone code (`app/lib/services/e2ee/*`,
`LanesService`, `PrivateRuntime`, `ApiClient`) works against the real Go server in `backend/`,
instead of only against the in-memory fake (`app/test/support/fake_e2ee_server.dart`).

Docker only. The script builds the server, `e2ee-bridge` and a tiny SQL probe (copied temporarily to
`backend/cmd/_e2eprobe`, removed again) in `golang:1.27`, starts a throwaway TimescaleDB
(`fsync=off`) and the server (host network, ports `E2E_DB_PORT=55433`, `E2E_API_PORT=18089`), then runs
`flutter test test/e2e_real_server/` in `ghcr.io/cirruslabs/flutter:stable`. Containers have unique names
and are removed at the end. Extra arguments are passed to `flutter test`.

    scripts/e2e-lanes.sh
    E2E_REQUIRE_SIDECAR=1 scripts/e2e-lanes.sh     # also fail while the sidecar predates lanes
    E2E_RUN=dev E2E_KEEP=1 scripts/e2e-lanes.sh    # keep the stack between runs (development)

Without `E2E_BASE_URL` (the normal `flutter test`) the suite is skipped.

How the pieces fit: `ApiClient` insists on https and one token store, so the tests use a pretend https
host that a zone-scoped http client rewrites to the real server and signs with the token of the phone the
call belongs to. The Orbitly server's own device is the real `e2ee-bridge` binary (`enroll --kind server`,
approved by the admin phone through `approveLinkRequest`, pinned by `run`). Plaintext at the server is
checked in the database (`locations`, `member_positions`) through the probe, and the server log is
grepped for Cleo's coordinates by the script.

Scenarios (`app/test/e2e_real_server/lanes_e2e_test.dart`): policy, lanes in use (Anna, Ben server; Cleo
phone), the real sidecar, cross reading and badges, opt-out, `required_server`, an app without the lanes
capability, and a circle key handed out as the server key.

## Encrypted chat scenario

`app/test/e2e_real_server/chat_e2e_test.dart` runs in the same stack
(`scripts/e2e-lanes.sh test/e2e_real_server/chat_e2e_test.dart`): three phones
exchange sealed chat, edit, delete (author and admin, plus a member's forged
edit/delete that must change nothing), a photo, a removed member, and a member
in the server lane whose chat still goes on the phone line while the real
sidecar runs. The database is searched for the message words (`e2ee_items`,
`chat_messages`, `audit_log`, photo blobs) and the script greps the server log
for them at the end. Plaintext send answers 409 `chat_encrypted`.
