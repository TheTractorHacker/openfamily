# Troubleshooting

Find your problem in the list, try the short checks, then follow the link for the full steps.

Always start with these three commands on the server. They answer most "is it even running?" questions:

```bash
docker compose ps                         # every service should be running / healthy
curl http://localhost:8080/healthz        # {"status":"ok"}
docker compose logs --tail 100 api        # the last lines of the server log
```

The admin web **System** page lists recent warnings and errors, and **Fleet** shows when each phone last reported.

> **Tip** When you ask for help, say your server version (shown in the admin web footer) and paste the last lines of the log. Remove addresses and secrets first.

## Nobody shows on the map

1. Open the server address in the phone's browser. If it does not load, fix DNS, ports 80/443 or the VPN first ([HTTPS and domain](../admin/https-and-domain.md)).
2. On the phone: location **all the time**, battery **unrestricted** ([Battery and permissions](../user/battery-and-permissions.md)).
3. In the circle: is **Share my location** on, and has the person paused sharing?
4. Private circle? The admin web cannot show it unless you are a member who approved the browser. Phones show each other.
5. Old app? With enforcement on, an unsupported app's uploads are refused ([App versions](../admin/app-versions.md)).

Full steps: [Nobody shows on the map](../admin/troubleshooting.md#nobody-shows-on-the-map) and the deep dive for Private circles, [No locations](no-locations.md).

## Locations stop when the phone is locked or idle

The screen being off is normal; Android or iOS stopping the app is the problem.

- Allow location **all the time**, allow notifications, and switch off battery saving for Orbitly ([Battery and permissions](../user/battery-and-permissions.md)).
- Run **Settings, Phone health** in the app: it checks permissions, battery exemptions and connectivity.
- Some phone makers close apps aggressively; see what happens when Android freezes the app in [Push](../push.md) and [Reliability](../reliability.md).
- The admin **Fleet** page shows the last time each phone reported and why it may have gone silent.

## Sessions: sign-in problems, lost phone

- **Lost or stolen phone:** sign in elsewhere, open **Settings, Security, Active sessions**, end the old session and change your password ([Lost or stolen phone](../user/members-and-devices.md#lost-or-stolen-phone)).
- **New phone:** sign in again; in a Private circle another of your devices must approve it, or use your recovery key.
- **Admin web says "Access denied":** only platform admins see admin pages. If `REQUIRE_ADMIN_MFA=true`, turn on two-step sign-in in the app, then sign out and in again.
- **Invite code refused:** check it was typed exactly, has not expired and that you are on the right server ([Invite and join](../user/invite-and-join.md)).

## Backups

- The admin **System** page warns when the last backup is missing or older than 48 hours. Run `./scripts/backup.sh` and copy `backups/` off the machine.
- Prove a backup works with `./scripts/verify-backup.sh backups/<file>.dump`.
- Back up the `server_device` volume with the database (losing it only means approving the server again).
- Restoring: [Backups and restore](../admin/backups.md#restore), in depth [Backup and restore](../backup-restore.md).

## Notifications and push

- Android has built-in push and needs nothing extra, but the phone must let the app run in the background ([Notifications](../admin/notifications.md)).
- Optional ntfy or UnifiedPush: check the ntfy app is installed and its server is reachable ([Push](../push.md#unifiedpush--ntfy-optional)).
- iPhone alerts need Apple push to be set up by the server admin ([Apple push](../admin/notifications.md#iphone-apple-push-apns)).
- SOS by text message needs an SMS provider ([SMS for SOS](../admin/notifications.md#sms-for-sos-optional)).
- Alerts say only "New message in a circle" unless verbose notifications are on; that is by design.

## Updates

- `./scripts/upgrade.sh` makes a backup and rolls back on its own if the new version is not healthy ([Updating the server](../admin/updates.md)).
- If it rolled back or left things off, restore the `backups/pre-upgrade-*.dump` ([Backups](../admin/backups.md)).
- People on an old app see "Update required": the server supports the last five app versions ([App versions](../admin/app-versions.md)).
- A phone that says "needs update" in a Private circle must update before it shows up; a circle admin can switch the circle to Normal in one tap ([Concepts](../concepts.md)).

## The server will not start

Run `docker compose run --rm api validate-config`. It prints what is wrong without showing secrets. Usual causes: `JWT_SECRET` or `POSTGRES_PASSWORD` not set, or a database TLS setting ([Self-hosting](../self-hosting.md#database-tls)).

## Still stuck

Open an issue at https://github.com/TheTractorHacker/openfamily/issues with the server version and the last lines of `docker compose logs api`.
More answers: [FAQ](../faq.md), [Admin troubleshooting](../admin/troubleshooting.md).
