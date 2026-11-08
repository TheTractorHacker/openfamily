import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/alert.dart';
import '../../models/circle.dart';
import '../../models/member.dart';
import '../alert_service.dart';
import '../api_client.dart';
import '../chat_service.dart';
import '../circle_selection.dart';
import '../circle_service.dart';
import '../delivery_status.dart';
import '../e2ee/private_runtime.dart';
import '../location_reporter.dart';
import '../location_service.dart';
import '../location_sharing_service.dart';
import '../sharing_service.dart';
import 'watch_snapshot.dart';

/// Companion bridge to a paired smartwatch (docs/design/WATCH_APPS.md).
///
/// The phone stays the only holder of tokens and Private-circle keys. It pushes
/// a compact, already readable snapshot to the watch and executes the few
/// commands the watch may send, using its own credentials. Everything here is
/// best effort and never throws into the app; without Google Play services or
/// a paired watch the native side does nothing.

/// What the native side knows about the watch connection.
class WatchLinkStatus {
  const WatchLinkStatus({this.available = false, this.nodes = 0, this.names = const <String>[]});

  /// Wearable support (Google Play services) exists on this phone.
  final bool available;

  /// Connected watches right now.
  final int nodes;
  final List<String> names;

  bool get connected => available && nodes > 0;

  static const WatchLinkStatus none = WatchLinkStatus();

  @override
  bool operator ==(Object other) =>
      other is WatchLinkStatus && other.available == available && other.nodes == nodes && listEquals(other.names, names);

  @override
  int get hashCode => Object.hash(available, nodes, Object.hashAll(names));
}

/// Native transport. Faked in tests.
abstract class WatchTransport {
  /// Publishes the snapshot JSON; false when nothing could be written.
  Future<bool> publish(String json);

  /// Removes the snapshot from the Data Layer (sign-out, bridge turned off).
  /// True only when the removal reached a connected watch; false means it is
  /// still owed (no watch connected, no Play Services) and the bridge keeps a
  /// persistent clear-pending flag and retries when a watch connects.
  Future<bool> clear();

  /// The user signed in again: native publishing may resume.
  Future<void> allowPublish();
  Future<WatchLinkStatus> status();

  /// Registers handlers for commands from the watch and for connection changes.
  void listen({required Future<void> Function(String json) onCommand, required void Function() onPeerChanged});
}

class MethodChannelWatchTransport implements WatchTransport {
  MethodChannelWatchTransport([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('app.openfamily/watch');
  final MethodChannel _channel;

  @override
  Future<bool> publish(String json) async {
    try {
      return await _channel.invokeMethod<bool>('publish', json) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    try {
      return await _channel.invokeMethod<bool>('clear') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> allowPublish() async {
    try {
      await _channel.invokeMethod<void>('allowPublish');
    } catch (_) {}
  }

  @override
  Future<WatchLinkStatus> status() async {
    try {
      final Map<Object?, Object?>? m = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      if (m == null) return WatchLinkStatus.none;
      return WatchLinkStatus(
        available: m['available'] == true,
        nodes: (m['nodes'] as num?)?.toInt() ?? 0,
        names: <String>[for (final Object? n in (m['names'] as List<Object?>?) ?? const <Object?>[]) '$n'],
      );
    } catch (_) {
      return WatchLinkStatus.none;
    }
  }

  @override
  void listen({required Future<void> Function(String json) onCommand, required void Function() onPeerChanged}) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'command' && call.arguments is String) {
        await onCommand(call.arguments as String);
      } else if (call.method == 'peerChanged') {
        onPeerChanged();
      }
      return null;
    });
  }
}

/// What a command does on the phone. The real one calls the existing services.
abstract class WatchActions {
  Future<void> sos();
  Future<void> checkIn();
  Future<DateTime?> pause(int minutes);
  Future<void> resume();
  Future<void> ack(String alertId);

  /// Sends [text] to the circle chat the phone shows (or the first circle).
  Future<void> reply(String text, {String? circleId});
}

class ApiWatchActions implements WatchActions {
  const ApiWatchActions();

  Future<({double? lat, double? lon})> _here() async {
    final LatLng? p = await LocationService.currentPosition();
    return (lat: p?.latitude, lon: p?.longitude);
  }

  @override
  Future<void> sos() async {
    final ({double? lat, double? lon}) h = await _here();
    final Map<String, dynamic> body = <String, dynamic>{if (h.lat != null && h.lon != null) ...<String, dynamic>{'lat': h.lat, 'lon': h.lon}};
    await ApiClient.post('/alerts/sos', body: body);
    unawaited(PrivateRuntime.instance.sealAlertPosition('sos', h.lat, h.lon));
    LocationReporter.startSosBurst();
  }

  @override
  Future<void> checkIn() async {
    final ({double? lat, double? lon}) h = await _here();
    final Map<String, dynamic> body = <String, dynamic>{
      'note': "I'm OK",
      if (h.lat != null && h.lon != null) ...<String, dynamic>{'lat': h.lat, 'lon': h.lon},
    };
    await ApiClient.post('/alerts/check-in', body: body);
    unawaited(PrivateRuntime.instance.sealAlertPosition('checkin', h.lat, h.lon, note: "I'm OK"));
  }

  @override
  Future<DateTime?> pause(int minutes) async => (await const SharingService().pause(minutes: minutes)).until;

  @override
  Future<void> resume() => const SharingService().resume();

  @override
  Future<void> ack(String alertId) => const AlertService().acknowledge(alertId);

  @override
  Future<void> reply(String text, {String? circleId}) async {
    if (circleId == null) throw StateError('no circle');
    await ChatService.instance.send(circleId, text);
  }
}

/// The few things read from the app's services when a snapshot is built. Kept
/// behind an interface so the bridge is testable without a server.
abstract class WatchContextSource {
  Future<WatchContext> read();

  /// Drops cached values so the next [read] is fresh (after a command).
  void invalidate();
}

class WatchContext {
  const WatchContext({
    this.signedIn = true,
    this.scopeId = 'all',
    this.scopeName = 'Everyone',
    this.scopePrivate = false,
    this.circles = const <WatchCircle>[],
    this.sharingPaused = false,
    this.pausedUntil,
    this.unread = 0,
    this.alerts = const <WatchAlert>[],
    this.privateMemberIds = const <String>{},
    this.chatCircleId,
  });
  final bool signedIn;
  final String scopeId;
  final String scopeName;
  final bool scopePrivate;
  final List<WatchCircle> circles;
  final bool sharingPaused;
  final DateTime? pausedUntil;
  final int unread;
  final List<WatchAlert> alerts;
  final Set<String> privateMemberIds;

  /// The circle quick replies are sent to.
  final String? chatCircleId;
}

/// Default source. Only called while a watch is connected, and it caches the
/// calls it has to make (circles 10 min, alerts and pause state 1 min).
class ServiceWatchContextSource implements WatchContextSource {
  List<Circle>? _circles;
  DateTime? _circlesAt;
  List<WatchAlert>? _alerts;
  DateTime? _alertsAt;
  SharingPause? _pause;
  DateTime? _pauseAt;

  static bool _fresh(DateTime? at, Duration ttl) => at != null && DateTime.now().difference(at) < ttl;

  @override
  void invalidate() {
    _alertsAt = null;
    _pauseAt = null;
  }

  @override
  Future<WatchContext> read() async {
    if (!_fresh(_circlesAt, const Duration(minutes: 10))) {
      try {
        _circles = await CircleService.instance.listCircles();
        _circlesAt = DateTime.now();
      } catch (_) {}
    }
    if (!_fresh(_alertsAt, const Duration(minutes: 1))) {
      try {
        final AlertPage page = await const AlertService().list(limit: 10);
        _alerts = <WatchAlert>[
          for (final AlertSummary a in page.alerts)
            if (a.isActive && !a.kind.isBubble)
              WatchAlert(
                id: a.id,
                kind: switch (a.kind) { AlertKind.sos => 'sos', AlertKind.help => 'help', _ => 'check_in' },
                from: a.senderName,
                at: a.createdAt,
                note: a.note,
              ),
        ];
        _alertsAt = DateTime.now();
      } catch (_) {}
    }
    if (!_fresh(_pauseAt, const Duration(minutes: 1))) {
      try {
        _pause = await const SharingService().pauseStatus();
        _pauseAt = DateTime.now();
      } catch (_) {}
    }
    final List<Circle> circles = _circles ?? const <Circle>[];
    final String? sel = await CircleSelectionStore.instance.read();
    Circle? scope;
    for (final Circle c in circles) {
      if (c.id == sel) scope = c;
    }
    final Circle? primary = circles.isEmpty ? null : circles.firstWhere((Circle c) => c.isPrimary, orElse: () => circles.first);
    // Members of Private circles, from the delivery reports the app already holds.
    final Set<String> priv = <String>{};
    for (final CircleDelivery d in DeliveryHints.reports.value.values) {
      if (DeliveryHints.circleById[d.circleId]?.isPrivate == true) {
        for (final MemberDelivery m in d.members) {
          priv.add(m.userId);
        }
      }
    }
    final SharingPause? p = _pause;
    final bool pauseActive = p != null && p.activeAt(DateTime.now());
    return WatchContext(
      scopeId: scope?.id ?? 'all',
      scopeName: scope?.name ?? 'Everyone',
      scopePrivate: scope?.isPrivate ?? false,
      circles: <WatchCircle>[for (final Circle c in circles) WatchCircle(id: c.id, name: c.name, isPrivate: c.isPrivate)],
      sharingPaused: !LocationSharingService.enabled.value || pauseActive,
      pausedUntil: pauseActive ? p.until : null,
      unread: ChatEvents.unreadTotal.value,
      alerts: _alerts ?? const <WatchAlert>[],
      privateMemberIds: priv,
      chatCircleId: scope?.id ?? primary?.id,
    );
  }
}

class WatchBridge {
  WatchBridge({
    WatchTransport? transport,
    WatchActions? actions,
    WatchContextSource? source,
    DateTime Function()? clock,
    this.minInterval = const Duration(seconds: 5),
    this.keepAlive = const Duration(minutes: 10),
    this.sosCooldown = const Duration(seconds: 60),
    this.commandCooldown = const Duration(seconds: 2),
    bool? supported,
  })  : _transport = transport ?? MethodChannelWatchTransport(),
        _actions = actions ?? const ApiWatchActions(),
        _source = source ?? ServiceWatchContextSource(),
        _clock = clock ?? DateTime.now,
        _supportedOverride = supported;

  static WatchBridge instance = WatchBridge();

  /// Wear OS (Android) and Apple Watch (iPhone). The Dart side is shared; the
  /// native transport is WatchBridgePlugin.kt on Android and WatchBridge.swift
  /// on iOS, both on the channel `app.openfamily/watch`.
  static bool get platformSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// True on an iPhone (Apple Watch instead of Wear OS wording).
  static bool get isApple => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static const String enabledKey = 'watch_bridge_enabled';
  static const String showPrivateKey = 'watch_show_private';
  static const String clearPendingKey = 'watch_clear_pending';

  final WatchTransport _transport;
  final WatchActions _actions;
  final WatchContextSource _source;
  final DateTime Function() _clock;
  final bool? _supportedOverride;
  final Duration minInterval;
  final Duration keepAlive;
  final Duration sosCooldown;
  final Duration commandCooldown;

  bool get _supported => _supportedOverride ?? platformSupported;

  /// Connection state for Settings, Watch.
  final ValueNotifier<WatchLinkStatus> link = ValueNotifier<WatchLinkStatus>(WatchLinkStatus.none);

  List<Member> _members = const <Member>[];
  String? _selfId;
  bool _enabled = true;
  bool _showPrivate = true;
  bool _started = false;
  bool _signedIn = true;

  /// A clear (sign-out, bridge off) the watch has not confirmed yet. Persisted;
  /// while set nothing is published.
  bool _clearPending = false;
  WatchCommandResult? _lastCommand;

  String? _lastHash;
  DateTime? _lastPublish;
  Timer? _trailing;
  Timer? _keepAliveTimer;
  bool _publishing = false;
  bool _dirty = false;

  final List<String> _seenCommandIds = <String>[];
  final Map<WatchCmd, DateTime> _lastRun = <WatchCmd, DateTime>{};

  bool get enabled => _enabled;
  bool get showPrivate => _showPrivate;

  /// Starts listening. Safe to call more than once; a no-op where unsupported.
  Future<void> start() async {
    if (_started || !_supported) return;
    _started = true;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      _enabled = p.getBool(enabledKey) ?? true;
      _showPrivate = p.getBool(showPrivateKey) ?? true;
      _clearPending = p.getBool(clearPendingKey) ?? false;
    } catch (_) {}

    _transport.listen(onCommand: handleCommand, onPeerChanged: () => unawaited(refreshLink(forcePublish: true)));
    _keepAliveTimer = Timer.periodic(keepAlive, (_) => unawaited(refreshLink(forcePublish: true)));
    await refreshLink(forcePublish: true);
  }

  /// Re-reads the connection and, when a watch is there, publishes.
  Future<void> refreshLink({bool forcePublish = false}) async {
    if (!_supported || !_started) return;
    link.value = await _transport.status();
    if (_clearPending) {
      await _deliverClear();
      return;
    }
    if (forcePublish) await publish(force: true);
  }

  Future<void> _setPending(bool v) async {
    _clearPending = v;
    try {
      (await SharedPreferences.getInstance()).setBool(clearPendingKey, v);
    } catch (_) {}
  }

  /// Tries to remove the watch's copy; keeps the flag when it cannot be confirmed.
  Future<void> _deliverClear() async {
    final bool ok = await _transport.clear();
    if (ok) {
      // Only a sign-out clear is final; "bridge off" is also finished once delivered.
      await _setPending(false);
    }
  }

  /// The user signed in again (called after a successful login).
  Future<void> signedIn() async {
    if (!_supported) return;
    _signedIn = true;
    // Native first: it starts a NEW session and tries to deliver any undelivered wipe
    // (the previous user's data on the watch is dropped by the session change). Only then
    // does the Dart gate open.
    await _transport.allowPublish();
    if (_clearPending) await _setPending(false);
    if (_started) await publish(force: true);
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    try {
      (await SharedPreferences.getInstance()).setBool(enabledKey, v);
    } catch (_) {}
    if (!v) {
      _lastHash = null;
      await _setPending(true);
      await _deliverClear();
    } else {
      await _transport.allowPublish();
      if (_clearPending) await _setPending(false);
      await publish(force: true);
    }
  }

  Future<void> setShowPrivate(bool v) async {
    _showPrivate = v;
    try {
      (await SharedPreferences.getInstance()).setBool(showPrivateKey, v);
    } catch (_) {}
    await publish(force: true);
  }

  /// Sign-out: the watch is told to forget everything.
  Future<void> signedOut() async {
    _members = const <Member>[];
    _signedIn = false;
    _lastCommand = null;
    _lastHash = null;
    _seenCommandIds.clear();
    if (!_supported) return;
    // Not best effort: the flag survives a restart and a missing watch, and is
    // retried when a watch connects.
    await _setPending(true);
    await _deliverClear();
  }

  /// Called with every new roster (FamilyService, same place as the home widget).
  void onMembers(List<Member> members, {String? selfId}) {
    if (!_supported || !_started) return;
    if (_clearPending || !_signedIn) return; // roster events after sign-out are stale
    _members = members;
    if (selfId != null) _selfId = selfId;
    unawaited(publish());
  }

  /// Publishes at most once per [minInterval] (the newest state always wins),
  /// and only when the content changed or [force] is set.
  Future<void> publish({bool force = false}) async {
    if (!_supported || !_started || !_enabled || _clearPending || !_signedIn) return;
    if (!link.value.connected) return;
    final DateTime now = _clock();
    if (_publishing) {
      _dirty = true;
      return;
    }
    final DateTime? last = _lastPublish;
    if (!force && last != null && now.difference(last) < minInterval) {
      _trailing ??= Timer(minInterval - now.difference(last), () {
        _trailing = null;
        unawaited(publish());
      });
      return;
    }
    _publishing = true;
    try {
      final WatchContext c = await _source.read();
      final String? selfId = _selfId ?? ChatEvents.selfUserId;
      final Map<String, dynamic> snap = buildWatchSnapshot(WatchSnapshotInput(
        now: now,
        signedIn: _signedIn && c.signedIn,
        members: _members,
        selfId: selfId,
        scopeId: c.scopeId,
        scopeName: c.scopeName,
        scopePrivate: c.scopePrivate,
        circles: c.circles,
        sharingPaused: c.sharingPaused,
        pausedUntil: c.pausedUntil,
        unread: c.unread,
        alerts: c.alerts,
        privateMemberIds: c.privateMemberIds,
        showPrivate: _showPrivate,
        lastCommand: _lastCommand,
      ));
      final String hash = watchContentHash(snap);
      if (!force && hash == _lastHash) return;
      // Re-check right before sending: a sign-out or switch-off while this
      // snapshot was being built must win over the in-flight push.
      if (!_enabled || _clearPending || !_signedIn) return;
      final bool ok = await _transport.publish(encodeWatchSnapshot(snap));
      if (ok) {
        _lastHash = hash;
        _lastPublish = now;
      }
    } catch (_) {
      // A failed publish is retried by the next roster change or keep-alive.
    } finally {
      _publishing = false;
      if (_dirty) {
        _dirty = false;
        unawaited(publish());
      }
    }
  }

  /// Runs a command from the watch. Always ends by publishing a snapshot that
  /// carries the result, so the watch learns whether it worked.
  Future<void> handleCommand(String raw) async {
    final WatchCommand? cmd = WatchCommand.tryParse(raw);
    if (cmd == null || !_enabled) return;
    final DateTime now = _clock();
    // Replay window and one-shot ids.
    if (now.difference(cmd.at).abs() > kWatchCommandWindow) {
      _record(cmd, false, 'The watch clock and the phone clock do not match.');
      return;
    }
    if (_seenCommandIds.contains(cmd.id)) return;
    _seenCommandIds.add(cmd.id);
    if (_seenCommandIds.length > 50) _seenCommandIds.removeAt(0);
    // Rate limits.
    final Duration gap = cmd.cmd == WatchCmd.sos ? sosCooldown : (cmd.cmd == WatchCmd.refresh ? minInterval : commandCooldown);
    final DateTime? prev = _lastRun[cmd.cmd];
    if (prev != null && now.difference(prev) < gap) {
      _record(cmd, cmd.cmd == WatchCmd.sos, cmd.cmd == WatchCmd.sos ? 'An SOS was just sent.' : 'Too fast. Try again.');
      return;
    }
    _lastRun[cmd.cmd] = now;
    bool ok = true;
    String message = '';
    try {
      switch (cmd.cmd) {
        case WatchCmd.sos:
          await _actions.sos();
        case WatchCmd.checkin:
          await _actions.checkIn();
        case WatchCmd.pause:
          await _actions.pause(int.parse(cmd.arg!));
        case WatchCmd.resume:
          await _actions.resume();
        case WatchCmd.ack:
          await _actions.ack(cmd.arg!);
        case WatchCmd.reply:
          final WatchContext c = await _source.read();
          await _actions.reply(kWatchReplies[cmd.arg]!, circleId: c.chatCircleId);
        case WatchCmd.refresh:
          break;
      }
    } catch (e) {
      ok = false;
      message = e is ApiException && e.status == 429 ? 'Wait a minute and try again.' : "The phone could not do it. Check its connection.";
    }
    _source.invalidate();
    _record(cmd, ok, message);
  }

  void _record(WatchCommand cmd, bool ok, String message) {
    _lastCommand = WatchCommandResult(id: cmd.id, cmd: cmd.cmd.name, ok: ok, at: _clock(), message: message);
    unawaited(publish(force: true));
  }

  @visibleForTesting
  void disposeForTest() {
    _trailing?.cancel();
    _keepAliveTimer?.cancel();
  }
}
