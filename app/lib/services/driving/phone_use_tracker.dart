import 'dart:math' as math;

import 'driving_config.dart';
import 'driving_event.dart';
import 'handling_analyzer.dart';
import 'phone_context.dart';

/// Screen signals delivered by the native receiver.
enum ScreenSignal { screenOn, screenOff, userPresent }

class _Seg {
  _Seg(this.s, this.e);
  int s;
  int e;
}

class _Episode {
  _Episode(this.lat, this.lon);
  final double? lat;
  final double? lon;
  final List<_Seg> segs = <_Seg>[];
  double maxSpeed = 0;
  int callMs = 0;
  int handledMs = 0;
  int get start => segs.first.s;
  int get lastEnd => segs.last.e;
  int get activeMs => segs.fold<int>(0, (int a, _Seg g) => a + (g.e - g.s));
}

/// Estimates phone use by the DRIVER while the vehicle moves. It never sees
/// content or which app is in use.
///
/// Evidence, all evaluated only while the GPS speed says the vehicle is really
/// moving (red lights, parking and the first/last seconds of a drive are not
/// counted):
///  - the screen is unlocked and the phone is being handled (motion sensors,
///    see [HandlingAnalyzer]), or was unlocked moments ago (a deliberate tap);
///    a lit screen on a phone that is not being handled is treated as a mounted
///    navigation display, and a screen "on" in a pocket (proximity near, no
///    handling) is ignored;
///  - a handset call at the ear, or a handled speakerphone call. Calls over
///    Bluetooth, a wired headset, Android Auto or a car are hands-free and are
///    NOT counted.
///
/// Interactions less than [PhoneUseConfig.mergeGapMs] apart form one event;
/// the event magnitude is the seconds of actual interaction.
class PhoneUseTracker {
  PhoneUseTracker({this.config = const PhoneUseConfig()});

  final PhoneUseConfig config;

  // Speed / drive state.
  double _speed = 0;
  int _speedT = -1 << 40;
  double? _lat;
  double? _lon;
  bool _moving = false;
  int? _belowSince;
  int _lastMovingT = -1 << 40;
  int? _driveStartT;

  // Screen state.
  bool _screenOn = false;
  int _screenOnT = 0;
  bool _unlocked = false;
  int _unlockT = 0;

  // Handling state.
  int _hFrom = 0;
  int _hUntil = -1 << 40;
  int _windowsSeen = 0;

  // Call / proximity / audio state.
  PhoneContext _ctx = const PhoneContext();

  int? _lastT;
  _Episode? _ep;
  final List<_Episode> _closed = <_Episode>[];
  int _emitted = 0;
  final List<DrivingEvent> _out = <DrivingEvent>[];

  /// True while an interaction is currently being counted.
  bool get interactionActive => _ep != null;

  /// Starts a new drive: clears all per-drive state.
  void begin(int tMs) {
    _speed = 0;
    _speedT = -1 << 40;
    _moving = false;
    _belowSince = null;
    _lastMovingT = -1 << 40;
    _driveStartT = null;
    _screenOn = false;
    _unlocked = false;
    _hUntil = -1 << 40;
    _windowsSeen = 0;
    _ctx = const PhoneContext();
    _lastT = tMs;
    _ep = null;
    _closed.clear();
    _emitted = 0;
  }

  void onSpeed(int tMs, double speed, double? lat, double? lon) {
    _advance(tMs);
    _speed = speed;
    _speedT = tMs;
    _lat = lat ?? _lat;
    _lon = lon ?? _lon;
    if (speed >= config.movingSpeedMps) {
      _lastMovingT = tMs;
      _belowSince = null;
    } else {
      _belowSince ??= tMs;
    }
    if (!_moving) {
      if (speed >= config.startSpeedMps) {
        _moving = true;
        _driveStartT ??= tMs;
      }
    } else if (_belowSince != null &&
        tMs - _belowSince! >= config.stopGraceMs) {
      _moving = false;
      _closeEpisode();
    }
  }

  void onScreen(int tMs, ScreenSignal sig) {
    _advance(tMs);
    switch (sig) {
      case ScreenSignal.screenOn:
        if (!_screenOn) {
          _screenOn = true;
          _screenOnT = tMs;
          _unlocked = false;
        }
      case ScreenSignal.userPresent:
        if (!_screenOn) {
          _screenOn = true;
          _screenOnT = tMs;
        }
        _unlocked = true;
        _unlockT = tMs;
      case ScreenSignal.screenOff:
        _screenOn = false;
        _unlocked = false;
    }
  }

  /// A verdict from the [HandlingAnalyzer]. The window covers
  /// [startMs, endMs] (already in the past when it arrives).
  void onHandling(HandlingWindow w) {
    if (_lastT != null && w.startMs > _lastT!) _advance(w.startMs);
    _windowsSeen++;
    if (w.handled) {
      if (w.startMs > _hUntil) _hFrom = w.startMs;
      _hUntil = math.max(_hUntil, w.endMs + config.handlingHoldMs);
      // A window is only known once it is over, so the interval it covers was
      // already walked past without this evidence: walk it again. Segments
      // are unioned, so nothing is counted twice.
      if (_lastT != null && w.startMs < _lastT!) _lastT = w.startMs;
    }
    _advance(w.endMs);
  }

  void onContext(PhoneContext c) {
    _advance(c.tMs);
    _ctx = c;
  }

  /// Ends any open interaction (drive over) and releases the pending events,
  /// dropping the last [PhoneUseConfig.driveEdgeMs] of the drive.
  void finish(int tMs) {
    _advance(tMs);
    _closeEpisode();
    final int cutoff = _lastMovingT - config.driveEdgeMs;
    final List<_Episode> rest = List<_Episode>.of(_closed);
    _closed.clear();
    for (final _Episode e in rest) {
      _trim(e, cutoff);
      _emit(e);
    }
    _moving = false;
    _driveStartT = null;
  }

  List<DrivingEvent> takeEvents() {
    // Episodes that ended well before the vehicle's last movement are final;
    // those near the end of the drive wait for finish() (they may be the
    // phone being taken out of the mount while parking).
    final List<_Episode> keep = <_Episode>[];
    for (final _Episode e in _closed) {
      if (e.lastEnd <= _lastMovingT - config.driveEdgeMs) {
        _emit(e);
      } else {
        keep.add(e);
      }
    }
    _closed
      ..clear()
      ..addAll(keep);
    final List<DrivingEvent> r = List<DrivingEvent>.of(_out);
    _out.clear();
    return r;
  }

  // ---- internals ---------------------------------------------------------

  void _trim(_Episode e, int cutoff) {
    e.segs.removeWhere((_Seg g) => g.s >= cutoff);
    for (final _Seg g in e.segs) {
      if (g.e > cutoff) g.e = cutoff;
    }
  }

  void _emit(_Episode e) {
    if (e.segs.isEmpty) return;
    final int active = e.activeMs;
    if (active < config.minActiveMs) return;
    if (_emitted >= config.maxEventsPerDrive) return;
    _emitted++;
    final double callShare = math.min(1.0, e.callMs / active);
    final double handledShare = math.min(1.0, e.handledMs / active);
    // Handset call at the ear is strong evidence; screen use is stronger when
    // the phone was verifiably handled, and weak when it rests on an unlock
    // alone or on the no-sensor fallback.
    final double screenConf =
        _windowsSeen > 0 ? 0.35 + 0.65 * handledShare : 0.4;
    final double conf =
        (0.9 * callShare + (1 - callShare) * screenConf).clamp(0.0, 1.0);
    _out.add(DrivingEvent(
      kind: DrivingEventKind.phoneUse,
      startedAtMs: e.start,
      endedAtMs: e.lastEnd,
      magnitude: math.min(active / 1000.0, 300.0),
      lat: e.lat,
      lon: e.lon,
      maxSpeedMps: e.maxSpeed,
      confidence: conf,
      activity: callShare >= 0.5 ? 'call' : 'screen',
    ));
  }

  void _closeEpisode() {
    final _Episode? e = _ep;
    _ep = null;
    if (e != null && e.segs.isNotEmpty) _closed.add(e);
  }

  /// Moves the clock to [t], counting interaction time in [lastT, t] under the
  /// state that held during it.
  void _advance(int t) {
    final int? last = _lastT;
    if (last == null) {
      _lastT = t;
      return;
    }
    if (t <= last) return;
    _lastT = t;
    final _Episode? open = _ep;
    if (open != null && last - open.lastEnd > config.mergeGapMs) {
      _closeEpisode();
    }
    if (!_moving || _speed < config.movingSpeedMps) return;
    final int b = math.min(t, _speedT + config.speedMaxAgeMs);
    int a = last;
    final int? ds = _driveStartT;
    if (ds != null) a = math.max(a, ds + config.driveEdgeMs);
    if (b <= a) return;

    final List<_Seg> parts = <_Seg>[];
    int callMs = 0, handledMs = 0;

    int ov(int from, int to) => math.max(0, math.min(b, to) - math.max(a, from));
    void add(int from, int to) {
      final int s = math.max(a, from), e = math.min(b, to);
      if (e > s) parts.add(_Seg(s, e));
    }

    final bool legacy = _windowsSeen == 0 &&
        _screenOn &&
        a - _screenOnT >= config.noSensorFallbackMs;
    if (_screenOn) {
      // Handled phone with a lit screen counts whether or not an unlock event
      // was seen (screen already on when the drive began, or no keyguard).
      add(_hFrom, _hUntil);
      handledMs += ov(_hFrom, _hUntil);
      final bool pocket = _ctx.near && ov(_hFrom, _hUntil) == 0;
      if (_unlocked && !pocket) {
        add(_unlockT, _unlockT + config.unlockGraceMs);
        if (legacy) add(a, b);
      }
    }
    if (_ctx.inCall && !_ctx.handsFree) {
      final bool atEar = _ctx.route == AudioRoute.earpiece ||
          (_ctx.route == AudioRoute.unknown && _ctx.near);
      if (atEar) {
        add(a, b);
        callMs += b - a;
      } else if (_ctx.route == AudioRoute.speaker) {
        // Speakerphone: only when the phone is actually being handled.
        add(_hFrom, _hUntil);
        callMs += ov(_hFrom, _hUntil);
      }
    }
    if (parts.isEmpty) return;

    parts.sort((_Seg x, _Seg y) => x.s.compareTo(y.s));
    final List<_Seg> merged = <_Seg>[parts.first];
    for (final _Seg p in parts.skip(1)) {
      if (p.s <= merged.last.e) {
        merged.last.e = math.max(merged.last.e, p.e);
      } else {
        merged.add(p);
      }
    }
    for (final _Seg g in merged) {
      _addSegment(g.s, g.e);
    }
    final _Episode? e = _ep;
    if (e != null) {
      e.callMs += callMs;
      e.handledMs += handledMs;
    }
  }

  void _addSegment(int s, int e) {
    _Episode? ep = _ep;
    if (ep != null &&
        (s - ep.lastEnd > config.mergeGapMs ||
            e - ep.start > config.maxEpisodeMs)) {
      _closeEpisode();
      ep = null;
    }
    ep ??= _ep = _Episode(_lat, _lon);
    final _Seg? last = ep.segs.isEmpty ? null : ep.segs.last;
    if (last != null && s <= last.e) {
      last.e = math.max(last.e, e);
    } else {
      ep.segs.add(_Seg(s, e));
    }
    ep.maxSpeed = math.max(ep.maxSpeed, _speed);
  }
}
