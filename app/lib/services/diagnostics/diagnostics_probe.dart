import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api_client.dart';
import '../background_location_service.dart';
import '../e2ee/e2ee_app.dart';
import '../e2ee/e2ee_service.dart' show LocalKeyException;
import '../e2ee/e2ee_vault.dart';
import '../e2ee/private_runtime.dart';
import '../e2ee/private_store.dart';
import '../offline/offline_sync.dart';
import '../location_sharing_service.dart';
import '../server_config.dart';
import '../token_storage.dart';
import 'diag_model.dart';

/// What the server said about this account (GET /me/diagnostics), reduced to
/// the fields the checks need. No coordinates exist in this response.
class ServerView {
  const ServerView({
    required this.state,
    this.lastReportAt,
    this.lastSeenAt,
    this.lastWsAt,
    this.pushRegistered,
    this.pushTransport = '',
    this.lastPushOkAt,
    this.lastPushFailAt,
    this.clockSkew,
    this.privateCircles = 0,
    this.silenceCircles = const <SilenceCircle>[],
  });

  final ServerState state;
  final DateTime? lastReportAt;
  final DateTime? lastSeenAt;
  final DateTime? lastWsAt;
  final bool? pushRegistered;
  final String pushTransport;
  final DateTime? lastPushOkAt;
  final DateTime? lastPushFailAt;
  final Duration? clockSkew;
  final int privateCircles;
  final List<SilenceCircle> silenceCircles;

  /// Parses the response. [deviceId] picks this phone's row; [sentAt] and
  /// [receivedAt] bracket the request so half the round trip is removed from
  /// the clock comparison.
  static ServerView parse(
    Map<String, dynamic> j, {
    required String? deviceId,
    required DateTime sentAt,
    required DateTime receivedAt,
  }) {
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
    final DateTime? serverTime = t(j['server_time']);
    Duration? skew;
    if (serverTime != null) {
      final DateTime mid = sentAt.toUtc().add(receivedAt.difference(sentAt) ~/ 2);
      skew = mid.difference(serverTime);
    }
    Map<String, dynamic>? mine;
    final Object? devs = j['devices'];
    if (devs is List) {
      for (final Object? d in devs) {
        if (d is Map<String, dynamic> && d['id'] == deviceId) mine = d;
      }
    }
    final List<SilenceCircle> circles = <SilenceCircle>[];
    int priv = 0;
    final Object? cs = j['circles'];
    if (cs is List) {
      for (final Object? c in cs) {
        if (c is! Map<String, dynamic>) continue;
        if (c['private'] == true) priv++;
        circles.add(SilenceCircle(
          id: (c['id'] as String?) ?? '',
          name: (c['name'] as String?) ?? '',
          hours: (c['silence_alert_hours'] as num?)?.toInt() ?? 0,
          isPrivate: c['private'] == true,
        ));
      }
    }
    return ServerView(
      state: ServerState.ok,
      lastReportAt: t(j['last_report_at']),
      lastSeenAt: t(mine?['last_seen']),
      lastWsAt: t(j['last_ws_at']),
      pushRegistered: mine == null ? null : mine['push_registered'] == true,
      pushTransport: (mine?['push_transport'] as String?) ?? '',
      lastPushOkAt: t(mine?['last_push_ok_at']),
      lastPushFailAt: t(mine?['last_push_fail_at']),
      clockSkew: skew,
      privateCircles: priv,
      silenceCircles: circles,
    );
  }
}

class SilenceCircle {
  const SilenceCircle({required this.id, required this.name, required this.hours, required this.isPrivate});
  final String id;
  final String name;
  final int hours;
  final bool isPrivate;
}

/// Gathers [DiagFacts] from the real phone. Every probe is isolated: one that
/// throws leaves its field null, which the checks report honestly.
class DiagnosticsProbe {
  DiagnosticsProbe._();

  static const MethodChannel _ch = MethodChannel('app.openfamily/diagnostics');

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<T?> _try<T>(Future<T?> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> nativeState() async {
    if (!_android) return null;
    return _try(() async {
      final Map<dynamic, dynamic>? m = await _ch.invokeMethod<Map<dynamic, dynamic>>('state');
      return m?.cast<String, dynamic>();
    });
  }

  /// Opens a vendor screen. Returns its label, or null if the vendor has none.
  static Future<String?> openOemSettings(String kind) async {
    if (!_android) return null;
    return _try(() => _ch.invokeMethod<String>('openOemSettings', <String, dynamic>{'kind': kind}));
  }

  static Future<ServerView> server() async {
    final DateTime sent = DateTime.now();
    try {
      final dynamic res = await ApiClient.get('/me/diagnostics');
      final DateTime received = DateTime.now();
      if (res is! Map<String, dynamic>) return const ServerView(state: ServerState.unknown);
      return ServerView.parse(res,
          deviceId: await TokenStorage.readDeviceId(), sentAt: sent, receivedAt: received);
    } on SessionExpiredException {
      return const ServerView(state: ServerState.authFailed);
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) return const ServerView(state: ServerState.authFailed);
      if (e.status == 404) {
        // An older server without /me/diagnostics: reachable, just no detail.
        return const ServerView(state: ServerState.ok);
      }
      return const ServerView(state: ServerState.unreachable);
    } catch (_) {
      return const ServerView(state: ServerState.unreachable);
    }
  }

  static String _host() {
    final String base = ServerConfig.instance.apiBaseUrl;
    return Uri.tryParse(base)?.host ?? '';
  }

  /// [light] skips the server round trip and the Private-store/key-store checks:
  /// enough for the health report, and nothing in it can hang.
  static Future<DiagFacts> collect({PackageVersion? version, bool light = false}) async {
    final Map<String, dynamic>? n = await nativeState();
    final bool? serviceOn = await _try(() => Geolocator.isLocationServiceEnabled());
    final bool whenInUse = await _try(() async => (await Permission.locationWhenInUse.status).isGranted) ?? false;
    final bool always = await _try(() async => (await Permission.locationAlways.status).isGranted) ?? false;
    final String perm = always ? 'always' : (whenInUse ? 'while_in_use' : 'denied');
    bool? precise;
    if (whenInUse || always) {
      final LocationAccuracyStatus? acc = await _try(() => Geolocator.getLocationAccuracy());
      if (acc != null) precise = acc == LocationAccuracyStatus.precise;
    }
    final bool? notif = await _try(() async => (await Permission.notification.status).isGranted);
    final List<ConnectivityResult>? net = await _try(() => Connectivity().checkConnectivity());
    final bool? online = net == null ? null : !(net.isEmpty || net.every((ConnectivityResult r) => r == ConnectivityResult.none));
    final ServerView sv = light ? const ServerView(state: ServerState.unknown) : online == false ? const ServerView(state: ServerState.unreachable) : await server();
    final int? outbox = await _try(() => OfflineSync.pendingCount());
    final bool? bg = _android ? await _try(() => BackgroundLocationService.isRunning()) : null;
    final String? deviceId = await _try(() => TokenStorage.readDeviceId());

    bool? storeExcluded;
    String storeError = '';
    try {
      if (light) throw StateError('light');
      await PrivateStore.files();
      storeExcluded = PrivateStore.status.backupExcluded;
      storeError = PrivateStore.status.error;
    } catch (_) {}
    final bool hasPrivate = !light && sv.privateCircles > 0 || ((await _try(() => PrivateRuntime.instance.privateCircles()))?.isNotEmpty ?? false);
    bool? vaultOk;
    String vaultDetail = '';
    bool needsUnlock = false, userAuth = false;
    if (hasPrivate) {
      try {
        final E2eeVault vault = SecureVault();
        final KeystoreStatus st = await vault.status();
        needsUnlock = st.unlockedDeviceRequired;
        userAuth = st.userAuthRequired;
        // A real decrypt of a stored secret proves the Keystore key still works.
        await E2eeApp.service.hasIdentity();
        vaultOk = true;
        // The same checks the app makes when it uses the key (the account note, the device id, the key size), so this
        // check cannot pass while the Encryption keys screen says the key cannot be read. A network or session
        // failure while asking who is signed in says nothing about the key and is ignored here.
        try {
          await E2eeApp.service.identity();
        } on LocalKeyException catch (e) {
          vaultOk = false;
          vaultDetail = e.reasonCode.isEmpty ? 'unreadable' : 'unreadable: ${e.reasonCode}';
        } on VaultInvalidatedException {
          rethrow;
        } catch (_) {}
      } on VaultInvalidatedException {
        vaultOk = false;
        vaultDetail = 'the key store was reset';
      } catch (_) {
        vaultOk = false;
        vaultDetail = 'unreadable';
      }
    }

    // The Private pipeline (counts, times, short codes): not in the light probe, which feeds the fleet report.
    final PrivateDeliveryFacts? delivery =
        hasPrivate && !light ? await _try(() => PrivateRuntime.instance.deliveryFacts()) : null;

    return DiagFacts(
      now: DateTime.now().toUtc(),
      isAndroid: _android,
      manufacturer: (n?['manufacturer'] as String?) ?? '',
      model: (n?['model'] as String?) ?? '',
      osRelease: (n?['release'] as String?) ?? '',
      sdk: (n?['sdk'] as num?)?.toInt(),
      appVersion: version?.label ?? '',
      locationService: serviceOn,
      locationPermission: perm,
      preciseLocation: precise,
      notificationsGranted: notif,
      ignoringBatteryOptimizations: n?['ignoringBatteryOptimizations'] as bool?,
      backgroundRestricted: n?['backgroundRestricted'] as bool?,
      powerSave: n?['powerSave'] as bool?,
      networkOnline: online,
      server: sv.state,
      serverHost: _host(),
      lastReportAt: sv.lastReportAt,
      lastSeenAt: sv.lastSeenAt,
      lastWsAt: sv.lastWsAt,
      outboxPending: outbox,
      pushRegistered: sv.pushRegistered,
      pushTransport: sv.pushTransport,
      lastPushOkAt: sv.lastPushOkAt,
      lastPushFailAt: sv.lastPushFailAt,
      clockSkew: sv.clockSkew,
      backgroundServiceRunning: bg,
      sharingEnabled: LocationSharingService.enabled.value,
      hasPrivateCircle: hasPrivate,
      storeBackupExcluded: storeExcluded,
      storeBackupError: storeError,
      vaultReadable: vaultOk,
      vaultDetail: vaultDetail,
      vaultNeedsUnlock: needsUnlock,
      vaultUserAuth: userAuth,
      deviceIdSuffix: deviceId == null || deviceId.length < 4 ? '' : deviceId.substring(deviceId.length - 4),
      privateDelivery: delivery,
    );
  }
}

/// App version label for the report (from package_info_plus, injected so the
/// probe does not need the plugin in tests).
class PackageVersion {
  const PackageVersion(this.label);
  final String label;
}
