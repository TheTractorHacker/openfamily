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
  /// [urgent] asks the platform to deliver it at once (Wear OS `setUrgent`);
  /// otherwise the system may batch it for a few minutes to save battery.
  /// WatchConnectivity has no such switch, so the iPhone ignores it.
  Future<bool> publish(String json, {bool urgent = true});

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
  Future<bool> publish(String json, {bool urgent = true}) async {
    try {
      // A map since v0.26; both native sides still accept the bare string of older builds.
      return await _channel.invokeMethod<bool>('publish', <String, Object>{'json': json, 'urgent': urgent}) ?? false;
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

  /// Fires when something the watch shows changed outside the roster: an alert
  /// arrived or was acknowledged, the unread count or the sharing state
  /// changed. The bridge then publishes within seconds instead of waiting for
  /// its slow cadence. Pushed, never polled.
  Stream<void> get changes;
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

/// Default source. Only called while a watch is connected. Alerts and the
/// pause state are no longer polled every minute: they are fetched once, then
/// again only when the live socket says something changed (an alert or
/// acknowledgement frame, a reconnect) or this phone paused or resumed, with a
/// slow safety refresh ([ttl], 10 min) for anything missed. Circles likewise.
class ServiceWatchContextSource implements WatchContextSource {
  ServiceWatchContextSource({
    Future<List<Circle>> Function()? listCircles,
    Future<List<WatchAlert>> Function()? listAlerts,
    Future<SharingPause> Function()? pauseStatus,
    DateTime Function()? clock,
    this.ttl = const Duration(minutes: 10),
  })  : _listCircles = listCircles ?? (() => CircleService.instance.listCircles()),
        _listAlerts = listAlerts ?? _fetchAlerts,
        _pauseStatus = pauseStatus ?? (() => const SharingService().pauseStatus()),
        _clock = clock ?? DateTime.now;

  final Future<List<Circle>> Function() _listCircles;
  final Future<List<WatchAlert>> Function() _listAlerts;
  final Future<SharingPause> Function() _pauseStatus;
  final DateTime Function() _clock;

  /// Safety refresh of what is otherwise pushed.
  final Duration ttl;

  List<Circle>? _circles;
  DateTime? _circlesAt;
  List<WatchAlert>? _alerts;
  DateTime? _alertsAt;
  SharingPause? _pause;
  DateTime? _pauseAt;

  static Future<List<WatchAlert>> _fetchAlerts() async {
    final AlertPage page = await const AlertService().list(limit: 10);
    return <WatchAlert>[
      for (final AlertSummary a in page.alerts)
        if (a.isActive && !a.kind.isBubble)
          WatchAlert(
            id: a.id,
            kind: switch (a.kind) { AlertKind.sos => 'sos', AlertKind.help => 'help', _ => 'check_in' },
            from: a.senderName,
            fromId: a.userId,
            at: a.createdAt,
            note: a.note,
          ),
    ];
  }

  bool _fresh(DateTime? at) => at != null && _clock().difference(at) < ttl;

  @override
  void invalidate() {
    _alertsAt = null;
    _pauseAt = null;
  }

  // ---- pushed changes ----
  late final StreamController<void> _changes = StreamController<void>.broadcast(onListen: _attach, onCancel: _detach);
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  @override
  Stream<void> get changes => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _alertsChanged(Object? _) {
    _alertsAt = null;
    _emit();
  }

  void _pauseChanged() {
    _pauseAt = null;
    _emit();
  }

  void _attach() {
    _subs
      ..add(AlertEvents.alerts.listen(_alertsChanged))
      ..add(AlertEvents.acks.listen(_alertsChanged))
      // Frames missed while the socket was down: fetch again.
      ..add(ChatEvents.reconnects.listen((_) {
        invalidate();
        _emit();
      }));
    ChatEvents.unreadTotal.addListener(_emit);
    LocationSharingService.enabled.addListener(_emit);
    SharingService.pauseChanges.addListener(_pauseChanged);
  }

  void _detach() {
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    ChatEvents.unreadTotal.removeListener(_emit);
    LocationSharingService.enabled.removeListener(_emit);
    SharingService.pauseChanges.removeListener(_pauseChanged);
  }

  @override
  Future<WatchContext> read() async {
    if (!_fresh(_circlesAt)) {
      try {
        _circles = await _listCircles();
        _circlesAt = _clock();
      } catch (_) {}
    }
    if (!_fresh(_alertsAt)) {
      try {
        _alerts = await _listAlerts();
        _alertsAt = _clock();
      } catch (_) {}
    }
    if (!_fresh(_pauseAt)) {
      try {
        _pause = await _pauseStatus();
        _pauseAt = _clock();
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
    final bool pauseActive = p != null && p.activeAt(_clock());
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

/// How often the phone may send, decided by what the watch app said last
/// (docs/design/WATCH_APPS.md, Cadence).
enum WatchTier {
  /// Default: the watch app is not on screen. Only meaningful changes, at most
  /// every [WatchBridge.hiddenInterval], not urgent; plus the keep-alive.
  hidden,

  /// The watch app is on screen in always-on (dimmed) mode: meaningful changes
  /// at most every [WatchBridge.ambientInterval].
  ambient,

  /// The watch app is on screen: every change, at most every
  /// [WatchBridge.minInterval], urgent.
  visible,
}

class WatchBridge {
  WatchBridge({
    WatchTransport? transport,
    WatchActions? actions,
    WatchContextSource? source,
    DateTime Function()? clock,
    Timer Function(Duration delay, void Function() callback)? timer,
    this.minInterval = const Duration(seconds: 5),
    this.ambientInterval = const Duration(seconds: 60),
    this.hiddenInterval = const Duration(minutes: 2),
    this.keepAlive = const Duration(minutes: 10),
    this.visibleKeepAlive = const Duration(seconds: 60),
    this.visibleTtl = const Duration(seconds: 150),
    this.ambientTtl = const Duration(minutes: 15),
    this.sosCooldown = const Duration(seconds: 60),
    this.commandCooldown = const Duration(seconds: 2),
    bool? supported,
  })  : _transport = transport ?? MethodChannelWatchTransport(),
        _actions = actions ?? const ApiWatchActions(),
        _source = source ?? ServiceWatchContextSource(),
        _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.new,
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
  final Timer Function(Duration, void Function()) _timer;
  final bool? _supportedOverride;

  /// Floor between two snapshots (and between two looks at the roster), and
  /// the cadence while the watch app is on screen.
  final Duration minInterval;

  /// Meaningful changes while the watch app is in always-on (ambient) mode.
  final Duration ambientInterval;

  /// Meaningful changes while the watch app is not on screen.
  final Duration hiddenInterval;

  /// Longest gap without a snapshot while a watch is connected (also carries
  /// the minor changes held back meanwhile), and how often the link is re-read.
  final Duration keepAlive;

  /// The same while the watch app is on screen, so its "Updated" line stays current.
  final Duration visibleKeepAlive;

  /// How long a `visible` / `visible ambient` from the watch counts without a
  /// repeat: a lost `hidden` (watch app killed, out of range) falls back to the
  /// hidden tier by itself. The watch repeats `visible` every 60 s.
  final Duration visibleTtl;
  final Duration ambientTtl;
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

  /// Fine content hash and the snapshot of the last publish (what the watch has).
  String? _lastHash;
  Map<String, dynamic>? _lastSent;
  DateTime? _lastPublish;

  /// Last time a snapshot was built and compared (at most once per [minInterval]).
  DateTime? _lastEval;
  Timer? _trailing;
  DateTime? _trailingAt;
  Timer? _keepAliveTimer;
  bool _publishing = false;
  bool _dirty = false;
  bool _dirtyEvent = false;
  bool _dirtyForce = false;
  bool _dirtyUrgent = false;
  StreamSubscription<void>? _changesSub;

  WatchTier _tier = WatchTier.hidden;
  DateTime? _tierUntil;

  final List<String> _seenCommandIds = <String>[];
  final Map<WatchCmd, DateTime> _lastRun = <WatchCmd, DateTime>{};

  bool get enabled => _enabled;
  bool get showPrivate => _showPrivate;

  /// What the watch app said last, expired after [visibleTtl] / [ambientTtl].
  WatchTier get tier => _tierAt(_clock());

  WatchTier _tierAt(DateTime now) {
    final DateTime? until = _tierUntil;
    return until != null && now.isBefore(until) ? _tier : WatchTier.hidden;
  }

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

    _transport.listen(onCommand: handleCommand, onPeerChanged: () => unawaited(refreshLink()));
    // Alerts, unread and sharing changes are pushed by the source; nothing polls.
    _changesSub = _source.changes.listen((_) => unawaited(publish(event: true)));
    await refreshLink(forcePublish: true);
    _armKeepAlive();
  }

  /// Re-reads the connection and, when a watch is there, publishes: always with
  /// [forcePublish], otherwise when a watch has just (re)appeared.
  Future<void> refreshLink({bool forcePublish = false}) async {
    if (!_supported || !_started) return;
    final bool was = link.value.connected;
    link.value = await _transport.status();
    if (_clearPending) {
      await _deliverClear();
      return;
    }
    if (!link.value.connected) {
      // Gone: what it had is unknown when it comes back, so the next snapshot is a full, urgent one.
      _lastSent = null;
      _lastHash = null;
      _tier = WatchTier.hidden;
      _tierUntil = null;
      return;
    }
    if (forcePublish || !was) await publish(force: true);
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
    _lastSent = null; // a new session: the first snapshot is urgent
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
      _lastSent = null;
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
    _lastSent = null;
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

  /// Runs [publish] again at [at], unless a run at or before it is already planned.
  void _scheduleAt(DateTime at) {
    final DateTime? planned = _trailingAt;
    if (_trailing != null && planned != null && !planned.isAfter(at)) return;
    _trailing?.cancel();
    final Duration d = at.difference(_clock());
    _trailingAt = at;
    _trailing = _timer(d.isNegative ? Duration.zero : d, () {
      _trailing = null;
      _trailingAt = null;
      unawaited(publish());
    });
  }

  /// How long a change of kind [c] still has to wait in [tier]; null: it is
  /// left to the keep-alive.
  Duration? _wait(WatchChange c, WatchTier tier, DateTime now) {
    final Duration need;
    switch (c) {
      case WatchChange.none:
        return null;
      case WatchChange.urgent:
      case WatchChange.event:
        need = minInterval;
      case WatchChange.meaningful:
        need = switch (tier) { WatchTier.visible => minInterval, WatchTier.ambient => ambientInterval, WatchTier.hidden => hiddenInterval };
      case WatchChange.minor:
        if (tier != WatchTier.visible) return null;
        need = minInterval;
    }
    final DateTime? last = _lastPublish;
    if (last == null) return Duration.zero;
    final Duration since = now.difference(last);
    return since >= need ? Duration.zero : need - since;
  }

  /// Sends the current state when the watch needs it (docs/design/WATCH_APPS.md,
  /// Cadence). The roster is looked at most once per [minInterval]; what changed
  /// decides how soon it goes out in the current [tier]: alerts, command answers
  /// and a new sign-in at once and urgent; unread and sharing within seconds;
  /// moves, places and battery steps at the tier's pace; GPS jitter and newer
  /// fix times with the keep-alive. [event]: called for a pushed change (alert,
  /// unread, sharing), which skips the roster floor. [force]: send now even when
  /// nothing changed (start, reconnect, settings, command answers).
  Future<void> publish({bool force = false, bool event = false, bool urgent = false}) async {
    if (!_supported || !_started || !_enabled || _clearPending || !_signedIn) return;
    if (!link.value.connected) return;
    if (_publishing) {
      _dirty = true;
      _dirtyEvent = _dirtyEvent || event;
      _dirtyForce = _dirtyForce || force;
      _dirtyUrgent = _dirtyUrgent || urgent;
      return;
    }
    final DateTime now = _clock();
    final DateTime? lastEval = _lastEval;
    if (!force && !event && lastEval != null && now.difference(lastEval) < minInterval) {
      _scheduleAt(lastEval.add(minInterval));
      return;
    }
    _lastEval = now;
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
      final WatchChange change = classifyWatchChange(_lastSent, snap);
      final WatchTier tier = _tierAt(now);
      if (!force) {
        final Duration? wait = _wait(change, tier, now);
        if (wait == null) return; // carried by the keep-alive
        if (wait > Duration.zero) {
          _scheduleAt(now.add(wait));
          return;
        }
      }
      // Re-check right before sending: a sign-out or switch-off while this
      // snapshot was being built must win over the in-flight push.
      if (!_enabled || _clearPending || !_signedIn) return;
      // Urgent only for what the user is waiting for: alerts, command answers, a
      // new sign-in, or the watch app on screen. The rest may be batched by the system.
      final bool isUrgent = urgent || change == WatchChange.urgent || tier != WatchTier.hidden;
      final bool ok = await _transport.publish(encodeWatchSnapshot(snap), urgent: isUrgent);
      if (ok) {
        _lastHash = hash;
        _lastSent = snap;
        _lastPublish = now;
      }
    } catch (_) {
      // A failed publish is retried by the next roster change or keep-alive.
    } finally {
      _publishing = false;
      if (_dirty) {
        _dirty = false;
        final bool ev = _dirtyEvent, f = _dirtyForce, u = _dirtyUrgent;
        _dirtyEvent = _dirtyForce = _dirtyUrgent = false;
        unawaited(publish(event: ev, force: f, urgent: u));
      }
    }
  }

  Duration _keepAliveFor(WatchTier t) => t == WatchTier.visible ? visibleKeepAlive : keepAlive;

  /// One timer for the keep-alive and the link re-check: fires [keepAlive] after
  /// the last snapshot ([visibleKeepAlive] while the watch app is on screen).
  void _armKeepAlive() {
    if (!_started) return;
    _keepAliveTimer?.cancel();
    final DateTime now = _clock();
    final Duration ka = _keepAliveFor(_tierAt(now));
    final DateTime? last = _lastPublish;
    final DateTime due = last != null && last.add(ka).isAfter(now) ? last.add(ka) : now.add(ka);
    _keepAliveTimer = _timer(due.difference(now), () => unawaited(_onKeepAlive()));
  }

  Future<void> _onKeepAlive() async {
    _keepAliveTimer = null;
    try {
      await refreshLink();
      final DateTime now = _clock();
      final DateTime? last = _lastPublish;
      if (last == null || now.difference(last) >= _keepAliveFor(_tierAt(now))) await publish(force: true);
    } finally {
      _armKeepAlive();
    }
  }

  /// `visible` / `hidden` from the watch: only changes the cadence. Never runs
  /// an action and never answers in `lastCommand` (that would be a snapshot per
  /// heartbeat).
  void _onPresence(WatchCommand cmd, DateTime now) {
    final WatchTier before = _tierAt(now);
    if (cmd.cmd == WatchCmd.hidden) {
      _tier = WatchTier.hidden;
      _tierUntil = null;
    } else if (cmd.arg == 'ambient') {
      _tier = WatchTier.ambient;
      _tierUntil = now.add(ambientTtl);
    } else {
      _tier = WatchTier.visible;
      _tierUntil = now.add(visibleTtl);
    }
    _armKeepAlive();
    final DateTime? last = _lastPublish;
    if (_tier == WatchTier.visible && before != WatchTier.visible && (last == null || now.difference(last) >= minInterval)) {
      // The app just came on screen: a fresh snapshot right away.
      unawaited(publish(force: true, urgent: true));
    } else {
      // Changes held back for the slower tier may be due now.
      unawaited(publish(event: true));
    }
  }

  /// Runs a command from the watch. Always ends by publishing a snapshot that
  /// carries the result, so the watch learns whether it worked.
  Future<void> handleCommand(String raw) async {
    final WatchCommand? cmd = WatchCommand.tryParse(raw);
    if (cmd == null || !_enabled) return;
    final DateTime now = _clock();
    final bool presence = cmd.cmd == WatchCmd.visible || cmd.cmd == WatchCmd.hidden;
    // Replay window and one-shot ids.
    if (now.difference(cmd.at).abs() > kWatchCommandWindow) {
      if (!presence) _record(cmd, false, 'The watch clock and the phone clock do not match.');
      return;
    }
    if (_seenCommandIds.contains(cmd.id)) return;
    _seenCommandIds.add(cmd.id);
    if (_seenCommandIds.length > 50) _seenCommandIds.removeAt(0);
    if (presence) {
      if (_started && !_clearPending && _signedIn) _onPresence(cmd, now);
      return;
    }
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
        case WatchCmd.visible:
        case WatchCmd.hidden:
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
    unawaited(_changesSub?.cancel());
  }
}
