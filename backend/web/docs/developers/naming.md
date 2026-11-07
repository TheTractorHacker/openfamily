# Naming: what is Orbitly and what is still "openfamily"

The product is called **Orbitly** (formerly OpenFamily). Everything a person
sees uses the new name. A number of internal identifiers keep the old spelling
**on purpose**: changing them would break existing installs, signed builds,
stored data or the wire protocol, and gains nothing for users.

| Identifier | Value | Why it stays |
|---|---|---|
| Android `applicationId` / namespace | `app.openfamily` | Android updates only apply to the same application id; it also ties push registration and the signing key. |
| iOS bundle id | `app.openfamily` (`.RunnerTests`) | Same: app updates, keychain and associated domains. |
| Keystore alias, release signing key | unchanged | A different key cannot update installed apps. |
| Deep-link scheme | `openfamily://join` | Invite links already shared and stored in messages keep working. |
| Dart package name | `openfamily` (`app/pubspec.yaml`, `package:openfamily/...`) | Internal; renaming only creates churn in every import. |
| Dart widget `OpenFamilyMark`, file `openfamily_brand.dart` | unchanged | Internal names. Shows the Orbitly mark. |
| Go module path | `github.com/TheTractorHacker/openfamily/backend` | Import paths; independent of the GitHub repository name. |
| Database name and role | `openfamily` | Existing data directories and backups. |
| Docker compose project `name:`, services, volumes, images (`openfamily-api:local`, ...) | unchanged | Volume names derive from the project name; renaming would orphan data. |
| Environment variables | `OPENFAMILY_*`, `E2EE_*` | Existing `.env` files. |
| HTTP headers | `X-OpenFamily-Compat`, `-Min-App-Version`, `-Latest-App-Version`, webhook `X-OpenFamily-*` | Wire protocol with released apps and Home Assistant. |
| Crypto and protocol labels | `openfamily/e2ee/v1/...`, `openfamily/backup-settings/v1`, ... | HKDF/AEAD domain-separation strings. Changing one makes existing keys and ciphertexts unreadable. |
| API paths, SQL, migrations | unchanged | Compatibility. |
| Home Assistant integration domain | `openfamily` (`custom_components/openfamily`, event names `openfamily_*`) | Existing HA installs and automations. Only the display name is Orbitly. |
| Backup file names | `openfamily-<timestamp>.dump` | Restore tooling and retention find them by this pattern. |
| `web/package.json` name | `openfamily-admin` | Internal. |
| Local APK cache file | `openfamily-release.apk` | Internal file inside `APK_DIR`. |

## Release files

Release assets from the rename on are named `orbitly-<version>.apk`, `.aab`,
`.spdx.json`, `-unsigned.ipa` and listed in `SHA256SUMS.txt`. Earlier releases
keep their `openfamily-<version>.*` names. The server picks the first `.apk`
asset of the latest release regardless of its name, so `/app.apk` and the
admin Builds page work with both. Obtainium filters that matched
`openfamily` should be changed to `orbitly` (or removed).

## GitHub repository

The repository is renamed from `TheTractorHacker/openfamily` to
`TheTractorHacker/orbitly`; GitHub redirects the old address. The only place
that holds the URL in code is `app/lib/brand.dart` and `web/src/lib/brand.ts`
(the `APK_GITHUB_REPO` default and the docs also name it). CI guards accept
both names until the rename is done.

## Keeping the rename clean

`scripts/rebrand.sh` renames user-visible strings, is safe to run again on a
merged tree, and `scripts/rebrand.sh --verify` (run in CI) fails if the old
product name reappears in user-visible text. It has an explicit list of files
it never touches (NOTICE, LICENSE, credits, this page, changelog history,
vendored packages, migrations). A line that must keep the old name, for
example a credit to the upstream project, is kept by including the words
"Based on OpenFamily", "formerly OpenFamily" or "wheresfrank".
