import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'e2ee_crypto.dart';
import 'e2ee_models.dart';

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
  static const List<String> all = <String>[fix, event, place, history, checkin, chat];

  /// Largest padded plaintext the server accepts per purpose (mirrors the Go side).
  static const Map<String, int> maxBucket = <String, int>{
    fix: 1024, event: 1024, checkin: 1024, chat: 4096, place: 4096, history: 69632,
  };
}

/// Signature domain of the item envelope.
const String _sigDomain = 'OFE2EE2-ITEM';

Uint8List _i64(int v) {
  final ByteData d = ByteData(8)..setUint64(0, v, Endian.big);
  return d.buffer.asUint8List();
}

int _readI64(Uint8List b, int off) => ByteData.sublistView(b, off, off + 8).getUint64(0, Endian.big);

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

  Map<String, dynamic> toUpload() => <String, dynamic>{
        'seq': seq,
        'purpose': purpose,
        'epoch': epoch,
        'size_bucket': sizeBucket,
        'ciphertext': E2ee.b64(ciphertext),
      };

  Map<String, dynamic> toStore() => <String, dynamic>{
        'c': circleId, 'd': deviceId, 's': seq, 'p': purpose, 'e': epoch, 'b': sizeBucket,
        'ct': E2ee.b64(ciphertext),
      };

  factory WireItem.fromStore(Map<String, dynamic> j) => WireItem(
        circleId: j['c'] as String,
        deviceId: j['d'] as String,
        seq: (j['s'] as num).toInt(),
        purpose: j['p'] as String,
        epoch: (j['e'] as num).toInt(),
        sizeBucket: (j['b'] as num).toInt(),
        ciphertext: E2ee.unb64(j['ct'] as String),
      );

  /// Parses a REST item or a WebSocket `e2ee_item` frame. Null if malformed.
  static WireItem? fromServer(Map<String, dynamic> j) {
    try {
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
      );
    } catch (_) {
      return null;
    }
  }
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
  });

  final String circleId;
  final String deviceId;

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

/// Who may send in a circle. Backed by the circle's E2EE state (the verified key
/// log): a sender must be an active (or, for older items, once active) APPROVED
/// device of a current member.
abstract class SenderDirectory {
  Future<DeviceKey?> sender(String circleId, String deviceId, {bool refresh = false});
}

/// Small persistent key/value store (SharedPreferences in the app).
abstract class ChannelKv {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class MemoryKv implements ChannelKv {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> get(String key) async => data[key];
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
class ChannelSealer {
  ChannelSealer({required this.keys, required this.kv, this.clock = const Clock()});

  final ChannelKeys keys;
  final ChannelKv kv;
  final Clock clock;

  /// Serialises seq allocation within this isolate.
  Future<void> _lock = Future<void>.value();

  String _seqKey(String circle, String device) => 'seq/$circle/$device';

  Future<int> _nextSeq(String circle, String device) {
    final Completer<int> c = Completer<int>();
    _lock = _lock.then((_) async {
      try {
        final int cur = int.tryParse(await kv.get(_seqKey(circle, device)) ?? '') ?? 0;
        await kv.set(_seqKey(circle, device), '${cur + 1}');
        c.complete(cur + 1);
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  /// Seals [body] as [purpose] for [circleId] under the newest epoch key this
  /// phone holds. Throws [ItemRejected] (noKey) when it holds none: the caller
  /// must NOT fall back to plaintext.
  Future<WireItem> seal(
    SenderIdentity me,
    String circleId,
    String purpose,
    Map<String, dynamic> body, {
    DateTime? at,
    int? maxEpoch,
  }) async {
    int epoch = await keys.latestEpoch(circleId);
    if (maxEpoch != null && epoch > maxEpoch) epoch = maxEpoch;
    if (epoch < 1) throw const ItemRejected(ItemRejection.noKey);
    final Uint8List? key = await keys.circleKey(circleId, epoch);
    if (key == null) throw const ItemRejected(ItemRejection.noKey);
    final int seq = await _nextSeq(circleId, me.deviceId);
    final int tsMs = (at ?? clock.now()).toUtc().millisecondsSinceEpoch;
    final Uint8List bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final Uint8List padded = await buildPaddedEnvelope(
        edSeed: me.edSeed, circleId: circleId, epoch: epoch, deviceId: me.deviceId, purpose: purpose, seq: seq, tsMs: tsMs, body: bodyBytes);
    final int cap = ChannelPurpose.maxBucket[purpose] ?? 1024;
    if (padded.length > cap) throw const ItemRejected(ItemRejection.malformed);
    final Uint8List ct = await E2ee.seal(key, circleId, epoch, me.deviceId, purpose, padded);
    return WireItem(
        circleId: circleId, deviceId: me.deviceId, seq: seq, purpose: purpose, epoch: epoch, sizeBucket: padded.length, ciphertext: ct);
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

  Future<List<Map<String, dynamic>>> _load() async {
    final String? raw = await kv.get(_key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _save(List<Map<String, dynamic>> l) => l.isEmpty ? kv.remove(_key) : kv.set(_key, jsonEncode(l));

  Future<void> enqueue(WireItem item) => _locked(() async {
        final List<Map<String, dynamic>> l = await _load();
        l.add(<String, dynamic>{...item.toStore(), 'q': clock.now().millisecondsSinceEpoch, 'n': 0});
        _prune(l);
        await _save(l);
      });

  void _prune(List<Map<String, dynamic>> l) {
    final int cut = clock.now().subtract(maxAge).millisecondsSinceEpoch;
    l.removeWhere((Map<String, dynamic> m) =>
        (m['q'] as int) < cut && m['p'] != ChannelPurpose.place && m['p'] != ChannelPurpose.event);
    while (l.length > maxItems) {
      // Drop the oldest live fix first; keep events, places and check-ins longest.
      int idx = l.indexWhere((Map<String, dynamic> m) => m['p'] == ChannelPurpose.fix);
      if (idx < 0) idx = 0;
      l.removeAt(idx);
    }
  }

  Future<int> length() => _locked(() async => (await _load()).length);

  Future<List<WireItem>> peek() => _locked(() async => (await _load()).map(WireItem.fromStore).toList());

  /// Sends the queue, at most [batchSize] per request, newest fixes first is NOT
  /// used: order is preserved so seq stays monotonic per device. Returns the
  /// number of items the server now has (stored or duplicate). Stops at the first
  /// transport failure; permanently rejected items are dropped.
  Future<int> flush(ChannelApi api, {required String Function(String circleId) deviceFor, int batchSize = 50}) async {
    int delivered = 0;
    while (true) {
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
      List<BatchResult> results;
      try {
        results = await api.postBatch(circle, device, items);
      } on PermanentUploadError {
        // e.g. circle no longer private / device revoked: drop the batch, it can never succeed.
        await _remove(batch, <int>{for (final WireItem i in items) i.seq});
        continue;
      } catch (_) {
        await _bump(batch);
        return delivered; // offline or server trouble: keep everything, try later
      }
      final Set<int> done = <int>{};
      for (final BatchResult r in results) {
        // stored/duplicate: server has it. rejected: permanent (bad epoch etc.), drop.
        done.add(r.seq);
        if (r.status != 'rejected') delivered++;
      }
      // Items the server did not mention stay queued.
      await _remove(batch, done);
      if (done.isEmpty) {
        await _bump(batch);
        return delivered;
      }
    }
  }

  Future<void> _remove(List<Map<String, dynamic>> batch, Set<int> seqs) => _locked(() async {
        final List<Map<String, dynamic>> l = await _load();
        final Set<String> keys = <String>{
          for (final Map<String, dynamic> m in batch)
            if (seqs.contains(m['s'])) '${m['c']}/${m['d']}/${m['s']}',
        };
        l.removeWhere((Map<String, dynamic> m) => keys.contains('${m['c']}/${m['d']}/${m['s']}'));
        await _save(l);
      });

  Future<void> _bump(List<Map<String, dynamic>> batch) => _locked(() async {
        final List<Map<String, dynamic>> l = await _load();
        final Set<String> keys = <String>{for (final Map<String, dynamic> m in batch) '${m['c']}/${m['d']}/${m['s']}'};
        for (final Map<String, dynamic> m in l) {
          if (keys.contains('${m['c']}/${m['d']}/${m['s']}')) m['n'] = ((m['n'] as int?) ?? 0) + 1;
        }
        // A batch that failed this many times is poison: drop it so it cannot pin the queue.
        l.removeWhere((Map<String, dynamic> m) => ((m['n'] as int?) ?? 0) >= 20);
        await _save(l);
      });

  Future<void> clear() => kv.remove(_key);
}

/// A failure that retrying cannot fix (4xx other than rate limiting).
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
class ChannelReceiver {
  ChannelReceiver({
    required this.keys,
    required this.directory,
    required this.kv,
    this.clock = const Clock(),
    this.maxSkew = const Duration(minutes: 10),
    this.rollbackGrace = const Duration(minutes: 10),
  });

  final ChannelKeys keys;
  final SenderDirectory directory;
  final ChannelKv kv;
  final Clock clock;

  /// Largest tolerated distance of a signed timestamp into the future.
  final Duration maxSkew;

  /// After a newer epoch was first seen, items sealed under older epochs are
  /// still accepted for this long (a phone that has not synced the new key yet).
  final Duration rollbackGrace;

  // ---- persisted receiver state --------------------------------------------

  String _hwKey(String c, String d) => 'hw/$c/$d'; // highest seq seen per sender
  String _devEpochKey(String c, String d) => 'dep/$c/$d'; // highest epoch used by sender
  String _epochSeenKey(String c) => 'maxep/$c'; // "epoch:firstSeenMs"

  Future<int> _int(String key) async => int.tryParse(await kv.get(key) ?? '') ?? 0;

  /// Seen (device, seq) pairs at or below the high-water mark are tracked in a
  /// small window set so out-of-order but new items are still accepted.
  String _winKey(String c, String d) => 'win/$c/$d';

  Future<Set<int>> _window(String c, String d) async {
    final String? raw = await kv.get(_winKey(c, d));
    if (raw == null || raw.isEmpty) return <int>{};
    return raw.split(',').map(int.parse).toSet();
  }

  /// Decrypts, authenticates and de-duplicates [item]. Throws [ItemRejected].
  /// A successful call records the item as seen (so a replay is a duplicate).
  Future<ReceivedItem> process(WireItem item) async {
    if (!ChannelPurpose.all.contains(item.purpose) || item.seq <= 0 || item.epoch < 1) {
      throw const ItemRejected(ItemRejection.malformed);
    }
    final Uint8List ct = item.ciphertext;
    final int hdrEpoch;
    try {
      hdrEpoch = E2ee.payloadEpoch(ct);
    } catch (_) {
      throw const ItemRejected(ItemRejection.malformed);
    }
    if (hdrEpoch != item.epoch) throw const ItemRejected(ItemRejection.malformed);

    // Duplicate? (cheap check before any crypto)
    final Set<int> win = await _window(item.circleId, item.deviceId);
    if (win.contains(item.seq)) throw const ItemRejected(ItemRejection.duplicate);

    final Uint8List? key = await keys.circleKey(item.circleId, item.epoch);
    if (key == null) throw const ItemRejected(ItemRejection.noKey);

    final Uint8List padded;
    try {
      padded = await E2ee.open(key, item.circleId, item.deviceId, item.purpose, ct);
    } on E2eeAuthException {
      throw const ItemRejected(ItemRejection.badCipher);
    } on E2eeFormatException {
      throw const ItemRejected(ItemRejection.malformed);
    }
    final Uint8List env;
    try {
      env = E2ee.unpad(padded);
    } catch (_) {
      throw const ItemRejected(ItemRejection.badPadding);
    }
    if (env.length < 1 + 8 + 8 + E2ee.sigLen || env[0] != 1) throw const ItemRejected(ItemRejection.badEnvelope);
    final int seq = _readI64(env, 1);
    final int tsMs = _readI64(env, 9);
    final Uint8List sig = Uint8List.fromList(env.sublist(17, 17 + E2ee.sigLen));
    final Uint8List bodyBytes = Uint8List.fromList(env.sublist(17 + E2ee.sigLen));
    // The inner (signed) seq must be the one the server shows, or the server could renumber.
    if (seq != item.seq) throw const ItemRejected(ItemRejection.badEnvelope);
    final DateTime ts = DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true);

    // Sender must be a known, approved device of a member of this circle.
    DeviceKey? dev = await directory.sender(item.circleId, item.deviceId);
    dev ??= await directory.sender(item.circleId, item.deviceId, refresh: true);
    if (dev == null) throw const ItemRejected(ItemRejection.unknownSender);
    if (dev.kind == 'recovery' || dev.approved != true) throw const ItemRejected(ItemRejection.senderNotMember);
    if (dev.revokedAt != null && ts.isAfter(dev.revokedAt!)) throw const ItemRejected(ItemRejection.senderNotMember);
    final bool ok = await E2ee.verify(
        dev.edPub,
        itemSignedMessage(
            circleId: item.circleId, epoch: item.epoch, deviceId: item.deviceId, purpose: item.purpose, seq: seq, tsMs: tsMs, body: bodyBytes),
        sig);
    if (!ok) throw const ItemRejected(ItemRejection.badSignature);

    final DateTime now = clock.now();
    if (ts.isAfter(now.add(maxSkew))) throw const ItemRejected(ItemRejection.clockSkew);

    // ---- epoch rollback ----------------------------------------------------
    // 1. A device never goes back to an older epoch: once a fresh item (higher seq than
    //    anything seen) used epoch E, a later-seq item with an older epoch is refused.
    final int hw = await _int(_hwKey(item.circleId, item.deviceId));
    final int devEpoch = await _int(_devEpochKey(item.circleId, item.deviceId));
    if (seq > hw && item.epoch < devEpoch) throw const ItemRejected(ItemRejection.epochRollback);
    // 2. Circle-wide: once a newer epoch has been seen for longer than the grace
    //    period, an item sealed under an older epoch is refused unless it is backlog
    //    (its signed time precedes the moment the newer epoch was first seen).
    final String? seen = await kv.get(_epochSeenKey(item.circleId));
    int maxEpoch = 0;
    int maxSeenAtMs = 0;
    if (seen != null && seen.contains(':')) {
      maxEpoch = int.tryParse(seen.split(':')[0]) ?? 0;
      maxSeenAtMs = int.tryParse(seen.split(':')[1]) ?? 0;
    }
    if (item.epoch < maxEpoch) {
      final bool backlog = tsMs < maxSeenAtMs;
      final bool inGrace = now.millisecondsSinceEpoch - maxSeenAtMs < rollbackGrace.inMilliseconds;
      if (!backlog && !inGrace) throw const ItemRejected(ItemRejection.epochRollback);
    }

    // ---- record state ------------------------------------------------------
    if (item.epoch > maxEpoch) {
      await kv.set(_epochSeenKey(item.circleId), '${item.epoch}:${now.millisecondsSinceEpoch}');
    }
    if (seq > hw) await kv.set(_hwKey(item.circleId, item.deviceId), '$seq');
    if (item.epoch > devEpoch) await kv.set(_devEpochKey(item.circleId, item.deviceId), '${item.epoch}');
    win.add(item.seq);
    // keep the window bounded: only the newest 512 seqs
    final List<int> sorted = win.toList()..sort();
    final List<int> kept = sorted.length > 512 ? sorted.sublist(sorted.length - 512) : sorted;
    await kv.set(_winKey(item.circleId, item.deviceId), kept.join(','));

    final Map<String, dynamic> body;
    try {
      final Object? decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('not an object');
      body = decoded;
    } catch (_) {
      throw const ItemRejected(ItemRejection.badEnvelope);
    }
    return ReceivedItem(
        circleId: item.circleId,
        deviceId: item.deviceId,
        userId: dev.userId,
        seq: seq,
        purpose: item.purpose,
        epoch: item.epoch,
        ts: ts,
        body: body,
        cursor: item.id);
  }
}

// ---------------------------------------------------------------------- sync

/// Pulls ciphertext after a stored cursor (catch-up on app open, after a push
/// wake-up or a socket reconnect) and runs it through a [ChannelReceiver].
class ChannelSync {
  ChannelSync({required this.api, required this.receiver, required this.kv});

  final ChannelApi api;
  final ChannelReceiver receiver;
  final ChannelKv kv;

  String _cur(String circleId) => 'cursor/$circleId';

  Future<int> cursor(String circleId) async => int.tryParse(await kv.get(_cur(circleId)) ?? '') ?? 0;

  Future<void> resetCursor(String circleId) => kv.remove(_cur(circleId));

  /// Fetches everything new, oldest first. [onItem] is awaited per verified item; rejected items are
  /// counted (never rethrown) and the cursor still advances so one bad item cannot wedge the stream.
  /// The cursor is stored only after a page was handled, so a crash re-delivers (and dedupes).
  Future<SyncStats> catchUp(String circleId, {required FutureOr<void> Function(ReceivedItem) onItem, List<String>? purposes, int maxPages = 50}) async {
    int accepted = 0;
    final Map<ItemRejection, int> rejected = <ItemRejection, int>{};
    // Items that arrived before their key / sender record are retried first.
    final List<WireItem> retry = await _deferred(circleId);
    if (retry.isNotEmpty) {
      await kv.remove(_def(circleId));
      for (final WireItem it in retry) {
        try {
          await onItem(await receiver.process(it));
          accepted++;
        } on ItemRejected catch (e) {
          if (_transient(e.reason)) await _defer(circleId, it);
        }
      }
    }
    int after = await cursor(circleId);
    for (int page = 0; page < maxPages; page++) {
      final Page p = await api.pull(circleId, after, purposes: purposes);
      for (final WireItem it in p.items) {
        try {
          final ReceivedItem r = await receiver.process(it);
          await onItem(r);
          accepted++;
        } on ItemRejected catch (e) {
          rejected[e.reason] = (rejected[e.reason] ?? 0) + 1;
          if (_transient(e.reason)) await _defer(circleId, it);
        }
      }
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
