# Performance of Private (phone-only) circles

Scope: release 0.23.1 work on the lag reported on an Android phone while a circle runs in Private mode: a laggy
bottom sheet, a slow UI, and members showing "location not available".

**Important: every number below was measured in the Flutter test VM on the build server (desktop CPU, in-memory
stores, no platform channels). They were NOT measured on a phone.** A phone CPU is several times slower and every
store/vault call there is a platform-channel round trip, so the real gains should be larger than the ratios here, but
that is a claim about the structure of the work, not a measurement. Reproduce with
`flutter test test/perf/private_pipeline_bench_test.dart` (prints `PERFMETRIC` lines).

## What was found (by reading the code, then confirmed by the benchmarks)

The bottom sheet itself was already fine: `test/perf/sheet_drag_builds_test.dart` (existing) shows that dragging the
People sheet rebuilds no rows. Roster updates are already coalesced to at most one per 220 ms
(`FamilyService.uiCoalesceWindow`). The jank came from what ran on the UI isolate **around** the sheet in a Private circle:

| # | Cause | Where | Per received item |
|---|---|---|---|
| 1 | Every received fix rewrote the member's whole stored track (up to 6000 points: decode JSON, merge, sort, encode, write) | `PrivateHistory.add` | one rewrite |
| 2 | Every item read its circle key from the vault (Android Keystore decrypt behind a platform channel) | `ServiceChannelKeys` -> `E2eeService.circleKey` | one vault read |
| 3 | Pure-Dart XChaCha20/HKDF/Ed25519 on the UI isolate (`cryptography` without `cryptography_flutter`) | `ChannelReceiver.process` | ~5 ms on a desktop CPU |
| 4 | Receiver bookkeeping written per item (replay window of 512 seqs, high-water mark, epoch) | `ChannelReceiver.process` | 3 to 4 store writes |
| 5 | One map frame (and so one roster change, one coalescer entry) per item, also for catch-up items that are already outdated | `PrivateRuntime._apply` | one frame |
| 6 | `replayLatest` (runs on **every** members snapshot) decoded each member's whole 7 day track just to take the last point | `PrivateRuntime.replayLatest` | n/a |
| 7 | The upload queue was fully decoded three times per change (version check, write, read-back) | `SealedQueue._mutateOnce` | per own fix |
| 8 | `OnDeviceProcessor` (trip/drive/week) ran on every own fix, on the UI isolate, for every phone-only member | `PrivateRuntime._processOnDevice` | per own fix |
| 9 | A snapshot of the roster (REST or `members` frame) carries no positions in a Private circle, so every member showed "No location yet" until an async replay finished | `FamilyService._replaceMembers` | per snapshot |

On Android the preferences file is also re-read (`SharedPreferences.reload()`, every key, including the big track
blobs) every 2 s and on every queue access; that cost grows with the size of the stored tracks. It is **not**
changed here (see "Not done").

## Benchmarks: before and after

Scenario: Alice sends 300 fixes (10 s apart); Bob's phone catches up on them in one go (the "open the app after a while"
case). Counting stores and a vault in the harness `test/support/private_bench_harness.dart`.

| Metric (Bob, 300 items) | Before (0.23.0) | After | 
|---|---|---|
| vault (Keystore) reads | 300 | 1 |
| key-value store reads | 1803 | 12 |
| key-value store writes | 905 | 9 |
| bytes written to the store | 1,868,457 | 1,846 (plus one track write, below) |
| bytes written, with a full 6000-point track already stored | 68,424,556 (68 MB) | 228,845 |
| map frames / roster changes | 300 | 2 |
| wall time of the whole catch-up (inline crypto) | 1771 ms | 1532 ms |
| wall time with a full 6000-point track | 5363 ms | 1589 ms |
| `replayLatest` x10 with a 6000-point track | 41 ms | 1 ms |

Reading the table honestly:

* The crypto itself costs about the same (~5 ms per item here). It did not get faster; it was moved. In the app it now
  runs in a long-lived worker isolate (`WorkerOpenRunner`, `item_open_job.dart`), so the UI isolate only does the
  cheap checks and the single apply per page. In the test VM the longest stretch the event loop was blocked during the
  catch-up fell to **21 ms** with the worker (45 ms with the inline runner, which yields every 4 items). The "before" run
  cannot be compared on this metric: its event loop never yielded between items, so the probe timer never fired
  (`maxLoopBlock=0` there means "the probe was starved", not "no blocking").
* The big wins are I/O and rebuild counts: 300 -> 2 frames, 68 MB -> 0.2 MB written, 300 -> 1 Keystore reads.
* Sender side, 300 fixes sealed, queued and uploaded: 2742 ms (about 9 ms per fix, mostly the Ed25519 signature and the
  AEAD). No "before" figure was taken for this. The queue change (#7) removes two of the three full decodes per change;
  that is by construction, it is not separately benchmarked.

## What changed

* **Receiver** (`private_channel.dart`): `ChannelReceiver.processMany` verifies a page in three stages: cheap checks and
  key/sender lookup (once per page), the heavy crypto as one hop to an `OpenRunner`, then the stateful checks (clock,
  replay window, epoch rollback, lane verdict) in order. Every check and its error mapping is unchanged; `process` is
  `processMany` of one. State is persisted once per batch. The same `(device, seq)` twice in one batch is refused as a
  duplicate. Tests: `test/services/e2ee/*` (unchanged, green) and `private_pipeline_regression_test.dart` (worker and
  inline runner give identical verdicts, including a flipped ciphertext byte and a duplicate).
  Small behaviour difference: for the legacy v1 item format the sender record is looked up before decrypting (v2 already
  did); a garbage item from an unknown device is now rejected as `unknownSender` instead of `badCipher`.
* **Worker isolate** (`item_open_job.dart`): only plain bytes cross to the worker (key, ciphertext, sender public key);
  it starts on first use, stops after 30 s idle, and falls back to the calling isolate if it cannot start or times out.
  The key never leaves memory except as that message.
* **Keys remembered** (`ServiceChannelKeys`): found keys for 10 minutes, newest-epoch answers for 15 s, dropped when keys
  were synced (`forgetKeys()` for sign-out). Missing keys are never cached.
* **History** (`PrivateHistory`, `writeBehind`): new points wait in memory and are merged into the stored track once per
  4 s / 400 points; reads and `flushStores()` (called when the app is paused) see them. The headless background isolate
  keeps the old write-at-once behaviour because it can be killed at any time.
* **Catch-up apply** (`PrivateRuntime._applyBatch`): fixes are grouped per member: one history write, one map frame with
  the newest fix. Older items of the page are in the history but are not replayed to the map.
* **Upload queue** (`SealedQueue._head`): the version/writer check reads the first two fields with a pattern instead of
  decoding the whole queue.
* **Last known position** (`last_positions.dart`): the newest received position per member and circle is kept in the
  E2EE vault (Android Keystore wrapped, same as the circle keys), written 3 s after a change and when the app pauses,
  loaded once at start (`PrivateRuntime.warmUp`). It is never dropped for being old. `replayLatest` now reads it instead
  of the tracks; `FamilyService._replaceMembers` puts it on the roster immediately (synchronously) so a snapshot never
  flashes "No location yet".
* **Heavy on-device processing is opt-in** (see below).

## "Location not available" in Private mode: the cause and the wording

Traced path: item -> `ChannelReceiver` -> `PrivateRuntime._apply` -> `onMemberFrame` -> `FamilyService.applySealedLocation`
-> `_applyLocation` -> `Member` -> `memberStatusLine` / `MemberTile` / `PersonPanel`.

Every place that prints "No location yet" is gated on `member.position == null`
(`member_tile.dart`, `member_status.dart`, `member_detail_screen.dart`, `person_panel.dart`, `member_mapper.dart`,
`widget_snapshot.dart`). Ways a phone that **does** receive items still had a null position:

1. **Roster snapshots wiped positions** (cause 9): the server sends no positions for a Private circle, and the restore
   was an async replay that decoded whole tracks. Fixed (synchronous restore from memory).
2. **Cold start was empty** until a fresh item arrived or the track store was decoded. Fixed (vault-backed last position).
3. A frame for a member that is not yet in the roster is dropped (`_applyLocation` returns when the id is unknown). The
   position is now in the last-position book and is applied when the roster arrives (`_withLastKnown`).
4. When a silent member had a delivery hint (for example "has not received the circle key yet"), the hint **replaced**
   the age of the last position. Now the screen says both: "Kin's phone has not received the circle key yet · last seen 3 h ago"
   (`memberStatusLine`, `memberDetailStatus`). Older than 24 h the plain "Updates stopped" line says "last seen 2 d ago"
   instead of a clock time with no date. The reasons themselves still come from `DeliveryHints` (v0.22.2).
5. Items that are really refused (no key, unknown sender, old app) still give nothing to show; that is what the
   delivery hints explain.

No code hides a member because the fix is old: the only staleness handling is the grey "stopped" status and the
"Position from 3h ago" label (`kStaleAfter` = 10 minutes), the pin stays. Verified by reading the marker and list code
(`map_screen.dart` filters only on `position != null`).

## On-device reports are an opt-in switch, off by default

Owner decision: a phone-only member's phone does only the light essentials by default (send its fix, receive and decrypt
the others' latest fix, show the map). Trip, drive and weekly figures are **not** computed and no result item is sealed or
sent until the member turns on **"Compute driving reports on this phone"** (My data processing screen,
`OnDeviceReportsTile`).

* Setting key: `OnDeviceReportsSetting.kvKey` = `procset/on_device_reports`, value `1` = on. It lives in the private-circle
  store, i.e. the SharedPreferences key `e2ee_chan_procset/on_device_reports` (a file named after it on iOS), so the
  background location isolate reads the same value. Code: `lib/services/processing/on_device_setting.dart` and
  `lib/widgets/on_device_reports_tile.dart` (separate small files on purpose).
* When on: fixes are collected and processed in a batch at most every 60 s (`onDeviceBatchEvery`), yielding to the event
  loop every 20 fixes, and `onDeviceAllowed` can veto a batch (hook for "only while charging / battery not low"; not yet
  wired to a battery source). **It still runs on the main isolate**, not in a background isolate: the processor writes through the
  same stores as the rest of the runtime. Running it in an isolate was not done (see below).
* When off, the "Waiting for X's phone" card now ends with "Driving reports need the server: turn on the server for this
  circle, or X can enable phone reports."
* Server-assisted members are unaffected (the server computes for them).

## Startup and release configuration (checked, no change needed)

* Release APKs are built with `flutter build apk --release` (`.github/workflows/apk.yml`): AOT, no asserts. The app has
  one `assert(` and two `print`/`debugPrint` calls in `lib/`; nothing logs per item. `PerfMonitor` recording is off unless
  switched on (`if (!recording) return;`).
* `main()` awaits only the stored settings the first frame needs, read together (`prefs` step in `PerfMonitor`), and
  starts push registration and the config refresh after the first frame. The Private runtime does nothing before the first frame
  (`warmUp` is started from the map screen's `initState`, not awaited).

## Not done / could not verify

* **Not measured on a phone.** No Android device or emulator was available; all timings are test-VM timings.
* **`SharedPreferences.reload()` cost** (whole file, every 2 s and on every queue access) is unchanged. Moving the large track
  blobs out of preferences into files on Android was considered and not done: the headless background isolate has no
  custom platform channel on Android to find a directory, and a wrong fallback could split data. It is the most likely
  remaining source of lag on a phone with many members; a measurement on a device is the next step.
* **`cryptography_flutter`** (native crypto) was not added: it needs a native build that could not be verified here. The
  worker isolate removes the work from the UI isolate without it.
* **Isolate for on-device reports**, battery/charging gate: see above.
* Sealing of the phone's own fixes still happens on the UI isolate (about 9 ms per fix on a desktop CPU, one per few seconds).
