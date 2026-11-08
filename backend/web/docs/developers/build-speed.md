# Build and CI speed

How long builds take, what the CI and the local scripts do to make them faster, and what to look at in the first CI runs. Measured numbers and estimates are kept apart on purpose.

## Where the time went (measured, GitHub runs of 2026-11-07/08)

Taken with `gh api repos/.../actions/runs/<id>/jobs` from the v0.25.2 tag run.

| Workflow / job | Wall time | Biggest steps |
| --- | --- | --- |
| Android release (`apk.yml`), one job | 15m 15s | analyze + test 222 s, **four sequential `flutter build` runs 635 s**, set up Flutter 23 s, SBOM 11 s |
| Wear OS release | 15m 19s | own work only about 3 min (tests 80 s, build 98 s); the other 12 min is `Attach to the GitHub release` polling for the release that `apk.yml` creates |
| Test: `ios` (macOS) | 26m 19s | RunnerTests 1101 s, simulator boot and install 177 s, simulator build 193 s |
| Test: `watchos` (macOS) | 4m 49s | iPhone build with watch 141 s |
| Test: `flutter` | 5m 08s | `flutter test` 255 s, analyze 19 s |
| Test: `backend` | 2m 35s | database container 31 s, tests 93 s |
| Test: `docs` | 13 s | |
| iOS unsigned IPA | 16m 04s | |
| Release images | 8m 52s | |

Earlier failures cost more than slow successes: v0.25.1 ran 37 minutes before failing (a Kotlin compile error that only showed up inside the long build), v0.25.0 failed after 1 minute.

Local, in Docker on the 16-core development host (shared with production and other jobs; load average was about 20 during these runs):

| Local run | Time |
| --- | --- |
| Cold-ish arm64 release APK (`apk-fast.sh --clean`: empty `app/build`, warm Gradle/pub/SDK volumes) | 662 s inside the container (Gradle 593 s) |
| Same, nothing changed, new container | 165 s (Gradle 161 s) |
| `:app:compileReleaseKotlin :app:lintVitalRelease` only (the CI early check), new container | 312 s |
| `--configuration-cache` | build fails ("Configuration cache entry discarded with 1 problem"), so it is **not** enabled |

These are pessimistic: the host was busy, and each run starts a fresh Gradle daemon (about a minute of JVM start and configuration under load). On an idle machine expect roughly half. A run from a truly empty set of volumes also downloads the SDK, NDK and Gradle dependencies (several GB) and was not repeated.

## What changed in CI

All of it is in `.github/workflows/`. Nothing could be run on GitHub from here, so the effect is **estimated** until the first runs (see the checklist below).

### `apk.yml` (tag push, manual run)

One job became parallel jobs; only `publish` waits for all of them:

- `compile-check`: Kotlin compile plus Android vital lint of the release variant. Fails in a few minutes on native errors instead of after the whole build (the v0.25.1 case). Measured locally at 312 s on a loaded host.
- `verify`: `flutter analyze` and `flutter test`. No longer in front of the builds, but `publish` needs it, so a red test still blocks the release.
- `build-main`: combined APK, then the AAB, from one checkout and one `flutter pub get` (`--no-pub` afterwards).
- `build-abi`: matrix, one runner each for the arm64-v8a and armeabi-v7a APKs. They add no wall time. They are cheap to keep (about 3 to 4 minutes of an otherwise idle runner each); `/app.apk` only serves the combined file, and the arm64 file is the server's fallback.
- `sbom`, `meta` (version math): seconds.
- `publish`: checksums, `apksigner` check (now also checks that all three APKs carry the same certificate), size budget warning, GitHub Release. This is the only job with `contents: write`.

Security properties kept: every action pinned to a commit SHA (the old `apk.yml` used floating `@v4` tags for four), `permissions: contents: read` by default, signing secrets are read only by the two build jobs in the signing step, key files are deleted with `if: always()` right after the build, nothing signed leaves a build job except the APK/AAB artifacts.

**Not done: one Gradle invocation for APK and AAB.** `flutter build` is one command per output type. Calling `./gradlew assembleRelease bundleRelease` directly needs the dozen `-P` properties the Flutter tool normally passes; that is easy to get subtly wrong and cannot be tested without a tag. The AAB step runs after the APK step in the same checkout so Gradle's up-to-date checks and build cache can skip repeated work; whether Dart AOT is reused is the first thing to read in the first run log (step times of the two builds).

### Caches

Gradle caches (`~/.gradle/caches`, wrapper), the NDK and CMake directories of the runner SDK, the pub cache (through `subosito/flutter-action`) are restored from `actions/cache`. A tag run cannot save a cache that other tags can read (GitHub scopes caches by ref), so the new `android-cache.yml` builds them on main when `app/android/**`, `app/pubspec.lock` or `wear/**` change, and weekly so they do not expire. Tag jobs only restore. Cache poisoning: only merged code on main can write them, pull requests cannot.

The runner gets `~/.gradle/gradle.properties` with a 6 GB heap and parallel and caching on. The repo `app/android/gradle.properties` now has `org.gradle.parallel=true`, `org.gradle.caching=true`, `kotlin.incremental=true` with the conservative 4 GB heap kept, and `wear/gradle.properties` the same flags.

### `wear.yml`

Gradle cache restore; unit tests stay before the signing material exists, but share one Gradle daemon with the build; the wait for the release polls every 15 s instead of 60 s. It still waits for `apk.yml`'s `publish`; the watch build itself is about 3 minutes.

### `test.yml`

- A `changes` job decides which jobs are needed. Docs-only changes run only `docs` (13 s). The two macOS jobs run only when `app/ios/**`, `app/pubspec.*` or `scripts/ios-watch-target.py` changed (or the workflow itself). If the diff cannot be computed, everything runs. Skipped jobs count as passed for branch protection. Tags always build iOS through `ios-unsigned.yml`.
- Flutter: analyze runs once; tests run in 3 shards with `--concurrency $(nproc)`. A final job still named `flutter` aggregates them so an existing required check keeps working. If `flutter test` was 255 s, estimate about 100 s per shard plus 45 s setup. The check names `flutter-analyze` and `flutter-test (1..3)` are new; add them to branch protection if you prefer them over the aggregate.
- Backend: stays `-p 1 -count=1` (packages share one database, and DB tests must really run). Go module and build cache come from `setup-go`. There is not much to win here (93 s of tests); a faster database image start was not attempted.
- Concurrency group: a newer push to the same PR or to main cancels the older run. Tags and manual runs never cancel.
- Shallow checkouts everywhere (`fetch-depth: 1`), job timeouts, pinned actions.
- macOS `RunnerTests` (1101 s) is the slowest job of the whole workflow. It builds the app a second time with `xcodebuild`. Sharing the derived data with the Flutter build, or caching Pods, is the next thing to try on a Mac; it could not be tested here.

### Self-hosted runners: no

The repo is public. A pull request from a fork can change a workflow and run arbitrary code on a self-hosted runner, which would be the owner's server (production data, keys, other apps). GitHub warns against exactly this. Everything here uses GitHub-hosted runners.

## Realistic targets

| | Before | Target | Why |
| --- | --- | --- | --- |
| Tag to signed APK on the release | 15 min (Android) | **about 8 to 10 minutes** (estimate) | critical path is now one runner doing APK then AAB (about 6 to 7 min with warm caches, from the 593 s of Gradle measured locally under load and the 635 s CI figure for four builds, minus two builds) plus about 1 min publish |
| Failure of a native/Kotlin error | after 6 to 37 min | **about 3 to 5 min** (`compile-check`) | |
| Docs-only push | whole test workflow | about 30 s | `changes` |
| Flutter tests in CI | 5 min | about 2.5 min | 3 shards |

Under 10 minutes is realistic only with a warm cache from main; a tag pushed right after a Gradle or `pubspec.lock` change misses the cache once (GitHub runners do not share anything else), and then costs what it cost before.

## Local fast builds

```bash
scripts/dev/apk-fast.sh                 # arm64 release APK, debug-signed
scripts/dev/apk-fast.sh --profile --install   # profile build, adb install -r
scripts/dev/test-fast.sh flutter test/chat     # targeted Flutter tests
scripts/dev/test-fast.sh go ./internal/chat/...  # Go tests with a throwaway database
```

`apk-fast.sh` keeps Gradle, pub and the SDK in Docker named volumes and builds inside this checkout, so repeat runs only redo what changed. The APK is signed with the **debug** key and says so in its file name (`...-DEBUG-SIGNED.apk`): fine for a test phone, not distributable, and it cannot update a phone that has the real build installed (uninstall first, local data is lost). Output goes to `.local-apks/` (git-ignored). `--cpus` defaults to 6 because the host is shared; use `/tmp/orbitly-heavy/heavy.sh` in front on the shared host.

For the inner loop, do not build APKs at all. On a desktop with Flutter installed, `cd app && flutter run -d <phone or emulator>` gives hot reload (press `r`) in about a second per change; use `flutter run --profile` for performance questions. Kotlin or manifest changes need a full run once; Dart changes do not. Use the APK script when you need a file to hand to someone or to test the release (R8) build.

## First CI runs: what to check

1. A push to main touching `app/android/**` runs `android-cache.yml`; both jobs should go green and write a cache (log line "Cache saved"). The second run should show "Cache restored".
2. Open a docs-only pull request: only `changes` and `docs` should run, `flutter`, `backend`, `ios` and `watchos` show as skipped.
3. Open a pull request touching `app/lib/**`: `flutter-analyze`, 3 `flutter-test` shards and the `flutter` aggregate run; no macOS job.
4. Push a pre-release tag (for example `v0.25.3-rc.1`): note the duration of `compile-check`, `build-main` (per step: APK build and AAB build separately), `build-abi`, `publish`. If the AAB step is as long as the APK step, Dart AOT is not being reused and the next step is to drive Gradle directly.
5. Confirm the Release has the same file names as before and the three APKs show the same signing certificate in the `publish` log.
6. In `compile-check`, confirm it reaches the Gradle step (the `--config-only` fallback is written but not exercised from here) and that restored NDK/CMake paths (`/usr/local/lib/android/sdk/...`) match the runner image; if the cache restores 0 bytes there, fix the path.

## Follow-up measuring plan

Record for five tags: per-job and per-step seconds (`gh api repos/<repo>/actions/runs/<id>/jobs`), cache hit or miss, queue time before each job starts. Compare with the table above. Then decide: drive Gradle directly for APK plus AAB; shard `build-abi`; keep or drop the armeabi-v7a-only APK; macOS RunnerTests derived-data reuse; a prebuilt CI container image with SDK, NDK and Flutter if cache restore time dominates.
