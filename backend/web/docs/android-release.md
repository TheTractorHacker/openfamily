# Android release process (operator)

## Signing key

The release keystore lives OUTSIDE the repository:

- `/home/dockhub/OpenFamily/private/keys/openfamily-release.jks` (mode 600)
- `/home/dockhub/OpenFamily/private/keys/key.properties` (mode 600; holds the passwords and the alias `openfamily`)

The directory is mode 700. `.gitignore` excludes `key.properties`, `*.jks` and `*.keystore`.

**Losing this keystore (or its passwords) means every installed copy can never
update again: family members must uninstall and reinstall the app (losing local
app data).** Back it up now:

1. Copy `openfamily-release.jks` and `key.properties` to at least two places you
   control, e.g. an encrypted USB stick and your password manager (attach both
   files, or store the base64 of the jks plus the passwords).
2. Test the backup: `keytool -list -keystore <copy>.jks` asks for the password.
3. Never commit them, email them, or paste them in chat.

Check the certificate fingerprint any time (it asks for the password):
`keytool -list -v -keystore openfamily-release.jks -alias openfamily | grep SHA256`.

## GitHub secrets

Run `scripts/android-secrets.sh owner/repo` and execute the printed `gh secret set`
commands. It prints no secret values. Secrets: `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.

## Releasing

```
git tag v0.2.0 && git push origin v0.2.0
```

The workflow `.github/workflows/apk.yml` runs `flutter analyze` and `flutter test`,
builds the signed APK and AAB, writes `SHA256SUMS.txt`, and creates the GitHub
Release with `openfamily-<version>.apk` (pre-release tags such as `v0.2.0-rc.1`
become GitHub pre-releases). The server's download cache (`APK_GITHUB_REPO`)
picks the first `.apk` asset of the latest `v*` release, which matches.

versionName is the tag without `v`. versionCode is
`(major*1000000 + minor*1000 + patch)*100 + 99` (final) or `+ rc number`
(pre-release), so newer tags always install over older ones. Do not reuse or
move tags. Minor and patch must stay below 1000.

A manual run (workflow_dispatch) only produces downloadable workflow artifacts.

## Local build

Put the keystore path in `app/android/key.properties` (`storeFile` is relative
to `app/android/app/`, absolute paths work), then `flutter build apk --release`.
Without key.properties the release build fails on purpose; for a throwaway
test build pass `-POPENFAMILY_ALLOW_DEBUG_SIGNING=true` (never distribute it).
