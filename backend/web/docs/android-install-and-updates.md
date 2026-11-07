# Installing OpenFamily on Android and getting updates

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
6. Open OpenFamily. When asked, enter the **server URL** the operator gave you
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

## Private repo

Obtainium needs a GitHub token: create a fine-grained personal access token
with read-only **Contents** access to that repo only, and paste it in Obtainium
Settings under **GitHub personal access token**. On the server set
`APK_GITHUB_TOKEN` (if used) similarly.

## Operator: verify the signature

```
apksigner verify --print-certs openfamily-<version>.apk
```

The `SHA-256 digest` of the certificate must equal the one from your keystore
(`docs/android-release.md`). Also check the file against `SHA256SUMS.txt` from
the release (`sha256sum -c SHA256SUMS.txt`). If the fingerprint ever differs,
do not install. Android itself refuses an update signed with a different key.
