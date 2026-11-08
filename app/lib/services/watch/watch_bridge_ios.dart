import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/member.dart';
import '../speed_units.dart';
import 'watch_actions.dart';
import 'watch_snapshot.dart';

/// What the iPhone knows about its Apple Watch.
class WatchStatus {
  const WatchStatus({
    this.supported = false,
    this.paired = false,
    this.appInstalled = false,
    this.reachable = false,
  });

  /// WatchConnectivity exists on this device (an iPhone, not an iPad).
  final bool supported;

  /// An Apple Watch is paired with this iPhone.
  final bool paired;

  /// The Orbitly watch app is installed on it.
  final bool appInstalled;

  /// The watch app can be reached right now.
  final bool reachable;

  /// True when pushing snapshots makes sense.
  bool get listening => supported && paired && appInstalled;

  factory WatchStatus.fromMap(Object? raw) {
    if (raw is! Map) return const WatchStatus();
    bool b(String k) => raw[k] == true;
    return WatchStatus(
      supported: b('supported'),
      paired: b('paired'),
      appInstalled: b('installed'),
      reachable: b('reachable'),
    );
  }
}

/// iPhone side of the Apple Watch app (docs/design/WATCH_APPS_APPLE.md).
///
/// Companion model: this class turns the live roster into a compact snapshot
/// and hands it to the native `WatchBridge.swift` (WatchConnectivity). The
/// watch answers with small commands which are run here with the phone's own
/// session and keys. Without a paired watch every method is a cheap no-op and
/// nothing is sent; there is no timer and no polling: a push happens only when
/// the roster changes, at most once per [throttle].
class WatchBridgeIos {
  WatchBridgeIos({
    MethodChannel? channel,
    WatchPhoneActions? actions,
    bool? supported,
    DateTime Function()? clock,
    this.throttle = const Duration(seconds: 15),
    this.extrasTtl = const Duration(seconds: 60),
    String Function()? sessionIdFactory,
  })  : _channel = channel ?? const MethodChannel('app.openfamily/watch'),
        _actions = actions ?? const DefaultWatchActions(),
        _supported = supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS),
        _clock = clock ?? DateTime.now,
        _newSessionId = sessionIdFactory ?? _randomSessionId;

  static final WatchBridgeIos instance = WatchBridgeIos();

  static const String prefKey = 'watch_show_family';
  static const String sessionPrefKey = 'watch_session_id';

  static String _randomSessionId() {
    final math.Random r = math.Random.secure();
    return List<String>.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  final String Function() _newSessionId;
  // Identity of the current sign-in; every snapshot carries it.
  String? _sessionId;

  final MethodChannel _channel;
  final WatchPhoneActions _actions;
  final bool _supported;
  final DateTime Function() _clock;
  final Duration throttle;
  final Duration extrasTtl;

  bool _started = false;
  // Set by clear() (sign-out, switch off). While set nothing is pushed; an
  // in-flight push notices through the generation counter and drops itself.
  bool _clearRequested = false;
  int _generation = 0;
  bool _enabled = true;
  WatchStatus _status = const WatchStatus();
  List<Member> _members = const <Member>[];
  String? _myId;
  String? _circleId;
  Timer? _timer;
  DateTime? _lastPush;
  WatchExtras? _extras;
  DateTime? _extrasAt;

  /// True on an iPhone (the only place the bridge does anything).
  bool get isSupported => _supported;

  /// Latest status seen from the native side.
  WatchStatus get status => _status;

  /// Called once at app start. Safe everywhere.
  Future<void> start() async {
    if (!_supported || _started) return;
    _started = true;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      _enabled = p.getBool(prefKey) ?? true;
      _sessionId = p.getString(sessionPrefKey);
      _channel.setMethodCallHandler(_onCall);
      await refreshStatus();
    } catch (_) {
      // A missing native side must never hurt the app.
    }
  }

  /// Asks the native side whether a watch with the app is there.
  Future<WatchStatus> refreshStatus() async {
    if (!_supported) return _status;
    try {
      _status = WatchStatus.fromMap(await _channel.invokeMethod<Object?>('status'));
    } catch (_) {
      _status = const WatchStatus();
    }
    return _status;
  }

  Future<bool> isEnabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(prefKey) ?? true;
  }

  /// The settings switch. Off removes everything from the watch.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(prefKey, value);
    if (!value) {
      await clear(keepSession: true);
    } else {
      // Same sign-in, sending allowed again. This is NOT a sign-in.
      _clearRequested = false;
      if (_supported && _started && _sessionId != null) {
        try {
          await _channel.invokeMethod<void>('resume');
        } catch (_) {}
      }
      _schedule(force: true);
    }
  }

  /// Sign-out: the watch must not keep any family data.
  ///
  /// [keepSession] is for switching the setting off (same user); sign-out
  /// leaves it false and forgets the session identity.
  Future<void> clear({bool keepSession = false}) async {
    _clearRequested = true;
    if (!keepSession) {
      _sessionId = null;
      try {
        (await SharedPreferences.getInstance()).remove(sessionPrefKey);
      } catch (_) {}
    }
    _generation++;
    _timer?.cancel();
    _timer = null;
    _members = const <Member>[];
    _extras = null;
    _extrasAt = null;
    _lastPush = null;
    if (!_supported || !_started) return;
    try {
      // The native side remembers the wipe until the watch has it.
      await _channel.invokeMethod<void>('clear', <String, dynamic>{'keepSession': keepSession});
    } catch (_) {}
  }

  /// A real sign-in (AuthService login): new session identity, pushes allowed
  /// again. The native side delivers any wipe that never reached the watch
  /// BEFORE the new session's data, and the watch drops data of other sessions.
  /// Never call this from the settings switch.
  Future<void> signedIn() async {
    _clearRequested = false;
    final String id = _newSessionId();
    _sessionId = id;
    try {
      (await SharedPreferences.getInstance()).setString(sessionPrefKey, id);
    } catch (_) {}
    if (!_supported || !_started) return;
    try {
      await _channel.invokeMethod<void>('signedIn', id);
    } catch (_) {}
  }

  /// Called by the family service whenever the roster changes.
  void onRoster(List<Member> members, {String? userId, String? circleId}) {
    if (!_supported || !_started || !_enabled || _clearRequested) return;
    _members = members;
    _myId = userId ?? _myId;
    _circleId = circleId ?? _circleId;
    if (!_status.listening) return;
    _schedule();
  }

  void _schedule({bool force = false}) {
    if (!_supported || !_started || !_enabled || _clearRequested || _timer != null) return;
    final DateTime now = _clock();
    Duration wait = Duration.zero;
    if (!force && _lastPush != null) {
      final Duration since = now.difference(_lastPush!);
      if (since < throttle) wait = throttle - since;
    }
    _timer = Timer(wait, () {
      _timer = null;
      unawaited(pushNow());
    });
  }

  /// Builds and sends one snapshot. Never throws.
  Future<void> pushNow() async {
    if (!_supported || !_started || !_enabled || _clearRequested) return;
    final int gen = _generation;
    // A restored session (app start with a saved login) has no identity yet:
    // the roster only exists for an authenticated user, so this is that path.
    if (_sessionId == null) await signedIn();
    try {
      final DateTime now = _clock();
      if (_extras == null || _extrasAt == null || now.difference(_extrasAt!) > extrasTtl) {
        _extras = await _actions.extras();
        _extrasAt = now;
      }
      final WatchExtras x = _extras ?? const WatchExtras();
      String? myName;
      for (final Member m in _members) {
        if (m.id == _myId) myName = m.name;
      }
      final bool sharing = !x.paused;
      final Map<String, dynamic> snap = buildWatchSnapshot(
        members: _members,
        myId: _myId,
        myName: myName,
        activeCircleId: _circleId,
        circles: x.circles,
        sharing: sharing,
        pausedUntil: x.pausedUntil,
        alerts: x.alerts,
        units: UnitPreferenceService.units.value,
        sessionId: _sessionId,
        now: now,
      );
      // A sign-out or switch-off may have happened while the extras loaded.
      if (gen != _generation || _clearRequested || !_enabled) return;
      _lastPush = now;
      await _channel.invokeMethod<void>('snapshot', jsonEncode(snap));
    } catch (_) {}
  }

  /// Commands from the watch. The reply goes straight back to the watch.
  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'statusChanged') {
      _status = WatchStatus.fromMap(call.arguments);
      if (_status.listening) _schedule(force: true);
      return null;
    }
    if (call.method != 'command') return null;
    final Object? raw = call.arguments;
    final Map<Object?, Object?> args = raw is Map ? raw : const <Object?, Object?>{};
    return handleCommand(args.map((Object? k, Object? v) => MapEntry(k.toString(), v)));
  }

  /// Runs one command. Public so tests can drive it without a channel.
  Future<Map<String, dynamic>> handleCommand(Map<String, Object?> args) async {
    if (!_enabled) {
      return _fail('Watch access is turned off in Orbitly settings on the iPhone.');
    }
    final String cmd = args['cmd'] is String ? args['cmd']! as String : '';
    try {
      switch (cmd) {
        case 'sos':
          await _actions.sos();
          return _ok('SOS sent to your family.');
        case 'sosResolve':
          await _actions.resolveSos();
          return _ok('Marked safe.');
        case 'checkin':
          await _actions.checkIn(<String>[
            for (final Member m in _members)
              if (m.id != _myId) m.id,
          ]);
          return _ok('Checked in.');
        case 'pause':
          final Object? m = args['minutes'];
          final int minutes = m is num ? m.toInt().clamp(15, 1440) : 60;
          await _actions.pause(minutes);
          _extrasAt = null;
          _schedule(force: true);
          return _ok('Sharing paused.');
        case 'resume':
          await _actions.resume();
          _extrasAt = null;
          _schedule(force: true);
          return _ok('Sharing resumed.');
        case 'refresh':
          _extrasAt = null;
          await pushNow();
          return _ok('Updated.');
        case 'reply':
          final Object? c = args['circleId'];
          final Object? t = args['text'];
          if (c is! String || t is! String) return _fail('That reply could not be sent.');
          await _actions.reply(c, t);
          return _ok('Sent.');
        case 'markRead':
          final Object? c = args['circleId'];
          if (c is String) await _actions.markRead(c);
          _extrasAt = null;
          return _ok('');
      }
    } on WatchCommandException catch (e) {
      return _fail(e.message);
    } catch (_) {
      return _fail('The iPhone could not do that. Open Orbitly there and try again.');
    }
    return _fail('Unknown request.');
  }

  static Map<String, dynamic> _ok(String message) =>
      <String, dynamic>{'ok': true, 'message': message};
  static Map<String, dynamic> _fail(String message) =>
      <String, dynamic>{'ok': false, 'message': message};

  @visibleForTesting
  Future<void> debugStatusChanged(Object? status) =>
      _onCall(MethodCall('statusChanged', status));

  @visibleForTesting
  void debugMark({bool started = true}) => _started = started;
}
