import 'driving_event.dart';

/// Screen signals delivered by the native receiver.
enum ScreenSignal { screenOn, screenOff, userPresent }

/// Estimates "screen activity while moving" (NOT proof the driver used the
/// phone: a passenger cannot be told apart, and navigation apps are not
/// recognised).
///
/// An interaction starts at an unlock (ACTION_USER_PRESENT) while the vehicle
/// moves faster than [minSpeedMps]; it ends at screen-off, when the vehicle
/// has stopped, or after [maxDuration]. A screen that is already on (a mounted
/// navigation display) produces no unlock and is therefore not counted. A
/// screen-on caused by a notification without an unlock is not counted either.
class PhoneUseTracker {
  PhoneUseTracker({
    this.minSpeedMps = 7.0,
    this.stoppedSpeedMps = 2.0,
    this.minDuration = const Duration(seconds: 3),
    this.maxDuration = const Duration(seconds: 120),
    this.speedMaxAgeMs = 5000,
  });

  final double minSpeedMps;
  final double stoppedSpeedMps;
  final Duration minDuration;
  final Duration maxDuration;
  final int speedMaxAgeMs;

  double _speed = 0;
  int _speedT = -1000000;
  double? _lat;
  double? _lon;

  int? _startT;
  double? _startLat;
  double? _startLon;
  final List<DrivingEvent> _out = <DrivingEvent>[];

  bool get interactionActive => _startT != null;

  void onSpeed(int tMs, double speed, double? lat, double? lon) {
    _speed = speed;
    _speedT = tMs;
    _lat = lat;
    _lon = lon;
    final int? s = _startT;
    if (s != null) {
      if (speed < stoppedSpeedMps || tMs - s >= maxDuration.inMilliseconds) {
        _end(tMs);
      }
    }
  }

  void onScreen(int tMs, ScreenSignal sig) {
    switch (sig) {
      case ScreenSignal.userPresent:
        final bool fresh = tMs - _speedT <= speedMaxAgeMs;
        if (_startT == null && fresh && _speed >= minSpeedMps) {
          _startT = tMs;
          _startLat = _lat;
          _startLon = _lon;
        }
      case ScreenSignal.screenOff:
        if (_startT != null) _end(tMs);
      case ScreenSignal.screenOn:
        break;
    }
  }

  /// Ends any open interaction (session over).
  void finish(int tMs) {
    if (_startT != null) _end(tMs);
  }

  void _end(int tMs) {
    final int s = _startT!;
    _startT = null;
    final int cappedEnd = tMs - s > maxDuration.inMilliseconds
        ? s + maxDuration.inMilliseconds
        : tMs;
    final int d = cappedEnd - s;
    if (d < minDuration.inMilliseconds) return;
    _out.add(DrivingEvent(
      kind: DrivingEventKind.phoneUse,
      startedAtMs: s,
      endedAtMs: cappedEnd,
      magnitude: d / 1000.0,
      lat: _startLat,
      lon: _startLon,
    ));
  }

  List<DrivingEvent> takeEvents() {
    final List<DrivingEvent> r = List<DrivingEvent>.of(_out);
    _out.clear();
    return r;
  }
}
