import 'dart:async';

import 'crash_detector.dart';
import 'crash_responder.dart';
import 'driving_event.dart';
import 'driving_events_service.dart';
import 'driving_session.dart';
import 'motion_detector.dart';
import 'driving_config.dart' show DrivingConfig;
import 'handling_analyzer.dart';
import 'phone_context.dart';
import 'phone_use_tracker.dart';

/// Receives raw samples from a [DrivingFeed]. Samples stay in memory inside
/// the detector and are never persisted or uploaded.
abstract class DrivingFeedSink {
  void onAccel(int tMs, double x, double y, double z);
  void onGyro(int tMs, double x, double y, double z);
  void onGps(int tMs, double speedMps, double lat, double lon);
  void onScreen(int tMs, ScreenSignal signal);

  /// Proximity / call / audio-route snapshot (phone-use detection only).
  void onContext(PhoneContext context);
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
    this.isCrashEnabled,
    this.crashResponder,
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
  /// Crash detection (opt-in). Both must be set for it to run.
  final Future<bool> Function()? isCrashEnabled;
  final CrashResponder? crashResponder;
  final CrashDetector _crash = CrashDetector();
  bool _crashOn = false;

  final Duration syncEvery = const Duration(minutes: 10);
  final Duration uploadEvery;
  final Duration tickEvery;
  final int Function() _clock;
  final DrivingMotionDetector _detector;
  final PhoneUseTracker _phone = PhoneUseTracker();
  late final HandlingAnalyzer _handling =
      HandlingAnalyzer(onWindow: _phone.onHandling);
  bool _screenOn = false;
  bool _inCall = false;
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
    _screenOn = false;
    _inCall = false;
    _handling.setActive(false);
    _phone.begin(_clock());
    _crash.reset();
    _crashOn = false;
    unawaited(_readFlags().then((List<bool> flags) {
      if (!_session.isActive) return;
      final bool phone = flags[0];
      _phoneActive = phone;
      _crashOn = flags[1];
      feed.start(this, withScreen: phone);
    }));
    _timer?.cancel();
    _timer = Timer.periodic(tickEvery, (_) => unawaited(_tick()));
  }

  Future<List<bool>> _readFlags() async {
    final bool phone = await isPhoneUseEnabled();
    bool crash = false;
    final Future<bool> Function()? c = isCrashEnabled;
    if (c != null && crashResponder != null) {
      try {
        crash = await c();
      } catch (_) {}
    }
    return <bool>[phone, crash];
  }

  void _checkCrash() {
    final CrashSignal? s = _crash.takeSignal();
    if (s != null) unawaited(crashResponder?.handle(s));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_finish());
  }

  Future<void> _finish() async {
    await feed.stop();
    _handling.setActive(false);
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
    if (_crashOn) {
      _crash.tick(now);
      _checkCrash();
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

  void _onAccel(int tMs, double x, double y, double z) {
    _detector.onAccel(tMs, x, y, z);
    if (_phoneActive) _handling.onAccel(tMs, x, y, z);
    if (_crashOn) _crash.onAccel(tMs, x, y, z);
  }

  @override
  void onAccel(int tMs, double x, double y, double z) =>
      _onAccel(tMs, x, y, z);

  @override
  void onGyro(int tMs, double x, double y, double z) {
    _detector.onGyro(tMs, x, y, z);
    if (_phoneActive) _handling.onGyro(tMs, x, y, z);
  }

  @override
  void onGps(int tMs, double speedMps, double lat, double lon) {
    _lastLat = lat;
    _lastLon = lon;
    _detector.onGps(tMs, speedMps, lat, lon);
    if (_crashOn) {
      _crash.onGps(tMs, speedMps, lat, lon);
      _checkCrash();
    }
    if (_phoneActive) _phone.onSpeed(tMs, speedMps, lat, lon);
    _session.onSpeed(tMs, speedMps);
  }

  @override
  void onScreen(int tMs, ScreenSignal signal) {
    if (!_phoneActive) return;
    _phone.onScreen(tMs, signal);
    if (signal == ScreenSignal.screenOff) {
      _screenOn = false;
    } else {
      _screenOn = true;
    }
    _syncHandling();
  }

  @override
  void onContext(PhoneContext context) {
    if (!_phoneActive) return;
    _phone.onContext(context);
    _inCall = context.inCall;
    _syncHandling();
  }

  /// Motion analysis only runs while the screen is lit or a call is active.
  void _syncHandling() => _handling.setActive(_screenOn || _inCall);

  Future<void> dispose() async {
    _timer?.cancel();
    _session.stop();
    await crashResponder?.dispose();
  }
}
