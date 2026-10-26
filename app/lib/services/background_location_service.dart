import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:background_locator_2/background_locator.dart';
import 'package:background_locator_2/location_dto.dart';
import 'package:background_locator_2/settings/android_settings.dart';
import 'package:background_locator_2/settings/ios_settings.dart';
import 'package:background_locator_2/settings/locator_settings.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart'
    hide AndroidSettings, LocationAccuracy;
import 'package:http/http.dart' as http;

import 'background_credential_store.dart';
import 'fix_quality.dart';
import 'live_boost.dart';
import 'tracking_cadence.dart';
import 'direct_push_service.dart';
import 'driving/driving_background.dart';
import 'location_outbox.dart';

/// Background location reporting: keeps the device's GPS position flowing to
/// the backend (`POST /locations`) even when the app is backgrounded or killed.
///
/// `background_locator_2` runs [onLocationUpdate] in a **separate background
/// isolate**, so it cannot touch the foreground app's [ApiClient] object. It
/// instead reads the API base URL, device id and ingest key from
/// [BackgroundCredentialStore] (secure storage) and talks to the backend directly via `dart:http`.
///
/// Authentication — the **device ingest key** only
/// (`X-Device-Key: <device_id>.<key>` header): a write-only, device-scoped
/// credential issued at registration and accepted by `POST /locations`,
/// `POST /locations/batch`, and `POST /devices/heartbeat`. It never expires,
/// so background reporting does not depend on the account session.
///
/// This isolate authenticates with the device ingest key ONLY (MOB-002). It
/// never reads or writes the access or refresh token and never calls
/// `/auth/refresh`. If the key is missing or rejected (401/403) reporting
/// pauses (fixes are queued) until the app is opened and provisions a new key
/// via `DeviceService.ensureIngestKey`.
///
/// Offline behavior: a fix that cannot be delivered is **queued** in the
/// [LocationOutbox] (store-and-forward) and delivered via `POST
/// /locations/batch` when a later report succeeds — hours later the family's
/// history shows the track through the dead zone instead of a hole. The
/// callbacks are deliberately non-throwing: any failure (missing credentials,
/// network error, stale `ts`, non-monotonic ordering) is captured or skipped
/// without ever surfacing an exception.

/// How long to wait for a single HTTP request before giving up.
const Duration _httpTimeout = Duration(seconds: 15);

/// Top-level liveness callback, invoked by the plugin's native alarm (roughly
/// every 10 minutes) even when no location fixes are produced — the device
/// stationary, GPS deferred by the OS power manager, etc. POSTs a bare
/// heartbeat so the family's "last seen" stays fresh without a location row.
@pragma('vm:entry-point')
Future<void> onHeartbeatTick() async {
  try {
    // Keep this isolate's direct-push connection (alerts without ntfy) alive.
    DirectPushService.ensureRunningInBackground();
    _initCadence();
    // No fixes may have arrived (stationary / deferred GPS): let expired
    // boosts and stale drive state fall back to the slow profile.
    unawaited(_applyProfile(_cadence.profile(DateTime.now().toUtc())));
    final _BackgroundCredentials? credentials = await _readCredentials();
    if (credentials == null) return;

    final int? batteryPct = await _readBattery();
    final Map<String, dynamic> body = <String, dynamic>{
      'device_id': credentials.deviceId,
    };
    if (batteryPct != null) body['battery_pct'] = batteryPct;

    await _report(credentials, '/devices/heartbeat', body);
  } catch (_) {
    // Never throw from the background callback.
  }
}

// --- adaptive cadence state (per isolate) ---------------------------------

/// Policy for this (background) isolate. Fed by the fixes it receives.
final TrackingCadence _cadence = TrackingCadence()..setBackground(true);
final ProfileApplier _applier = ProfileApplier(_cadence.config);
final FixQualityFilter _fixFilter = FixQualityFilter();
bool _cadenceInitialized = false;

bool _posting = false;
Map<String, dynamic>? _pendingBody;
DateTime? _lastPostAt;
DateTime? _lastSentTs;
DateTime? _lastDrainAt;
DateTime? _batteryReadAt;
int? _batteryCache;
bool _chargingCache = false;
DateTime? _boostReadAt;
DateTime? _presenceReadAt;
bool _presenceCache = false;

/// Minimum spacing of outbox drains while posts keep succeeding (at 1 Hz a
/// drain per post would hammer shared_preferences).
const Duration _drainEvery = Duration(seconds: 10);

void _initCadence() {
  if (_cadenceInitialized) return;
  _cadenceInitialized = true;
  // The service is registered with the stationary profile; record it as the
  // applied one so the first fix does not needlessly re-request updates.
  final DateTime now = DateTime.now().toUtc();
  _applier.markApplied(
    _cadence.profile(now),
    now.subtract(_cadence.config.minApplyGap),
  );
  LiveBoost.register(_cadence, onBoost: () {
    unawaited(_applyProfile(_cadence.profile(DateTime.now().toUtc())));
  });
}

/// Pushes [profile] to the native location request if it changed (debounced
/// by [ProfileApplier]). Prefers the in-place native update; falls back to a
/// full re-registration on Android builds without it. Never throws.
Future<void> _applyProfile(CadenceProfile profile) async {
  try {
    final DateTime now = DateTime.now().toUtc();
    final CadenceProfile? next = _applier.next(profile, now);
    if (next == null) return;
    _applier.markApplied(next, now);
    final int ms = next.gpsInterval.inMilliseconds;
    final bool ok = await BackgroundLocator.updateLocationRequest(
      intervalMs: ms <= 0 ? 1000 : ms,
      distanceFilter: next.distanceFilterM,
      highAccuracy: next.highAccuracy,
    );
    if (!ok && Platform.isAndroid) {
      await BackgroundLocationService._register(next);
    }
  } catch (_) {
    // Never throw from the background callback.
  }
}

Future<void> _refreshBatteryIfStale(DateTime now) async {
  final DateTime? at = _batteryReadAt;
  if (at != null && now.difference(at) < const Duration(seconds: 30)) return;
  _batteryReadAt = now;
  _batteryCache = await _readBattery();
  try {
    final BatteryState st =
        await Battery().batteryState.timeout(const Duration(seconds: 5));
    _chargingCache =
        st == BatteryState.charging || st == BatteryState.full;
  } catch (_) {
    _chargingCache = false;
  }
  _cadence.setBattery(_batteryCache, charging: _chargingCache);
}

/// Picks up a boost persisted by the other isolate (e.g. the direct-push
/// command landed in the UI isolate).
Future<void> _refreshPersistedBoost(DateTime now) async {
  final DateTime? at = _boostReadAt;
  if (at != null && now.difference(at) < const Duration(seconds: 5)) return;
  _boostReadAt = now;
  final DateTime? until = await LiveBoost.readActive(now);
  if (until != null) _cadence.startBoost(until.difference(now), now);
}

Future<bool> _foregroundReporterAlive(DateTime now) async {
  final DateTime? at = _presenceReadAt;
  if (at != null && now.difference(at) < const Duration(seconds: 3)) {
    return _presenceCache;
  }
  _presenceReadAt = now;
  _presenceCache = await ForegroundPresence.isFresh(now);
  return _presenceCache;
}

/// Top-level location callback, invoked by the plugin in the background isolate.
///
/// Must be top-level (or a static method) and annotated `@pragma('vm:entry-point')`
/// so the plugin can look it up by callback handle across isolates.
@pragma('vm:entry-point')
Future<void> onLocationUpdate(LocationDto location) async {
  try {
    // Skip spoofed locations (Android mock-location detection).
    if (location.isMocked) return;
    DirectPushService.ensureRunningInBackground();
    _initCadence();

    // Arms the on-device driving detection (opt-in, no-op unless enabled).
    unawaited(DrivingBackground.onLocationFix(
      speedMps: location.speed > 0 ? location.speed : 0,
      lat: location.latitude,
      lon: location.longitude,
    ));

    final DateTime now = DateTime.now().toUtc();
    await _refreshBatteryIfStale(now);
    await _refreshPersistedBoost(now);

    final DateTime fixTs = DateTime.fromMillisecondsSinceEpoch(
      location.time.toInt(),
      isUtc: true,
    );
    final FixVerdict verdict = _fixFilter.check(
      ts: fixTs,
      lat: location.latitude,
      lon: location.longitude,
      accuracyM: location.accuracy,
      speedMps: location.speed,
      lastSentTs: _lastSentTs,
    );
    if (verdict != FixVerdict.ok) return;

    _cadence.onFix(
      now: now,
      speedMps: location.speed,
      motionState: location.motionState,
    );
    final CadenceProfile profile = _cadence.profile(now);
    unawaited(_applyProfile(profile));

    // Post gate: the profile's minimum spacing, and no doubled traffic while
    // the foreground reporter is alive and running a fast profile.
    final DateTime? lastPost = _lastPostAt;
    if (lastPost != null && now.difference(lastPost) < profile.minPostInterval) {
      return;
    }
    if (profile.isFast && await _foregroundReporterAlive(now)) return;

    final _BackgroundCredentials? credentials = await _readCredentials();
    if (credentials == null) return;

    final Map<String, dynamic> body =
        _buildBody(location, credentials.deviceId, _batteryCache);

    // One request at a time: keep only the newest pending fix; the one it
    // replaces goes to the outbox and ships through the batch path.
    if (_posting) {
      final Map<String, dynamic>? replaced = _pendingBody;
      _pendingBody = body;
      if (replaced != null) await LocationOutbox.enqueue(replaced);
      return;
    }
    await _sendAndDrain(credentials, body);
  } catch (_) {
    // Never throw from the background callback.
  }
}

Future<void> _sendAndDrain(
  _BackgroundCredentials credentials,
  Map<String, dynamic> first,
) async {
  Map<String, dynamic>? body = first;
  _posting = true;
  try {
    while (body != null) {
      _lastPostAt = DateTime.now().toUtc();
      final _PostResult r = await _postLocation(credentials, body);
      if (r.ok) {
        final DateTime? ts = DateTime.tryParse('${body['ts']}')?.toUtc();
        if (ts != null) _lastSentTs = ts;
        if (r.live) {
          final DateTime n = DateTime.now().toUtc();
          _cadence.startBoost(_cadence.config.liveFlagBoost, n);
          unawaited(_applyProfile(_cadence.profile(n)));
        }
        final DateTime n = DateTime.now().toUtc();
        final DateTime? lastDrain = _lastDrainAt;
        if (lastDrain == null || n.difference(lastDrain) >= _drainEvery) {
          _lastDrainAt = n;
          // Bounded so one tick does not flood the radio.
          await LocationOutbox.drain(
            send: (List<Map<String, dynamic>> batch) =>
                _sendLocationBatch(credentials, batch),
          );
        }
      } else {
        // Offline (or auth hiccup): park the fix for backfill.
        await LocationOutbox.enqueue(body);
      }
      body = _pendingBody;
      _pendingBody = null;
    }
  } finally {
    _posting = false;
  }
}

class _PostResult {
  const _PostResult(this.ok, this.live);
  final bool ok;
  final bool live;
}

/// POSTs one location; reports success and the server's `"live": true` hint.
Future<_PostResult> _postLocation(
  _BackgroundCredentials credentials,
  Map<String, dynamic> body,
) async {
  try {
    final http.Response response = await _post(
      credentials.apiBaseUrl,
      _ingestHeaders(credentials),
      '/locations',
      body,
    );
    final bool ok = response.statusCode == 201 || response.statusCode == 200;
    return _PostResult(ok, ok && LiveBoost.responseIsLive(response.body));
  } catch (_) {
    return const _PostResult(false, false);
  }
}

/// The credentials the background isolate can see (secure storage).
class _BackgroundCredentials {
  const _BackgroundCredentials({
    required this.apiBaseUrl,
    required this.deviceId,
    required this.ingestKey,
  });

  final String apiBaseUrl;
  final String deviceId;
  final String ingestKey;
}

bool _migrated = false;

/// Reads the credential set; requires base URL, device id and ingest key.
Future<_BackgroundCredentials?> _readCredentials() async {
  if (!_migrated) {
    _migrated = true;
    // Moves a pre-update plaintext ingest key into secure storage and deletes
    // the legacy prefs entries, in case this isolate runs before the app UI.
    await BackgroundCredentialStore.migrateLegacyPrefs();
  }
  final String? apiBaseUrl = await BackgroundCredentialStore.readApiBaseUrl();
  final String? deviceId = await BackgroundCredentialStore.readDeviceId();
  final String? ingestKey = await BackgroundCredentialStore.readIngestKey();
  if (apiBaseUrl == null ||
      apiBaseUrl.isEmpty ||
      deviceId == null ||
      deviceId.isEmpty ||
      ingestKey == null ||
      ingestKey.isEmpty) {
    return null;
  }
  return _BackgroundCredentials(
    apiBaseUrl: apiBaseUrl,
    deviceId: deviceId,
    ingestKey: ingestKey,
  );
}

/// Delivers one report (location or heartbeat) with the ingest key.
///
/// Returns true only when the backend accepted the report (2xx). Any other
/// outcome (network failure, stale `ts` 400, key rejected) returns false so
/// [onLocationUpdate] can queue the fix for backfill.
Future<bool> _report(
  _BackgroundCredentials credentials,
  String path,
  Map<String, dynamic> body,
) async {
  final http.Response response = await _post(
    credentials.apiBaseUrl,
    _ingestHeaders(credentials),
    path,
    body,
  );
  // 201 = stored; 200 = stationary-deduped (the server refreshed liveness
  // and skipped the locations row); 204 = heartbeat ack.
  return response.statusCode == 201 ||
      response.statusCode == 200 ||
      response.statusCode == 204;
}

/// Sends one drained outbox batch to `POST /locations/batch` with the ingest
/// key. Returns true only on 2xx (the endpoint is idempotent for retries).
Future<bool> _sendLocationBatch(
  _BackgroundCredentials credentials,
  List<Map<String, dynamic>> points,
) async {
  if (points.isEmpty) return true; // Nothing to send.
  final http.Response response = await _post(
    credentials.apiBaseUrl,
    _ingestHeaders(credentials),
    '/locations/batch',
    LocationOutbox.batchBody(points),
  );
  return response.statusCode >= 200 && response.statusCode < 300;
}

Map<String, String> _ingestHeaders(_BackgroundCredentials c) =>
    <String, String>{
      'X-Device-Key': '${c.deviceId}.${c.ingestKey}',
      'Content-Type': 'application/json',
    };

/// Reads the battery level, or null if unavailable (e.g. web, or the method
/// channel is not reachable from the background isolate). Bounded by a timeout
/// so a non-responsive method channel can't stall the callback indefinitely.
Future<int?> _readBattery() async {
  try {
    return await Battery()
        .batteryLevel
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    return null;
  }
}

/// Builds the `POST /locations` body from a [LocationDto]. The motion state
/// arrives piggybacked on the location payload from the native side — the
/// earlier design read it through shared_preferences, which never worked
/// (native writes the plugin's own prefs file; Dart reads Flutter's), leaving
/// every background row's motion_state empty.
Map<String, dynamic> _buildBody(
  LocationDto location,
  String deviceId,
  int? batteryPct,
) {
  final Map<String, dynamic> body = <String, dynamic>{
    'device_id': deviceId,
    'ts': DateTime.fromMillisecondsSinceEpoch(
      location.time.toInt(),
      isUtc: true,
    ).toUtc().toIso8601String(),
    'lat': location.latitude,
    'lon': location.longitude,
    'motion_state': location.motionState,
    'source': 'background',
  };
  if (batteryPct != null) body['battery_pct'] = batteryPct;
  if (location.accuracy > 0) body['accuracy_meters'] = location.accuracy;
  // Altitude is valid below sea level (negative), so send any finite value.
  if (location.altitude.isFinite) body['altitude_meters'] = location.altitude;
  body.addAll(speedFields(
    speedMps: location.speed,
    speedAccuracyMps: location.speedAccuracy,
    accuracyM: location.accuracy,
  ));
  if (location.heading >= 0) body['heading_deg'] = location.heading;
  return body;
}

/// POSTs a JSON body to the API with the given headers.
Future<http.Response> _post(
  String apiBaseUrl,
  Map<String, String> headers,
  String path,
  Map<String, dynamic> body,
) {
  return http
      .post(
        Uri.parse('$apiBaseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      )
      .timeout(_httpTimeout);
}

/// Foreground-facing control surface for the background location service.
class BackgroundLocationService {
  BackgroundLocationService._();

  /// Whether [start] should proceed to register the location update. Set true
  /// at [start] entry and false by [stop], so a [stop] that lands while [start]
  /// is still awaiting its async setup aborts the registration instead of
  /// leaving the foreground service running after logout.
  static bool _shouldRun = false;

  /// Starts background location tracking.
  ///
  /// Tuned for battery: a 60-second interval is far less aggressive than the
  /// foreground reporter's continuous 10-meter stream, while still keeping the
  /// family's view of the user fresh. The distance filter is deliberately zero:
  /// with a displacement filter a stationary device produces no fixes at all,
  /// which would silence both position updates and liveness. The server dedups
  /// stationary points, so periodic fixes cost no storage and keep "last seen"
  /// fresh. While stationary the native side further drops to a slow,
  /// low-power request profile (see ActivityTransitionsManager), and the
  /// native liveness alarm drives [onHeartbeatTick] as a safety net.
  static Future<void> start() async {
    _shouldRun = true;
    await BackgroundLocator.initialize();
    if (!_shouldRun) return;
    // The background isolate's foreground service needs background location
    // ("Allow all the time"). With only foreground ("While using the app")
    // access, Android 15+ rejects starting a `location` foreground service
    // unless the app is in the foreground — which crashes the app when start()
    // runs during startup. Only proceed when background access is granted.
    try {
      final LocationPermission permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always) {
        return;
      }
    } catch (_) {
      // checkPermission can throw on some platforms (e.g. web); proceed anyway
      // and let the plugin surface any remaining problem.
    }
    if (!_shouldRun) return;
    await _register(TrackingCadence().profile(DateTime.now().toUtc())
        // Fresh policy in background mode = the stationary profile.
        );
  }

  /// Registers (or re-registers) the plugin with the request described by
  /// [profile]. Used at start and as the fallback when the in-place native
  /// update is unavailable. Never throws.
  static Future<void> _register(CadenceProfile profile) async {
    final int seconds = (profile.gpsInterval.inMilliseconds / 1000).ceil();
    try {
      await BackgroundLocator.registerLocationUpdate(
        onLocationUpdate,
        heartbeatCallback: onHeartbeatTick,
        androidSettings: AndroidSettings(
          accuracy: profile.highAccuracy
              ? LocationAccuracy.HIGH
              : LocationAccuracy.BALANCED,
          interval: seconds < 1 ? 60 : seconds,
          distanceFilter: profile.distanceFilterM,
          wakeLockTime: 60,
          client: LocationClient.google,
          androidNotificationSettings: const AndroidNotificationSettings(
            notificationChannelName: 'OpenFamily',
            notificationTitle: 'OpenFamily',
            notificationMsg: 'Sharing your location with your family',
            notificationBigMsg:
                'OpenFamily is sharing your location in the background so your '
                'family can see where you are.',
          ),
        ),
        iosSettings: const IOSSettings(
          accuracy: LocationAccuracy.HIGH,
          distanceFilter: 50,
          showsBackgroundLocationIndicator: true,
          stopWithTerminate: false,
        ),
      );
    } catch (_) {
      // Never throw from start(): it is called fire-and-forget, and a failure
      // here (e.g. permission revoked mid-flight) must not crash the app.
    }
  }

  /// Stops background location tracking.
  static Future<void> stop() async {
    _shouldRun = false;
    DirectPushService.instance.stop();
    await BackgroundLocator.unRegisterLocationUpdate();
  }

  /// Whether background location tracking is currently active.
  static Future<bool> isRunning() => BackgroundLocator.isServiceRunning();
}
