import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../e2ee/e2ee_vault.dart';
import 'offline_errors.dart';

/// What a queued update is. The first three are never dropped to make room or
/// for age: a message, a check-in or an SOS the user pressed must arrive.
class QueueKind {
  QueueKind._();
  static const String sos = 'sos';
  static const String checkin = 'checkin';
  static const String chat = 'chat';
  static const String place = 'place';
  static const String setting = 'setting';

  static const Set<String> protected = <String>{sos, checkin, chat};
}

/// One update waiting for the server: a request to replay, in order.
class QueuedItem {
  QueuedItem({
    required this.id,
    required this.kind,
    required this.method,
    required this.path,
    this.body,
    int? at,
    this.attempts = 0,
    this.coalesceKey,
    this.meta = const <String, dynamic>{},
  }) : at = at ?? DateTime.now().millisecondsSinceEpoch;

  /// Chosen by the phone, also sent as `client_id` so the server stores a replay once.
  final String id;
  final String kind;
  final String method;
  final String path;
  final Map<String, dynamic>? body;

  /// When the user did it (ms since epoch).
  final int at;
  int attempts;

  /// Items with the same key replace each other (the newest setting wins).
  final String? coalesceKey;

  /// Free data for the UI that queued it (circle id, text to show).
  final Map<String, dynamic> meta;

  bool get isProtected => QueueKind.protected.contains(kind);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'i': id,
        'k': kind,
        'm': method,
        'p': path,
        if (body != null) 'b': body,
        't': at,
        'n': attempts,
        if (coalesceKey != null) 'c': coalesceKey,
        if (meta.isNotEmpty) 'x': meta,
      };

  static QueuedItem? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return QueuedItem(
        id: j['i'] as String,
        kind: j['k'] as String,
        method: j['m'] as String,
        path: j['p'] as String,
        body: (j['b'] as Map?)?.cast<String, dynamic>(),
        at: (j['t'] as num).toInt(),
        attempts: (j['n'] as num?)?.toInt() ?? 0,
        coalesceKey: j['c'] as String?,
        meta: (j['x'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the queue lives.
abstract class QueueStorage {
  Future<String?> read();
  Future<void> write(String json);
}

/// Memory only (tests).
class MemoryQueueStorage implements QueueStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String json) async => value = json;
}

/// The queue holds positions (SOS, check-ins) and message text, so it lives in
/// the Keystore-wrapped vault. If the vault refuses (a locked phone), the SOS
/// is worth more than the encryption: it falls back to app preferences and moves
/// back into the vault on the next successful write.
class VaultQueueStorage implements QueueStorage {
  VaultQueueStorage(this.vault);
  final E2eeVault vault;
  static const String name = 'offline/v1/queue';
  static const String _fallbackKey = 'offline_queue_fallback_v1';

  @override
  Future<String?> read() async {
    try {
      final Uint8List? raw = await vault.read(name);
      if (raw != null) return utf8.decode(raw);
    } catch (_) {}
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return p.getString(_fallbackKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String json) async {
    try {
      await vault.write(name, Uint8List.fromList(utf8.encode(json)));
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (p.containsKey(_fallbackKey)) await p.remove(_fallbackKey);
      return;
    } catch (_) {}
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_fallbackKey, json);
  }
}

/// How one replay ended.
enum SendOutcome { delivered, rejected, retryLater, stop }

/// Result of [OfflineQueue.submit].
class Submitted {
  const Submitted.sent(this.response) : queued = false;
  const Submitted.queued()
      : queued = true,
        response = null;

  /// True when the update was saved on the phone and will be sent later.
  final bool queued;
  final dynamic response;
}

/// The queue already holds the maximum of messages/check-ins/SOS and refuses
/// another instead of dropping an older one.
class QueueFull implements Exception {
  const QueueFull();
  @override
  String toString() => 'QueueFull';
}

/// Sends one queued request. Throws what [ApiClient] throws.
typedef QueueSender = Future<dynamic> Function(QueuedItem item);

/// Durable, ordered store-and-forward queue for the things a person did while
/// the server was out of reach: SOS, check-ins, chat messages, place changes,
/// settings. Survives app kill and reboot.
///
/// - Replay is in order (oldest first), except that an SOS goes first.
/// - A transport failure or 5xx/429 stops the run and keeps everything; it never
///   counts toward dropping anything.
/// - A 4xx the server will never accept moves the item to [rejected] (kept for
///   the user to see, bounded) and the run continues.
/// - SOS, check-ins and chat are never dropped for age or to make room. Beyond
///   [protectedCap] a new one is refused (the caller tells the user); it does not
///   silently displace an older one.
/// - Places and settings expire after [softMaxAge] and are capped at [softCap]
///   (oldest first); settings with the same key replace each other.
class OfflineQueue {
  OfflineQueue({
    required this.storage,
    this.protectedCap = 1000,
    this.softCap = 300,
    this.softMaxAge = const Duration(days: 7),
    this.rejectedCap = 50,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final QueueStorage storage;
  final int protectedCap, softCap, rejectedCap;
  final Duration softMaxAge;
  final DateTime Function() _clock;

  static OfflineQueue instance = OfflineQueue(storage: VaultQueueStorage(SecureVault()));

  /// Number of waiting items, for the status chip and Diagnostics.
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// Called once per delivered item with the server's answer (for example to
  /// turn a local pending chat bubble into the real message).
  final List<void Function(QueuedItem item, dynamic response)> onDelivered =
      <void Function(QueuedItem, dynamic)>[];

  List<QueuedItem>? _items;
  List<Map<String, dynamic>> _rejected = <Map<String, dynamic>>[];
  Future<void> _lock = Future<void>.value();
  bool _flushing = false;

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

  Future<List<QueuedItem>> _load() async {
    final List<QueuedItem>? have = _items;
    if (have != null) return have;
    final List<QueuedItem> out = <QueuedItem>[];
    try {
      final String? raw = await storage.read();
      if (raw != null && raw.isNotEmpty) {
        final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
        for (final Object? e in (m['q'] as List?) ?? const <Object?>[]) {
          final QueuedItem? it = QueuedItem.fromJson(e);
          if (it != null) out.add(it);
        }
        _rejected = ((m['r'] as List?) ?? const <Object?>[]).whereType<Map>().map((Map e) => e.cast<String, dynamic>()).toList();
      }
    } catch (_) {
      // unreadable: start empty rather than crash the UI
    }
    _items = out;
    count.value = out.length;
    return out;
  }

  Future<void> _save(List<QueuedItem> items) async {
    count.value = items.length;
    try {
      await storage.write(jsonEncode(<String, dynamic>{
        'v': 1,
        'q': items.map((QueuedItem i) => i.toJson()).toList(),
        'r': _rejected,
      }));
    } catch (_) {
      // Kept in memory; the next change writes again.
    }
  }

  /// Adds [item]. Returns false only when a protected item had to be refused
  /// because the queue holds [protectedCap] of them already.
  Future<bool> enqueue(QueuedItem item) => _locked(() async {
        final List<QueuedItem> l = await _load();
        if (l.any((QueuedItem x) => x.id == item.id)) return true;
        if (item.isProtected && l.where((QueuedItem x) => x.isProtected).length >= protectedCap) return false;
        if (item.coalesceKey != null) l.removeWhere((QueuedItem x) => x.coalesceKey == item.coalesceKey);
        l.add(item);
        _pruneSoft(l);
        await _save(l);
        return true;
      });

  void _pruneSoft(List<QueuedItem> l) {
    final int cut = _clock().subtract(softMaxAge).millisecondsSinceEpoch;
    l.removeWhere((QueuedItem x) => !x.isProtected && x.at < cut);
    int soft = l.where((QueuedItem x) => !x.isProtected).length;
    while (soft > softCap) {
      final int idx = l.indexWhere((QueuedItem x) => !x.isProtected);
      l.removeAt(idx);
      soft--;
    }
  }

  Future<List<QueuedItem>> items({String? kind}) => _locked(() async {
        final List<QueuedItem> l = await _load();
        return l.where((QueuedItem x) => kind == null || x.kind == kind).toList();
      });

  Future<int> size() => _locked(() async => (await _load()).length);

  /// Items the server refused for good (shown in Diagnostics; bounded).
  Future<int> rejectedCount() => _locked(() async {
        await _load();
        return _rejected.length;
      });

  Future<void> remove(String id) => _locked(() async {
        final List<QueuedItem> l = await _load();
        l.removeWhere((QueuedItem x) => x.id == id);
        await _save(l);
      });

  /// Forgets everything (sign-out: queued updates belong to the account).
  Future<void> clear() => _locked(() async {
        _items = <QueuedItem>[];
        _rejected = <Map<String, dynamic>>[];
        count.value = 0;
        try {
          await storage.write(jsonEncode(<String, dynamic>{'v': 1, 'q': <Object?>[], 'r': <Object?>[]}));
        } catch (_) {}
      });

  /// Drops the in-memory copy so the next call reads storage again (tests of "kill and restart").
  @visibleForTesting
  void forgetMemory() => _items = null;

  /// Replays the queue in order through [send] (default: the API client).
  /// Single flight. Returns how many items were delivered.
  Future<int> flush({QueueSender? send}) async {
    if (_flushing) return 0;
    _flushing = true;
    int delivered = 0;
    try {
      final QueueSender sender = send ?? _defaultSend;
      while (true) {
        final QueuedItem? next = await _locked(() async {
          final List<QueuedItem> l = await _load();
          if (l.isEmpty) return null;
          final List<QueuedItem> order = List<QueuedItem>.of(l)
            ..sort((QueuedItem a, QueuedItem b) {
              final int pa = a.kind == QueueKind.sos ? 0 : 1, pb = b.kind == QueueKind.sos ? 0 : 1;
              return pa != pb ? pa - pb : a.at.compareTo(b.at);
            });
          return order.first;
        });
        if (next == null) break;
        final (SendOutcome outcome, dynamic response) = await _sendOne(sender, next);
        if (outcome == SendOutcome.delivered) {
          delivered++;
          await remove(next.id);
          for (final void Function(QueuedItem, dynamic) f in List<void Function(QueuedItem, dynamic)>.of(onDelivered)) {
            try {
              f(next, response);
            } catch (_) {}
          }
        } else if (outcome == SendOutcome.rejected) {
          await _locked(() async {
            final List<QueuedItem> l = await _load();
            l.removeWhere((QueuedItem x) => x.id == next.id);
            if (next.isProtected) {
              _rejected.add(<String, dynamic>{'k': next.kind, 'i': next.id, 't': next.at});
              while (_rejected.length > rejectedCap) {
                _rejected.removeAt(0);
              }
            }
            await _save(l);
          });
        } else {
          await _locked(() async {
            final List<QueuedItem> l = await _load();
            for (final QueuedItem x in l) {
              if (x.id == next.id) x.attempts++;
            }
            await _save(l);
          });
          break; // retryLater / stop: keep everything, try again when the server is back
        }
      }
    } finally {
      _flushing = false;
    }
    return delivered;
  }

  /// Tries to send [item] right now; when the server cannot be reached it is
  /// queued instead (and [Submitted.queued] says so, so the screen can show
  /// "not sent yet"). Any other failure (the server said no) is rethrown.
  ///
  /// Order is kept: a chat message waits behind earlier queued ones of the
  /// same circle. While the server is known to be unreachable nothing waits
  /// 15 seconds on a dead connection: the item is saved at once and replayed
  /// when it returns.
  Future<Submitted> submit(
    QueuedItem item, {
    QueueSender? send,
    bool Function()? serverKnownDown,
  }) async {
    final QueueSender sender = send ?? _defaultSend;
    final bool behindOthers = item.kind == QueueKind.chat &&
        (await items(kind: QueueKind.chat)).any((QueuedItem x) => x.meta['circle'] == item.meta['circle']);
    if (behindOthers || (serverKnownDown?.call() ?? false)) {
      if (!await enqueue(item)) throw const QueueFull();
      return const Submitted.queued();
    }
    try {
      return Submitted.sent(await sender(item));
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!isOfflineError(e)) rethrow;
      if (!await enqueue(item)) throw const QueueFull();
      return const Submitted.queued();
    }
  }

  Future<(SendOutcome, dynamic)> _sendOne(QueueSender sender, QueuedItem item) async {
    try {
      return (SendOutcome.delivered, await sender(item));
    } on SessionExpiredException {
      return (SendOutcome.stop, null);
    } catch (e) {
      // An SOS the server calls "already sent a moment ago" reached the family.
      if (item.kind == QueueKind.sos && isRateLimited(e)) return (SendOutcome.delivered, null);
      if (isPermanentRejection(e)) return (SendOutcome.rejected, null);
      return (SendOutcome.retryLater, null);
    }
  }

  Future<dynamic> _defaultSend(QueuedItem item) {
    final Map<String, dynamic>? body = item.body == null ? null : Map<String, dynamic>.of(item.body!);
    // Tell the family it was sent late, so a stale SOS or check-in is not mistaken for live.
    if (body != null && (item.kind == QueueKind.sos || item.kind == QueueKind.checkin)) {
      final Duration late = _clock().difference(DateTime.fromMillisecondsSinceEpoch(item.at));
      if (late > const Duration(minutes: 2)) {
        final DateTime t = DateTime.fromMillisecondsSinceEpoch(item.at);
        final String hh = t.hour.toString().padLeft(2, '0'), mm = t.minute.toString().padLeft(2, '0');
        // The server accepts 280 characters: leave room for the suffix, never lose an SOS to a long note.
        String note = (body['note'] as String? ?? '').trim();
        if (note.runes.length > 230) note = String.fromCharCodes(note.runes.take(230));
        body['note'] = '${note.isEmpty ? '' : '$note '}(sent late, pressed at $hh:$mm)';
      }
    }
    switch (item.method) {
      case 'POST':
        return ApiClient.post(item.path, body: body);
      case 'PUT':
        return ApiClient.put(item.path, body: body);
      case 'PATCH':
        return ApiClient.patch(item.path, body: body);
      case 'DELETE':
        return ApiClient.delete(item.path, body: body);
    }
    throw ArgumentError('unsupported method ${item.method}');
  }
}
