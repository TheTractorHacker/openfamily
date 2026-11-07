# Updating the server

Updating is a script on the server, never a button on the web. That keeps the
web page from holding powers over your machine.

```bash
./scripts/upgrade.sh
```

It makes a backup, pulls the new version, rebuilds, waits until `/healthz` is
healthy and rolls back to the previous version if it is not. Run it from the
server's `openfamily` folder with no uncommitted changes.

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

## Something went wrong

`upgrade.sh` prints how to restore the pre-upgrade backup. See
[Backup and restore](../backup-restore.md) and [Troubleshooting](troubleshooting.md).
