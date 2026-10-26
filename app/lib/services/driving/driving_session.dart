/// GPS-speed state machine that decides when the motion sensors run. The
/// sensors run ONLY between [onSpeed] seeing a driving speed and the vehicle
/// having been stationary for [stationaryStop] (or a start that never turned
/// into real driving), so nothing samples while parked or walking.
class DrivingSessionController {
  DrivingSessionController({
    required this.onStart,
    required this.onStop,
    this.startSpeedMps = 5.0,
    this.confirmFor = const Duration(seconds: 10),
    this.confirmWithin = const Duration(seconds: 90),
    this.stationaryStop = const Duration(seconds: 120),
  });

  /// Called when sensors should start / stop.
  final void Function() onStart;
  final void Function() onStop;

  /// Speed that starts a session (background fixes arrive every ~60 s, so one
  /// fix above this arms it; [confirmFor] then validates it on the 1 Hz feed).
  final double startSpeedMps;

  /// Speed must stay above [startSpeedMps] this long to confirm real driving.
  final Duration confirmFor;

  /// An unconfirmed session (a bike ride that ended, a speed glitch) stops
  /// after this long.
  final Duration confirmWithin;

  /// Continuous time below [startSpeedMps] after which the session ends.
  final Duration stationaryStop;

  bool _active = false;
  bool _confirmed = false;
  int _startedAt = 0;
  int _lastMoving = 0;
  int? _sustainedSince;

  bool get isActive => _active;
  bool get isConfirmed => _confirmed;

  void onSpeed(int tMs, double speedMps) {
    if (speedMps >= startSpeedMps) {
      if (!_active) {
        _active = true;
        _confirmed = false;
        _startedAt = tMs;
        onStart();
      }
      _lastMoving = tMs;
      _sustainedSince ??= tMs;
      if (tMs - _sustainedSince! >= confirmFor.inMilliseconds) {
        _confirmed = true;
      }
    } else {
      _sustainedSince = null;
    }
  }

  /// Call periodically (every few seconds) while active.
  void tick(int nowMs) {
    if (!_active) return;
    final bool unconfirmedTooLong =
        !_confirmed && nowMs - _startedAt > confirmWithin.inMilliseconds;
    final bool idle = nowMs - _lastMoving > stationaryStop.inMilliseconds;
    if (unconfirmedTooLong || idle) stop();
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _confirmed = false;
    _sustainedSince = null;
    onStop();
  }
}
