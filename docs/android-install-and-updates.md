# Installing Orbitly on Android and getting updates

How family members install Orbitly on Android with Obtainium and receive updates, and how the operator publishes them.

## Family members: install once

1. On your phone install **Obtainium** (get it from obtainium.imranr.dev or its
   GitHub releases page, or F-Droid).
2. In Obtainium tap **Add App**, paste the repo URL the operator gave you
   (`https://github.com/OWNER/REPO`) and tap **Add**.
3. Settings for this app (tap its entry, then the gear): leave **Include
   prereleases** OFF. In Obtainium Settings keep **Background updates** ON and
   allow Obtainium to run in the background.
4. Tap **Install**. Android will ask to let Obtainium install apps: allow it.
5. Before installing, check the signature (operator, see below): the operator
   shows you the SHA-256 fingerprint. After install, compare it in Obtainium's
   app info or ask the operator to confirm.
6. Open Orbitly. When asked, enter the **server URL** the operator gave you
   (e.g. `https://family.example.com`) and sign in.
7. Permissions: set **Location to "Allow all the time"**, allow notifications and
   "Physical activity", and when asked choose **Don't optimize** / allow the
   battery-optimization exemption so tracking keeps running. On some brands
   (Samsung, Xiaomi, Huawei) also set the app's battery to "Unrestricted".

## Updates

Obtainium checks GitHub every few hours. When the operator publishes a new
version it downloads and installs over the old one; your data and login stay.
Android may show an "Update" confirmation: tap it. You can also open Obtainium
and pull to refresh. Never uninstall to update.

### Sign-in and encryption keys survive updates

Installing a new version over the old one keeps you signed in and keeps this
phone's encryption key. The app never deletes a key on its own: if the key
store has a hiccup after an update or a restart, the app says the key "can't
be read" and offers **Try again**; nothing is lost while you wait. It only
signs you out when the server says the session is no longer valid, never
because the phone could not read its storage.

If it happens anyway:

1. Tap **Try again**, or restart the phone and open the app again.
2. Open **Settings, Diagnostics** and copy the report: the
   "Sign-in and key storage" section says what failed (no secrets in it).
   Send it to your server operator.
3. Only if the key stays unreadable, use **Set this phone up again**. The old
   key is put aside on the phone, not deleted, and **Encryption keys** offers
   to bring it back if it becomes readable later.

Prepare once, so a lost key is never a problem: write down your **recovery
phrase** (Encryption keys, Recovery phrase), and make sure each Private
circle has a **second admin** who can approve a new phone. Uninstalling the
app deletes its keys; never uninstall to update.

## Release file names

Releases from the Orbitly rename on are called `orbitly-<version>.apk`; older
ones are `orbitly-<version>.apk`. The app and package id are the same, so an
installed app simply updates. If you set an APK name filter in Obtainium, use
`^orbitly-[0-9]` (or clear it). A release also carries `orbitly-wear-<version>.apk`,
the [Wear OS watch app](user/watch.md); that file is not for phones, so do not use
a plain `orbitly` filter. The server's `/app.apk` and the admin Builds page take
the first `.apk` of the latest release that is not an `orbitly-wear-` file.

## Private repo

Obtainium needs a GitHub token: create a fine-grained personal access token
with read-only **Contents** access to that repo only, and paste it in Obtainium
Settings under **GitHub personal access token**. On the server set
`APK_GITHUB_TOKEN` (if used) similarly.

## Operator: verify the signature

```
apksigner verify --print-certs orbitly-<version>.apk
```

The `SHA-256 digest` of the certificate must equal the one from your keystore
(`docs/android-release.md`). Also check the file against `SHA256SUMS.txt` from
the release (`sha256sum -c SHA256SUMS.txt`); the watch app has `SHA256SUMS-wear.txt`. If the fingerprint ever differs,
do not install. Android itself refuses an update signed with a different key.
