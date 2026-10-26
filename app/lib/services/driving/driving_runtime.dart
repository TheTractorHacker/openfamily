import 'dart:async';

import 'driving_config.dart';
import 'driving_event.dart';
import 'driving_events_service.dart';
import 'driving_session.dart';
import 'motion_detector.dart';
import 'phone_use_tracker.dart';

/// Receives raw samples from a [DrivingFeed]. Samples stay in memory inside
/// the detector and are never persisted or uploaded.
abstract class DrivingFeedSink {
  void onAccel(int tMs, double x, double y, double z);
  void onGyro(int tMs, double x, double y, double z);
  void onGps(int tMs, double speedMps, double lat, double lon);
  void onScreen(int tMs, ScreenSignal signal);
}

/// Source of sensor/GPS/screen data. Started and stopped strictly by the
/// session state machine.
abstract class DrivingFeed {
  /// Starts the motion sensors and the 1 Hz GPS feed (and the screen feed if
  /// [withScreen]).
  void start(DrivingFeedSink sink, {required bool withScreen});

  /// Cancels every subscription.
  Future<void> stop();
}

/// Glue living in the background isolate: GPS-speed state machine -> sensors
/// -> detector -> outbox -> upload.
class DrivingRuntime implements DrivingFeedSink {
  DrivingRuntime({
    required this.feed,
    required this.service,
    required this.isEnabled,
    required this.isPhoneUseEnabled,
    this.syncOptIn,
    int Function()? clock,
    DrivingConfig config = const DrivingConfig(),
    this.uploadEvery = const Duration(seconds: 60),
    this.tickEvery = const Duration(seconds: 5),
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _detector = DrivingMotionDetector(config: config) {
    _session = DrivingSessionController(onStart: _start, onStop: _stop);
  }

  final DrivingFeed feed;
  final DrivingEventsService service;
  final Future<bool> Function() isEnabled;
  final Future<bool> Function() isPhoneUseEnabled;

  /// Tells the server the effective opt-in until it has acknowledged it
  /// (detection is on by default). Retried at most every [syncEvery].
  final Future<bool> Function()? syncOptIn;
  final Duration syncEvery = const Duration(minutes: 10);
  final Duration uploadEvery;
  final Duration tickEvery;
  final int Function() _clock;
  final DrivingMotionDetector _detector;
  final PhoneUseTracker _phone = PhoneUseTracker();
  late final DrivingSessionController _session;

  Timer? _timer;
  int _lastUpload = 0;
  int? _lastSync;
  bool _synced = false;
  double? _lastLat;
  double? _lastLon;
  bool _phoneActive = false;

  bool get sensorsRunning => _session.isActive;

  /// Called for every background location fix (about once a minute). Arms the
  /// sensors when the speed is high enough and the user has opted in.
  Future<void> onBackgroundFix({
    required double speedMps,
    double? lat,
    double? lon,
  }) async {
    await _maybeSyncOptIn();
    if (!await isEnabled()) {
      if (_session.isActive) _session.stop();
      return;
    }
    _lastLat = lat ?? _lastLat;
    _lastLon = lon ?? _lastLon;
    _session.onSpeed(_clock(), speedMps);
    // A queue left over from a previous session (offline) is retried here.
    await _maybeUpload(force: false);
  }

  Future<void> _maybeSyncOptIn() async {
    final Future<bool> Function()? sync = syncOptIn;
    if (sync == null || _synced) return;
    final int now = _clock();
    final int? last = _lastSync;
    if (last != null && now - last < syncEvery.inMilliseconds) return;
    _lastSync = now;
    try {
      _synced = await sync(); // acknowledged: stop asking
    } catch (_) {}
  }

  void _start() {
    _detector.reset();
    _phoneActive = false;
    unawaited(isPhoneUseEnabled().then((bool phone) {
      if (!_session.isActive) return;
      _phoneActive = phone;
      feed.start(this, withScreen: phone);
    }));
    _timer?.cancel();
    _timer = Timer.periodic(tickEvery, (_) => unawaited(_tick()));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_finish());
  }

  Future<void> _finish() async {
    await feed.stop();
    final int now = _clock();
    _phone.finish(now);
    final List<DrivingEvent> ev = <DrivingEvent>[
      ..._detector.takeEvents(flush: true),
      ..._phone.takeEvents(),
    ];
    await service.queue(ev);
    await _maybeUpload(force: true);
  }

  Future<void> _tick() async {
    final int now = _clock();
    // Only the 1 Hz feed keeps the session alive once it is running; the
    // opt-out is also honoured here so turning the switch off stops sampling
    // within seconds.
    if (!await isEnabled()) {
      _session.stop();
      return;
    }
    _session.tick(now);
    if (!_session.isActive) return;
    final List<DrivingEvent> ev = <DrivingEvent>[
      ..._detector.takeEvents(),
      ..._phone.takeEvents(),
    ];
    if (ev.isNotEmpty) await service.queue(ev);
    await _maybeUpload(force: false);
  }

  Future<void> _maybeUpload({required bool force}) async {
    final int now = _clock();
    if (!force && now - _lastUpload < uploadEvery.inMilliseconds) return;
    _lastUpload = now;
    try {
      await service.uploadQueued();
    } catch (_) {
      // Retried at the next opportunity.
    }
  }

  // ---- DrivingFeedSink ---------------------------------------------------

  @override
  void onAccel(int tMs, double x, double y, double z) =>
      _detector.onAccel(tMs, x, y, z);

  @override
  void onGyro(int tMs, double x, double y, double z) =>
      _detector.onGyro(tMs, x, y, z);

  @override
  void onGps(int tMs, double speedMps, double lat, double lon) {
    _lastLat = lat;
    _lastLon = lon;
    _detector.onGps(tMs, speedMps, lat, lon);
    if (_phoneActive) _phone.onSpeed(tMs, speedMps, lat, lon);
    _session.onSpeed(tMs, speedMps);
  }

  @override
  void onScreen(int tMs, ScreenSignal signal) {
    if (_phoneActive) _phone.onScreen(tMs, signal);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _session.stop();
  }
}
