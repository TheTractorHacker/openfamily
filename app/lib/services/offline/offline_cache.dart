import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../e2ee/e2ee_vault.dart';
import 'offline_errors.dart';

/// One cached document and when it was saved.
class CacheEntry {
  const CacheEntry(this.data, this.savedAt);
  final Object? data;
  final DateTime savedAt;
}

/// A value read through the cache, and whether it is the last known copy
/// instead of a fresh answer.
class Cached<T> {
  const Cached(this.value, {this.fromCache = false, this.savedAt});
  final T value;
  final bool fromCache;
  final DateTime? savedAt;
}

/// The last snapshot of what the server told this phone (circles, members and
/// their last positions, places, recent chat, notifications), so the app
/// renders at once and keeps working when the server is down.
///
/// Stored in the same Keystore-wrapped vault as the circle keys (it holds
/// positions, so it is never a plain file) under `offline/v1/`. Bounded:
/// one document is at most [maxBytes]; larger ones are not stored. A vault that
/// refuses (locked phone) just means "no cache right now": reads return
/// nothing, writes are skipped, nothing throws.
class OfflineCache {
  OfflineCache({required this.vault, this.maxBytes = 256 * 1024, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final E2eeVault vault;
  final int maxBytes;
  final DateTime Function() _clock;

  /// The shared instance. Replaced by tests.
  static OfflineCache instance = OfflineCache(vault: SecureVault());

  static const String prefix = 'offline/v1/';
  final Map<String, CacheEntry> _mem = <String, CacheEntry>{};

  String _name(String key) => '$prefix$key';

  Future<CacheEntry?> read(String key) async {
    final CacheEntry? hot = _mem[key];
    if (hot != null) return hot;
    try {
      final Uint8List? raw = await vault.read(_name(key));
      if (raw == null) return null;
      final Map<String, dynamic> m = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final CacheEntry e = CacheEntry(
        m['d'],
        DateTime.fromMillisecondsSinceEpoch((m['t'] as num).toInt(), isUtc: true),
      );
      _mem[key] = e;
      return e;
    } catch (_) {
      return null;
    }
  }

  /// Saves [data] (JSON-encodable). Returns whether it was stored.
  Future<bool> write(String key, Object? data) async {
    try {
      final CacheEntry e = CacheEntry(data, _clock().toUtc());
      final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{
        't': e.savedAt.millisecondsSinceEpoch,
        'd': data,
      })));
      if (bytes.length > maxBytes) return false;
      _mem[key] = e;
      await vault.write(_name(key), bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Like [write], but keeps at most [max] documents per [group] (oldest saved are
  /// deleted first), for caches keyed by something open-ended such as a date range.
  Future<bool> writeInGroup(String group, String key, Object? data, {int max = 30}) async {
    final bool ok = await write(key, data);
    if (!ok) return false;
    try {
      final CacheEntry? idx = await read('idx/$group');
      final List<String> keys = <String>[
        if (idx != null && idx.data is List) ...(idx.data! as List).whereType<String>(),
      ]..remove(key);
      keys.add(key);
      while (keys.length > max) {
        await delete(keys.removeAt(0));
      }
      await write('idx/$group', keys);
    } catch (_) {}
    return true;
  }

  Future<void> delete(String key) async {
    _mem.remove(key);
    try {
      await vault.delete(_name(key));
    } catch (_) {}
  }

  /// Forgets everything (sign-out: the snapshot belongs to the account).
  Future<void> clearAll() async {
    _mem.clear();
    try {
      for (final String n in await vault.names()) {
        if (n.startsWith(prefix)) await vault.delete(n);
      }
    } catch (_) {}
  }

  /// Fetches fresh data and remembers it. When the server cannot be reached
  /// (or is failing) it returns the last copy instead, marked [Cached.fromCache].
  /// With no copy the original error is rethrown, and so is every error that is
  /// an answer from the server (4xx) or a dead session.
  Future<Cached<T>> fetch<T>(
    String key,
    Future<T> Function() load, {
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
    String? group,
    int maxInGroup = 30,
  }) async {
    try {
      final T fresh = await load();
      unawaited(group == null ? write(key, encode(fresh)) : writeInGroup(group, key, encode(fresh), max: maxInGroup));
      return Cached<T>(fresh);
    } catch (e) {
      if (!isOfflineError(e)) rethrow;
      final CacheEntry? c = await read(key);
      if (c != null) {
        try {
          return Cached<T>(decode(c.data), fromCache: true, savedAt: c.savedAt);
        } catch (_) {
          // an unreadable copy is as good as none
        }
      }
      rethrow;
    }
  }
}
