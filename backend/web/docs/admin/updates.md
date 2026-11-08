# Updating the server

Updating is a script on the server, never a button on the web. That keeps the
web page from holding powers over your machine.

```bash
./scripts/upgrade.sh
```

It makes a backup, pulls the new version, rebuilds, waits until `/healthz` is
healthy and rolls back to the previous version if it is not. Run it from the
server's Orbitly folder (it may still be called `openfamily`) with no uncommitted changes.

## Before you update

- Read [What is new](../CHANGELOG.md) (also on the admin **Documents** page).
- Check [App versions](app-versions.md): after the update the server supports
  the **last five** app versions. People on older apps see "Update required".
- Make sure you have a recent [backup](backups.md).

## After you update

- Admin web, **System**: confirm the version and a healthy database.
- Admin web, **Settings, App versions**: see who needs a nudge, and copy the
  ready-made message.
- The Documents page now shows the notes for the new version.

## Updating the phones

Family members update the app via Obtainium or the store. The server keeps
working for the last five minor versions, so nobody has to update on the same
day. See [API compatibility](../api-compat.md).

**Watch app.** Each release can also carry `orbitly-wear-<version>.apk` (and an
`.aab`), the Wear OS watch app, built by a separate workflow (`wear.yml`) and
attached to the same release once the phone build has created it. The watch app
needs nothing on your server; it only talks to the phone it is paired with. Update
it with the phone app, see [Orbitly on your watch](../user/watch.md). The server's
APK download never serves the watch file.

## Something went wrong

`upgrade.sh` prints how to restore the pre-upgrade backup. See
[Backup and restore](../backup-restore.md) and [Troubleshooting](troubleshooting.md).
