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
import '../push_service.dart';
import '../driving/driving_settings.dart';
import 'e2ee_api.dart';
import 'e2ee_app.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'e2ee_service.dart';
import 'e2ee_trust.dart';
import 'e2ee_vault.dart';
import 'lanes_service.dart';
import 'lanes_wire.dart';
import 'lanes_store.dart';
import 'private_channel.dart';
import 'private_store.dart';
import 'private_history.dart';
import 'private_places.dart';

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
class ServiceChannelKeys implements ChannelKeys, ServerKeys {
  ServiceChannelKeys(this.service);
  final E2eeService service;

  @override
  Future<Uint8List?> circleKey(String circleId, int epoch) => service.circleKey(circleId, epoch);

  @override
  Future<int> latestEpoch(String circleId) async {
    final List<int> e = await service.heldEpochs(circleId);
    return e.isEmpty ? 0 : e.last;
  }

  @override
  Future<Uint8List?> serverKey(String circleId, int gen) => service.serverKey(circleId, gen);

  @override
  Future<int> latestServerGen(String circleId) => service.latestServerGen(circleId);
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
      // 0 = no connection, 408/429/5xx = try again later. Other 4xx can never succeed.
      if (e.status == 0 || e.status == 408 || e.status == 429 || e.status >= 500) rethrow;
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
    final http.Response r = await http
        .post(Uri.parse('$apiBaseUrl/circles/$circleId/e2ee/batch'),
            headers: headers,
            body: jsonEncode(<String, dynamic>{
              'sender_device_id': deviceId,
              'items': items.map((WireItem i) => i.toUpload()).toList(),
            }))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode >= 200 && r.statusCode < 300) {
      final List<dynamic> list = ((jsonDecode(r.body) as Map<String, dynamic>)['results'] as List<dynamic>?) ?? <dynamic>[];
      return list
          .cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => BatchResult((m['seq'] as num).toInt(), (m['status'] as String?) ?? 'rejected'))
          .toList();
    }
    if (r.statusCode == 408 || r.statusCode == 429 || r.statusCode >= 500) throw StateError('retry ${r.statusCode}');
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
  })  : channel = channel ?? const HttpChannelApi(),
        _rng = rng ?? Random.secure() {
    final ServiceChannelKeys ck = ServiceChannelKeys(service);
    keys = ck;
    lanes = KvLaneSource(kv);
    this.directory = directory ?? StateSenderDirectory(api);
    sealer = ChannelSealer(keys: keys, kv: kv, clock: clock, lanes: lanes, serverKeys: ck);
    queue = SealedQueue(kv: kv, clock: clock);
    receiver = ChannelReceiver(keys: keys, directory: this.directory, kv: kv, clock: clock, serverKeys: ck, lanes: lanes);
    lanesService = LanesService(service: service, api: api, kv: kv, clock: clock, onLaneChanged: (String c) async {
      await queue.reconcileLanes(lanes);
    });
    results = ResultStore(kv);
    sync = ChannelSync(api: this.channel, receiver: receiver, kv: kv);
    history = PrivateHistory(kv: kv, now: clock.now);
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
    );
  }

  static PrivateRuntime? override;
  static PrivateRuntime? _instance;
  static PrivateRuntime get instance => override ??
      (_instance ??= PrivateRuntime(service: E2eeApp.service, api: const ApiE2eeApi(), kv: const PrefsChannelKv()));

  final E2eeService service;
  final E2eeApi api;
  final ChannelKv kv;
  final Clock clock;
  final ChannelApi channel;
  final Random _rng;
  late final ChannelKeys keys;

  /// Verified lane facts for the sealer, the queue and the receiver (persisted).
  late final KvLaneSource lanes;

  /// Verifies and changes lanes (policy, own pref, SK custody). Needs the session.
  late final LanesService lanesService;

  /// Result items (`trip`, `drive`, `week`) received from other members' phones.
  late final ResultStore results;
  late final SenderDirectory directory;
  late final ChannelSealer sealer;
  late final SealedQueue queue;
  late final ChannelReceiver receiver;
  late final ChannelSync sync;
  late final PrivateHistory history;
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

  // ---------------------------------------------------------------- circles

  static const String _modeKey = 'modes/v1';

  /// True while the primary circle (the one the server-side screens such as
  /// trips and the weekly summary work on) is Private. Screens that need the
  /// server to read positions show "not available" while this is set.
  static final ValueNotifier<bool> primaryPrivate = ValueNotifier<bool>(false);

  String? _primary;

  /// Private circles an approved, consented OpenFamily server can read. Server-side
  /// screens (trips, weekly summary, admin map) work for them again. Place alerts
  /// stay on the phones' sealed places (the single source of truth for arrivals);
  /// the server only geofences places that exist as server places.
  Set<String> _serverMember = <String>{};
  final Map<String, String> _names = <String, String>{};

  /// Updates the known circle modes and persists them for the background isolate.
  Future<void> setCircles(List<Circle> circles) async {
    _all = circles.map((Circle c) => c.id).toSet();
    _private = circles.where((Circle c) => c.isPrivate).map((Circle c) => c.id).toSet();
    _serverMember = circles.where((Circle c) => c.isPrivate && c.e2eeServerMember).map((Circle c) => c.id).toSet();
    _names
      ..clear()
      ..addEntries(circles.map((Circle c) => MapEntry<String, String>(c.id, c.name)));
    final Iterable<Circle> prim = circles.where((Circle c) => c.isPrimary);
    _primary = prim.isEmpty ? null : prim.first.id;
    primaryPrivate.value = _primary != null && _private.contains(_primary) && !_serverMember.contains(_primary);
    await kv.set(_modeKey, jsonEncode(<String, dynamic>{
      'all': _all.toList(), 'private': _private.toList(), 'server_member': _serverMember.toList(), 'primary': _primary, 'names': _names,
    }));
  }

  Future<void> _loadModes() async {
    if (_all.isNotEmpty) return;
    final String? raw = await kv.get(_modeKey);
    if (raw == null) return;
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
        if (loc['motion_state'] != null && loc['motion_state'] != '') 'mo': loc['motion_state'],
      };

  /// Routes one location report (the body `POST /locations` would carry).
  /// Returns whether the caller must STILL send the plaintext report (only for
  /// standard circles). Sealing failure for a private circle never falls back to
  /// plaintext: the item is simply not sent for that circle.
  Future<bool> routeFix(Map<String, dynamic> locationBody) async {
    final UplinkMode mode = await uplinkMode();
    if (mode == UplinkMode.plaintextOnly) return true;
    unawaited(_sealFix(locationBody));
    return mode == UplinkMode.both;
  }

  static const String _parkedKey = 'parked/v1';

  /// Fixes that could not be sealed right now (vault unreachable from the
  /// background isolate, key not here yet). They stay in app-private storage like
  /// the pre-existing location outbox, and are sealed with their ORIGINAL
  /// timestamp when the app next runs. They are never sent in plaintext.
  Future<void> _park(Map<String, dynamic> loc) async {
    try {
      final String? raw = await kv.get(_parkedKey);
      final List<dynamic> l = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
      l.add(<String, dynamic>{
        'ts': loc['ts'], 'lat': loc['lat'], 'lon': loc['lon'], 'accuracy_meters': loc['accuracy_meters'],
        'altitude_meters': loc['altitude_meters'], 'speed_mps': loc['speed_mps'], 'heading_deg': loc['heading_deg'],
        'battery_pct': loc['battery_pct'], 'motion_state': loc['motion_state'],
      });
      final int cut = clock.now().subtract(const Duration(hours: 12)).millisecondsSinceEpoch;
      final List<dynamic> kept = l.where((dynamic e) {
        final DateTime? t = DateTime.tryParse(((e as Map<String, dynamic>)['ts'] as String?) ?? '');
        return t != null && t.millisecondsSinceEpoch >= cut;
      }).toList();
      await kv.set(_parkedKey, jsonEncode(kept.length > 720 ? kept.sublist(kept.length - 720) : kept));
    } catch (_) {}
  }

  /// Seals parked fixes (oldest first). Returns how many were handled.
  Future<int> drainParked() async {
    final String? raw = await kv.get(_parkedKey);
    if (raw == null || raw.isEmpty) return 0;
    await kv.remove(_parkedKey);
    int n = 0;
    try {
      for (final dynamic e in (jsonDecode(raw) as List<dynamic>)) {
        await _sealFix((e as Map<String, dynamic>).cast<String, dynamic>());
        n++;
      }
    } catch (_) {}
    return n;
  }

  Future<void> _sealFix(Map<String, dynamic> loc) async {
    try {
      final SenderIdentity? me = await _me();
      if (me == null) {
        await _park(loc);
        return;
      }
      final DateTime ts = DateTime.tryParse((loc['ts'] as String?) ?? '')?.toUtc() ?? clock.now();
      final Map<String, dynamic> body = fixBodyFromLocation(loc);
      final double? lat = (loc['lat'] as num?)?.toDouble(), lon = (loc['lon'] as num?)?.toDouble();
      final double? acc = (loc['accuracy_meters'] as num?)?.toDouble();
      for (final String circle in await privateCircles()) {
        // A circle that requires server processing and this member has not consented to:
        // nothing is sealed or sent for it (the server would refuse a phone-lane item anyway).
        if (await lanes.store.status(circle) == LaneStatus.consentRequired) continue;
        final WireItem it = await sealer.seal(me, circle, ChannelPurpose.fix, body, at: ts);
        await queue.enqueue(it);
        if (lat != null && lon != null) {
          await chunker.add(circle, TrackPoint(ts.millisecondsSinceEpoch, lat, lon, acc));
          await history.add(circle, me.userId, <TrackPoint>[TrackPoint(ts.millisecondsSinceEpoch, lat, lon, acc)]);
          await _maybeSealHistory(me, circle);
          await _evaluatePlaces(me, circle, lat, lon, ts, acc);
        }
      }
      await _processOnDevice(me, loc, ts);
      // Batched, jittered upload: do not wake the radio for every fix.
      _scheduleFlush();
    } catch (_) {
      // Never throw into the location pipeline and never fall back to plaintext.
      await _park(loc);
    }
  }

  Timer? _flushTimer;

  void _scheduleFlush({Duration? after}) {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(after ?? const Duration(seconds: 2) + uploadJitter(_rng, max: const Duration(seconds: 3)), () {
      unawaited(flush());
    });
  }

  /// Uploads the queue now (also called on app resume and when the network returns).
  Future<int> flush() async {
    // An opt-out the server has not confirmed yet is sent again here, so it does not depend on the user reopening a screen.
    unawaited(_retryOptOuts());
    try {
      final SenderIdentity? me = await _me();
      if (me == null) return 0;
      return await queue.flush(channel, deviceFor: (_) => me.deviceId, lanes: lanes, onNeedKeySync: (String c) => unawaited(_syncKeys(c)));
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

  Future<void> _processOnDevice(SenderIdentity me, Map<String, dynamic> loc, DateTime ts) async {
    try {
      final Set<String> circles = await phoneOnlyCircles();
      if (circles.isEmpty) return;
      _resultCircles = circles;
      final OnDeviceProcessor p = _proc(me);
      try {
        p.phoneUseEnabled = await DrivingSettings.phoneUseEnabled(reload: false);
      } catch (_) {}
      if (!_processorRestored) {
        _processorRestored = true;
        final List<TrackPoint> past = await trailFor(me.userId, ts.subtract(const Duration(hours: 6)), ts);
        await p.restore(<Fix>[
          for (final TrackPoint t in past)
            if (t.tsMs < ts.millisecondsSinceEpoch)
              Fix(tsUs: t.tsMs * 1000, lat: t.lat, lon: t.lon, accuracyM: t.accuracy ?? 0, deviceId: me.deviceId)
        ]);
      }
      final double? lat = (loc['lat'] as num?)?.toDouble(), lon = (loc['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      await p.onFix(Fix(
          tsUs: ts.microsecondsSinceEpoch,
          lat: lat,
          lon: lon,
          speedMps: (loc['speed_mps'] as num?)?.toDouble(),
          accuracyM: (loc['accuracy_meters'] as num?)?.toDouble() ?? 0,
          deviceId: me.deviceId));
      await p.tickWeekly();
    } catch (_) {
      // Processing is best effort and must never disturb the location pipeline.
    }
  }

  Future<void> _maybeSealHistory(SenderIdentity me, String circle) async {
    final Map<String, dynamic>? chunk = await chunker.takeIfDue(circle);
    if (chunk == null) return;
    final WireItem it = await sealer.seal(me, circle, ChannelPurpose.history, chunk);
    await queue.enqueue(it);
  }

  /// Seals an arbitrary item (check-in/SOS position, place, event).
  Future<void> sendItem(String circleId, String purpose, Map<String, dynamic> body, {bool flushNow = true}) async {
    final SenderIdentity? me = await _me();
    if (me == null) throw const ItemRejected(ItemRejection.noKey);
    await queue.enqueue(await sealer.seal(me, circleId, purpose, body));
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
        final SealedPlace? p = SealedPlace.fromJson(<String, dynamic>{
          'id': E2ee.newUuid(), 'name': e['name'], 'lat': e['lat'], 'lon': e['lon'],
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
    await sendItem(circleId, ChannelPurpose.place, p.toJson());
    book(circleId).apply(p, clock.now().millisecondsSinceEpoch);
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
      'places': b.places.map((SealedPlace p) => p.toJson()).toList(),
    }));
  }

  /// Loads persisted places (call before evaluating, e.g. in the background isolate).
  Future<void> loadBook(String circleId) async {
    if (_books.containsKey(circleId)) return;
    final String? raw = await kv.get(_bookKey(circleId));
    final PlaceBook b = book(circleId);
    if (raw == null) return;
    try {
      for (final dynamic j in ((jsonDecode(raw) as Map<String, dynamic>)['places'] as List<dynamic>)) {
        final SealedPlace? p = SealedPlace.fromJson(j as Map<String, dynamic>);
        if (p != null) b.apply(p, 1);
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
    } catch (_) {}
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
    await drainParked();
    await flush();
    await tickPlaces();
    for (final String id in await privateCircles()) {
      try {
        await lanesService.maintain(id);
      } catch (_) {
        // offline or an older server: the last verified lane facts stay in force
      }
      try {
        await catchUp(id);
      } catch (_) {
        // offline: the next resume or socket frame retries
      }
    }
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
    return sync.catchUp(circleId, onItem: _apply);
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

  Future<void> _rememberUser(String circleId, String userId) async {
    final String raw = await kv.get(_usersKey(circleId)) ?? '';
    final Set<String> s = raw.isEmpty ? <String>{} : raw.split(',').toSet();
    if (s.add(userId)) await kv.set(_usersKey(circleId), s.join(','));
  }

  /// Re-emits each member's newest decrypted position as a map frame. The
  /// roster REST/`members` snapshot of a Private circle carries no positions (the
  /// server has none), so this restores "last known" after every refresh.
  Future<void> replayLatest() async {
    final Set<String> privs = await privateCircles();
    if (privs.isEmpty) return; // standard users: no identity lookup, no request
    final SenderIdentity? me = await _me();
    for (final String circle in privs) {
      final String raw = await kv.get(_usersKey(circle)) ?? '';
      for (final String user in raw.isEmpty ? <String>[] : raw.split(',')) {
        if (me != null && user == me.userId) continue;
        final List<TrackPoint> pts = await history.range(
            circle, user, clock.now().subtract(const Duration(days: 7)), clock.now().add(const Duration(days: 1)));
        if (pts.isEmpty) continue;
        final TrackPoint p = pts.last;
        onMemberFrame?.call(<String, dynamic>{
          'type': 'location', 'user_id': user, 'circle_id': circle, 'lat': p.lat, 'lon': p.lon,
          'ts': DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true).toIso8601String(),
          'accuracy_meters': p.accuracy,
        });
      }
    }
  }

  Future<void> _apply(ReceivedItem r) async {
    final SenderIdentity? me = await _me();
    final bool mine = me != null && r.userId == me.userId;
    switch (r.purpose) {
      case ChannelPurpose.fix:
        final double? lat = (r.body['lat'] as num?)?.toDouble(), lon = (r.body['lon'] as num?)?.toDouble();
        if (lat == null || lon == null || lat < -90 || lat > 90 || lon < -180 || lon > 180) return;
        await history.add(r.circleId, r.userId, <TrackPoint>[
          TrackPoint(r.ts.millisecondsSinceEpoch, lat, lon, (r.body['acc'] as num?)?.toDouble())
        ]);
        if (mine) return;
        await _rememberUser(r.circleId, r.userId);
        onMemberFrame?.call(<String, dynamic>{
          'type': 'location',
          'user_id': r.userId,
          'circle_id': r.circleId,
          'lat': lat,
          'lon': lon,
          'ts': r.ts.toIso8601String(),
          'last_seen_at': clock.now().toIso8601String(),
          'battery_pct': r.body['bat'],
          'speed_mps': r.body['spd'],
          'heading_deg': r.body['hdg'],
          'motion_state': r.body['mo'],
          'accuracy_meters': r.body['acc'],
        });
      case ChannelPurpose.history:
        await history.add(r.circleId, r.userId, HistoryChunker.parse(r.body));
        if (!mine) await _rememberUser(r.circleId, r.userId);
      case ChannelPurpose.place:
        final SealedPlace? p = SealedPlace.fromJson(r.body);
        if (p == null) return;
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
          final String place = (r.body['name'] as String?) ?? 'a place';
          final String who = nameOf?.call(r.userId) ?? 'Someone';
          await notify('OpenFamily', placeEventText(who, place, r.body['a'] == 'enter'));
        }
      case ChannelPurpose.trip:
      case ChannelPurpose.drive:
      case ChannelPurpose.week:
        // Figures a member's phone computed. Stored under the VERIFIED author.
        await results.put(r);
      case ChannelPurpose.checkin:
        if (mine) return;
        final String who = nameOf?.call(r.userId) ?? 'Someone';
        final String kind = (r.body['k'] as String?) ?? 'checkin';
        final double? la = (r.body['lat'] as num?)?.toDouble(), lo = (r.body['lon'] as num?)?.toDouble();
        if (la != null && lo != null && la >= -90 && la <= 90 && lo >= -180 && lo <= 180) {
          await history.add(r.circleId, r.userId, <TrackPoint>[TrackPoint(r.ts.millisecondsSinceEpoch, la, lo)]);
          await _rememberUser(r.circleId, r.userId);
          onMemberFrame?.call(<String, dynamic>{
            'type': 'location', 'user_id': r.userId, 'circle_id': r.circleId, 'lat': la, 'lon': lo,
            'ts': r.ts.toIso8601String(), 'last_seen_at': clock.now().toIso8601String(),
          });
        }
        if (clock.now().difference(r.ts) <= const Duration(minutes: 30)) {
          // The wording carries no position; open the app to see it.
          final String what = kind == 'sos' ? 'sent an SOS' : (kind == 'help' ? 'asked for help' : 'checked in');
          await notify('OpenFamily', '$who $what');
        }
      default:
        break;
    }
  }
}
