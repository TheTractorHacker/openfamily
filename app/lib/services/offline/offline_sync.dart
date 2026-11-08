import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../api_client.dart';
import '../chat_service.dart';
import '../e2ee/private_runtime.dart';
import '../location_outbox.dart';
import 'offline_cache.dart';
import 'offline_queue.dart';
import 'server_reachability.dart';

/// Glue for local-first operation: starts the reachability probe, flushes every
/// store-and-forward queue when the server is back, and keeps the "N updates
/// waiting" count current. One `start()` after sign-in; idempotent.
class OfflineSync {
  OfflineSync._();

  static StreamSubscription<List<ConnectivityResult>>? _net;
  static bool _started = false;
  static Timer? _pendingTimer;

  /// Wires [ServerReachability.instance] to `GET /healthz`.
  static void start() {
    if (_started) return;
    _started = true;
    final ServerReachability r = ServerReachability.instance;
    r.probe = () async {
      try {
        await ApiClient.healthz();
        return true;
      } catch (_) {
        return false;
      }
    };
    if (!r.onRecovered.contains(flushAll)) r.onRecovered.add(flushAll);
    OfflineQueue.instance.onDelivered.add(ChatEvents.handleQueueDelivered);
    OfflineQueue.instance.count.addListener(_scheduleRefresh);
    try {
      _net = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
        final bool up = results.any((ConnectivityResult c) => c != ConnectivityResult.none);
        r.connectivityChanged(connected: up);
        if (up) unawaited(flushAll());
      });
    } catch (_) {
      // No connectivity plugin (tests, desktop): probing by failures still works.
    }
    unawaited(refreshPending());
  }

  static void _scheduleRefresh() {
    _pendingTimer ??= Timer(const Duration(milliseconds: 300), () {
      _pendingTimer = null;
      unawaited(refreshPending());
    });
  }

  /// Sends everything that is waiting, oldest first, SOS first. Safe to call
  /// often: each queue is single-flight and does nothing when empty.
  static Future<void> flushAll() async {
    try {
      await OfflineQueue.instance.flush();
    } catch (_) {}
    try {
      await LocationOutbox.drainAll(send: sendOutboxBatchViaApi);
    } catch (_) {}
    try {
      await PrivateRuntime.instance.flush();
    } catch (_) {}
    await refreshPending();
  }

  /// How many updates wait on this phone, all queues together.
  static Future<int> pendingCount() async {
    int n = 0;
    try {
      n += await OfflineQueue.instance.size();
    } catch (_) {}
    try {
      n += await LocationOutbox.size();
    } catch (_) {}
    try {
      n += await PrivateRuntime.instance.queue.length();
    } catch (_) {}
    return n;
  }

  static Future<void> refreshPending() async {
    ServerReachability.instance.setPending(await pendingCount());
  }

  /// Sign-out: the snapshot and the queued updates belong to the account.
  static Future<void> clearAll() async {
    await OfflineCache.instance.clearAll();
    await OfflineQueue.instance.clear();
    try {
      await PrivateRuntime.instance.forgetAccount();
    } catch (_) {}
    try {
      (await SharedPreferences.getInstance()).remove(_ownerKey);
    } catch (_) {}
    ServerReachability.instance.setPending(0);
  }

  /// After a sign-in: what waits on this phone belongs to whoever created it. A session that only ran out is
  /// kept for the same person; a different person signing in must never inherit (or send) it.
  static Future<void> adoptAccount(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? owner = prefs.getString(_ownerKey);
      if (owner != null && owner.isNotEmpty && owner != userId) await clearAll();
      await prefs.setString(_ownerKey, userId);
    } catch (_) {}
  }

  static const String _ownerKey = 'offline_owner_user_id';

  static Future<void> stop() async {
    await _net?.cancel();
    _net = null;
    _started = false;
  }
}
