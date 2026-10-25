import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/member.dart';
import '../models/place.dart';
import 'alert_service.dart';
import 'api_client.dart';
import 'member_avatar_cache.dart';
import 'member_mapper.dart';
import 'place_service.dart';
import 'server_config.dart';
import 'token_storage.dart';

/// The caller's family summary from `GET /family`.
class FamilyInfo {
  const FamilyInfo({
    required this.name,
    required this.role,
    required this.userId,
  });

  final String name;

  /// The caller's role: "admin", "member", or "child".
  final String role;

  /// The caller's own user id.
  final String userId;
}

/// Fetches the family + members over REST and streams live location and avatar
/// metadata updates over the `/ws/stream` WebSocket.
///
/// Usage:
/// ```dart
/// final service = FamilyService(
///   onMembersChanged: (members) => setState(() => _members = members),
///   onUserId: (id) => setState(() => _userId = id),
/// );
/// final name = await service.fetchFamilyName();
/// final members = await service.fetchMembers();
/// await service.start(); // opens the WebSocket
/// // ... later:
/// service.dispose();
/// ```
///
/// The WebSocket authenticates by carrying the access token as the
/// `Sec-WebSocket-Protocol` subprotocol (never in the URL). On error/close it
/// reconnects with exponential backoff (1s → 2s → 4s … capped at 30s) and
/// re-fetches members so a missed `members` frame is recovered.
///
/// Connection death is not always observable: when a phone loses coverage, the
/// socket usually dies *silently* (half-open; carrier NAT mapping expired and
/// the server's close never arrives), so waiting for `onError`/`onDone` can
/// leave the app listening on a zombie socket forever. Two mechanisms make
/// recovery deterministic:
/// - an app-level `ping` frame sent on a fixed cadence (the server replies
///   `pong`), and
/// - an inbound-activity watchdog: if **no frame of any kind** arrives within
///   the dead-connection window, the socket is torn down and reconnected
///   regardless of what the socket object itself believes.
/// The OS connectivity watcher additionally forces an immediate reconnect on
/// network regain/handoff instead of waiting out the backoff timer.
class FamilyService {
  FamilyService({this.onMembersChanged, this.onUserId});

  /// Fired whenever the member list is replaced or a member is updated.
  void Function(List<Member> members)? onMembersChanged;

  /// Fired once the `welcome` frame identifies the caller's own user id.
  void Function(String userId)? onUserId;

  List<Member> _members = <Member>[];
  List<Place> _places = <Place>[];
  String? _userId;

  /// Cadence of the app-level WebSocket ping and of the inbound-activity
  /// watchdog check. Keep in sync with the server's expectations (the backend
  /// pings every 30s from its own writeLoop; the two heartbeats are
  /// independent and both fine).
  static const Duration _pingInterval = Duration(seconds: 30);

  /// How long the socket may receive **no frame at all** before it is treated
  /// as dead and force-reconnected. Three ping intervals: one lost pong can
  /// still be jitter; three means the path is gone.
  static const Duration _deadConnectionTimeout = Duration(seconds: 90);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _stalenessTimer;

  /// App-level ping timer, created with the socket and torn down with it.
  Timer? _pingTimer;

  /// Inbound-silence watchdog timer, created with the socket.
  Timer? _watchdogTimer;

  /// OS connectivity watcher, owned for the service's lifetime once [start]
  /// has been called.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// When the last frame of ANY kind arrived on the socket. Any inbound frame
  /// (pong, presence, location, snapshot…) proves the path is alive; the
  /// watchdog reconnects when this goes stale.
  DateTime _lastInboundFrameAt = DateTime.now();

  /// Whether [start] has been called. Gates the connectivity watcher: without
  /// a started session (e.g. the initial load failed and the screen is showing
  /// its error card) there is no socket to manage.
  bool _started = false;

  bool _disposed = false;
  int _attempt = 0;

  /// The caller's own user id (from the `welcome` frame), or null until known.
  String? get userId => _userId;

  /// The current member list (live-updated).
  List<Member> get members => List<Member>.unmodifiable(_members);

  /// `GET /family` → the family name.
  Future<String> fetchFamilyName() async {
    final FamilyInfo info = await fetchFamily();
    return info.name;
  }

  /// `GET /family` → the caller's family summary (name, role, user id).
  Future<FamilyInfo> fetchFamily() async {
    final dynamic data = await ApiClient.get('/family');
    final Map<String, dynamic> map = data as Map<String, dynamic>;
    return FamilyInfo(
      name: map['name'] as String? ?? 'Family',
      role: map['role'] as String? ?? 'member',
      userId: map['user_id'] as String? ?? '',
    );
  }

  /// `GET /family/members` → the mapped member list.
  ///
  /// Also populates the internal [_members] list so a `location` frame that
  /// arrives between this fetch and the WebSocket `members` snapshot is not
  /// dropped (it can be matched against the freshly fetched members).
  Future<List<Member>> fetchMembers() async {
    final dynamic data = await ApiClient.get('/family/members');
    final List<dynamic> list = data as List<dynamic>;
    final List<Member> mapped = list
        .map((dynamic e) => memberFromJson(e as Map<String, dynamic>))
        .toList();
    await _refreshPlaces();
    return _replaceMembers(mapped);
  }

  /// Reloads saved places so a member standing still at Home/Work is labeled
  /// with that place instead of a generic "Stationary". Failures keep the
  /// last known list — members still render without place names.
  Future<void> _refreshPlaces() async {
    try {
      _places = await PlaceService.fetchPlaces();
    } catch (_) {
      // Keep whatever we already have.
    }
  }

  /// Opens the WebSocket and begins streaming live updates.
  Future<void> start() async {
    _disposed = false;
    _started = true;
    _attempt = 0;
    _startStalenessTimer();
    _listenForConnectivity();
    await _connect();
  }

  /// Re-fetches members over REST and publishes them via [onMembersChanged].
  ///
  /// Used when the app returns to the foreground: the socket may still be
  /// mid-repair (or the app sat backgrounded for hours), so this bounds how
  /// long the map can show a stale snapshot to one REST round-trip. Refreshes
  /// the access token as a side effect when it has expired, via the API
  /// client's 401 → refresh path. Never throws.
  Future<void> refreshMembers() async {
    if (_disposed) return;
    try {
      await fetchMembers();
      onMembersChanged?.call(_members);
    } catch (_) {
      // Keep the previous snapshot; the reconnect chain and connectivity
      // watcher will retry.
    }
  }

  /// Periodically re-evaluates each member's staleness so a member whose
  /// updates stop (phone off / no signal) transitions to the grey "stopped"
  /// status even though no `location` frame arrives for them.
  void _startStalenessTimer() {
    _stalenessTimer?.cancel();
    _stalenessTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_disposed || _members.isEmpty) return;
      final List<Member> refreshed = _members.map(refreshStaleness).toList();
      var changed = false;
      for (int i = 0; i < _members.length; i++) {
        if (!identical(refreshed[i], _members[i])) {
          changed = true;
          break;
        }
      }
      if (changed) {
        _members = refreshed;
        onMembersChanged?.call(_members);
      }
    });
  }

  Future<void> _connect() async {
    if (_disposed) return;

    String? token;
    try {
      token = await TokenStorage.readAccessToken();
    } catch (_) {
      // Treat a secure-storage failure like a missing token: stay inside the
      // retry chain instead of throwing out of an async callback. A real
      // logout disposes this service, cancelling the retry timer.
      token = null;
    }
    if (token == null) {
      // No usable session yet. Keep the reconnect chain alive so a transient
      // storage hiccup cannot kill the stream for the whole session.
      _scheduleReconnect();
      return;
    }

    // Drop any previous socket first so repeated starts/reconnects never leak
    // a half-open channel (this also makes reconnect-after-connect safe when
    // the connectivity watcher races a scheduled reconnect).
    _teardownSocket();

    final WebSocketChannel channel =
        WebSocketChannel.connect(_wsUri(), protocols: <String>[token]);
    _channel = channel;
    _lastInboundFrameAt = DateTime.now();
    _subscription = channel.stream.listen(
      _onFrame,
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );

    // Heartbeat: a socket can die with no error event and no failed write
    // (half-open after losing coverage — the client used to send nothing and
    // protocol-level pings are consumed below the stream API). Generate
    // traffic so the server sees liveness, and monitor inbound silence so the
    // client detects a dead path even when every write "succeeds" into the
    // void (TCP send buffers swallow writes to a black hole).
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPing());
    _watchdogTimer = Timer.periodic(_pingInterval, (_) => _checkLiveness());
  }

  /// Sends one app-level ping frame. The backend's read loop replies `pong`
  /// through its single-writer send channel. A thrown write means the socket
  /// is dead; reconnect immediately rather than waiting for the watchdog.
  void _sendPing() {
    final WebSocketChannel? channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(<String, String>{'type': 'ping'}));
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// Force-reconnects if no frame of any kind arrived inside the
  /// dead-connection window. This is the detector for silently dead sockets:
  /// neither `onError` nor `onDone` ever fires for them, so inbound silence is
  /// the only reliable signal.
  void _checkLiveness() {
    if (DateTime.now().difference(_lastInboundFrameAt) >
        _deadConnectionTimeout) {
      _scheduleReconnect();
    }
  }

  /// Cancels the socket's timers and subscription and closes the channel, so
  /// reconnects/start cycles can never leak a half-open socket.
  void _teardownSocket() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _subscription?.cancel();
    _subscription = null;
    final WebSocketChannel? channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        channel.sink.close();
      } catch (_) {
        // The sink may already be dead; nothing to recover.
      }
    }
  }

  void _onFrame(dynamic raw) {
    // Any frame — even a malformed or unknown one — proves the connection
    // path is alive, so reset the watchdog before parsing.
    _lastInboundFrameAt = DateTime.now();
    if (raw is! String) return;
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return; // Ignore malformed frames.
    }

    switch (map['type']) {
      case 'welcome':
        final String? id = map['user_id'] as String?;
        if (id != null) {
          _userId = id;
          AlertEvents.selfUserId = id;
          onUserId?.call(id);
        }
        break;
      case 'members':
        final List<dynamic> list =
            (map['members'] as List<dynamic>?) ?? const [];
        final List<Member> mapped = list
            .map((dynamic e) => memberFromJson(e as Map<String, dynamic>))
            .toList();
        _replaceMembers(mapped);
        _attempt = 0; // Successful connection — reset reconnect backoff.
        onMembersChanged?.call(_members);
        break;
      case 'location':
        _applyLocation(map);
        break;
      case 'presence':
        _applyPresence(map);
        break;
      case 'avatar':
        _applyAvatar(map);
        break;
      case 'alert':
      case 'alert_ack':
        AlertEvents.handleFrame(map);
        break;
    }
  }

  void _applyLocation(Map<String, dynamic> map) {
    final String? id = map['user_id'] as String?;
    if (id == null) return;
    final int index = _members.indexWhere((Member m) => m.id == id);
    if (index < 0) return;
    _members[index] = applyPlaceAddress(
      memberFromLocationUpdate(_members[index], map),
      _places,
    );
    onMembersChanged?.call(_members);
  }

  /// Applies a `presence` liveness frame (no position change): refreshes the
  /// member's "last seen" so a stationary but reporting member does not flip
  /// to grey "stopped".
  void _applyPresence(Map<String, dynamic> map) {
    final String? id = map['user_id'] as String?;
    if (id == null) return;
    final int index = _members.indexWhere((Member m) => m.id == id);
    if (index < 0) return;
    final Member updated = applyPlaceAddress(
      memberFromPresenceUpdate(_members[index], map),
      _places,
    );
    if (identical(updated, _members[index])) return;
    _members[index] = updated;
    onMembersChanged?.call(_members);
  }

  /// Applies an `avatar` metadata frame and clears the old private image bytes
  /// so visible avatar widgets fetch the replacement immediately.
  void _applyAvatar(Map<String, dynamic> map) {
    final String? id = map['user_id'] as String?;
    if (id == null) return;
    final int index = _members.indexWhere((Member m) => m.id == id);
    if (index < 0) return;

    final Member updated = memberFromAvatarUpdate(_members[index], map);
    if (identical(updated, _members[index])) return;

    MemberAvatarCache.instance.invalidate(id);
    _members[index] = updated;
    onMembersChanged?.call(_members);
  }

  /// Replaces the member snapshot while releasing private image bytes for
  /// changed or removed avatar metadata.
  ///
  /// A REST response or `members` WebSocket snapshot can arrive after a newer
  /// avatar frame. Preserve the highest known durable revision in that case so
  /// an older snapshot never makes a fresh photo disappear or reappear.
  List<Member> _replaceMembers(List<Member> incoming) {
    final Map<String, Member> previousById = <String, Member>{
      for (final Member member in _members) member.id: member,
    };
    final Set<String> incomingIds = incoming
        .map((Member member) => member.id)
        .where((String id) => id.isNotEmpty)
        .toSet();

    for (final Member previous in _members) {
      if (previous.id.isNotEmpty && !incomingIds.contains(previous.id)) {
        MemberAvatarCache.instance.invalidate(previous.id);
      }
    }

    final List<Member> reconciled = incoming.map((Member candidate) {
      final Member? previous = previousById[candidate.id];
      if (previous == null) return candidate;

      // The version changes atomically with every avatar upload/removal. A
      // snapshot at the same or a lower revision cannot authoritatively change
      // avatar metadata, so retain the newest metadata already observed.
      final Member next = candidate.avatarVersion <= previous.avatarVersion
          ? candidate.copyWithAvatar(
              hasAvatar: previous.hasAvatar,
              avatarUpdatedAt: previous.avatarUpdatedAt,
              avatarVersion: previous.avatarVersion,
            )
          : candidate;

      if (_avatarMetadataChanged(previous, next) && previous.id.isNotEmpty) {
        MemberAvatarCache.instance.invalidate(previous.id);
      }
      return next;
    }).toList();

    _members = reconciled
        .map((Member m) => applyPlaceAddress(m, _places))
        .toList();
    return _members;
  }

  bool _avatarMetadataChanged(Member before, Member after) {
    return before.hasAvatar != after.hasAvatar ||
        before.avatarVersion != after.avatarVersion ||
        before.avatarUpdatedAt != after.avatarUpdatedAt;
  }

  /// Schedules a reconnect with exponential backoff, re-fetching members first
  /// so any missed `members` frame is recovered.
  void _scheduleReconnect() {
    if (_disposed) return;
    // Tear down whatever socket state we have (including the heartbeat and
    // watchdog timers) so the retry always begins from a clean slate.
    _teardownSocket();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_backoff(), () async {
      if (_disposed) return;
      try {
        await fetchMembers();
        onMembersChanged?.call(_members);
      } catch (_) {
        // Keep the previous members; the next reconnect will retry the fetch.
      }
      await _connect();
    });
  }

  /// 1s → 2s → 4s → 8s → 16s → 30s (capped).
  Duration _backoff() {
    final int exp = _attempt < 5 ? _attempt : 5;
    _attempt++;
    final int seconds = math.min(1 << exp, 30);
    return Duration(seconds: seconds);
  }

  /// Derives the WebSocket URL from the configured API base URL by swapping
  /// the scheme (https→wss, http→ws) and appending `/ws/stream`.
  Uri _wsUri() {
    final Uri base = Uri.parse(ServerConfig.instance.apiBaseUrl);
    final String scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(scheme: scheme, path: '/ws/stream');
  }

  /// Subscribes to OS connectivity changes for the service's lifetime
  /// (idempotent). Events only matter once [start] has created a session.
  void _listenForConnectivity() {
    _connectivitySub ??=
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
  }

  /// Reconnects immediately when the OS reports a working network. This is the
  /// fast-recovery trigger: without it, a regained connection can sit idle
  /// while the backoff timer holds a reconnect up to 30s in the future — and
  /// silently-dead zombie sockets (the hiking case) produce no event at all,
  /// which is what the ping/watchdog pair above is for.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_disposed || !_started) return;
    final bool connected = results
        .any((ConnectivityResult result) => result != ConnectivityResult.none);
    if (!connected) {
      // Losing the radio: there is nothing useful to do until a network
      // exists; the watchdog tears the dead socket down on its own schedule.
      return;
    }
    // Network regained (or a Wi-Fi ⇄ cellular handoff): a fresh connection
    // revalidates DNS, routing, and NAT mappings immediately. idempotent —
    // teardown runs before every connect.
    _forceReconnect();
  }

  /// Tears down the current socket (if any) and reconnects immediately with
  /// the backoff reset. Callers: the connectivity watcher.
  void _forceReconnect() {
    if (_disposed) return;
    _attempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardownSocket();
    unawaited(_connect());
  }

  /// Closes the WebSocket and cancels any pending reconnect + staleness timer.
  void dispose() {
    _disposed = true;
    _started = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
    _teardownSocket();
    MemberAvatarCache.instance.clear();
  }
}
