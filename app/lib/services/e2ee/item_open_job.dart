import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'e2ee_crypto.dart';
import 'private_channel.dart' show ItemRejection, itemSignedMessage;

// The CPU-heavy half of receiving an item: XChaCha20-Poly1305 + HKDF + Ed25519 verify in pure Dart.
// It is a pure function of plain bytes (key, ciphertext, sender public key), so it can run on any isolate
// without changing a single cryptographic rule: the receiver still decides, on the UI isolate, which key and
// which sender key go in, and still owns every check that touches state (duplicates, rollback, clock).
//
// Measured in the test VM (docs/developers/performance-private.md): about 5 ms per item on a desktop CPU, so
// 300 items blocked the UI isolate for ~1.7 s; a phone CPU is several times slower.

/// Everything [runOpenJob] needs. Only sendable types (bytes, strings, ints).
class OpenJob {
  const OpenJob({
    required this.version,
    required this.line,
    required this.key,
    required this.circleId,
    required this.deviceId,
    required this.purpose,
    required this.seq,
    required this.ciphertext,
    required this.senderEdPub,
  });
  final int version;
  final int line;
  final Uint8List key;
  final String circleId;
  final String deviceId;
  final String purpose;
  final int seq;
  final Uint8List ciphertext;
  final Uint8List senderEdPub;
}

/// Outcome of one job: either [rejection] (index into [ItemRejection]) or the verified fields.
class OpenOut {
  OpenOut.ok(this.seq, this.tsMs, this.body, this.gen, this.line) : rejection = -1;
  OpenOut.fail(ItemRejection r)
      : rejection = r.index,
        seq = 0,
        tsMs = 0,
        body = null,
        gen = 0,
        line = 0;
  final int rejection;
  final int seq;
  final int tsMs;
  final Uint8List? body;
  final int gen;
  final int line;
  bool get ok => rejection < 0;
  ItemRejection get reason => ItemRejection.values[rejection];
}

/// Decrypts, unpads, checks the envelope and verifies the sender signature. Same checks, same order and same
/// error mapping as the inline code that used to live in `ChannelReceiver.process`.
Future<OpenOut> runOpenJob(OpenJob j) async {
  try {
    if (j.version == E2ee.msgVersion) {
      final Uint8List padded;
      try {
        padded = await E2ee.open(j.key, j.circleId, j.deviceId, j.purpose, j.ciphertext);
      } on E2eeAuthException {
        return OpenOut.fail(ItemRejection.badCipher);
      } on E2eeFormatException {
        return OpenOut.fail(ItemRejection.malformed);
      }
      final Uint8List env;
      try {
        env = E2ee.unpad(padded);
      } catch (_) {
        return OpenOut.fail(ItemRejection.badPadding);
      }
      if (env.length < 1 + 8 + 8 + E2ee.sigLen || env[0] != 1) return OpenOut.fail(ItemRejection.badEnvelope);
      final ByteData bd = ByteData.sublistView(env);
      final int seq = bd.getUint64(1, Endian.big);
      final int tsMs = bd.getUint64(9, Endian.big);
      final Uint8List sig = Uint8List.fromList(env.sublist(17, 17 + E2ee.sigLen));
      final Uint8List body = Uint8List.fromList(env.sublist(17 + E2ee.sigLen));
      // The inner (signed) seq must be the one the server shows, or the server could renumber.
      if (seq != j.seq) return OpenOut.fail(ItemRejection.badEnvelope);
      final int gen = E2ee.parsePayloadHeader(j.ciphertext).gen;
      final bool ok = await E2ee.verify(
          j.senderEdPub,
          itemSignedMessage(circleId: j.circleId, epoch: gen, deviceId: j.deviceId, purpose: j.purpose, seq: seq, tsMs: tsMs, body: body),
          sig);
      if (!ok) return OpenOut.fail(ItemRejection.badSignature);
      return OpenOut.ok(seq, tsMs, body, gen, E2ee.linePhone);
    }
    final ItemV2 v;
    try {
      v = await E2ee.openItemV2(j.key, j.circleId, j.line, j.deviceId, j.senderEdPub, j.purpose, j.seq, j.ciphertext);
    } on E2eeAuthException catch (e) {
      return OpenOut.fail(e.message == 'bad item signature'
          ? ItemRejection.badSignature
          : (e.message == 'seq mismatch' ? ItemRejection.badEnvelope : ItemRejection.badCipher));
    } on E2eeFormatException {
      return OpenOut.fail(ItemRejection.malformed);
    }
    return OpenOut.ok(v.seq, v.tsMs, v.body, v.gen, v.line);
  } catch (_) {
    return OpenOut.fail(ItemRejection.malformed);
  }
}

/// Where the heavy half runs.
abstract class OpenRunner {
  Future<List<OpenOut>> run(List<OpenJob> jobs);
}

/// On the calling isolate (tests, web). Yields to the event loop every few items so a long batch cannot starve frames.
class InlineOpenRunner implements OpenRunner {
  const InlineOpenRunner();
  @override
  Future<List<OpenOut>> run(List<OpenJob> jobs) async {
    final List<OpenOut> out = <OpenOut>[];
    for (int i = 0; i < jobs.length; i++) {
      out.add(await runOpenJob(jobs[i]));
      if (i % 4 == 3) await Future<void>.delayed(Duration.zero);
    }
    return out;
  }
}

/// A long-lived worker isolate, started on first use and stopped after [idle] without work.
/// Falls back to the calling isolate if it cannot be started or does not answer in time.
class WorkerOpenRunner implements OpenRunner {
  WorkerOpenRunner({this.idle = const Duration(seconds: 30), this.timeout = const Duration(seconds: 60)});
  final Duration idle;
  final Duration timeout;

  Isolate? _iso;
  SendPort? _send;
  ReceivePort? _recv;
  Future<bool>? _starting;
  int _nextId = 0;
  final Map<int, Completer<List<OpenOut>>> _pending = <int, Completer<List<OpenOut>>>{};
  Timer? _idleTimer;

  /// How many batches went to the worker / ran inline (diagnostics and tests).
  int batchesOnWorker = 0, batchesInline = 0;

  bool get running => _iso != null;

  Future<bool> _ensure() => _starting ??= _start();

  Future<bool> _start() async {
    if (kIsWeb) return false;
    try {
      final ReceivePort recv = ReceivePort();
      final Completer<SendPort> ready = Completer<SendPort>();
      recv.listen((dynamic m) {
        if (m is SendPort) {
          if (!ready.isCompleted) ready.complete(m);
        } else if (m is List && m.length == 2) {
          _pending.remove(m[0])?.complete((m[1] as List<dynamic>).cast<OpenOut>());
        }
      });
      final Isolate iso = await Isolate.spawn(_entry, recv.sendPort, debugName: 'of-crypto');
      _send = await ready.future.timeout(const Duration(seconds: 10));
      _iso = iso;
      _recv = recv;
      return true;
    } catch (_) {
      _stop();
      return false;
    }
  }

  static void _entry(SendPort main) {
    final ReceivePort rp = ReceivePort();
    main.send(rp.sendPort);
    rp.listen((dynamic m) async {
      final int id = (m as List<dynamic>)[0] as int;
      final List<OpenOut> out = <OpenOut>[];
      for (final OpenJob j in (m[1] as List<dynamic>).cast<OpenJob>()) {
        out.add(await runOpenJob(j));
      }
      main.send(<Object>[id, out]);
    });
  }

  void _stop() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _iso?.kill(priority: Isolate.immediate);
    _recv?.close();
    _iso = null;
    _send = null;
    _recv = null;
    _starting = null;
    for (final Completer<List<OpenOut>> c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('crypto worker stopped'));
    }
    _pending.clear();
  }

  @override
  Future<List<OpenOut>> run(List<OpenJob> jobs) async {
    if (jobs.isEmpty) return <OpenOut>[];
    _idleTimer?.cancel();
    try {
      if (await _ensure()) {
        final int id = ++_nextId;
        final Completer<List<OpenOut>> c = Completer<List<OpenOut>>();
        _pending[id] = c;
        _send!.send(<Object>[id, jobs]);
        final List<OpenOut> out = await c.future.timeout(timeout);
        batchesOnWorker++;
        return out;
      }
    } catch (_) {
      _stop();
    } finally {
      if (_iso != null && _pending.isEmpty) _idleTimer = Timer(idle, _stop);
    }
    batchesInline++;
    return const InlineOpenRunner().run(jobs);
  }

  /// Stops the isolate now (app exit, tests).
  void dispose() => _stop();
}

