import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';
import 'device_service.dart';
import 'fix_quality.dart';
import 'live_boost.dart';
import 'location_outbox.dart';
import 'perf/perf_monitor.dart';
import 'tracking_cadence.dart';

/// Periodically reports the device's foreground GPS position to the backend
/// (`POST /locations`) so the family can see where the user is.
///
/// Foreground-only: it runs while the [MapScreen] is alive. When the app is
/// backgrounded, geolocator's stream naturally pauses on most platforms and
/// resumes on return. Background reporting is a separate, deferred piece.
///
/// The reporter is deliberately non-throwing and idempotent:
/// - [start] is a no-op when already running.
/// - A failed device registration or a stream that errors out is retried on a
///   backoff cycle rather than surfacing an exception to the caller.
/// - Per-report failures (stale `ts`, non-monotonic ordering, clock skew) are
///   expected and skipped silently.
///
/// Concurrency safety: a monotonically increasing [_generation] counter
/// prevents re-entrancy races. Each [start] bumps the generation (it is
/// **never** reset — not even by [stop]); every async checkpoint in
/// [_startStream] verifies the generation is still current, so a [stop] or a
/// rapid stop→start cycle cleanly aborts stale in-flight invocations and
/// never leaks a second GPS subscription. A separate [_active] flag tracks
/// the running/stopped state.
class LocationReporter {
  /// Whether the reporter is currently running (set by [start], cleared by
  /// [stop]).
  bool _active = false;

  /// Monotonically increasing generation counter. Bumped on each [start];
  /// **never** reset. This ensures a stale in-flight [_startStream] from a
  /// previous generation can always be distinguished from the current one.
  int _generation = 0;

  /// The active position stream subscription, if any.
  StreamSubscription<Position>? _subscription;

  /// Periodic liveness heartbeat while reporting is active. Covers the
  /// stationary case: geolocator's distance-filtered stream emits nothing when
  /// the user is still, so without a heartbeat the member flips to grey
  /// "stopped / Last seen Xm ago" even though the app is alive and posting.
  Timer? _heartbeatTimer;

  /// Pending restart timer after a stream error/close or failed registration.
  Timer? _restartTimer;

  /// The registered device id, resolved lazily and retried on restart.
  String? _deviceId;

  final Battery _battery = Battery();

  // Serialization / throttling / dedup state.
  /// True while a POST is in flight; newer updates are skipped meanwhile.
  bool _posting = false;

  /// Timestamp of the last position we sent (or the backend rejected), used to
  /// dedup equal/out-of-order timestamps against the backend's monotonic rule.
  DateTime? _lastSentTs;

  /// When the last POST was attempted, used to rate-limit against flooding.
  DateTime? _lastPostTime;

  /// The latest position seen while a POST was in flight, processed (backfilled)
  /// once the current POST completes so a slow POST doesn't lose a fix.
  Position? _pendingPosition;

  /// How long to wait before retrying the stream after it errors or closes.
  static const Duration _restartDelay = Duration(seconds: 15);

  /// How often to send a liveness heartbeat when no location has been posted
  /// recently (the backend refreshes `devices.last_seen` on both paths, so a
  /// moving user's location posts make the heartbeat redundant). Matches the
  /// background service's reporting cadence.
  static const Duration _heartbeatInterval = Duration(seconds: 60);

  /// Whether an SOS burst is active (process-wide; the SOS screen sets it).
  static bool _sosActive = false;

  static Timer? _sosBurstTimer;

  /// Reports more often for a few minutes after SOS: the cadence policy's
  /// `sos` tier (2 s) wins over every other tier.
  static void startSosBurst({Duration last = const Duration(minutes: 5)}) {
    _sosActive = true;
    _sosBurstTimer?.cancel();
    _sosBurstTimer = Timer(last, stopSosBurst);
  }

  static void stopSosBurst() {
    _sosBurstTimer?.cancel();
    _sosBurstTimer = null;
    _sosActive = false;
  }

  // --- adaptive cadence -----------------------------------------------------

  final TrackingCadence _cadence = TrackingCadence();
  late final ProfileApplier _applier = ProfileApplier(_cadence.config);
  final FixQualityFilter _filter = FixQualityFilter();

  /// Re-evaluates the profile every few seconds: covers expiry of a boost /
  /// SOS and drive-mode exit when no fixes arrive (distance-filtered stream).
  Timer? _cadenceTimer;
  static const Duration _cadenceTick = Duration(seconds: 5);

  DateTime? _batteryReadAt;
  int? _batteryCache;
  DateTime? _lastDrainAt;
  static const Duration _drainEvery = Duration(seconds: 10);

  /// Latest profile (read by tests / the Performance screen).
  CadenceProfile? get currentProfile => _applier.applied;

  /// Geolocator settings for [p]. Pure; exposed for tests.
  @visibleForTesting
  static LocationSettings settingsFor(CadenceProfile p) {
    final int df = p.distanceFilterM.round();
    final LocationAccuracy acc =
        p.highAccuracy ? LocationAccuracy.high : LocationAccuracy.medium;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: acc,
          distanceFilter: df,
          intervalDuration:
              p.gpsInterval > Duration.zero ? p.gpsInterval : null,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(accuracy: acc, distanceFilter: df);
      default:
        return LocationSettings(accuracy: acc, distanceFilter: df);
    }
  }

  Future<void> _refreshBattery(DateTime now) async {
    final DateTime? at = _batteryReadAt;
    if (at != null && now.difference(at) < const Duration(seconds: 30)) return;
    _batteryReadAt = now;
    try {
      _batteryCache = await _battery.batteryLevel;
    } catch (_) {
      _batteryCache = null; // battery_plus is unsupported on web.
    }
    bool charging = false;
    try {
      final BatteryState st = await _battery.batteryState;
      charging = st == BatteryState.charging || st == BatteryState.full;
    } catch (_) {}
    _cadence.setBattery(_batteryCache, charging: charging);
  }

  /// Syncs external inputs (SOS, persisted boost from the other isolate,
  /// battery) into the policy, then reconfigures the GPS stream if the
  /// profile changed (debounced). Never throws.
  Future<void> _reevaluate() async {
    if (!_active) return;
    try {
      final DateTime now = DateTime.now().toUtc();
      _cadence.setSos(_sosActive);
      await _refreshBattery(now);
      final DateTime? until = await LiveBoost.readActive(now);
      if (until != null) _cadence.startBoost(until.difference(now), now);
      unawaited(ForegroundPresence.mark(now));
      _applyDesiredProfile(now);
    } catch (_) {}
  }

  void _applyDesiredProfile(DateTime now) {
    if (!_active) return;
    final CadenceProfile desired = _cadence.profile(now);
    PerfMonitor.instance.cadenceProfile = desired.label;
    final CadenceProfile? next = _applier.next(desired, now);
    if (next == null) return;
    _applier.markApplied(next, now);
    if (_subscription != null) unawaited(_startStream(_generation));
  }

  /// Instance boost entry used by the live-boost hook.
  void _onBoost() {
    _applyDesiredProfile(DateTime.now().toUtc());
  }

  /// Ensures the device is registered, then starts the position stream.
  ///
  /// Fire-and-forget from the caller's perspective: never throws, and does not
  /// block the UI. Calling it again while running is a no-op.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    _generation++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => _sendHeartbeat(),
    );
    _cadenceTimer?.cancel();
    _cadenceTimer = Timer.periodic(_cadenceTick, (_) => _reevaluate());
    LiveBoost.register(_cadence, onBoost: _onBoost);
    unawaited(ForegroundPresence.mark(DateTime.now().toUtc()));
    await _startStream(_generation);
  }

  /// Sends a bare liveness heartbeat (`POST /devices/heartbeat`) so the
  /// backend refreshes `devices.last_seen` — and the family's "last seen" for
  /// this member — without writing a location row. Skipped when a location was
  /// posted within the last interval (that already refreshed it server-side)
  /// or while another request is in flight. Never throws.
  Future<void> _sendHeartbeat() async {
    if (!_active || _posting) return;
    final DateTime? lastPost = _lastPostTime;
    if (lastPost != null &&
        DateTime.now().toUtc().difference(lastPost) < _heartbeatInterval) {
      return;
    }
    final String? deviceId = _deviceId;
    if (deviceId == null) return; // Registration retry loop will recover.

    try {
      int? batteryPct;
      try {
        batteryPct = await _battery.batteryLevel;
      } catch (_) {
        batteryPct = null;
      }
      final Map<String, dynamic> body = <String, dynamic>{'device_id': deviceId};
      if (batteryPct != null) body['battery_pct'] = batteryPct;
      await ApiClient.post('/devices/heartbeat', body: body);
    } on SessionExpiredException {
      // The app root handles the redirect; stop reporting for this session.
      stop();
    } catch (_) {
      // Network/API failures are expected offline; the next tick retries.
    }
  }

  /// Registers the device (if needed) and opens the position stream.
  ///
  /// [gen] is the generation this invocation belongs to; every async checkpoint
  /// re-checks it so a [stop] or a new [start] cleanly aborts stale work.
  ///
  /// Registration is re-attempted on each restart cycle while [_deviceId] is
  /// null, so a transient registration failure at launch is recovered rather
  /// than silently dropped for the whole session.
  Future<void> _startStream(int gen) async {
    if (!_active || _generation != gen) return;

    if (_deviceId == null) {
      try {
        _deviceId = await DeviceService.ensureRegistered();
      } on SessionExpiredException {
        // The app root has already redirected to login; nothing to report.
        stop();
        return;
      } catch (_) {
        // Registration failed (e.g. network). Retry on the next cycle.
        _scheduleRestart(gen);
        return;
      }
      // A stop() or start() may have landed while registration was in flight.
      if (!_active || _generation != gen) return;
    }

    // Stop looping if permission is permanently denied; otherwise proceed (a
    // `denied` state may still be granted later, and `getPositionStream` will
    // surface any remaining problem).
    try {
      final LocationPermission permission =
          await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever) {
        stop();
        return;
      }
    } catch (_) {
      // checkPermission can throw on some platforms (e.g. web); fall through
      // and let getPositionStream surface the error instead.
    }
    if (!_active || _generation != gen) return;

    Stream<Position> stream;
    try {
      final DateTime now = DateTime.now().toUtc();
      _cadence.setSos(_sosActive);
      final CadenceProfile profile = _cadence.profile(now);
      if (_applier.applied == null) _applier.markApplied(profile, now);
      PerfMonitor.instance.cadenceProfile = profile.label;
      stream = Geolocator.getPositionStream(
        locationSettings: settingsFor(_applier.applied ?? profile),
      );
    } catch (_) {
      // Permission denied / services off / platform error. Retry later so a
      // subsequent permission grant starts producing updates.
      _scheduleRestart(gen);
      return;
    }

    // Clean up any stale subscription from a previous cycle before opening a
    // new one, so we never run two concurrent GPS streams / duplicate POSTs.
    await _subscription?.cancel();
    if (!_active || _generation != gen) return;

    _subscription = stream.listen(
      (Position p) => _onPosition(p),
      onError: (Object _) {
        _subscription?.cancel();
        _subscription = null;
        _scheduleRestart(gen);
      },
      onDone: () {
        _subscription = null;
        _scheduleRestart(gen);
      },
    );
  }

  /// Schedules a single restart attempt after the stream errors/closes or a
  /// registration attempt fails. [gen] ties the timer to the originating
  /// generation so a stale timer never fires for a newer cycle.
  void _scheduleRestart(int gen) {
    if (!_active || _generation != gen) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(_restartDelay, () {
      _restartTimer = null;
      if (_active && _generation == gen) _startStream(gen);
    });
  }

  /// The `POST /locations` body for [position]. Pure; exposed for tests.
  ///
  /// `speed_mps` is the GPS Doppler speed as reported, including 0 when the
  /// receiver says 0 and the fix is accurate (see [speedFields]).
  @visibleForTesting
  static Map<String, dynamic> buildBody(
    Position position, {
    required String? deviceId,
    int? batteryPct,
  }) {
    final Map<String, dynamic> body = <String, dynamic>{
      'device_id': deviceId,
      'ts': position.timestamp.toUtc().toIso8601String(),
      'lat': position.latitude,
      'lon': position.longitude,
      'motion_state': '',
      'source': 'foreground',
    };
    if (batteryPct != null) body['battery_pct'] = batteryPct;
    if (position.accuracy > 0) body['accuracy_meters'] = position.accuracy;
    // Altitude is valid below sea level (negative), so send any finite value.
    if (position.altitude.isFinite) {
      body['altitude_meters'] = position.altitude;
    }
    body.addAll(speedFields(
      speedMps: position.speed,
      speedAccuracyMps: position.speedAccuracy,
      accuracyM: position.accuracy,
    ));
    // Note: geolocator reports heading as 0.0 when unknown on some
    // platforms, so a 0 heading may mean "unknown" — acceptable since the
    // backend treats heading as optional.
    if (position.heading >= 0) body['heading_deg'] = position.heading;
    return body;
  }

  /// Entry point for stream fixes: sanity-filters, feeds the cadence policy,
  /// then hands the fix to [_deliver].
  Future<void> _onPosition(Position position) async {
    if (!_active) return;
    final DateTime now = DateTime.now().toUtc();
    final FixVerdict verdict = _filter.check(
      ts: position.timestamp,
      lat: position.latitude,
      lon: position.longitude,
      accuracyM: position.accuracy,
      speedMps: position.speed,
      lastSentTs: _lastSentTs,
    );
    if (verdict != FixVerdict.ok) return;
    _cadence.onFix(now: now, speedMps: position.speed);
    _cadence.setSos(_sosActive);
    _applyDesiredProfile(now);
    await _deliver(position);
  }

  /// Builds and POSTs a location report for a single [Position].
  ///
  /// Updates are serialized (one POST at a time), throttled (the active
  /// profile's minimum interval), and deduped (monotonic timestamps). A
  /// position that arrives while a POST is in flight becomes the single
  /// pending one; the pending fix it replaces is parked in the outbox and
  /// ships through the batch endpoint, so a slow network never piles up
  /// requests and never loses a point. The pending fix is sent once the
  /// current POST completes, bypassing the rate limiter so the final position
  /// is always reported.
  Future<void> _deliver(Position position, {bool bypassRateLimit = false}) async {
    if (_posting) {
      final Position? replaced = _pendingPosition;
      _pendingPosition = position;
      if (replaced != null) {
        unawaited(LocationOutbox.enqueue(
          buildBody(replaced, deviceId: _deviceId, batteryPct: _batteryCache),
        ));
      }
      return;
    }

    // Dedup: skip equal/out-of-order timestamps (backend requires monotonic).
    final DateTime ts = position.timestamp.toUtc();
    if (_lastSentTs != null && !ts.isAfter(_lastSentTs!)) return;

    if (!bypassRateLimit) {
      final DateTime now = DateTime.now().toUtc();
      final Duration gate = _cadence.profile(now).minPostInterval;
      if (_lastPostTime != null && now.difference(_lastPostTime!) < gate) {
        return;
      }
    }

    _posting = true;
    _lastPostTime = DateTime.now().toUtc();
    Map<String, dynamic> body =
        buildBody(position, deviceId: _deviceId, batteryPct: null);
    try {
      await _refreshBattery(DateTime.now().toUtc());
      body = buildBody(position, deviceId: _deviceId, batteryPct: _batteryCache);

      final dynamic res = await ApiClient.post('/locations', body: body);
      _lastSentTs = ts;
      PerfMonitor.instance.recordFixSent();
      if (LiveBoost.responseIsLive(res)) {
        final DateTime n = DateTime.now().toUtc();
        _cadence.startBoost(_cadence.config.liveFlagBoost, n);
        _applyDesiredProfile(n);
      }
      // Connectivity works — opportunistically deliver anything the device
      // queued while it was offline (throttled: at 1 Hz a drain per post
      // would hammer storage).
      final DateTime n = DateTime.now().toUtc();
      if (_lastDrainAt == null || n.difference(_lastDrainAt!) >= _drainEvery) {
        _lastDrainAt = n;
        unawaited(LocationOutbox.drain(send: sendOutboxBatchViaApi));
      }
    } on SessionExpiredException {
      // The app root handles the redirect; stop reporting for this session.
      // The report is not queued: no session, no device identity to ingest
      // under until re-login.
      stop();
    } on ApiException catch (e) {
      // A non-zero status is a genuine backend rejection (e.g. 400 for stale
      // ts or non-monotonic ordering): record it as sent so we don't retry the
      // same timestamp. A zero status is a network/timeout failure where the
      // point never reached the server, so leave _lastSentTs untouched so the
      // point can be retried on the next update.
      if (e.status != 0) {
        _lastSentTs = ts;
      }
      // Either way, park the report for offline backfill: a network failure
      // re-sends it verbatim; a rejection (e.g. a non-monotonic race with the
      // background reporter) is healed by the batch endpoint's relaxed
      // freshness rules. Permanently invalid points are dropped by the
      // backend's batch validation, so nothing loops forever.
      await LocationOutbox.enqueue(body);
    } catch (_) {
      // Unexpected error (e.g. malformed body). Intentionally swallowed so the
      // reporter never crashes the app; queue the report for backfill the
      // same way.
      await LocationOutbox.enqueue(body);
    } finally {
      _posting = false;
    }

    // If the reporter was stopped during the POST (session expired or app
    // backgrounded), don't backfill.
    if (!_active) return;

    final Position? pending = _pendingPosition;
    _pendingPosition = null;
    if (pending != null) {
      final DateTime pendingTs = pending.timestamp.toUtc();
      if (_lastSentTs == null || pendingTs.isAfter(_lastSentTs!)) {
        await _deliver(pending, bypassRateLimit: true);
      }
    }
  }

  /// Cancels the position stream and any pending restart, and clears state.
  void stop() {
    _active = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _cadenceTimer?.cancel();
    _cadenceTimer = null;
    _restartTimer?.cancel();
    _restartTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _pendingPosition = null;
    LiveBoost.unregister(_cadence);
    _applier.reset();
    _filter.reset();
    unawaited(ForegroundPresence.clear());
  }
}
