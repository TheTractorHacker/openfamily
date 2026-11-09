import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'item_open_job.dart';
import 'lanes_wire.dart';
import '../offline/offline_errors.dart';

// Phase 2 of docs/design/E2EE.md: the encrypted channel of a Private circle.
//
// Everything here is pure Dart over small interfaces (key store, directory,
// server API, key/value store, clock) so it is unit-testable without a server.
//
// Layers, innermost first:
//   body (JSON, purpose specific)
//   -> envelope  v(1) || seq(8) || ts_ms(8) || sig(64) || body      (signed by the sender DEVICE key)
//   -> Pad       length(2) || envelope || zeros (bucketed)
//   -> E2ee.seal XChaCha20-Poly1305 under the circle key, AAD binds circle, epoch, sender device, purpose
// The signature covers circle, epoch, device, purpose, seq, ts and body, so a member who shares the
// circle key still cannot forge a position "from" someone else's phone.

/// The purposes of the encrypted channel (the server only accepts these).
class ChannelPurpose {
  ChannelPurpose._();
  static const String fix = 'fix';
  static const String event = 'event';
  static const String place = 'place';
  static const String history = 'history';
  static const String checkin = 'checkin';
  static const String chat = 'chat';

  /// Result items of on-device processing (PRIVACY_PROCESSING 8.4): a finished
  /// trip, the driving figures of a trip, a week summary. Sealed in the AUTHOR's lane.
  static const String trip = 'trip';
  static const String drive = 'drive';
  static const String week = 'week';
  static const List<String> all = <String>[fix, event, place, history, checkin, chat, trip, drive, week];

  /// The purposes that carry on-device processing results.
  static const List<String> results = <String>[trip, drive, week];

  /// Largest padded plaintext the server accepts per purpose (mirrors the Go side).
  static const Map<String, int> maxBucket = <String, int>{
    fix: 1024, event: 1024, checkin: 1024, chat: 8192, place: 4096, history: 69632,
    trip: 1024, drive: 4096, week: 1024,
  };
}

/// Signature domain of the item envelope.
const String _sigDomain = 'OFE2EE2-ITEM';

Uint8List _i64(int v) {
  final ByteData d = ByteData(8)..setUint64(0, v, Endian.big);
  return d.buffer.asUint8List();
}


/// The bytes the sender device signs.
Uint8List itemSignedMessage({
  required String circleId,
  required int epoch,
  required String deviceId,
  required String purpose,
  required int seq,
  required int tsMs,
  required List<int> body,
}) {
  return E2ee.cat(<List<int>>[
    utf8.encode('$_sigDomain\x00'),
    utf8.encode(circleId),
    E2ee.u32(epoch),
    utf8.encode(deviceId),
    <int>[utf8.encode(purpose).length],
    utf8.encode(purpose),
    _i64(seq),
    _i64(tsMs),
    body,
  ]);
}

/// Signs [body] as the sender device and returns the padded envelope that gets sealed.
Future<Uint8List> buildPaddedEnvelope({
  required Uint8List edSeed,
  required String circleId,
  required int epoch,
  required String deviceId,
  required String purpose,
  required int seq,
  required int tsMs,
  required Uint8List body,
}) async {
  final Uint8List sig = await E2ee.sign(
      edSeed, itemSignedMessage(circleId: circleId, epoch: epoch, deviceId: deviceId, purpose: purpose, seq: seq, tsMs: tsMs, body: body));
  return E2ee.pad(E2ee.cat(<List<int>>[<int>[1], _i64(seq), _i64(tsMs), sig, body]));
}

/// A sealed item as it goes to / comes from the server.
///
/// [epoch] is the generation of the key of [line]: the circle key epoch for
/// the phone line, the SK generation for the server line.
class WireItem {
  const WireItem({
    required this.circleId,
    required this.deviceId,
    required this.seq,
    required this.purpose,
    required this.epoch,
    required this.sizeBucket,
    required this.ciphertext,
    this.id,
    this.receivedAt,
    this.line = E2ee.linePhone,
    this.declaredLine,
    this.twin,
  });

  final String circleId;
  final String deviceId;
  final int seq;
  final String purpose;
  final int epoch;
  final int sizeBucket;
  final Uint8List ciphertext;

  /// Server cursor (null before upload).
  final int? id;
  final DateTime? receivedAt;

  /// Key line this item was sealed under (own items: authoritative).
  final int line;

  /// The `key_line` the SERVER reported for a downloaded item (null when it
  /// reported none). Routing metadata, not trust: the receiver checks it
  /// against the signed header and rejects a mismatch.
  final int? declaredLine;

  /// Queue only: the same item sealed under the phone line (same seq and time),
  /// kept so a server-line item can be turned into a phone-line item without
  /// ever storing plaintext if the member opts out before the upload.
  final WireItem? twin;

  Map<String, dynamic> toUpload() => <String, dynamic>{
        'seq': seq,
        'purpose': purpose,
        'epoch': epoch,
        'size_bucket': sizeBucket,
        'ciphertext': E2ee.b64(ciphertext),
        // Only the server line is labelled: a phone-line item is byte-for-byte
        // what an older app uploads (no new field, old servers stay happy).
        if (line == E2ee.lineServer) LanesFields.keyLine: E2ee.lineName(line),
      };

  Map<String, dynamic> toStore() => <String, dynamic>{
        'c': circleId, 'd': deviceId, 's': seq, 'p': purpose, 'e': epoch, 'b': sizeBucket,
        'ct': E2ee.b64(ciphertext),
        if (line != E2ee.linePhone) 'l': line,
        if (twin != null) 'tw': twin!.toStore(),
      };

  factory WireItem.fromStore(Map<String, dynamic> j) => WireItem(
        circleId: j['c'] as String,
        deviceId: j['d'] as String,
        seq: (j['s'] as num).toInt(),
        purpose: j['p'] as String,
        epoch: (j['e'] as num).toInt(),
        sizeBucket: (j['b'] as num).toInt(),
        ciphertext: E2ee.unb64(j['ct'] as String),
        line: E2ee.validLine((j['l'] as num?)?.toInt() ?? E2ee.linePhone) ? ((j['l'] as num?)?.toInt() ?? E2ee.linePhone) : throw const FormatException('line'),
        twin: j['tw'] is Map<String, dynamic> ? WireItem.fromStore(j['tw'] as Map<String, dynamic>) : null,
      );

  /// Parses a REST item or a WebSocket `e2ee_item` frame. Null if malformed,
  /// including an unknown `key_line` (fail closed).
  static WireItem? fromServer(Map<String, dynamic> j) {
    try {
      final Object? kl = j[LanesFields.keyLine];
      final int? declared = kl == null ? null : E2ee.parseLine(kl as String);
      return WireItem(
        circleId: j['circle_id'] as String,
        deviceId: j['device_id'] as String,
        seq: (j['seq'] as num).toInt(),
        purpose: j['purpose'] as String,
        epoch: (j['epoch'] as num).toInt(),
        sizeBucket: (j['size_bucket'] as num).toInt(),
        ciphertext: E2ee.unb64(j['ciphertext'] as String),
        id: (j['id'] as num?)?.toInt(),
        receivedAt: j['received_at'] is String ? DateTime.tryParse(j['received_at'] as String)?.toUtc() : null,
        declaredLine: declared,
        line: declared ?? E2ee.linePhone,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How an item should be presented: derived on THIS phone from the verified
/// header and the signed log, never from a server flag.
enum ProcessingBadge {
  /// Sealed under the phone key: the server cannot read it.
  phoneOnly,

  /// Sealed under the server key by a member whose signed pref says server.
  serverAssisted,

  /// Sealed under the server key but the author's signed pref does not confirm it.
  unverified,
}

/// A verified, decrypted item.
class ReceivedItem {
  const ReceivedItem({
    required this.circleId,
    required this.deviceId,
    required this.userId,
    required this.seq,
    required this.purpose,
    required this.epoch,
    required this.ts,
    required this.body,
    this.cursor,
    this.line = E2ee.linePhone,
    this.verdict = LaneVerdict.consistent,
  });

  final String circleId;
  final String deviceId;

  /// Key line the item was sealed under, taken from the VERIFIED header.
  final int line;

  /// For a server-line item: whether the author's signed pref confirms it.
  final LaneVerdict verdict;

  ProcessingBadge get badge => line == E2ee.linePhone
      ? ProcessingBadge.phoneOnly
      : (verdict == LaneVerdict.consistent ? ProcessingBadge.serverAssisted : ProcessingBadge.unverified);

  /// The account that owns the (verified, approved) sender device.
  final String userId;
  final int seq;
  final String purpose;
  final int epoch;

  /// The sender's signed timestamp (UTC). Not the server's.
  final DateTime ts;
  final Map<String, dynamic> body;
  final int? cursor;
}

/// Result of verifying one item of a batch: the item, or why it was refused.
class ItemOutcome {
  const ItemOutcome.ok(ReceivedItem this.item) : rejected = null;
  const ItemOutcome.reject(ItemRejected this.rejected) : item = null;
  final ReceivedItem? item;
  final ItemRejected? rejected;
}

/// Why an incoming item was refused (never shown to the user as content).
enum ItemRejection {
  malformed,
  noKey,
  badCipher,
  badPadding,
  unknownSender,
  senderNotMember,
  badSignature,
  badEnvelope,
  duplicate,
  epochRollback,
  clockSkew,

  /// The server's `key_line` differs from the signed header (cross-line confusion / relabelling).
  laneMismatch,
}

class ItemRejected implements Exception {
  const ItemRejected(this.reason);
  final ItemRejection reason;
  @override
  String toString() => 'ItemRejected($reason)';
}

// ---------------------------------------------------------------- interfaces

/// Circle keys held by this phone (backed by the E2EE vault in the app).
abstract class ChannelKeys {
  Future<Uint8List?> circleKey(String circleId, int epoch);

  /// Highest epoch for which this phone holds a key (0 if none).
  Future<int> latestEpoch(String circleId);
}

/// Server-line keys (SK) held by this phone. A separate interface so older
/// [ChannelKeys] implementations (and an "old app" simulation) need no change.
abstract class ServerKeys {
  Future<Uint8List?> serverKey(String circleId, int gen);
  Future<int> latestServerGen(String circleId);
}

/// What lane this phone seals under for one circle. [skGen] is the SK
/// generation to seal under when [line] is the server line.
class LaneChoice {
  const LaneChoice(this.line, [this.skGen = 0]);
  static const LaneChoice phone = LaneChoice(E2ee.linePhone);
  final int line;
  final int skGen;
}

/// The verified lane facts the channel needs. Backed by `LanesService` (which
/// verifies signatures and the transparency log and persists the result).
/// EVERY method fails closed: unknown, unverifiable or erroring means the
/// phone lane / "not confirmed".
abstract class LaneSource {
  /// This member's own effective lane for [circleId] (from their own signed pref).
  Future<LaneChoice> ownLane(String circleId);

  /// Whether the server lane may be USED by this phone right now (own pref
  /// server, admin policy on). Read again at upload time.
  Future<bool> serverLaneAllowed(String circleId);

  /// The verified pref history of [userId] (for badge decisions on received items).
  Future<List<PrefEntry>> prefsOf(String circleId, String userId);

  /// Whether the verified admin policy has server assistance on.
  Future<bool> serverAssistOn(String circleId);
}

/// Optional extra of a [ChannelKv]: a lock shared by every isolate (and process) that uses the store, so a
/// read-modify-write cannot interleave with another one. Stores without it rely on the version check alone.
abstract class LockableKv {
  Future<T> withLock<T>(String name, Future<T> Function() body);
}

/// Optional extra of a [LaneSource]: a counter that changes whenever the stored
/// lane facts of a circle change. The upload queue reads it again immediately
/// before each request and starts over when it moved.
abstract class VersionedLaneSource {
  Future<int> laneVersion(String circleId);
}

/// Who may send in a circle. Backed by the circle's E2EE state (the verified key
/// log): a sender must be an active (or, for older items, once active) APPROVED
/// device of a current member.
abstract class SenderDirectory {
  Future<DeviceKey?> sender(String circleId, String deviceId, {bool refresh = false});
}

/// Small persistent key/value store (SharedPreferences in the app).
abstract class ChannelKv {
  Future<String?> get(String key);

  /// Like [get] but never from a cache: another isolate (the background
  /// location service) may have written the value since. Lane facts and the
  /// queue are read this way.
  Future<String?> getFresh(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class MemoryKv implements ChannelKv {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<String?> getFresh(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

class BatchResult {
  const BatchResult(this.seq, this.status, {this.error});
  final int seq;

  /// stored | duplicate | rejected
  final String status;
  final String? error;
}

class Page {
  const Page(this.items, this.nextCursor, this.hasMore);
  final List<WireItem> items;
  final int nextCursor;
  final bool hasMore;
}

/// Server calls of the channel. Everything on the wire is ciphertext.
abstract class ChannelApi {
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> items);
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200});
}

class Clock {
  const Clock();
  DateTime now() => DateTime.now().toUtc();
}

// -------------------------------------------------------------------- sender

/// This phone's sending identity: the device id and Ed25519 seed. The seed is
/// held only for the duration of a call.
class SenderIdentity {
  const SenderIdentity(this.deviceId, this.edSeed, this.userId);
  final String deviceId;
  final Uint8List edSeed;
  final String userId;
}

/// Seals payloads for one circle and keeps the per-(circle, device) sequence.
///
/// Lane selection (PRIVACY_PROCESSING 3.2): without [lanes] and [serverKeys]
/// this is exactly the v1 sealer (phone line only) which is what an old app
/// does. With them, each item is sealed under the line of THIS member's own
/// signed pref, read at seal time. Any doubt means the phone line.
class ChannelSealer {
  ChannelSealer({required this.keys, required this.kv, this.clock = const Clock(), this.lanes, this.serverKeys});

  final ChannelKeys keys;
  final ChannelKv kv;
  final Clock clock;
  final LaneSource? lanes;
  final ServerKeys? serverKeys;

  /// Items that were meant for the server line but sealed under the phone line
  /// because no usable SK was held (diagnostics; never a privacy loss).
  int laneFallbacks = 0;

  /// Serialises seq allocation within this isolate.
  Future<void> _lock = Future<void>.value();

  String _seqKey(String circle, String device) => 'seq/$circle/$device';

  Future<int> _nextSeq(String circle, String device) {
    final Completer<int> c = Completer<int>();
    _lock = _lock.then((_) async {
      try {
        // Fresh read: the background isolate seals with the same device and counter. A value cached in this
        // isolate would hand out a seq the other one already used, and the server drops the second as a duplicate.
        final int cur = int.tryParse(await kv.getFresh(_seqKey(circle, device)) ?? '') ?? 0;
        await kv.set(_seqKey(circle, device), '${cur + 1}');
        c.complete(cur + 1);
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  Future<LaneChoice> _choice(String circleId) async {
    final LaneSource? l = lanes;
    if (l == null || serverKeys == null) return LaneChoice.phone;
    try {
      final LaneChoice c = await l.ownLane(circleId);
      if (c.line == E2ee.lineServer && c.skGen >= 1 && await l.serverLaneAllowed(circleId)) return c;
    } catch (_) {}
    return LaneChoice.phone;
  }

  /// Seals [body] as [purpose] for [circleId] under the lane of this member's
  /// signed pref. Phone lane: the newest epoch key this phone holds; server
  /// lane: the SK generation of the verified policy (plus a phone-line twin for
  /// the queue). Throws [ItemRejected] (noKey) when no key is held at all: the
  /// caller must NOT fall back to plaintext.
  Future<WireItem> seal(
    SenderIdentity me,
    String circleId,
    String purpose,
    Map<String, dynamic> body, {
    DateTime? at,
    int? maxEpoch,
  }) async {
    // Chat is sealed under the phone key line ONLY, whatever this member's lane is:
    // never wrapped to the server device, never readable by the sidecar.
    // Places are too: they belong to the whole circle, and only phones that hold the server key can open a
    // server-line item, so a place sealed in an admin's server lane stayed invisible to every other member
    // (the server does not use places; it never imports them).
    // Events and check-ins (arrivals, departures, SOS) are the same: members read them, the server never does (it
    // asks for fix and history items only), so a server-lane copy only hid them from every member without the
    // server key (no arrival or SOS notification for them).
    final bool phoneLineOnly = purpose == ChannelPurpose.chat ||
        purpose == ChannelPurpose.place ||
        purpose == ChannelPurpose.event ||
        purpose == ChannelPurpose.checkin;
    final LaneChoice choice = phoneLineOnly ? LaneChoice.phone : await _choice(circleId);
    final int tsMs = (at ?? clock.now()).toUtc().millisecondsSinceEpoch;
    final Uint8List bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    if (choice.line == E2ee.lineServer) {
      final Uint8List? sk = await serverKeys!.serverKey(circleId, choice.skGen);
      if (sk != null) return _sealServer(me, circleId, purpose, bodyBytes, tsMs, choice.skGen, sk, maxEpoch);
      laneFallbacks++;
    }
    return _sealPhone(me, circleId, purpose, bodyBytes, tsMs, maxEpoch, null);
  }

  Future<WireItem> _sealPhone(SenderIdentity me, String circleId, String purpose, Uint8List bodyBytes, int tsMs, int? maxEpoch, int? seqOverride) async {
    int epoch = await keys.latestEpoch(circleId);
    if (maxEpoch != null && epoch > maxEpoch) epoch = maxEpoch;
    if (epoch < 1) throw const ItemRejected(ItemRejection.noKey);
    final Uint8List? key = await keys.circleKey(circleId, epoch);
    if (key == null) throw const ItemRejected(ItemRejection.noKey);
    final int seq = seqOverride ?? await _nextSeq(circleId, me.deviceId);
    final Uint8List padded = await buildPaddedEnvelope(
        edSeed: me.edSeed, circleId: circleId, epoch: epoch, deviceId: me.deviceId, purpose: purpose, seq: seq, tsMs: tsMs, body: bodyBytes);
    final int cap = ChannelPurpose.maxBucket[purpose] ?? 1024;
    if (padded.length > cap) throw const ItemRejected(ItemRejection.malformed);
    final Uint8List ct = await E2ee.seal(key, circleId, epoch, me.deviceId, purpose, padded);
    return WireItem(
        circleId: circleId, deviceId: me.deviceId, seq: seq, purpose: purpose, epoch: epoch, sizeBucket: padded.length, ciphertext: ct);
  }

  Future<WireItem> _sealServer(SenderIdentity me, String circleId, String purpose, Uint8List bodyBytes, int tsMs, int gen, Uint8List sk, int? maxEpoch) async {
    final int padded = E2ee.padBucket(1 + 8 + 8 + E2ee.sigLen + bodyBytes.length);
    if (padded > (ChannelPurpose.maxBucket[purpose] ?? 1024)) throw const ItemRejected(ItemRejection.malformed);
    final int seq = await _nextSeq(circleId, me.deviceId);
    final Uint8List ct = await E2ee.sealItemV2(sk, circleId, E2ee.lineServer, gen, me.deviceId, me.edSeed, purpose, seq, tsMs, bodyBytes);
    // The phone-line twin (same seq, same time) lets the queue re-seal on an
    // opt-out without keeping plaintext. No CK held: no twin, the queue drops instead.
    WireItem? twin;
    try {
      twin = await _sealPhone(me, circleId, purpose, bodyBytes, tsMs, maxEpoch, seq);
    } on ItemRejected {
      twin = null;
    }
    return WireItem(
        circleId: circleId, deviceId: me.deviceId, seq: seq, purpose: purpose, epoch: gen, sizeBucket: padded, ciphertext: ct,
        line: E2ee.lineServer, twin: twin);
  }
}

// -------------------------------------------------------------------- queue

/// Store-and-forward queue of sealed items (they are sealed before they are
/// queued, so nothing readable is ever on disk or in memory longer than needed).
/// Retries are idempotent on the server by (circle, device, seq).
class SealedQueue {
  SealedQueue({required this.kv, this.clock = const Clock(), this.maxItems = 2000, this.maxAge = const Duration(hours: 48)});

  final ChannelKv kv;
  final Clock clock;
  final int maxItems;

  /// Items older than this (by enqueue time) are dropped, except places/events.
  final Duration maxAge;

  static const String _key = 'queue/v1';
  static final Random _rng = Random.secure();
  Future<void> _lock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() f) {
    final Completer<T> c = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  /// The stored queue: a versioned envelope `{v, w, i}` (older builds stored a bare list).
  Future<({int ver, String w, List<Map<String, dynamic>> items})> _read() async {
    final String? raw = await kv.getFresh(_key);
    if (raw == null || raw.isEmpty) return (ver: 0, w: '', items: <Map<String, dynamic>>[]);
    try {
      final Object? d = jsonDecode(raw);
      if (d is List<dynamic>) return (ver: 0, w: '', items: d.cast<Map<String, dynamic>>());
      if (d is Map<String, dynamic>) {
        return (ver: (d['v'] as num).toInt(), w: (d['w'] as String?) ?? '', items: (d['i'] as List<dynamic>).cast<Map<String, dynamic>>());
      }
    } catch (_) {}
    return (ver: 0, w: '', items: <Map<String, dynamic>>[]);
  }

  static final RegExp _headRe = RegExp(r'^\{"v":(\d+),"w":"([^"]*)"');

  /// Only the version and writer id of the stored queue. They are the first two fields of the record we write, so
  /// they are read with a pattern instead of decoding the whole (up to megabytes of) queue twice more per change.
  /// Anything that does not look like our record falls back to the full read.
  Future<({int ver, String w})> _head() async {
    final String? raw = await kv.getFresh(_key);
    if (raw != null) {
      final Match? m = _headRe.firstMatch(raw);
      if (m != null) return (ver: int.parse(m.group(1)!), w: m.group(2)!);
    }
    final snap = await _read();
    return (ver: snap.ver, w: snap.w);
  }

  /// Read-modify-write that survives a second writer (the background location
  /// isolate shares this store). SharedPreferences has no atomic compare-and-swap, so:
  /// read fresh, apply [op], look at the version again right before the write
  /// (start over if it moved), write `{v+1, writer-id}`, read back and start over
  /// if another writer's record is there instead. [op] must be idempotent.
  Future<T> _mutate<T>(Future<T> Function(List<Map<String, dynamic>> l) op) => _locked(() {
        final ChannelKv store = kv;
        return store is LockableKv ? (store as LockableKv).withLock('queue', () => _mutateOnce(op)) : _mutateOnce(op);
      });

  Future<T> _mutateOnce<T>(Future<T> Function(List<Map<String, dynamic>> l) op) async {
        T? result;
        for (int attempt = 0; attempt < 8; attempt++) {
          final snap = await _read();
          result = await op(snap.items);
          final int cur = (await _head()).ver;
          if (cur != snap.ver && attempt < 7) continue;
          final String w = '${_rng.nextInt(1 << 30)}-${clock.now().microsecondsSinceEpoch}';
          await kv.set(_key, jsonEncode(<String, dynamic>{'v': snap.ver + 1, 'w': w, 'i': snap.items}));
          final back = await _head();
          if (back.ver == snap.ver + 1 && back.w == w) return result as T;
        }
        return result as T;
      }

  Future<List<Map<String, dynamic>>> _load() async => (await _read()).items;

  Future<void> enqueue(WireItem item) => _mutate((List<Map<String, dynamic>> l) async {
        final String k = '${item.circleId}/${item.deviceId}/${item.seq}';
        if (l.any((Map<String, dynamic> m) => '${m['c']}/${m['d']}/${m['s']}' == k)) return;
        l.add(<String, dynamic>{...item.toStore(), 'q': clock.now().millisecondsSinceEpoch, 'n': 0});
        _prune(l);
      });

  /// What the queue may never drop to make room or for age: things a person did on purpose
  /// (check-ins incl. SOS positions, chat) and the places/events that change state for others.
  static bool _kept(Map<String, dynamic> m) {
    final Object? p = m['p'];
    return p == ChannelPurpose.checkin || p == ChannelPurpose.chat || p == ChannelPurpose.place || p == ChannelPurpose.event;
  }

  void _prune(List<Map<String, dynamic>> l) {
    final int cut = clock.now().subtract(maxAge).millisecondsSinceEpoch;
    l.removeWhere((Map<String, dynamic> m) => (m['q'] as int) < cut && !_kept(m));
    while (l.length > maxItems) {
      // Drop the oldest live fix first, then the oldest other droppable item (history, results).
      // Check-ins, chat, places and events are never displaced: the queue may exceed the cap
      // by those instead of losing something a person wrote.
      int idx = l.indexWhere((Map<String, dynamic> m) => m['p'] == ChannelPurpose.fix);
      if (idx < 0) idx = l.indexWhere((Map<String, dynamic> m) => !_kept(m));
      if (idx < 0) break;
      l.removeAt(idx);
    }
  }

  Future<int> length() => _locked(() async => (await _load()).length);

  Future<List<WireItem>> peek() => _locked(() async => (await _load()).map(WireItem.fromStore).toList());

  /// Sends the queue, at most [batchSize] per request, newest fixes first is NOT
  /// used: order is preserved so seq stays monotonic per device. Returns the
  /// number of items the server now has (stored or duplicate). Stops at the first
  /// transport failure; permanently rejected items are dropped.
  ///
  /// Server-line items are only ever sent while [lanes] confirms, RIGHT BEFORE
  /// each request, that this member's own signed pref still says server (and
  /// the policy is still on). Otherwise the item is replaced by its phone-line
  /// twin or dropped (see [reconcileLanes]). Without a [lanes] source no
  /// server-line item is ever sent.
  Future<int> flush(ChannelApi api,
      {required String Function(String circleId) deviceFor, int batchSize = 50, LaneSource? lanes, void Function(String circleId)? onNeedKeySync}) async {
    int delivered = 0;
    while (true) {
      await reconcileLanes(lanes);
      final List<Map<String, dynamic>> all = await _locked(_load);
      if (all.isEmpty) return delivered;
      // One request is for one circle + device.
      final Map<String, dynamic> first = all.first;
      final String circle = first['c'] as String;
      final String device = first['d'] as String;
      final List<Map<String, dynamic>> batch = all
          .where((Map<String, dynamic> m) => m['c'] == circle && m['d'] == device)
          .take(batchSize)
          .toList();
      final List<WireItem> items = batch.map(WireItem.fromStore).toList();
      // Last look at the pref before the bytes leave the phone. The lane record is
      // read fresh (not from a cache) and its version must not move between the check
      // and the request; if it did, start over (the loop reconciles first).
      final int ver0 = await _laneVersion(lanes, circle);
      if (items.any((WireItem i) => i.line == E2ee.lineServer) && !(lanes != null && await _allowsServer(lanes, circle))) {
        continue; // the next loop turn reconciles (twin or drop) before anything is sent
      }
      if (ver0 != await _laneVersion(lanes, circle)) continue;
      List<BatchResult> results;
      try {
        results = await api.postBatch(circle, device, items);
      } on UploadUnavailable {
        return delivered; // no connection / session being renewed: keep everything, and do NOT count a failure
      } on PermanentUploadError catch (e) {
        // e.g. circle no longer private / device revoked: drop the batch, it can never succeed.
        // Not silent: the diagnostics screen tells the user that the relay refused updates, and why.
        await noteUndelivered(circle, 'http_${e.message}');
        await _remove(batch, <int>{for (final WireItem i in items) i.seq});
        continue;
      } catch (e) {
        // Offline or server trouble (5xx): keep everything, try later. A server that is down does not make
        // the items bad, so only an answer that is not a connection problem counts against the batch.
        if (!isOfflineError(e)) await _bump(batch);
        return delivered;
      }
      final Set<int> done = <int>{};
      bool needSync = false;
      for (final BatchResult r in results) {
        if (r.status != 'rejected') {
          // stored/duplicate: the server has it.
          done.add(r.seq);
          delivered++;
          continue;
        }
        final String code = r.error ?? '';
        if (transientRejections.contains(code)) {
          // An epoch problem a key sync may fix: keep the item, sync keys, retry later (bounded by the retry counter).
          needSync = true;
          continue;
        }
        // Permanent. A required_server refusal is NOT silent: the user is told the data was not delivered.
        if (code == 'required_server') await noteUndelivered(circle, code);
        done.add(r.seq);
      }
      if (needSync) onNeedKeySync?.call(circle);
      // Items the server did not mention stay queued.
      await _remove(batch, done);
      if (done.isEmpty) {
        await _bump(batch);
        return delivered;
      }
    }
  }

  /// Rejection codes of the relay that a key sync can cure; the item stays queued.
  static const Set<String> transientRejections = <String>{'legacy_epoch_closed', 'bad_epoch'};

  static Future<int> _laneVersion(LaneSource? lanes, String circle) async {
    try {
      return lanes is VersionedLaneSource ? await (lanes as VersionedLaneSource).laneVersion(circle) : 0;
    } catch (_) {
      return -1;
    }
  }

  String _undeliveredKey(String circle) => 'queue/undelivered/$circle';

  /// Remembers that the relay refused an item for good ([code]); shown to the user.
  Future<void> noteUndelivered(String circle, String code) async {
    int n = 0;
    try {
      n = ((jsonDecode(await kv.getFresh(_undeliveredKey(circle)) ?? '{}') as Map<String, dynamic>)['n'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    await kv.set(_undeliveredKey(circle), jsonEncode(<String, dynamic>{'n': n + 1, 'code': code, 'at': clock.now().millisecondsSinceEpoch}));
  }

  /// How many items of [circle] were refused for good, and why; null when none.
  Future<({int count, String code})?> undelivered(String circle) async {
    try {
      final Map<String, dynamic> m = jsonDecode(await kv.getFresh(_undeliveredKey(circle)) ?? '') as Map<String, dynamic>;
      final int n = (m['n'] as num).toInt();
      return n > 0 ? (count: n, code: (m['code'] as String?) ?? '') : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUndelivered(String circle) => kv.remove(_undeliveredKey(circle));

  static Future<bool> _allowsServer(LaneSource lanes, String circle) async {
    try {
      return await lanes.serverLaneAllowed(circle);
    } catch (_) {
      return false;
    }
  }

  /// Re-seals or drops queued server-line items whose circle no longer allows
  /// the server lane (opt-out, policy off, SK missing, no lane source). An item
  /// with a phone-line twin is replaced by the twin IN PLACE (same circle,
  /// device and seq, so ordering and idempotency hold); one without is dropped.
  /// Nothing is ever re-sealed from plaintext: none is stored. Returns how many
  /// items were changed. Call it whenever a pref changes (and flush calls it
  /// before every request).
  Future<int> reconcileLanes(LaneSource? lanes) => _mutate((List<Map<String, dynamic>> l) async {
        final Map<String, bool> allowed = <String, bool>{};
        int changed = 0;
        for (int i = l.length - 1; i >= 0; i--) {
          final Map<String, dynamic> m = l[i];
          if (((m['l'] as num?)?.toInt() ?? E2ee.linePhone) != E2ee.lineServer) continue;
          final String c = m['c'] as String;
          final bool ok = allowed[c] ??= lanes != null && await _allowsServer(lanes, c);
          if (ok) continue;
          changed++;
          final Object? tw = m['tw'];
          if (tw is Map<String, dynamic>) {
            l[i] = <String, dynamic>{...tw, 'q': m['q'], 'n': m['n']};
          } else {
            l.removeAt(i);
          }
        }
        return changed;
      });

  Future<void> _remove(List<Map<String, dynamic>> batch, Set<int> seqs) => _mutate((List<Map<String, dynamic>> l) async {
        final Set<String> keys = <String>{
          for (final Map<String, dynamic> m in batch)
            if (seqs.contains(m['s'])) '${m['c']}/${m['d']}/${m['s']}',
        };
        l.removeWhere((Map<String, dynamic> m) => keys.contains('${m['c']}/${m['d']}/${m['s']}'));
      });

  Future<void> _bump(List<Map<String, dynamic>> batch) => _mutate((List<Map<String, dynamic>> l) async {
        final Set<String> keys = <String>{for (final Map<String, dynamic> m in batch) '${m['c']}/${m['d']}/${m['s']}'};
        for (final Map<String, dynamic> m in l) {
          if (keys.contains('${m['c']}/${m['d']}/${m['s']}')) m['n'] = ((m['n'] as int?) ?? 0) + 1;
        }
        // Items that keep failing are dropped only if they are expendable (live fixes, history, results): a
        // 5xx storm must never eat a sealed check-in or chat message. Those wait for the server.
        l.removeWhere((Map<String, dynamic> m) => ((m['n'] as int?) ?? 0) >= 20 && !_kept(m));
      });

  Future<void> clear() => _mutate((List<Map<String, dynamic>> l) async => l.clear());
}

/// A failure that retrying cannot fix (4xx other than rate limiting).
/// The relay could not be asked right now (no connection, session being renewed, slow down). The
/// queue keeps its items and does not count the attempt as a failure of the batch.
class UploadUnavailable implements Exception {
  const UploadUnavailable(this.message);
  final String message;
  @override
  String toString() => 'UploadUnavailable($message)';
}

class PermanentUploadError implements Exception {
  const PermanentUploadError(this.message);
  final String message;
  @override
  String toString() => 'PermanentUploadError($message)';
}

/// Random jitter so a family's phones do not all upload on the same second.
Duration uploadJitter(Random rng, {Duration max = const Duration(seconds: 8)}) =>
    Duration(milliseconds: rng.nextInt(max.inMilliseconds + 1));

// ------------------------------------------------------------------ receiver

/// Verifies and decrypts incoming items.
///
/// v1 items are the phone line. v2 items carry (line, generation) in the signed
/// header; the key is chosen from THAT header (never from a server field), the
/// server's `key_line` must agree with it, and the rollback rule runs per line.
class ChannelReceiver {
  ChannelReceiver({
    required this.keys,
    required this.directory,
    required this.kv,
    this.clock = const Clock(),
    this.maxSkew = const Duration(minutes: 10),
    this.rollbackGrace = const Duration(minutes: 10),
    this.serverKeys,
    this.lanes,
    this.runner = const InlineOpenRunner(),
  });

  /// Where the heavy crypto of [processMany] runs (the app passes a worker isolate).
  final OpenRunner runner;

  final ChannelKeys keys;
  final SenderDirectory directory;
  final ChannelKv kv;
  final Clock clock;

  /// SK store. Null (an old app, or a phone without lanes): a server-line item is "noKey".
  final ServerKeys? serverKeys;

  /// Verified lane facts for badges. Null: every server-line item is flagged.
  final LaneSource? lanes;

  /// Largest tolerated distance of a signed timestamp into the future.
  final Duration maxSkew;

  /// After a newer epoch was first seen, items sealed under older epochs are
  /// still accepted for this long (a phone that has not synced the new key yet).
  final Duration rollbackGrace;

  // ---- persisted receiver state --------------------------------------------

  String _hwKey(String c, String d) => 'hw/$c/$d'; // highest seq seen per sender (one seq space for both lines)
  // The rollback state is per KEY LINE: a newer SK generation never outdates CK and vice versa.
  String _devEpochKey(String c, String d, int line) => line == E2ee.linePhone ? 'dep/$c/$d' : 'dep/$c/$d/s'; // highest gen used by sender
  String _epochSeenKey(String c, int line) => line == E2ee.linePhone ? 'maxep/$c' : 'maxep/$c/s'; // "gen:firstSeenMs"

  Future<int> _int(String key) async => int.tryParse(await kv.get(key) ?? '') ?? 0;

  /// Seen (device, seq) pairs at or below the high-water mark are tracked in a
  /// small window set so out-of-order but new items are still accepted.
  String _winKey(String c, String d) => 'win/$c/$d';

  Future<Set<int>> _window(String c, String d) async {
    final String? raw = await kv.get(_winKey(c, d));
    if (raw == null || raw.isEmpty) return <int>{};
    return raw.split(',').map(int.parse).toSet();
  }

  Future<DeviceKey> _sender(WireItem item) async {
    DeviceKey? dev = await directory.sender(item.circleId, item.deviceId);
    dev ??= await directory.sender(item.circleId, item.deviceId, refresh: true);
    if (dev == null) throw const ItemRejected(ItemRejection.unknownSender);
    return dev;
  }

  /// Serialises batches: the replay window and rollback state are read, changed and written per batch.
  Future<void> _procLock = Future<void>.value();

  /// Decrypts, authenticates and de-duplicates [item]. Throws [ItemRejected].
  /// A successful call records the item as seen (so a replay is a duplicate).
  Future<ReceivedItem> process(WireItem item) async {
    final ItemOutcome o = (await processMany(<WireItem>[item])).single;
    if (o.rejected != null) throw o.rejected!;
    return o.item!;
  }

  /// Verifies a whole batch (a catch-up page). The checks and their order are those of [process]; what changes is
  /// the cost: keys and sender records are looked up once, the heavy crypto of all items runs in one hop to [runner]
  /// (a worker isolate in the app) and the receiver state is written once per batch instead of once per item.
  /// Results are in input order; a refused item is an outcome, not an exception.
  Future<List<ItemOutcome>> processMany(List<WireItem> items) {
    final Completer<List<ItemOutcome>> c = Completer<List<ItemOutcome>>();
    _procLock = _procLock.then((_) async {
      try {
        c.complete(await _processBatch(items));
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<List<ItemOutcome>> _processBatch(List<WireItem> items) async {
    final List<ItemOutcome?> outs = List<ItemOutcome?>.filled(items.length, null);
    final Map<String, Set<int>> windows = <String, Set<int>>{};
    final Set<String> dirtyWindows = <String>{};
    final Map<String, int> ints = <String, int>{};
    final Set<String> dirtyInts = <String>{};
    final Map<String, String?> epochSeen = <String, String?>{};
    final Map<String, Uint8List?> keyCache = <String, Uint8List?>{};

    Future<int> getInt(String k) async => ints[k] ??= await _int(k);
    void setInt(String k, int v) {
      ints[k] = v;
      dirtyInts.add(k);
    }

    // ---- stage 1: cheap checks, key and sender lookup (no crypto) ----------
    final List<int> jobIndex = <int>[];
    final List<OpenJob> jobs = <OpenJob>[];
    final Map<int, (PayloadHeader, DeviceKey)> ctx = <int, (PayloadHeader, DeviceKey)>{};
    for (int i = 0; i < items.length; i++) {
      final WireItem item = items[i];
      try {
        if (!ChannelPurpose.all.contains(item.purpose) || item.seq <= 0 || item.epoch < 1) {
          throw const ItemRejected(ItemRejection.malformed);
        }
        final Uint8List ct = item.ciphertext;
        final PayloadHeader hdr;
        try {
          hdr = E2ee.parsePayloadHeader(ct); // unknown version or line: malformed (fail closed)
        } catch (_) {
          throw const ItemRejected(ItemRejection.malformed);
        }
        if (hdr.gen != item.epoch) throw const ItemRejected(ItemRejection.malformed);
        final int line = hdr.line;
        // A chat item on the server line is never valid (phone key line only).
        if (item.purpose == ChannelPurpose.chat && line != E2ee.linePhone) throw const ItemRejected(ItemRejection.laneMismatch);
        // The server's routing label must agree with the signed header.
        if (item.declaredLine != null && item.declaredLine != line) throw const ItemRejected(ItemRejection.laneMismatch);

        // Duplicate? (cheap check before any crypto)
        final String wk = _winKey(item.circleId, item.deviceId);
        final Set<int> win = windows[wk] ??= await _window(item.circleId, item.deviceId);
        if (win.contains(item.seq)) throw const ItemRejected(ItemRejection.duplicate);

        // The key comes from the line in the signed header, never from anything else.
        final String kk = '${item.circleId}/$line/${hdr.gen}';
        if (!keyCache.containsKey(kk)) {
          keyCache[kk] = line == E2ee.linePhone
              ? await keys.circleKey(item.circleId, hdr.gen)
              : await serverKeys?.serverKey(item.circleId, hdr.gen);
        }
        final Uint8List? key = keyCache[kk];
        if (key == null) throw const ItemRejected(ItemRejection.noKey);

        final DeviceKey dev = await _sender(item);
        // v2: sender approval is checked before any decryption.
        if (hdr.version != E2ee.msgVersion && (dev.kind == 'recovery' || dev.approved != true)) {
          throw const ItemRejected(ItemRejection.senderNotMember);
        }
        ctx[i] = (hdr, dev);
        jobIndex.add(i);
        jobs.add(OpenJob(
            version: hdr.version, line: line, key: key, circleId: item.circleId, deviceId: item.deviceId,
            purpose: item.purpose, seq: item.seq, ciphertext: ct, senderEdPub: dev.edPub));
      } on ItemRejected catch (e) {
        outs[i] = ItemOutcome.reject(e);
      }
    }

    // ---- stage 2: the heavy crypto, off the UI isolate ----------------------
    final List<OpenOut> opened = await runner.run(jobs);

    // ---- stage 3: state checks and bookkeeping, in order --------------------
    for (int n = 0; n < jobIndex.length; n++) {
      final int i = jobIndex[n];
      final WireItem item = items[i];
      final (PayloadHeader hdr, DeviceKey dev) = ctx[i]!;
      final OpenOut o = opened[n];
      try {
        if (!o.ok) throw ItemRejected(o.reason);
        final int line = hdr.line;
        if (hdr.version != E2ee.msgVersion) {
          if (o.line != line || o.gen != hdr.gen) throw const ItemRejected(ItemRejection.laneMismatch);
        }
        final int seq = o.seq;
        final int tsMs = o.tsMs;
        final DateTime ts = DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true);
        _checkSender(dev, ts);

        final DateTime now = clock.now();
        if (ts.isAfter(now.add(maxSkew))) throw const ItemRejected(ItemRejection.clockSkew);

        // The same (device, seq) twice in one batch: the first one wins.
        final String wk = _winKey(item.circleId, item.deviceId);
        final Set<int> win = windows[wk]!;
        if (win.contains(item.seq)) throw const ItemRejected(ItemRejection.duplicate);

        // ---- epoch / generation rollback, per key line -----------------------
        // 1. A device never goes back to an older generation: once a fresh item (higher seq than
        //    anything seen) used generation G, a later-seq item with an older one is refused.
        final String hwK = _hwKey(item.circleId, item.deviceId);
        final String deK = _devEpochKey(item.circleId, item.deviceId, line);
        final int hw = await getInt(hwK);
        final int devEpoch = await getInt(deK);
        if (seq > hw && hdr.gen < devEpoch) throw const ItemRejected(ItemRejection.epochRollback);
        // 2. Circle-wide: once a newer generation has been seen for longer than the grace
        //    period, an item sealed under an older one is refused unless it is backlog
        //    (its signed time precedes the moment the newer one was first seen).
        final String esK = _epochSeenKey(item.circleId, line);
        if (!epochSeen.containsKey(esK)) epochSeen[esK] = await kv.get(esK);
        final String? seen = epochSeen[esK];
        int maxEpoch = 0;
        int maxSeenAtMs = 0;
        if (seen != null && seen.contains(':')) {
          maxEpoch = int.tryParse(seen.split(':')[0]) ?? 0;
          maxSeenAtMs = int.tryParse(seen.split(':')[1]) ?? 0;
        }
        if (hdr.gen < maxEpoch) {
          final bool backlog = tsMs < maxSeenAtMs;
          final bool inGrace = now.millisecondsSinceEpoch - maxSeenAtMs < rollbackGrace.inMilliseconds;
          if (!backlog && !inGrace) throw const ItemRejected(ItemRejection.epochRollback);
        }

        // ---- lane verdict (server line only): is the author's signed pref consistent? ----
        LaneVerdict verdict = LaneVerdict.consistent;
        if (line == E2ee.lineServer) {
          verdict = LaneVerdict.flagged;
          final LaneSource? l = lanes;
          if (l != null) {
            try {
              if (await l.serverAssistOn(item.circleId)) {
                verdict = E2ee.classifyItemLane(await l.prefsOf(item.circleId, dev.userId), line, tsMs);
              }
            } catch (_) {
              verdict = LaneVerdict.flagged;
            }
          }
        }

        // ---- record state ----------------------------------------------------
        if (hdr.gen > maxEpoch) {
          epochSeen[esK] = '${hdr.gen}:${now.millisecondsSinceEpoch}';
          dirtyInts.add('\u0000$esK');
        }
        if (seq > hw) setInt(hwK, seq);
        if (hdr.gen > devEpoch) setInt(deK, hdr.gen);
        win.add(item.seq);
        dirtyWindows.add(wk);

        final Map<String, dynamic> body;
        try {
          final Object? decoded = jsonDecode(utf8.decode(o.body!));
          if (decoded is! Map<String, dynamic>) throw const FormatException('not an object');
          body = decoded;
        } catch (_) {
          throw const ItemRejected(ItemRejection.badEnvelope);
        }

        outs[i] = ItemOutcome.ok(ReceivedItem(
            circleId: item.circleId,
            deviceId: item.deviceId,
            userId: dev.userId,
            seq: seq,
            purpose: item.purpose,
            epoch: hdr.gen,
            ts: ts,
            body: body,
            cursor: item.id,
            line: line,
            verdict: verdict));
      } on ItemRejected catch (e) {
        outs[i] = ItemOutcome.reject(e);
      }
    }

    // ---- persist the receiver state once per batch ---------------------------
    for (final String k in dirtyInts) {
      if (k.startsWith('\u0000')) {
        final String esK = k.substring(1);
        await kv.set(esK, epochSeen[esK]!);
      } else {
        await kv.set(k, '${ints[k]}');
      }
    }
    for (final String wk in dirtyWindows) {
      // keep the window bounded: only the newest 512 seqs
      final List<int> sorted = windows[wk]!.toList()..sort();
      final List<int> kept = sorted.length > 512 ? sorted.sublist(sorted.length - 512) : sorted;
      await kv.set(wk, kept.join(','));
    }
    return outs.cast<ItemOutcome>();
  }

  void _checkSender(DeviceKey dev, DateTime ts) {
    if (dev.kind == 'recovery' || dev.approved != true) throw const ItemRejected(ItemRejection.senderNotMember);
    if (dev.revokedAt != null && ts.isAfter(dev.revokedAt!)) throw const ItemRejected(ItemRejection.senderNotMember);
  }
}

// ---------------------------------------------------------------------- sync

/// Pulls ciphertext after a stored cursor (catch-up on app open, after a push
/// wake-up or a socket reconnect) and runs it through a [ChannelReceiver].
class ChannelSync {
  ChannelSync({required this.api, required this.receiver, required this.kv, this.pageLimit = 200});

  final ChannelApi api;
  final ChannelReceiver receiver;
  final ChannelKv kv;

  /// Items asked for per page. Smaller pages keep the peak memory of a big catch-up low
  /// (a lite phone asks for 50); the cap of `10000` items per call is the same.
  final int pageLimit;

  String _cur(String circleId) => 'cursor/$circleId';

  Future<int> cursor(String circleId) async => int.tryParse(await kv.get(_cur(circleId)) ?? '') ?? 0;

  Future<void> resetCursor(String circleId) => kv.remove(_cur(circleId));

  /// Fetches everything new, oldest first. [onItem] is awaited per verified item; rejected items are
  /// counted (never rethrown) and the cursor still advances so one bad item cannot wedge the stream.
  /// The cursor is stored only after a page was handled, so a crash re-delivers (and dedupes).
  Future<SyncStats> catchUp(String circleId,
      {FutureOr<void> Function(ReceivedItem)? onItem,
      FutureOr<void> Function(List<ReceivedItem>)? onBatch,
      List<String>? purposes,
      int? maxPages}) async {
    assert(onItem != null || onBatch != null);
    int accepted = 0;
    final Map<ItemRejection, int> rejected = <ItemRejection, int>{};
    Future<void> handle(List<WireItem> items, {required bool retrying}) async {
      final List<ItemOutcome> outs = await receiver.processMany(items);
      final List<ReceivedItem> good = <ReceivedItem>[];
      for (int i = 0; i < items.length; i++) {
        final ItemRejected? rej = outs[i].rejected;
        if (rej == null) {
          good.add(outs[i].item!);
          continue;
        }
        if (!retrying) rejected[rej.reason] = (rejected[rej.reason] ?? 0) + 1;
        if (_transient(rej.reason)) await _defer(circleId, items[i]);
      }
      if (onBatch != null) {
        if (good.isNotEmpty) await onBatch(good);
      } else {
        for (final ReceivedItem r in good) {
          await onItem!(r);
        }
      }
      accepted += good.length;
    }

    // Items that arrived before their key / sender record are retried first.
    final List<WireItem> retry = await _deferred(circleId);
    if (retry.isNotEmpty) {
      await kv.remove(_def(circleId));
      await handle(retry, retrying: true);
    }
    int after = await cursor(circleId);
    final int pages = maxPages ?? ((10000 + pageLimit - 1) ~/ pageLimit);
    for (int page = 0; page < pages; page++) {
      final Page p = await api.pull(circleId, after, purposes: purposes, limit: pageLimit);
      await handle(p.items, retrying: false);
      if (p.nextCursor > after) {
        after = p.nextCursor;
        // Only advance the stored cursor when no purpose filter hides other items.
        if (purposes == null) await kv.set(_cur(circleId), '$after');
      }
      if (!p.hasMore) break;
    }
    return SyncStats(accepted, rejected);
  }

  String _def(String circleId) => 'deferred/$circleId';

  /// Rejections that may heal (the key or the sender record is not here yet).
  bool _transient(ItemRejection r) => r == ItemRejection.noKey || r == ItemRejection.unknownSender;

  Future<List<WireItem>> _deferred(String circleId) async {
    final String? raw = await kv.get(_def(circleId));
    if (raw == null || raw.isEmpty) return <WireItem>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>().map(WireItem.fromStore).toList();
    } catch (_) {
      return <WireItem>[];
    }
  }

  Future<void> _defer(String circleId, WireItem it) async {
    final List<WireItem> l = await _deferred(circleId);
    if (l.any((WireItem x) => x.deviceId == it.deviceId && x.seq == it.seq)) return;
    l.add(it);
    final List<WireItem> kept = l.length > 200 ? l.sublist(l.length - 200) : l;
    await kv.set(_def(circleId), jsonEncode(kept.map((WireItem x) => x.toStore()).toList()));
  }

  /// Handles one live (WebSocket) item. Returns null if it was refused.
  Future<ReceivedItem?> live(WireItem it) async {
    try {
      return await receiver.process(it);
    } on ItemRejected {
      return null;
    }
  }
}

class SyncStats {
  const SyncStats(this.accepted, this.rejected);
  final int accepted;
  final Map<ItemRejection, int> rejected;
  int get rejectedTotal => rejected.values.fold(0, (int a, int b) => a + b);
}
