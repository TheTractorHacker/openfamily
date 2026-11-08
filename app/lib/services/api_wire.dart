import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Wire-efficiency building blocks used by [ApiClient]
/// (docs/developers/api-efficiency.md). Pure Dart so each part is unit tested
/// with fakes; nothing here touches a screen.

/// Thrown to a caller whose [ApiCancelToken] was cancelled (usually because
/// its screen was disposed). Callers just stop; it is not an error to show.
class ApiCancelled implements Exception {
  const ApiCancelled();
  @override
  String toString() => 'ApiCancelled';
}

/// Lets a screen stop waiting for a request when it is disposed.
///
/// Honest limits: a request already on the wire is not aborted (package:http
/// 1.x cannot), the response is ignored. What it saves is the decode, the
/// state update and the rebuild after the screen is gone. A shared (coalesced)
/// request keeps running for the other callers.
class ApiCancelToken {
  final Completer<void> _c = Completer<void>();
  bool get isCancelled => _c.isCompleted;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }

  /// Completes [work] normally, or throws [ApiCancelled] as soon as the token
  /// is cancelled.
  Future<T> guard<T>(Future<T> work) {
    if (isCancelled) {
      // Swallow the abandoned future's eventual error.
      unawaited(work.then<void>((_) {}, onError: (_) {}));
      return Future<T>.error(const ApiCancelled());
    }
    final Completer<T> out = Completer<T>();
    work.then((T v) {
      if (!out.isCompleted) out.complete(v);
    }, onError: (Object e, StackTrace s) {
      if (!out.isCompleted) out.completeError(e, s);
    });
    _c.future.then((_) {
      if (!out.isCompleted) out.completeError(const ApiCancelled());
    });
    return out.future;
  }
}

/// Shares one in-flight future between simultaneous identical requests.
class RequestCoalescer {
  final Map<String, Future<Object?>> _inFlight = <String, Future<Object?>>{};

  int get inFlight => _inFlight.length;

  Future<T> run<T>(String key, Future<T> Function() start) {
    final Future<Object?>? existing = _inFlight[key];
    if (existing != null) return existing.then((Object? v) => v as T);
    final Future<T> f = start();
    _inFlight[key] = f;
    f.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_inFlight[key], f)) _inFlight.remove(key);
    });
    return f;
  }
}

class CachedResponse {
  const CachedResponse(this.etag, this.bytes, this.contentType);
  final String etag;
  final Uint8List bytes;
  final String contentType;
}

/// Small bounded LRU of validated responses for conditional GETs.
///
/// Bounded on purpose (phones, low-memory tiers): at most [maxEntries]
/// entries, [maxEntryBytes] each, [maxTotalBytes] overall. A 304 is only
/// honoured for a validator this client itself sent, so a stale or foreign
/// entry can never be served as another user's data.
class ConditionalCache {
  ConditionalCache({
    this.maxEntries = 24,
    this.maxEntryBytes = 256 * 1024,
    this.maxTotalBytes = 1024 * 1024,
  });

  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;
  final LinkedHashMap<String, CachedResponse> _m =
      LinkedHashMap<String, CachedResponse>();
  int _total = 0;

  int get length => _m.length;
  int get totalBytes => _total;

  CachedResponse? get(String key) {
    final CachedResponse? v = _m.remove(key);
    if (v != null) _m[key] = v; // most recently used last
    return v;
  }

  void put(String key, CachedResponse v) {
    remove(key);
    if (v.bytes.length > maxEntryBytes) return;
    _m[key] = v;
    _total += v.bytes.length;
    while (_m.length > maxEntries || _total > maxTotalBytes) {
      final String oldest = _m.keys.first;
      remove(oldest);
    }
  }

  void remove(String key) {
    final CachedResponse? old = _m.remove(key);
    if (old != null) _total -= old.bytes.length;
  }

  void clear() {
    _m.clear();
    _total = 0;
  }
}

/// Backoff for idempotent retries: exponential with full-ish jitter.
/// attempt 0 -> ~[250,500] ms, 1 -> ~[500,1000] ms, capped at [capMs].
Duration retryDelay(int attempt, math.Random rng, {int baseMs = 250, int capMs = 4000}) {
  final int exp = math.min(capMs, baseMs * (1 << math.min(attempt, 6)));
  final int ms = exp ~/ 2 + rng.nextInt(exp ~/ 2 + 1);
  return Duration(milliseconds: ms);
}

/// Statuses worth retrying for an idempotent request: the transport failed
/// (0) or a proxy/overloaded server answered 502/503/504 (never 4xx).
bool isTransientStatus(int status) =>
    status == 0 || status == 502 || status == 503 || status == 504;

/// Applies a `?since=` delta response to the local list.
///
/// `full == true`: replace everything with `items`. Otherwise merge `items`
/// by id and drop every local row whose id is not in `ids` (a deletion is the
/// absence of the id, so no tombstone table has to be kept or expired).
List<Map<String, dynamic>> mergeDelta(
  List<Map<String, dynamic>> local,
  Map<String, dynamic> delta,
) {
  final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
    for (final dynamic i in (delta['items'] as List<dynamic>? ?? const <dynamic>[]))
      Map<String, dynamic>.from(i as Map<dynamic, dynamic>),
  ];
  if (delta['full'] == true) return items;
  final Set<String> keep = <String>{
    for (final dynamic i in (delta['ids'] as List<dynamic>? ?? const <dynamic>[])) '$i',
  };
  final Map<String, Map<String, dynamic>> byId = <String, Map<String, dynamic>>{
    for (final Map<String, dynamic> m in local)
      if (keep.contains('${m['id']}')) '${m['id']}': m,
  };
  for (final Map<String, dynamic> m in items) {
    final String id = '${m['id']}';
    byId[id] = <String, dynamic>{...?byId[id], ...m};
  }
  // Keep the server's order where the server told us (ids), else append.
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final dynamic id in (delta['ids'] as List<dynamic>? ?? const <dynamic>[])) {
    final Map<String, dynamic>? m = byId.remove('$id');
    if (m != null) out.add(m);
  }
  out.addAll(byId.values);
  return out;
}

// -----------------------------------------------------------------------------
// HTTP QUERY capability
// -----------------------------------------------------------------------------

/// Where the per-server QUERY capability is remembered.
abstract class QueryCapabilityStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PrefsQueryCapabilityStore implements QueryCapabilityStore {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }
}

class MemoryQueryCapabilityStore implements QueryCapabilityStore {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// Remembers, per server, whether the HTTP QUERY method works end to end
/// (phone, OS network stack, proxy, CDN, server). Decision table:
///
/// * unknown or older than [reprobeAfter]: try QUERY once (a probe);
/// * QUERY worked: keep using it, re-check after [reprobeAfter];
/// * QUERY failed and POST worked: use POST, re-try QUERY after [reprobeAfter];
/// * the server says it has QUERY off (bootstrap `wire.query == false`): POST
///   without a probe.
class QueryCapability {
  QueryCapability({
    QueryCapabilityStore? store,
    DateTime Function()? clock,
    this.reprobeAfter = const Duration(hours: 24),
  })  : _store = store ?? PrefsQueryCapabilityStore(),
        _clock = clock ?? DateTime.now;

  final QueryCapabilityStore _store;
  final DateTime Function() _clock;
  final Duration reprobeAfter;
  final Map<String, bool> _serverFlag = <String, bool>{};

  static String _key(String server) => 'api.query_cap.$server';

  /// The server told us (bootstrap / compat) whether QUERY is enabled.
  void noteServerFlag(String server, bool enabled) => _serverFlag[server] = enabled;

  Future<bool> shouldTryQuery(String server) async {
    if (_serverFlag[server] == false) return false;
    final String? v = await _store.read(_key(server));
    if (v == null) return true; // never probed
    final List<String> p = v.split(':');
    final int? at = p.length == 2 ? int.tryParse(p[1]) : null;
    if (at == null) return true;
    final bool expired =
        _clock().difference(DateTime.fromMillisecondsSinceEpoch(at)) > reprobeAfter;
    if (expired) return true;
    return p[0] == 'query';
  }

  Future<void> recordQueryWorked(String server) =>
      _store.write(_key(server), 'query:${_clock().millisecondsSinceEpoch}');

  Future<void> recordFellBack(String server) =>
      _store.write(_key(server), 'post:${_clock().millisecondsSinceEpoch}');
}

/// Process-wide instances used by [ApiClient].
class ApiWire {
  ApiWire._();

  static final RequestCoalescer coalescer = RequestCoalescer();
  static final ConditionalCache cache = ConditionalCache();
  static QueryCapability queryCapability = QueryCapability();
  static math.Random random = math.Random();

  /// How many times an idempotent GET is retried after a transient failure.
  static int maxGetRetries = 2;

  /// Test hook: forget everything (a new session starts with a clean cache).
  @visibleForTesting
  static void resetForTest() {
    cache.clear();
    queryCapability = QueryCapability(store: MemoryQueryCapabilityStore());
    maxGetRetries = 2;
  }

  /// Statuses on which QUERY is given up in favour of POST. 400 is included
  /// because some proxies/WAFs answer an unknown method with 400.
  static bool queryUnsupportedStatus(int status) =>
      status == 405 || status == 501 || status == 400 || status == 415;

  /// A response that came back 304 turned back into a 200 with the cached body.
  static http.Response fromCache(CachedResponse c, Map<String, String> headers) =>
      http.Response.bytes(c.bytes, 200, headers: <String, String>{
        ...headers,
        'content-type': c.contentType,
      });
}
