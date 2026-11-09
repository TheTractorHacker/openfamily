import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/circle.dart';
import '../api_client.dart';
import '../processing/fix.dart';
import '../processing/on_device_processor.dart';
import '../processing/processing_source.dart';
import '../direct_push_service.dart' show LocalDirectPushNotifier;
import '../push_service.dart';
import '../driving/driving_settings.dart';
import 'e2ee_api.dart';
import 'e2ee_app.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'e2ee_service.dart';
import 'e2ee_trust.dart';
import 'e2ee_vault.dart';
import 'item_open_job.dart';
import 'lanes_service.dart';
import 'lanes_wire.dart';
import 'lanes_store.dart';
import 'private_channel.dart';
import 'private_store.dart';
import 'private_history.dart';
import 'last_positions.dart';
import '../processing/on_device_setting.dart';
import 'private_places.dart';
import '../chat/chat_engine.dart';
import '../chat/chat_store.dart';
import '../chat_service.dart' show ChatEvents;
import '../notification_prefs_service.dart' show NotificationNames;
import '../perf/perf_profile.dart';

/// SharedPreferences-backed [ChannelKv]. The queue, cursors, sequence numbers,
/// dedupe windows and the on-device history live here. Everything stored is
/// either ciphertext (the queue) or data the user already sees on screen.
class PrefsChannelKv implements ChannelKv {
  const PrefsChannelKv();
  static const String _p = 'e2ee_chan_';
  static DateTime? _reloadedAt;

  /// iOS: the sensitive stores are files in one directory excluded from backups ([PrivateStore]); elsewhere null.
  Future<ChannelKv?> _files() => PrivateStore.files();

  @override
  Future<String?> get(String key) async {
    final ChannelKv? f = await _files();
    if (f != null) return f.get(key);
    final SharedPreferences p = await SharedPreferences.getInstance();
    // The background isolate writes the same file: re-read, at most every 2 s.
    final DateTime now = DateTime.now();
    if (_reloadedAt == null || now.difference(_reloadedAt!) > const Duration(seconds: 2)) {
      _reloadedAt = now;
      await p.reload();
    }
    return p.getString('$_p$key');
  }

  @override
  Future<String?> getFresh(String key) async {
    final ChannelKv? f = await _files();
    if (f != null) return f.getFresh(key);
    // Lane facts and the queue: always re-read the file, the other isolate may have written it.
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.reload();
    _reloadedAt = DateTime.now();
    return p.getString('$_p$key');
  }

  @override
  Future<void> set(String key, String value) async {
    final ChannelKv? f = await _files();
    if (f != null) return f.set(key, value);
    await (await SharedPreferences.getInstance()).setString('$_p$key', value);
  }

  @override
  Future<void> remove(String key) async {
    final ChannelKv? f = await _files();
    if (f != null) return f.remove(key);
    await (await SharedPreferences.getInstance()).remove('$_p$key');
  }
}

/// [ChannelKeys] and [ServerKeys] over the vault.
///
/// A vault read is a Keystore decrypt behind a platform channel (and `heldEpochs` lists, i.e. decrypts, every vault
/// entry), so the keys are remembered in memory for [ttl]. A key of a given (circle, epoch) never changes once stored;
/// the "newest epoch" answers can, so they live for [latestTtl] only and [invalidate] drops them when keys were synced.
/// Only found keys are remembered (a missing key is asked for again).
class ServiceChannelKeys implements ChannelKeys, ServerKeys {
  ServiceChannelKeys(this.service, {this.ttl = const Duration(minutes: 10), this.latestTtl = const Duration(seconds: 15), DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final E2eeService service;
  final Duration ttl, latestTtl;
  final DateTime Function() _now;
  final Map<String, ({DateTime at, Uint8List key})> _keys = <String, ({DateTime at, Uint8List key})>{};
  final Map<String, ({DateTime at, int v})> _latest = <String, ({DateTime at, int v})>{};

  /// Forget cached newest-epoch answers (and keys) of [circleId], or everything.
  void invalidate([String? circleId]) {
    if (circleId == null) {
      _keys.clear();
      _latest.clear();
      return;
    }
    _keys.removeWhere((String k, _) => k.contains('/$circleId/'));
    _latest.removeWhere((String k, _) => k.endsWith('/$circleId'));
  }

  int _seenTick = TickVault.tick;

  /// Anything written to or removed from the vault since the last call (a new epoch, a rotation, a wipe) drops what is remembered.
  void _checkTick() {
    if (_seenTick == TickVault.tick) return;
    _seenTick = TickVault.tick;
    _keys.clear();
    _latest.clear();
  }

  Future<Uint8List?> _cached(String name, Future<Uint8List?> Function() load) async {
    _checkTick();
    final ({DateTime at, Uint8List key})? c = _keys[name];
    if (c != null && _now().difference(c.at) < ttl) return c.key;
    final int t = TickVault.tick;
    final Uint8List? k = await load();
    if (k != null && t == TickVault.tick) _keys[name] = (at: _now(), key: k);
    return k;
  }

  Future<int> _latestOf(String name, Future<int> Function() load) async {
    _checkTick();
    final ({DateTime at, int v})? c = _latest[name];
    if (c != null && c.v > 0 && _now().difference(c.at) < latestTtl) return c.v;
    final int t = TickVault.tick;
    final int v = await load();
    if (t == TickVault.tick) _latest[name] = (at: _now(), v: v);
    return v;
  }

  @override
  Future<Uint8List?> circleKey(String circleId, int epoch) => _cached('ck/$circleId/$epoch', () => service.circleKey(circleId, epoch));

  @override
  Future<int> latestEpoch(String circleId) => _latestOf('ck/$circleId', () async {
        final List<int> e = await service.heldEpochs(circleId);
        return e.isEmpty ? 0 : e.last;
      });

  @override
  Future<Uint8List?> serverKey(String circleId, int gen) => _cached('sk/$circleId/$gen', () => service.serverKey(circleId, gen));

  @override
  Future<int> latestServerGen(String circleId) => _latestOf('sk/$circleId', () => service.latestServerGen(circleId));
}

/// [SenderDirectory] over the circle's E2EE state (members, their devices and
/// the approval flags the server computed; the key log protects the keys).
class StateSenderDirectory implements SenderDirectory {
  StateSenderDirectory(this.api, {this.ttl = const Duration(minutes: 5), DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final E2eeApi api;
  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ({DateTime at, Map<String, DeviceKey> devices})> _cache = <String, ({DateTime at, Map<String, DeviceKey> devices})>{};

  @override
  Future<DeviceKey?> sender(String circleId, String deviceId, {bool refresh = false}) async {
    final ({DateTime at, Map<String, DeviceKey> devices})? c = _cache[circleId];
    if (c != null && !refresh && _now().difference(c.at) < ttl && c.devices.containsKey(deviceId)) {
      return c.devices[deviceId];
    }
    if (c != null && refresh && _now().difference(c.at) < const Duration(seconds: 20)) {
      return c.devices[deviceId]; // do not hammer the server with refreshes
    }
    final CircleE2eeState st = await api.circleState(circleId);
    final Map<String, DeviceKey> m = <String, DeviceKey>{};
    for (final CircleE2eeMember member in st.members) {
      for (final DeviceKey d in member.devices) {
        m[d.deviceId] = d;
      }
    }
    _cache[circleId] = (at: _now(), devices: m);
    return m[deviceId];
  }

  void invalidate(String circleId) => _cache.remove(circleId);
}

/// [ChannelApi] over [ApiClient].
class HttpChannelApi implements ChannelApi {
  const HttpChannelApi();

  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> items) async {
    try {
      final dynamic r = await ApiClient.post('/circles/$circleId/e2ee/batch', body: <String, dynamic>{
        'sender_device_id': deviceId,
        'items': items.map((WireItem i) => i.toUpload()).toList(),
      });
      final List<dynamic> list = ((r as Map<String, dynamic>)['results'] as List<dynamic>?) ?? <dynamic>[];
      return list
          .cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => BatchResult((m['seq'] as num).toInt(), (m['status'] as String?) ?? 'rejected', error: m['error'] as String?))
          .toList();
    } on ApiException catch (e) {
      // 0 = no connection, 401 = the session is being renewed, 408/429 = slow down: keep the items and try
      // again later (this must not count against the batch). 5xx also retries. Other 4xx can never succeed.
      if (e.status == 0 || e.status == 401 || e.status == 408 || e.status == 429) throw UploadUnavailable('${e.status}');
      if (e.status >= 500) rethrow;
      throw PermanentUploadError('${e.status}');
    }
  }

  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) async {
    final dynamic r = await ApiClient.get('/circles/$circleId/e2ee/items', query: <String, String>{
      'after': '$after',
      'limit': '$limit',
      LanesFields.keyLine: 'all', // absent = phone line only on the server
      if (purposes != null && purposes.isNotEmpty) 'purpose': purposes.join(','),
    });
    final Map<String, dynamic> m = r as Map<String, dynamic>;
    final List<WireItem> items = ((m['items'] as List<dynamic>?) ?? <dynamic>[])
        .cast<Map<String, dynamic>>()
        .map(WireItem.fromServer)
        .whereType<WireItem>()
        .toList();
    return Page(items, (m['next_cursor'] as num?)?.toInt() ?? after, m['has_more'] == true);
  }
}

/// [ChannelApi] for the headless background isolate: authenticates with the
/// per-device ingest key (the session token is not reachable there) and only
/// uploads. Pulling needs the session and happens in the foreground.
class IngestKeyChannelApi implements ChannelApi {
  const IngestKeyChannelApi(this.apiBaseUrl, this.headers);
  final String apiBaseUrl;
  final Map<String, String> headers;

  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> items) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('$apiBaseUrl/circles/$circleId/e2ee/batch'),
              headers: headers,
              body: jsonEncode(<String, dynamic>{
                'sender_device_id': deviceId,
                'items': items.map((WireItem i) => i.toUpload()).toList(),
              }))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      // No connection / timeout in the background: not the batch's fault.
      throw UploadUnavailable('$e');
    }
    if (r.statusCode >= 200 && r.statusCode < 300) {
      final List<dynamic> list = ((jsonDecode(r.body) as Map<String, dynamic>)['results'] as List<dynamic>?) ?? <dynamic>[];
      return list
          .cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => BatchResult((m['seq'] as num).toInt(), (m['status'] as String?) ?? 'rejected'))
          .toList();
    }
    if (r.statusCode == 401 || r.statusCode == 408 || r.statusCode == 429) throw UploadUnavailable('${r.statusCode}');
    if (r.statusCode >= 500) throw StateError('retry ${r.statusCode}');
    throw PermanentUploadError('${r.statusCode}');
  }

  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) =>
      throw UnsupportedError('pulling needs the foreground session');
}

class _OfflineE2eeApi implements E2eeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('no session in the background isolate');
}

class _NoDirectory implements SenderDirectory {
  @override
  Future<DeviceKey?> sender(String circleId, String deviceId, {bool refresh = false}) async => null;
}

/// This phone's own view of its delivery for one Private circle.
class LocalDelivery {
  const LocalDelivery({
    required this.hasKey,
    required this.heldEpoch,
    required this.queued,
    required this.parked,
    required this.lastSealedAt,
    required this.lastPulledCursor,
    required this.undelivered,
    required this.undeliveredCode,
    this.sealProblem = '',
  });
  final bool hasKey;

  /// Why the last fix could not be encrypted on this phone ('' = it was).
  final String sealProblem;
  final int heldEpoch;

  /// Sealed updates waiting for the network.
  final int queued;

  /// Positions waiting for the circle key.
  final int parked;
  final DateTime? lastSealedAt;
  final int lastPulledCursor;

  /// Updates the relay refused for good, and the reason code.
  final int undelivered;
  final String undeliveredCode;
}

/// How a fix must be delivered, decided from the user's circles.
enum UplinkMode {
  /// No private circle: exactly the pre-E2EE behaviour.
  plaintextOnly,

  /// Both kinds: plaintext only feeds the standard circles (the server never
  /// shows it to a private one); sealed copies go to each private circle.
  both,

  /// Every circle is private: nothing plaintext may be sent (the server refuses it).
  sealedOnly,
}

/// Decides the uplink from circle modes. Pure; this is the multi-circle rule of
/// docs/design/E2EE.md. [privateCircleIds] are the circles in private mode,
/// [allCircleIds] every circle the user is in.
UplinkMode uplinkModeFor(Set<String> privateCircleIds, Set<String> allCircleIds) {
  if (privateCircleIds.isEmpty) return UplinkMode.plaintextOnly;
  return allCircleIds.every(privateCircleIds.contains) ? UplinkMode.sealedOnly : UplinkMode.both;
}

/// Notification shown for a decrypted arrival/departure.
String placeEventText(String who, String place, bool entered) =>
    entered ? '$who arrived at $place' : '$who left $place';

/// The Private-circle engine of the app: seals and uploads this phone's fixes,
/// evaluates places on the phone, receives and verifies other members' items and
/// feeds the existing map models. One instance per process (the background
/// isolate has its own and shares only the preferences).
class PrivateRuntime {
  PrivateRuntime({
    required this.service,
    required this.api,
    required this.kv,
    this.clock = const Clock(),
    SenderDirectory? directory,
    ChannelApi? channel,
    Random? rng,
    this.opener = const InlineOpenRunner(),
    Duration? historyWriteBehind = const Duration(seconds: 4),
    int? maxHistoryPoints,
    int? catchUpPageSize,
  })  : channel = channel ?? const HttpChannelApi(),
        _rng = rng ?? Random.secure() {
    final ServiceChannelKeys ck = ServiceChannelKeys(service);
    keys = ck;
    _keyCache = ck;
    lanes = KvLaneSource(kv);
    this.directory = directory ?? StateSenderDirectory(api);
    sealer = ChannelSealer(keys: keys, kv: kv, clock: clock, lanes: lanes, serverKeys: ck);
    queue = SealedQueue(kv: kv, clock: clock);
    receiver = ChannelReceiver(keys: keys, directory: this.directory, kv: kv, clock: clock, serverKeys: ck, lanes: lanes, runner: opener);
    lanesService = LanesService(service: service, api: api, kv: kv, clock: clock, onLaneChanged: (String c) async {
      await queue.reconcileLanes(lanes);
    });
    results = ResultStore(kv);
    chatStore = ChatStore(kv: kv, now: clock.now);
    chat = ChatEngine(store: chatStore, directory: StateChatDirectory(api), now: clock.now)
      ..notify = (String t, String b) {
        return chatNotify(t, b);
      }
      ..isViewing = (String c) {
        return ChatEvents.viewingCircleId == c;
      }
      // Same "Show names in notifications" rule as the server's chat pushes.
      ..showNames = NotificationNames.load
      ..circleName = circleName
      ..onChange = ChatEvents.handleEngineChange;
    sync = ChannelSync(api: this.channel, receiver: receiver, kv: kv, pageLimit: catchUpPageSize ?? PerfProfile.current.catchUpPageSize);
    history = PrivateHistory(
        kv: kv, now: clock.now, writeBehind: historyWriteBehind, maxPointsPerMember: maxHistoryPoints ?? PerfProfile.current.maxHistoryPoints);
    lastPositions = LastPositionBook(vault: service.vault);
    chunker = HistoryChunker(kv: kv, now: clock.now);
  }

  /// A runtime for the headless background isolate: keys come from the vault,
  /// uploads use the ingest key, nothing needs the app session. If the vault is
  /// unreachable from that isolate, fixes are parked and sealed by the
  /// foreground runtime later (never sent in plaintext).
  factory PrivateRuntime.background({required String apiBaseUrl, required Map<String, String> headers}) {
    late final E2eeService svc;
    svc = E2eeService(
      api: _OfflineE2eeApi(),
      vault: SecureVault(),
      trust: TrustStore(PrefsTrustKv()),
      userIdProvider: () => svc.storedUserId(),
    );
    return PrivateRuntime(
      service: svc,
      api: _OfflineE2eeApi(),
      kv: const PrefsChannelKv(),
      channel: IngestKeyChannelApi(apiBaseUrl, headers),
      directory: _NoDirectory(),
      historyWriteBehind: null, // the headless isolate may be killed at any moment: write at once
    );
  }

  static PrivateRuntime? override;
  static PrivateRuntime? _instance;

  /// The runtime if one was already created (never creates one).
  static PrivateRuntime? get existing => override ?? _instance;
  static PrivateRuntime get instance => override ??
      (_instance ??= PrivateRuntime(
          service: E2eeApp.service, api: const ApiE2eeApi(), kv: const PrefsChannelKv(), opener: WorkerOpenRunner()));

  final E2eeService service;
  final E2eeApi api;
  final ChannelKv kv;
  final Clock clock;
  final ChannelApi channel;
  final Random _rng;
  late final ChannelKeys keys;
  late final ServiceChannelKeys _keyCache;

  /// Where the heavy crypto of received items runs (a worker isolate in the app, the calling isolate in tests).
  final OpenRunner opener;

  /// Forgets remembered keys (sign-out, account switch).
  void forgetKeys() => _keyCache.invalidate();

  /// Verified lane facts for the sealer, the queue and the receiver (persisted).
  late final KvLaneSource lanes;

  /// Verifies and changes lanes (policy, own pref, SK custody). Needs the session.
  late final LanesService lanesService;

  /// Result items (`trip`, `drive`, `week`) received from other members' phones.
  late final ResultStore results;

  /// Local encrypted-chat history and the engine that applies `chat` items.
  late final ChatStore chatStore;
  late final ChatEngine chat;
  late final SenderDirectory directory;
  late final ChannelSealer sealer;
  late final SealedQueue queue;
  late final ChannelReceiver receiver;
  late final ChannelSync sync;
  late final PrivateHistory history;

  /// The newest received position per member and circle, encrypted at rest in the vault.
  late final LastPositionBook lastPositions;
  late final HistoryChunker chunker;

  final Map<String, PlaceBook> _books = <String, PlaceBook>{};
  final Map<String, PlaceEvaluator> _evals = <String, PlaceEvaluator>{};
  Set<String> _private = <String>{};
  Set<String> _all = <String>{};

  /// Called with a synthetic `location` frame for each decrypted member fix, so
  /// the existing map pipeline needs no new model.
  void Function(Map<String, dynamic> frame)? onMemberFrame;

  /// Called when the circle's places changed (sealed place item received).
  void Function(String circleId)? onPlacesChanged;

  /// Resolves a user id to a display name for local notifications.
  String Function(String userId)? nameOf;

  /// Shows a local notification (injectable for tests).
  Future<void> Function(String title, String body) notify = PushService.showForeground;

  /// Shows an encrypted-chat notification (injectable for tests). Unlike
  /// [notify] it also works with the app in the background and from the
  /// background isolate: for encrypted chat the server sends only a
  /// content-free wake-up, so this phone is the only one that can show the
  /// message, and [PushService.showForeground] drops anything while the app
  /// is not on screen. The text follows "Show names in notifications".
  Future<void> Function(String title, String body) chatNotify = _showChatNotification;

  // ---------------------------------------------------------------- circles

  static const String _modeKey = 'modes/v1';

  /// True while the primary circle (the one the server-side screens such as
  /// trips and the weekly summary work on) is Private. Screens that need the
  /// server to read positions show "not available" while this is set.
  static final ValueNotifier<bool> primaryPrivate = ValueNotifier<bool>(false);

  String? _primary;

  /// Private circles an approved, consented Orbitly server can read. Server-side
  /// screens (trips, weekly summary, admin map) work for them again. Place alerts
  /// stay on the phones' sealed places (the single source of truth for arrivals);
  /// the server only geofences places that exist as server places.
  Set<String> _serverMember = <String>{};

  /// Circles this account administers (from the last [setCircles] in this isolate).
  Set<String> _adminOf = <String>{};
  final Map<String, String> _names = <String, String>{};

  /// Updates the known circle modes and persists them for the background isolate.
  Future<void> setCircles(List<Circle> circles) async {
    await _loadModes();
    final Set<String> before = Set<String>.of(_private);
    _all = circles.map((Circle c) => c.id).toSet();
    _private = circles.where((Circle c) => c.isPrivate).map((Circle c) => c.id).toSet();
    _serverMember = circles.where((Circle c) => c.isPrivate && c.e2eeServerMember).map((Circle c) => c.id).toSet();
    _adminOf = circles.where((Circle c) => c.role == 'admin').map((Circle c) => c.id).toSet();
    _names
      ..clear()
      ..addEntries(circles.map((Circle c) => MapEntry<String, String>(c.id, c.name)));
    final Iterable<Circle> prim = circles.where((Circle c) => c.isPrimary);
    _primary = prim.isEmpty ? null : prim.first.id;
    primaryPrivate.value = _primary != null && _private.contains(_primary) && !_serverMember.contains(_primary);
    final String enc = jsonEncode(<String, dynamic>{
      'all': _all.toList(), 'private': _private.toList(), 'server_member': _serverMember.toList(), 'primary': _primary, 'names': _names,
    });
    _modesRaw = enc;
    await kv.set(_modeKey, enc);
    _newlyPrivate = _private.difference(before);
  }

  /// Circles that turned Private in the last [setCircles] call (so the first view is not empty:
  /// [onAppActive] sends a fix for them right away).
  Set<String> _newlyPrivate = <String>{};

  String? _modesRaw;

  /// Reads the circle modes the foreground persisted. It re-reads every time (the kv
  /// caches for a couple of seconds at most): the background isolate lives for days, and a
  /// circle that turned Private after its first fix must not leave it sending plaintext
  /// (which the server refuses) while it believes nothing is private.
  Future<void> _loadModes() async {
    final String? raw = await kv.get(_modeKey);
    if (raw == null || raw == _modesRaw) return;
    _modesRaw = raw;
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      _all = ((m['all'] as List<dynamic>?) ?? <dynamic>[]).cast<String>().toSet();
      _private = ((m['private'] as List<dynamic>?) ?? <dynamic>[]).cast<String>().toSet();
      _primary = m['primary'] as String?;
      _serverMember = ((m['server_member'] as List<dynamic>?) ?? <dynamic>[]).cast<String>().toSet();
      final Object? n = m['names'];
      if (n is Map<String, dynamic>) {
        _names
          ..clear()
          ..addAll(n.map((String k, dynamic v) => MapEntry<String, String>(k, '$v')));
      }
      primaryPrivate.value = _primary != null && _private.contains(_primary) && !_serverMember.contains(_primary);
    } catch (_) {}
  }

  Future<UplinkMode> uplinkMode() async {
    await _loadModes();
    return uplinkModeFor(_private, _all);
  }

  Future<Set<String>> privateCircles() async {
    await _loadModes();
    return Set<String>.of(_private);
  }

  // ------------------------------------------------------------------ send

  Future<SenderIdentity?> _me() async {
    final LocalIdentity? id = await service.identity();
    return id == null ? null : SenderIdentity(id.deviceId, id.edSeed, id.userId);
  }

  static Map<String, dynamic> fixBodyFromLocation(Map<String, dynamic> loc) => <String, dynamic>{
        'lat': loc['lat'],
        'lon': loc['lon'],
        if (loc['accuracy_meters'] != null) 'acc': loc['accuracy_meters'],
        if (loc['altitude_meters'] != null) 'alt': loc['altitude_meters'],
        if (loc['speed_mps'] != null) 'spd': loc['speed_mps'],
        if (loc['heading_deg'] != null) 'hdg': loc['heading_deg'],
        if (loc['battery_pct'] != null) 'bat': loc['battery_pct'],
        // Optional since 0.26.14; older receivers ignore unknown keys.
        if (loc['charging'] is bool) 'chg': loc['charging'],
        if (loc['motion_state'] != null && loc['motion_state'] != '') 'mo': loc['motion_state'],
      };

  /// Routes one location report (the body `POST /locations` would carry).
  /// Returns whether the caller must STILL send the plaintext report (only for
  /// standard circles). Sealing failure for a private circle never falls back to
  /// plaintext: the item is simply not sent for that circle.
  DateTime? _lastRemembered;

  Future<bool> routeFix(Map<String, dynamic> locationBody) async {
    // Remember the newest fix (at most every 30 s) even while no circle is private: the day a circle turns Private
    // this is what lets the first view be non-empty.
    final DateTime nowT = clock.now();
    if (_lastRemembered == null || nowT.difference(_lastRemembered!) >= const Duration(seconds: 30)) {
      _lastRemembered = nowT;
      await _rememberLastFix(locationBody, DateTime.tryParse((locationBody['ts'] as String?) ?? '')?.toUtc() ?? nowT);
    }
    final UplinkMode mode = await uplinkMode();
    if (mode == UplinkMode.plaintextOnly) return true;
    _queueSeal(locationBody);
    return mode == UplinkMode.both;
  }

  /// Fixes waiting for the seal worker, oldest first.
  final List<Map<String, dynamic>> _sealWaiting = <Map<String, dynamic>>[];
  bool _sealRunning = false;

  /// At most this many fixes wait to be sealed. While driving the background service hands over one fix per second;
  /// every seal is several store round trips (on Android each a platform-channel call, a fresh read a reload of the
  /// whole preferences file). They used to be started all at once, unawaited: on a phone slower than 1 Hz the
  /// unfinished seals could pile up without bound, with the queue lock and the upload waiting behind all of them,
  /// so the dot on the others' maps would fall further behind for the whole drive. Now one seal runs at a time and, when this limit
  /// is reached, the OLDEST waiting fix is skipped (a 1 Hz track loses a point; the newest position is never late
  /// by more than this many seals).
  static const int maxSealWaiting = 10;

  /// Fixes skipped by the limit above since this runtime started (diagnostics).
  int sealSkipped = 0;

  /// Fixes waiting to be sealed right now (diagnostics, tests).
  int get sealWaiting => _sealWaiting.length + (_sealRunning ? 1 : 0);

  void _queueSeal(Map<String, dynamic> loc) {
    _sealWaiting.add(loc);
    while (_sealWaiting.length > maxSealWaiting) {
      _sealWaiting.removeAt(0);
      sealSkipped++;
    }
    if (_sealRunning) return;
    _sealRunning = true;
    unawaited(_runSeals());
  }

  Future<void> _runSeals() async {
    try {
      while (_sealWaiting.isNotEmpty) {
        await _sealFix(_sealWaiting.removeAt(0)); // never throws
      }
    } finally {
      _sealRunning = false;
    }
  }

  static const String _parkedKey = 'parked/v1';

  /// Fixes that could not be sealed right now (vault unreachable from the
  /// background isolate, key not here yet). They stay in app-private storage like
  /// the pre-existing location outbox, and are sealed with their ORIGINAL
  /// timestamp when the app next runs. They are never sent in plaintext.
  Future<void> _park(Map<String, dynamic> loc, {List<String>? circles}) async {
    try {
      final String? raw = await kv.get(_parkedKey);
      final List<dynamic> l = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
      l.add(<String, dynamic>{
        'ts': loc['ts'], 'lat': loc['lat'], 'lon': loc['lon'], 'accuracy_meters': loc['accuracy_meters'],
        'altitude_meters': loc['altitude_meters'], 'speed_mps': loc['speed_mps'], 'heading_deg': loc['heading_deg'],
        'battery_pct': loc['battery_pct'], 'charging': loc['charging'], 'motion_state': loc['motion_state'],
        if (circles != null) 'for': circles,
      });
      final int cut = clock.now().subtract(const Duration(hours: 12)).millisecondsSinceEpoch;
      final List<dynamic> kept = l.where((dynamic e) {
        final DateTime? t = DateTime.tryParse(((e as Map<String, dynamic>)['ts'] as String?) ?? '');
        return t != null && t.millisecondsSinceEpoch >= cut;
      }).toList();
      await kv.set(_parkedKey, jsonEncode(kept.length > 720 ? kept.sublist(kept.length - 720) : kept));
    } catch (_) {}
  }

  bool _drainingParked = false;

  /// Seals parked fixes (oldest first). Returns how many were handled.
  ///
  /// One drain at a time: a fix that cannot be sealed again is parked again, and its "go and get the key" step
  /// ([_keysThenDrain]) used to start another drain from inside this one, over and over, while the phone already
  /// held a key. A call while a drain runs returns 0 at once.
  Future<int> drainParked() async {
    if (_drainingParked) return 0;
    _drainingParked = true;
    try {
      final String? raw = await kv.getFresh(_parkedKey);
      if (raw == null || raw.isEmpty) return 0;
      await kv.remove(_parkedKey);
      int n = 0;
      List<dynamic> entries;
      try {
        entries = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        return 0;
      }
      for (final dynamic e in entries) {
        // One bad entry must not lose the ones behind it (the key was removed above).
        try {
          final Map<String, dynamic> m = (e as Map<dynamic, dynamic>).cast<String, dynamic>();
          final Object? only = m['for'];
          await _sealFix(m, only: only is List ? only.cast<String>().toSet() : null);
          n++;
        } catch (_) {}
      }
      return n;
    } finally {
      _drainingParked = false;
    }
  }

  Future<void> _sealFix(Map<String, dynamic> loc, {bool resend = false, Set<String>? only}) async {
    try {
      final SenderIdentity? me = await _me();
      if (me == null) {
        await _noteSealError(const LocalKeyException(LocalKeyProblem.missing));
        await _park(loc);
        return;
      }
      final DateTime ts = DateTime.tryParse((loc['ts'] as String?) ?? '')?.toUtc() ?? clock.now();
      if (!resend) await _rememberLastFix(loc, ts);
      final Map<String, dynamic> body = fixBodyFromLocation(loc);
      final double? lat = (loc['lat'] as num?)?.toDouble(), lon = (loc['lon'] as num?)?.toDouble();
      final double? acc = (loc['accuracy_meters'] as num?)?.toDouble();
      final List<String> missingKey = <String>[];
      for (final String circle in await privateCircles()) {
        if (only != null && !only.contains(circle)) continue;
        // A circle that requires server processing and this member has not consented to:
        // nothing is sealed or sent for it (the server would refuse a phone-lane item anyway).
        if (await lanes.store.status(circle) == LaneStatus.consentRequired) continue;
        final WireItem it;
        try {
          it = await sealer.seal(me, circle, ChannelPurpose.fix, body, at: ts);
        } on ItemRejected catch (e) {
          if (e.reason != ItemRejection.noKey) rethrow;
          // This phone does not hold the circle key (yet). Park the fix, and go and get the key: waiting for the
          // user to open a settings screen is how a whole family ended up with nobody sending.
          missingKey.add(circle);
          continue;
        }
        await queue.enqueue(it);
        await kv.set(_sealedAtKey(circle), '${clock.now().millisecondsSinceEpoch}');
        if (lat != null && lon != null) {
          await chunker.add(circle, TrackPoint(ts.millisecondsSinceEpoch, lat, lon, acc));
          await history.add(circle, me.userId, <TrackPoint>[TrackPoint(ts.millisecondsSinceEpoch, lat, lon, acc)]);
          await _maybeSealHistory(me, circle);
          await _evaluatePlaces(me, circle, lat, lon, ts, acc);
        }
      }
      if (missingKey.isNotEmpty) {
        // Parked for exactly the circles that lacked the key; the others already got their copy.
        await _park(loc, circles: missingKey);
        for (final String c in missingKey) {
          unawaited(_keysThenDrain(c));
        }
      }
      if (!resend) await _processOnDevice(me, loc, ts);
      await _clearSealError();
      // Batched, jittered upload: do not wake the radio for every fix.
      _scheduleFlush();
    } catch (e) {
      // Never throw into the location pipeline and never fall back to plaintext. But remember WHY, so the
      // Delivery screen can say "this phone's key cannot be read" instead of "waiting for the circle key".
      await _noteSealError(e);
      await _park(loc, circles: only?.toList());
    }
  }

  static const String _sealErrKey = 'sealerr/v1';
  bool _sealErrSet = true; // unknown at start: the first success clears whatever an earlier run left

  /// Records the last reason a fix could not be sealed (a type name and a coarse class, never key material).
  Future<void> _noteSealError(Object e) async {
    try {
      final LocalKeyException? k = localKeyProblemOf(e);
      await kv.set(_sealErrKey, jsonEncode(<String, dynamic>{
        'at': clock.now().toUtc().toIso8601String(),
        'problem': k?.problem.name ?? 'other',
        'cause': k?.cause ?? e.runtimeType.toString(),
      }));
      _sealErrSet = true;
    } catch (_) {}
  }

  DateTime? _sealErrClearedAt;

  /// After a successful seal. Also clears, at most once a minute, a note the OTHER isolate left.
  Future<void> _clearSealError() async {
    final DateTime now = clock.now();
    final DateTime? last = _sealErrClearedAt;
    if (!_sealErrSet && last != null && now.difference(last) < const Duration(minutes: 1)) return;
    try {
      await kv.remove(_sealErrKey);
      _sealErrSet = false;
      _sealErrClearedAt = now;
    } catch (_) {}
  }

  /// The last sealing failure on this phone (either isolate), or null when the last fix sealed fine.
  Future<({DateTime? at, String problem, String cause})?> lastSealError() async {
    try {
      final String? raw = await kv.getFresh(_sealErrKey);
      if (raw == null || raw.isEmpty) return null;
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      return (at: DateTime.tryParse('${m['at']}'), problem: '${m['problem']}', cause: '${m['cause']}');
    } catch (_) {
      return null;
    }
  }

  /// User-facing words for [lastSealError], or '' when there is nothing to say.
  static String sealProblemText(String problem) {
    for (final LocalKeyProblem p in LocalKeyProblem.values) {
      if (p.name == problem) return LocalKeyException(p).message;
    }
    return problem.isEmpty ? '' : 'Positions could not be encrypted on this phone. Open "Fix this circle" or Encryption keys.';
  }

  static const String _lastFixKey = 'lastfix/v1';
  String _sealedAtKey(String circle) => 'sealedat/$circle';

  Future<void> _rememberLastFix(Map<String, dynamic> loc, DateTime ts) async {
    try {
      final String? old = await kv.get(_lastFixKey);
      if (old != null) {
        final DateTime? o = DateTime.tryParse(((jsonDecode(old) as Map<String, dynamic>)['ts'] as String?) ?? '');
        if (o != null && !ts.isAfter(o)) return; // a parked, older fix must not replace the newest one
      }
      await kv.set(_lastFixKey, jsonEncode(<String, dynamic>{
        'ts': ts.toIso8601String(), 'lat': loc['lat'], 'lon': loc['lon'], 'accuracy_meters': loc['accuracy_meters'],
        'altitude_meters': loc['altitude_meters'], 'speed_mps': loc['speed_mps'], 'heading_deg': loc['heading_deg'],
        'battery_pct': loc['battery_pct'], 'charging': loc['charging'], 'motion_state': loc['motion_state'],
      }));
    } catch (_) {}
  }

  /// When this phone last sealed a fix for [circleId] (null: never since it was installed).
  Future<DateTime?> lastSealedAt(String circleId) async {
    final int? ms = int.tryParse(await kv.get(_sealedAtKey(circleId)) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// Seals the last known position again (with its own, original time) for the given circles, so
  /// a circle that just turned Private, or a phone that was closed for a while, is not empty to the
  /// others until the next GPS fix. Returns false when there is no last fix or it is older than [maxAge].
  Future<bool> resendLastFix({Set<String>? circles, Duration maxAge = const Duration(hours: 12)}) async {
    try {
      final String? raw = await kv.get(_lastFixKey);
      if (raw == null) return false;
      final Map<String, dynamic> loc = (jsonDecode(raw) as Map<String, dynamic>).cast<String, dynamic>();
      final DateTime? ts = DateTime.tryParse((loc['ts'] as String?) ?? '');
      if (ts == null || clock.now().difference(ts) > maxAge) return false;
      await _sealFix(loc, resend: true, only: circles);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ circle keys

  final Map<String, DateTime> _keyTry = <String, DateTime>{};

  /// Makes sure this phone holds the newest circle key the server has a wrap for. A wrap that was made for this phone
  /// is worthless until the phone fetches it, and nothing else ever fetched it automatically. Returns true if a key
  /// was stored. Throttled (a minute per circle) unless [force]. Never throws.
  Future<bool> ensureKeys(String circleId, {bool force = false}) async {
    final DateTime now = clock.now();
    final DateTime? last = _keyTry[circleId];
    if (!force && last != null && now.difference(last) < const Duration(minutes: 1)) return false;
    _keyTry[circleId] = now;
    try {
      final int held = await keys.latestEpoch(circleId);
      final CircleE2eeState st = await api.circleState(circleId);
      if (!st.isPrivate || st.epoch <= held) return false;
      final bool got = await service.syncCircleKeys(circleId) > 0;
      _keyCache.invalidate(circleId);
      return got;
    } catch (_) {
      return false;
    }
  }

  Future<void> _keysThenDrain(String circleId) async {
    final bool got = await ensureKeys(circleId);
    // "Already has the newest key" is the other way to be ready: the key may have arrived through another path
    // (a settings screen, an admin's wrap) after the fix was parked, and nothing else would ever seal it.
    if (got || await keys.latestEpoch(circleId) > 0) {
      await drainParked();
      unawaited(flush());
    }
  }

  /// An admin's phone wraps the circle key for members' new phones that are waiting (only the automatic, safe
  /// cases; anything that needs a person's confirmation stays on the Encryption keys screen). Never throws.
  Future<int> wrapForWaitingDevices(String circleId) async {
    try {
      return (await service.processPending(circleId)).wrapped;
    } catch (_) {
      return 0;
    }
  }

  Timer? _flushTimer;

  void _scheduleFlush({Duration? after}) {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(after ?? const Duration(seconds: 2) + uploadJitter(_rng, max: const Duration(seconds: 3)), () {
      unawaited(flush());
    });
  }

  Future<int>? _flushing;
  bool _flushAgain = false;
  DateTime? _parkedTriedAt;

  /// Parked fixes are tried again from [flush] at most this often (a key that arrives seals them at once through
  /// [_keysThenDrain]). Fixes that still cannot be sealed are parked again, so without this every upload while
  /// driving re-sealed the whole parked list (up to 720 fixes) first.
  static const Duration parkedRetryEvery = Duration(seconds: 30);

  /// Uploads the queue now (also called on app resume and when the network returns).
  ///
  /// One upload at a time: a call while one runs makes it go round once more (so what was queued meanwhile is
  /// sent too) and gets the same result, instead of posting the same batch twice in parallel.
  Future<int> flush() {
    final Future<int>? running = _flushing;
    if (running != null) {
      _flushAgain = true;
      return running;
    }
    final Future<int> f = _flushRounds();
    _flushing = f;
    return f;
  }

  Future<int> _flushRounds() async {
    int n = 0;
    try {
      do {
        _flushAgain = false;
        n += await _flushOnce();
      } while (_flushAgain);
    } finally {
      _flushing = null;
    }
    return n;
  }

  Future<int> _flushOnce() async {
    // An opt-out the server has not confirmed yet is sent again here, so it does not depend on the user reopening a screen.
    unawaited(_retryOptOuts());
    try {
      final SenderIdentity? me = await _me();
      if (me == null) return 0;
      // What is already sealed goes first: the newest position must not wait for old parked fixes.
      int n = await queue.flush(channel, deviceFor: (_) => me.deviceId, lanes: lanes, onNeedKeySync: (String c) => unawaited(_syncKeys(c)));
      // Fixes parked for want of a key are sealed as soon as the key is here, whichever path brought it.
      final DateTime now = clock.now();
      final DateTime? tried = _parkedTriedAt;
      if ((tried == null || now.difference(tried) >= parkedRetryEvery || now.isBefore(tried)) &&
          (await kv.getFresh(_parkedKey) ?? '').isNotEmpty) {
        _parkedTriedAt = now;
        if (await drainParked() > 0) {
          n += await queue.flush(channel, deviceFor: (_) => me.deviceId, lanes: lanes, onNeedKeySync: (String c) => unawaited(_syncKeys(c)));
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  // ------------------------------------------------- on-device processing

  OnDeviceProcessor? _processor;
  bool _processorRestored = false;
  Set<String> _resultCircles = <String>{};

  /// Private circles in which this member is PHONE-ONLY (their own signed pref):
  /// results for them are computed here and sealed in the phone lane. A circle
  /// where the member is server-assisted gets none (the server computes), and a
  /// circle awaiting required consent gets none (nothing is shared there).
  Future<Set<String>> phoneOnlyCircles() async {
    final Set<String> out = <String>{};
    for (final String c in await privateCircles()) {
      if (await lanes.store.status(c) == LaneStatus.consentRequired) continue;
      if ((await lanes.ownLane(c)).line == E2ee.linePhone) out.add(c);
    }
    return out;
  }

  OnDeviceProcessor _proc(SenderIdentity me) => _processor ??= OnDeviceProcessor(
        kv: kv,
        userId: me.userId,
        now: clock.now,
        publish: (String kind, Map<String, dynamic> body) async {
          // The circles are re-read per item: a lane change in between must never leak a phone result to a wrong lane
          // (the sealer picks the lane itself, this only picks which circles get a copy).
          for (final String c in _resultCircles) {
            await queue.enqueue(await sealer.seal(me, c, kind, body));
          }
        },
      );

  /// Fixes waiting for the next on-device processing batch (only used while the opt-in switch is on).
  final List<(Map<String, dynamic>, DateTime)> _procBacklog = <(Map<String, dynamic>, DateTime)>[];
  DateTime? _procLast;
  Timer? _procTimer;

  /// Heavy processing runs in batches at most this often (the switch is off by default, see [OnDeviceReportsSetting]).
  Duration onDeviceBatchEvery = const Duration(seconds: 60);

  /// Extra gate for the heavy work (the app can return false while the phone is low on battery and not charging).
  Future<bool> Function()? onDeviceAllowed;

  Future<void> _processOnDevice(SenderIdentity me, Map<String, dynamic> loc, DateTime ts) async {
    try {
      // Off by default: a phone-only member's phone sends its fix and shows the map, nothing more.
      if (!await OnDeviceReportsSetting.isOn(kv)) {
        _procBacklog.clear();
        return;
      }
      if ((await phoneOnlyCircles()).isEmpty) return;
      _procBacklog.add((loc, ts));
      if (_procBacklog.length > 600) _procBacklog.removeAt(0);
      final DateTime? last = _procLast;
      if (last != null && clock.now().difference(last) < onDeviceBatchEvery) {
        _procTimer ??= Timer(onDeviceBatchEvery, () {
          _procTimer = null;
          unawaited(_drainProcessing(me));
        });
        return;
      }
      await _drainProcessing(me);
    } catch (_) {
      // Processing is best effort and must never disturb the location pipeline.
    }
  }

  Future<void> _drainProcessing(SenderIdentity me) async {
    try {
      if (_procBacklog.isEmpty) return;
      final Future<bool> Function()? gate = onDeviceAllowed;
      if (gate != null && !await gate()) return; // try again with the next fix
      final Set<String> circles = await phoneOnlyCircles();
      if (circles.isEmpty) {
        _procBacklog.clear();
        return;
      }
      _resultCircles = circles;
      final OnDeviceProcessor p = _proc(me);
      try {
        p.phoneUseEnabled = await DrivingSettings.phoneUseEnabled(reload: false);
      } catch (_) {}
      final List<(Map<String, dynamic>, DateTime)> batch = List<(Map<String, dynamic>, DateTime)>.of(_procBacklog);
      _procBacklog.clear();
      _procLast = clock.now();
      if (!_processorRestored) {
        _processorRestored = true;
        final DateTime firstTs = batch.first.$2;
        final List<TrackPoint> past = await trailFor(me.userId, firstTs.subtract(const Duration(hours: 6)), firstTs);
        await p.restore(<Fix>[
          for (final TrackPoint t in past)
            if (t.tsMs < firstTs.millisecondsSinceEpoch)
              Fix(tsUs: t.tsMs * 1000, lat: t.lat, lon: t.lon, accuracyM: t.accuracy ?? 0, deviceId: me.deviceId)
        ]);
      }
      int n = 0;
      for (final (Map<String, dynamic> loc, DateTime ts) in batch) {
        final double? lat = (loc['lat'] as num?)?.toDouble(), lon = (loc['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        await p.onFix(Fix(
            tsUs: ts.microsecondsSinceEpoch,
            lat: lat,
            lon: lon,
            speedMps: (loc['speed_mps'] as num?)?.toDouble(),
            accuracyM: (loc['accuracy_meters'] as num?)?.toDouble() ?? 0,
            deviceId: me.deviceId));
        if (++n % 20 == 0) await Future<void>.delayed(Duration.zero); // let frames through
      }
      await p.tickWeekly();
      _scheduleFlush();
    } catch (_) {
      // best effort
    }
  }

  Future<void> _maybeSealHistory(SenderIdentity me, String circle) async {
    final Map<String, dynamic>? chunk = await chunker.takeIfDue(circle);
    if (chunk == null) return;
    final WireItem it = await sealer.seal(me, circle, ChannelPurpose.history, chunk);
    await queue.enqueue(it);
  }

  /// Seals [body] and puts it in the upload queue WITHOUT flushing (the caller
  /// records its own bookkeeping first, then calls [flush]).
  Future<({WireItem item, String userId})> queueSealed(String circleId, String purpose, Map<String, dynamic> body, {DateTime? at}) async {
    final SenderIdentity? me = await _me();
    if (me == null) throw const ItemRejected(ItemRejection.noKey);
    final WireItem it = await sealer.seal(me, circleId, purpose, body, at: at);
    await queue.enqueue(it);
    return (item: it, userId: me.userId);
  }

  /// This account's user id, or null before a key exists.
  Future<String?> myUserId() async => (await _me())?.userId;

  /// Seals an arbitrary item (check-in/SOS position, place, event).
  Future<void> sendItem(String circleId, String purpose, Map<String, dynamic> body, {bool flushNow = true, DateTime? at}) async {
    final SenderIdentity? me = await _me();
    if (me == null) throw const ItemRejected(ItemRejection.noKey);
    await queue.enqueue(await sealer.seal(me, circleId, purpose, body, at: at));
    if (flushNow) unawaited(flush());
  }

  // ----------------------------------------------------------------- places

  PlaceBook book(String circleId) => _books.putIfAbsent(circleId, PlaceBook.new);

  List<SealedPlace> places(String circleId) => book(circleId).places;

  /// The private circle a new place should go to: [circleId] if it is private,
  /// else the primary circle when that is private and the place is family-wide
  /// (null circle). Null means "use the normal server path".
  Future<String?> privateTargetFor(String? circleId) async {
    await _loadModes();
    if (circleId != null) return _private.contains(circleId) ? circleId : null;
    return _primary != null && _private.contains(_primary) ? _primary : null;
  }

  String circleName(String circleId) => _names[circleId] ?? 'Private circle';

  /// Whether [circleId] is the primary circle (family-wide places belong to it).
  bool isPrimary(String circleId) => _primary == circleId;

  /// Whether the server's plaintext places of [circleId] are left over from an unfinished move to sealed places
  /// that this account may finish: a Private circle without a legacy trusted server member (whose server-side
  /// places are legitimate), administered by this account (only an admin may delete the plaintext copies).
  bool canFinishPlaceMove(String circleId) =>
      _private.contains(circleId) && !_serverMember.contains(circleId) && _adminOf.contains(circleId);

  /// Every sealed place of every private circle, with its circle.
  Future<List<({String circleId, SealedPlace place})>> allSealedPlaces() async {
    final List<({String circleId, SealedPlace place})> out = <({String circleId, SealedPlace place})>[];
    for (final String c in await privateCircles()) {
      await loadBook(c);
      for (final SealedPlace p in places(c)) {
        out.add((circleId: c, place: p));
      }
    }
    return out;
  }

  /// The circle that holds sealed place [placeId], if any.
  Future<String?> circleOfPlace(String placeId) async {
    for (final String c in await privateCircles()) {
      await loadBook(c);
      if (book(c).byId(placeId) != null) return c;
    }
    return null;
  }

  /// Migration when a circle turns Private: seals the circle's existing plaintext
  /// places (every member receives them) and then asks the server to delete its
  /// plaintext copies. Returns the number of places moved.
  Future<int> migratePlaces(String circleId, {required bool primary}) async {
    final dynamic data = await ApiClient.get('/family/places');
    int moved = 0;
    if (data is List) {
      for (final dynamic e in data) {
        if (e is! Map<String, dynamic>) continue;
        final Object? c = e['circle_id'];
        if (!(c == circleId || (c == null && primary))) continue;
        // The server's place id is kept (the server knew it anyway): a retry after a failed
        // purge re-seals the SAME places instead of adding copies.
        final Object? sid = e['id'];
        final SealedPlace? p = SealedPlace.fromJson(<String, dynamic>{
          'id': sid is String && sid.isNotEmpty ? sid : E2ee.newUuid(), 'name': e['name'], 'lat': e['lat'], 'lon': e['lon'],
          'r': e['radius_meters'] ?? 100, 'type': e['type'], 'addr': e['address'] ?? '',
        });
        if (p == null) continue;
        await savePlace(circleId, p);
        moved++;
      }
    }
    await ApiClient.post('/circles/$circleId/e2ee/purge-plaintext');
    return moved;
  }

  /// Creates or edits a place of a Private circle (sealed, distributed to every member).
  Future<void> savePlace(String circleId, SealedPlace p) async {
    await loadBook(circleId);
    final DateTime at = clock.now().toUtc();
    // The book keeps the same signed time as the item, so a later re-share carries it unchanged.
    await sendItem(circleId, ChannelPurpose.place, p.toJson(), at: at);
    book(circleId).apply(p, at.millisecondsSinceEpoch);
    _evals[circleId]?.resetPlace(p.id);
    await _persistBook(circleId);
    onPlacesChanged?.call(circleId);
  }

  Future<void> deletePlace(String circleId, SealedPlace p) => savePlace(
      circleId,
      SealedPlace(id: p.id, name: p.name, lat: p.lat, lon: p.lon, radiusMeters: p.radiusMeters, deleted: true));

  String _bookKey(String c) => 'book/$c';

  Future<void> _persistBook(String circleId) async {
    final PlaceBook b = book(circleId);
    await kv.set(_bookKey(circleId), jsonEncode(<String, dynamic>{
      'places': b.allEntries
          .map((({SealedPlace place, int tsMs}) e) => <String, dynamic>{...e.place.toJson(), 'ts': e.tsMs})
          .toList(),
    }));
  }

  /// Signed time of a place persisted by a build that did not store it.
  static const int _unknownPlaceTs = 1;

  String _placesSharedKey(String c) => 'placespub/$c';

  /// Which key a place sealed now would be readable under: the newest circle key epoch this phone holds. Places are
  /// always sealed on the phone line (every member holds that key), whatever lane this member is in. Null when this
  /// phone holds no key for the circle. Places shared by an earlier build under the server lane carry a different
  /// marker, so they are shared again once.
  Future<String?> _placeKeyMarker(String circleId) async {
    final int epoch = await keys.latestEpoch(circleId);
    if (epoch < 1) return null;
    return '$epoch:${E2ee.linePhone}:0';
  }

  /// True when this phone holds places of [circleId] that were not sealed under the circle's CURRENT key.
  ///
  /// A sealed place is readable only by phones holding the key it was sealed under. A phone that joins later (a new
  /// member, a reset or replaced phone) gets the newest key only, and turning Private mode off deletes every sealed
  /// item from the server: either way the places then exist only on the phones that already had them.
  Future<bool> placesNeedSharing(String circleId) async {
    await loadBook(circleId);
    if (places(circleId).isEmpty) return false;
    final String? marker = await _placeKeyMarker(circleId);
    return marker != null && await kv.get(_placesSharedKey(circleId)) != marker;
  }

  /// Seals every place this phone holds for [circleId] again, under the current key, so every member's phone can
  /// read them. Each place keeps its id and its original signed time: a phone that already has it (or a newer edit,
  /// or its deletion) ignores the copy. Only members receive it, exactly like a new place. Returns how many places
  /// were sealed. Throws [ItemRejected] (noKey) when this phone holds no key for the circle.
  Future<int> sharePlaces(String circleId) async {
    final SenderIdentity? me = await _me();
    if (me == null) throw const ItemRejected(ItemRejection.noKey);
    await loadBook(circleId);
    final String? marker = await _placeKeyMarker(circleId);
    if (marker == null) throw const ItemRejected(ItemRejection.noKey);
    final PlaceBook b = book(circleId);
    int n = 0;
    for (final ({SealedPlace place, int tsMs}) e in b.entries) {
      int ts = e.tsMs;
      if (ts <= _unknownPlaceTs) {
        ts = clock.now().millisecondsSinceEpoch;
        b.apply(e.place, ts);
      }
      await queue.enqueue(await sealer.seal(me, circleId, ChannelPurpose.place, e.place.toJson(),
          at: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)));
      n++;
    }
    await _persistBook(circleId);
    await kv.set(_placesSharedKey(circleId), marker);
    unawaited(flush());
    return n;
  }

  /// [sharePlaces] for every Private circle whose key changed since this phone last shared its places. Never throws.
  Future<int> sharePlacesIfDue() async {
    int n = 0;
    for (final String c in await privateCircles()) {
      try {
        if (await lanes.store.status(c) == LaneStatus.consentRequired) continue;
        if (await placesNeedSharing(c)) n += await sharePlaces(c);
      } catch (_) {
        // no key yet / offline: the next app open tries again
      }
    }
    return n;
  }

  /// Private circles in which this phone holds places the other members may not be able to read.
  Future<Set<String>> circlesWithUnsharedPlaces() async {
    final Set<String> out = <String>{};
    for (final String c in await privateCircles()) {
      try {
        if (await placesNeedSharing(c)) out.add(c);
      } catch (_) {}
    }
    return out;
  }

  /// Loads persisted places (call before evaluating, e.g. in the background isolate).
  Future<void> loadBook(String circleId) async {
    if (_books.containsKey(circleId)) return;
    final String? raw = await kv.get(_bookKey(circleId));
    final PlaceBook b = book(circleId);
    if (raw == null) return;
    try {
      for (final dynamic j in ((jsonDecode(raw) as Map<String, dynamic>)['places'] as List<dynamic>)) {
        final Map<String, dynamic> m = j as Map<String, dynamic>;
        final SealedPlace? p = SealedPlace.fromJson(m);
        final Object? ts = m['ts'];
        if (p != null) b.apply(p, ts is int && ts > 0 ? ts : _unknownPlaceTs);
      }
    } catch (_) {}
  }

  PlaceEvaluator _evaluator(String circleId) => _evals.putIfAbsent(circleId, PlaceEvaluator.new);

  Future<void> _evaluatePlaces(SenderIdentity me, String circle, double lat, double lon, DateTime ts, double? acc) async {
    await loadBook(circle);
    final List<SealedPlace> ps = places(circle);
    if (ps.isEmpty) return;
    final PlaceEvaluator ev = _evaluator(circle);
    for (final PlaceEvent e in ev.onFix(lat, lon, ts, acc, ps)) {
      await queue.enqueue(await sealer.seal(me, circle, ChannelPurpose.event, <String, dynamic>{
        'k': 'place',
        'a': e.entered ? 'enter' : 'exit',
        'pid': e.placeId,
        'name': e.placeName,
        'at': e.at.millisecondsSinceEpoch,
      }));
    }
  }

  /// Fires pending (debounced) place transitions; call from a periodic timer.
  Future<void> tickPlaces() async {
    final SenderIdentity? me = await _me();
    if (me == null) return;
    for (final String circle in await privateCircles()) {
      final PlaceEvaluator? ev = _evals[circle];
      if (ev == null) continue;
      for (final PlaceEvent e in ev.tick(places(circle))) {
        await queue.enqueue(await sealer.seal(me, circle, ChannelPurpose.event, <String, dynamic>{
          'k': 'place',
          'a': e.entered ? 'enter' : 'exit',
          'pid': e.placeId,
          'name': e.placeName,
          'at': e.at.millisecondsSinceEpoch,
        }));
      }
    }
    unawaited(flush());
  }

  /// Sends the position of an SOS / help / check-in sealed to every private
  /// circle (the server withholds it from the plaintext alert). Never throws.
  Future<void> sealAlertPosition(String kind, double? lat, double? lon, {String? note}) async {
    try {
      for (final String c in await privateCircles()) {
        await sendItem(c, ChannelPurpose.checkin, <String, dynamic>{
          'k': kind,
          if (lat != null && lon != null) ...<String, dynamic>{'lat': lat, 'lon': lon},
          if (note != null && note.isNotEmpty) 'note': note.length > 280 ? note.substring(0, 280) : note,
        });
      }
    } catch (_) {}
  }

  /// The relay refused items for an epoch reason: fetch the newest circle keys so new items use them.
  Future<void> _syncKeys(String circleId) async {
    try {
      await service.syncCircleKeys(circleId);
      _keyCache.invalidate(circleId);
    } catch (_) {}
  }

  /// Tells the server what this app understands, once per phone key, so a key
  /// registered by an older build is also known to read encrypted chat.
  Future<void> _declareCaps() async {
    try {
      final LocalIdentity? id = await service.identity();
      if (id == null) return;
      final String want = '${id.deviceId}:${E2eeService.capabilities.join(',')}';
      if (await kv.get('caps/declared') == want) return;
      await api.putCaps(id.deviceId, E2eeService.capabilities);
      await kv.set('caps/declared', want);
    } catch (_) {
      // offline or an older server: tried again at the next app start
    }
  }

  /// Bumped when this phone signed the server lane on its own (section 23), so the notice card appears.
  static final ValueNotifier<int> autoApplied = ValueNotifier<int>(0);

  /// "Members are on the server by default": for every Private circle where the admin's setting says so, this
  /// member's OWN phone signs the server lane once (never over an earlier choice). Offline or an older server: nothing happens.
  Future<void> _autoApplyAll(Set<String> privs) async {
    if (privs.isEmpty) return;
    bool auto = false, follow = false;
    try {
      final ServerProfile p = await api.serverProfile();
      auto = p.autoApply;
      follow = p.followCircleDefault; // section 24: the circle admin's signed "server by default" counts too
    } catch (_) {}
    if (!auto && !follow) return;
    await _declareCaps(); // the server only accepts a lane pref from a phone that declared it can read the server line
    for (final String id in privs) {
      try {
        if (await lanesService.autoApplyIfDue(id, autoApply: auto, followCircleDefault: follow) == AutoApplyOutcome.applied) {
          autoApplied.value++;
          unawaited(lanesService.maintain(id).catchError((Object _) => lanesService.refresh(id)));
        }
      } catch (_) {
        // offline or an older server: tried again at the next open
      }
    }
  }

  Future<void> _retryOptOuts() async {
    try {
      for (final String c in await privateCircles()) {
        if (await lanesService.store.pendingBody(c) != null) await lanesService.retryPendingOptOut(c);
      }
    } catch (_) {}
  }

  /// Everything the foreground does when the app opens, resumes or regains the
  /// network: refresh circle modes, seal parked fixes, upload the queue, fire
  /// pending place transitions and catch up on every private circle.
  Future<void> onAppActive(List<Circle> circles) async {
    await setCircles(circles);
    final Set<String> privs = await privateCircles();
    // Keys first: without the circle key this phone can neither send nor read.
    for (final String id in privs) {
      await ensureKeys(id);
      unawaited(wrapForWaitingDevices(id));
    }
    unawaited(_declareCaps());
    await drainParked();
    // A circle that just turned Private, or one this phone has not sent anything to for a while: send the last
    // position now, so the first view of the others is not empty.
    final Set<String> stale = <String>{};
    for (final String id in privs) {
      final DateTime? at = await lastSealedAt(id);
      if (_newlyPrivate.contains(id) || at == null || clock.now().difference(at) > const Duration(minutes: 3)) stale.add(id);
    }
    if (stale.isNotEmpty) await resendLastFix(circles: stale);
    await flush();
    await tickPlaces();
    for (final String id in privs) {
      try {
        await lanesService.maintain(id);
      } catch (_) {
        // offline or an older server: the last verified lane facts stay in force
      }
    }
    await _autoApplyAll(privs);
    for (final String id in privs) {
      try {
        await catchUp(id);
      } catch (_) {
        // offline: the next resume or socket frame retries
      }
    }
    // After the catch-up (newer edits and deletions are in the book): places this phone holds that the circle's
    // current key cannot open yet are sealed again, so a member who joined, or a phone that was replaced, after the
    // key changed sees them too. A circle that just turned Private (again) always gets them: turning it off deleted
    // the sealed copies from the server.
    for (final String id in _newlyPrivate.intersection(privs)) {
      try {
        await kv.remove(_placesSharedKey(id));
      } catch (_) {}
    }
    await sharePlacesIfDue();
  }

  // ------------------------------------------------------------ diagnostics

  /// What THIS phone knows about its own delivery for [circleId] (no server round trip).
  Future<LocalDelivery> localDelivery(String circleId) async {
    int parked = 0;
    try {
      final String? raw = await kv.get(_parkedKey);
      if (raw != null && raw.isNotEmpty) parked = (jsonDecode(raw) as List<dynamic>).length;
    } catch (_) {}
    final int epoch = await keys.latestEpoch(circleId);
    final und = await queue.undelivered(circleId);
    final ({DateTime? at, String problem, String cause})? se = await lastSealError();
    return LocalDelivery(
      sealProblem: se == null ? '' : sealProblemText(se.problem),
      hasKey: epoch > 0,
      heldEpoch: epoch,
      queued: await queue.length(),
      parked: parked,
      lastSealedAt: await lastSealedAt(circleId),
      lastPulledCursor: await sync.cursor(circleId),
      undelivered: und?.count ?? 0,
      undeliveredCode: und?.code ?? '',
    );
  }

  /// The one-tap "Fix this circle": gets the circle key, lets an admin phone share keys that are waiting, seals
  /// parked fixes, sends the last known position, uploads, and downloads everything new. Returns what was done, in words.
  Future<List<String>> fixCircle(String circleId) async {
    final List<String> done = <String>[];
    // Without this phone's own key nothing below can work (fetching the circle key, sealing, reading): say so.
    try {
      await service.requireIdentity();
    } catch (e) {
      final LocalKeyException? k = localKeyProblemOf(e);
      if (k != null) {
        await _noteSealError(k);
        return <String>[k.message];
      }
      // A network or session problem: the steps below report it in their own words.
    }
    final int before = await keys.latestEpoch(circleId);
    final bool got = await ensureKeys(circleId, force: true);
    final int after = await keys.latestEpoch(circleId);
    if (got) {
      done.add('Fetched the circle key for this phone.');
    } else if (after == 0) {
      done.add("This phone still has no key for the circle. An admin's phone has to share it (Settings, Security, Encryption keys).");
    } else if (before == after) {
      done.add('This phone already has the newest circle key.');
    }
    final int wrapped = await wrapForWaitingDevices(circleId);
    if (wrapped > 0) done.add('Shared the circle key with $wrapped waiting phone${wrapped == 1 ? '' : 's'}.');
    final int parked = await drainParked();
    if (parked > 0) done.add('Sealed $parked position${parked == 1 ? '' : 's'} that were waiting for the key.');
    if (after > 0 && await resendLastFix(circles: <String>{circleId}, maxAge: const Duration(days: 2))) {
      done.add('Sent your last known position.');
    }
    final int sent = await flush();
    if (sent > 0) done.add('Uploaded $sent update${sent == 1 ? '' : 's'}.');
    if (after > 0) {
      try {
        final SyncStats st = await catchUp(circleId);
        done.add(st.accepted > 0 ? 'Received ${st.accepted} update${st.accepted == 1 ? '' : 's'} from the others.' : 'No new updates from the others.');
        await replayLatest();
      } catch (_) {
        done.add("Couldn't reach the server to download updates. Check the connection and try again.");
      }
    }
    return done;
  }

  // ---------------------------------------------------------------- receive

  /// Handles a live WebSocket `e2ee_item` frame.
  Future<bool> onWireFrame(Map<String, dynamic> frame) async {
    final WireItem? it = WireItem.fromServer(frame);
    if (it == null) return false;
    final ReceivedItem? r = await sync.live(it);
    if (r == null) return false;
    await _apply(r);
    return true;
  }

  /// Pulls and applies everything new for [circleId] (app open, push wake-up, reconnect).
  Future<SyncStats> catchUp(String circleId) async {
    await loadBook(circleId);
    return sync.catchUp(circleId, onBatch: _applyBatch);
  }

  /// A member's decrypted track across all Private circles for [from, to).
  Future<List<TrackPoint>> trailFor(String userId, DateTime from, DateTime to) async {
    final Map<int, TrackPoint> byTs = <int, TrackPoint>{};
    for (final String c in await privateCircles()) {
      for (final TrackPoint p in await history.range(c, userId, from, to)) {
        byTs.putIfAbsent(p.tsMs, () => p);
      }
    }
    return byTs.values.toList()..sort((TrackPoint a, TrackPoint b) => a.tsMs.compareTo(b.tsMs));
  }

  String _usersKey(String circleId) => 'users/$circleId';

  final Map<String, Set<String>> _knownUsers = <String, Set<String>>{};

  Future<Set<String>> _usersOf(String circleId) async {
    final Set<String>? have = _knownUsers[circleId];
    if (have != null) return have;
    final String raw = await kv.get(_usersKey(circleId)) ?? '';
    return _knownUsers[circleId] = raw.isEmpty ? <String>{} : raw.split(',').toSet();
  }

  Future<void> _rememberUser(String circleId, String userId) async {
    final Set<String> s = await _usersOf(circleId);
    if (s.add(userId)) await kv.set(_usersKey(circleId), s.join(','));
  }

  /// Re-emits each member's newest decrypted position as a map frame. The
  /// roster REST/`members` snapshot of a Private circle carries no positions (the
  /// server has none), so this restores "last known" after every refresh.
  Future<void> replayLatest() async {
    final Set<String> privs = await privateCircles();
    if (privs.isEmpty) return; // standard users: no identity lookup, no request
    await lastPositions.load();
    final SenderIdentity? me = await _me();
    for (final String circle in privs) {
      for (final String user in await _usersOf(circle)) {
        if (me != null && user == me.userId) continue;
        LastPosition? p = lastPositions.ofIn(circle, user);
        if (p == null) {
          // Seen before the last-position book existed: take the newest point of the stored track once.
          final List<TrackPoint> pts = await history.range(
              circle, user, clock.now().subtract(const Duration(days: 7)), clock.now().add(const Duration(days: 1)));
          if (pts.isEmpty) continue;
          final TrackPoint t = pts.last;
          p = LastPosition(circleId: circle, userId: user, tsMs: t.tsMs, lat: t.lat, lon: t.lon, acc: t.accuracy);
          lastPositions.note(p);
        }
        onMemberFrame?.call(p.toFrame());
      }
    }
  }

  /// Applies a verified batch (one catch-up page). Fixes are grouped: one history write per member and ONE map
  /// frame per member (their newest fix), instead of one of each per item. Everything else goes through [_apply].
  Future<void> _applyBatch(List<ReceivedItem> items) async {
    final SenderIdentity? me = await _me();
    final List<ReceivedItem> fixes = <ReceivedItem>[];
    for (final ReceivedItem r in items) {
      if (r.purpose == ChannelPurpose.fix) {
        fixes.add(r);
      } else {
        await _apply(r);
      }
    }
    if (fixes.isNotEmpty) await _applyFixes(fixes, mineId: me?.userId);
  }

  Future<void> _applyFixes(List<ReceivedItem> fixes, {required String? mineId}) async {
    final Map<String, List<ReceivedItem>> byMember = <String, List<ReceivedItem>>{};
    for (final ReceivedItem r in fixes) {
      final double? lat = (r.body['lat'] as num?)?.toDouble(), lon = (r.body['lon'] as num?)?.toDouble();
      if (lat == null || lon == null || lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
      byMember.putIfAbsent('${r.circleId}\u0000${r.userId}', () => <ReceivedItem>[]).add(r);
    }
    for (final List<ReceivedItem> group in byMember.values) {
      final ReceivedItem first = group.first;
      await history.add(first.circleId, first.userId, <TrackPoint>[
        for (final ReceivedItem r in group)
          TrackPoint(r.ts.millisecondsSinceEpoch, (r.body['lat'] as num).toDouble(), (r.body['lon'] as num).toDouble(), (r.body['acc'] as num?)?.toDouble())
      ]);
      if (mineId != null && first.userId == mineId) continue;
      await _rememberUser(first.circleId, first.userId);
      ReceivedItem newest = group.first;
      for (final ReceivedItem r in group) {
        if (r.ts.isAfter(newest.ts)) newest = r;
      }
      final Map<String, dynamic> b = newest.body;
      final LastPosition pos = LastPosition(
          circleId: newest.circleId, userId: newest.userId, tsMs: newest.ts.millisecondsSinceEpoch,
          lat: (b['lat'] as num).toDouble(), lon: (b['lon'] as num).toDouble(), acc: (b['acc'] as num?)?.toDouble(),
          bat: b['bat'] as num?, spd: b['spd'] as num?, hdg: b['hdg'] as num?, mo: b['mo'] as String?,
          chg: b['chg'] is bool ? b['chg'] as bool : null);
      lastPositions.note(pos);
      onMemberFrame?.call(pos.toFrame(heardAt: clock.now()));
    }
  }

  /// Writes everything held in memory (call when the app goes to the background).
  Future<void> flushStores() async {
    await history.flush();
    await lastPositions.flush();
  }

  /// Loads the remembered last positions (cheap, once). Call early so the first roster is not blank.
  Future<void> warmUp() => lastPositions.load();

  /// The last position ever received for [userId] in any Private circle (null: none yet or not loaded).
  LastPosition? lastKnown(String userId, {String? circleId}) {
    if (!lastPositions.loaded) return null;
    return circleId == null ? lastPositions.of(userId) : lastPositions.ofIn(circleId, userId);
  }

  /// Sign-out or account change: nothing remembered about other people may outlive the account.
  Future<void> forgetAccount() async {
    await lastPositions.clear();
    _knownUsers.clear();
    try {
      await kv.remove(_parkedKey);
    } catch (_) {}
  }

  /// Who a notification names: the person when the account's "Show names in notifications" is on, otherwise
  /// "A family member" (the same rule as the server's pushes and the chat notifications). The place of an arrival
  /// is always shown.
  Future<String> _notificationWho(String userId) async {
    if (!await NotificationNames.load()) return 'A family member';
    return nameOf?.call(userId) ?? 'Someone';
  }

  Future<void> _apply(ReceivedItem r) async {
    final SenderIdentity? me = await _me();
    final bool mine = me != null && r.userId == me.userId;
    switch (r.purpose) {
      case ChannelPurpose.fix:
        await _applyFixes(<ReceivedItem>[r], mineId: me?.userId);
      case ChannelPurpose.history:
        await history.add(r.circleId, r.userId, HistoryChunker.parse(r.body));
        if (!mine) await _rememberUser(r.circleId, r.userId);
      case ChannelPurpose.place:
        final SealedPlace? p = SealedPlace.fromJson(r.body);
        if (p == null) return;
        // Load the persisted book first: persisting a book that was never loaded would drop every other place.
        await loadBook(r.circleId);
        if (book(r.circleId).apply(p, r.ts.millisecondsSinceEpoch)) {
          _evals[r.circleId]?.resetPlace(p.id);
          await _persistBook(r.circleId);
          onPlacesChanged?.call(r.circleId);
        }
      case ChannelPurpose.event:
        if (mine) return;
        // Only fresh events raise a notification; catch-up of old ones stays silent.
        if (clock.now().difference(r.ts) > const Duration(minutes: 30)) return;
        if (r.body['k'] == 'place') {
          final String rawPlace = ((r.body['name'] as String?) ?? '').trim();
          await notify('Orbitly',
              placeEventText(await _notificationWho(r.userId), rawPlace.isEmpty ? 'a place' : rawPlace, r.body['a'] == 'enter'));
        }
      case ChannelPurpose.trip:
      case ChannelPurpose.drive:
      case ChannelPurpose.week:
        // Figures a member's phone computed. Stored under the VERIFIED author.
        await results.put(r);
      case ChannelPurpose.chat:
        await chat.apply(r, me: me?.userId ?? '');
      case ChannelPurpose.checkin:
        if (mine) return;
        final String who = await _notificationWho(r.userId);
        final String kind = (r.body['k'] as String?) ?? 'checkin';
        final double? la = (r.body['lat'] as num?)?.toDouble(), lo = (r.body['lon'] as num?)?.toDouble();
        if (la != null && lo != null && la >= -90 && la <= 90 && lo >= -180 && lo <= 180) {
          await history.add(r.circleId, r.userId, <TrackPoint>[TrackPoint(r.ts.millisecondsSinceEpoch, la, lo)]);
          await _rememberUser(r.circleId, r.userId);
          lastPositions.note(LastPosition(circleId: r.circleId, userId: r.userId, tsMs: r.ts.millisecondsSinceEpoch, lat: la, lon: lo));
          onMemberFrame?.call(<String, dynamic>{
            'type': 'location', 'user_id': r.userId, 'circle_id': r.circleId, 'lat': la, 'lon': lo,
            'ts': r.ts.toIso8601String(), 'last_seen_at': clock.now().toIso8601String(),
          });
        }
        if (clock.now().difference(r.ts) <= const Duration(minutes: 30)) {
          // The wording carries no position; open the app to see it.
          final String what = kind == 'sos' ? 'sent an SOS' : (kind == 'help' ? 'asked for help' : 'checked in');
          await notify('Orbitly', '$who $what');
        }
      default:
        break;
    }
  }
}

final LocalDirectPushNotifier _chatNotifier = LocalDirectPushNotifier();
int _chatNoteSeq = 0;

Future<void> _showChatNotification(String title, String body) async {
  try {
    // Distinct ids so two messages do not replace each other.
    final int id = 0x30000000 | ((DateTime.now().millisecondsSinceEpoch ~/ 1000 + _chatNoteSeq++) & 0x0fffffff);
    await _chatNotifier.show(id: id, title: title, body: body);
  } catch (_) {
    // No notification plugin (tests, unsupported platform).
  }
}
