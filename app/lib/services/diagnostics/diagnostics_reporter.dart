import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../app_compat.dart';
import '../device_service.dart';
import '../token_storage.dart';
import 'diag_model.dart';
import 'diagnostics_probe.dart';

/// Tells the server how this phone is doing (PUT /devices/{id}/diagnostics), so
/// the admin Fleet health page and the "phone went silent" alert can explain
/// themselves. Sends only states and counts: no coordinates, no tokens.
class DiagnosticsReporter {
  DiagnosticsReporter._();

  static const String _lastKey = 'diag_last_report_at';
  static const String _versionKey = 'diag_last_report_version';
  static const Duration minGap = Duration(minutes: 30);

  /// The wire body for [f]. Pure, so the redaction is testable.
  static Map<String, dynamic> body(DiagFacts f) => <String, dynamic>{
        'os_version': f.osRelease.isEmpty ? '' : 'Android ${f.osRelease}${f.sdk == null ? '' : ' (SDK ${f.sdk})'}',
        'battery_opt': f.backgroundRestricted == true
            ? 'restricted'
            : f.ignoringBatteryOptimizations == true
                ? 'unrestricted'
                : f.ignoringBatteryOptimizations == false
                    ? 'optimized'
                    : 'unknown',
        if (f.outboxPending != null) 'outbox_pending': f.outboxPending,
        'loc_permission': f.locationPermission ?? 'unknown',
        'notif_permission': f.notificationsGranted == null ? 'unknown' : (f.notificationsGranted! ? 'granted' : 'denied'),
        if (f.backgroundServiceRunning != null) 'bg_service': f.backgroundServiceRunning,
        if (f.appVersion.isNotEmpty) 'app_version': f.appVersion,
      };

  /// Sends the report unless one went out within [minGap] (or [force]).
  /// Never throws.
  static Future<void> report(DiagFacts f, {bool force = false}) async {
    if (kIsWeb) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? last = prefs.getInt(_lastKey);
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (!force && last != null && now - last < minGap.inMilliseconds) return;
      // A phone that registered its device before ids were stored (or whose
      // store was cleared) has no id: register/look it up instead of giving up.
      final String id = (await TokenStorage.readDeviceId()) ?? await DeviceService.ensureRegistered();
      final Map<String, dynamic> b = body(f);
      await ApiClient.put('/devices/$id/diagnostics', body: b);
      await prefs.setInt(_lastKey, now);
      final Object? v = b['app_version'];
      if (v is String) await prefs.setString(_versionKey, v);
    } catch (_) {
      // Best effort: a failed report must never disturb the app.
    }
  }
}

extension DiagnosticsAutoReport on DiagnosticsReporter {
  /// Whether a report is due: none yet, the last one is older than
  /// [DiagnosticsReporter.minGap], or the app version changed since (an update).
  static bool due({required int? lastMs, required int nowMs, required String? lastVersion, required String version}) {
    if (lastMs == null) return true;
    if (version.isNotEmpty && lastVersion != version) return true;
    return nowMs - lastMs >= DiagnosticsReporter.minGap.inMilliseconds;
  }

  static bool _running = false;

  /// Collects and sends a report only when one is due. Called at start-up,
  /// on login, when the app comes to the foreground and from the foreground
  /// reporter's heartbeat; cheap when nothing is due. Uses a light probe (no
  /// server round trip, no key-store reads) so it cannot stall.
  static Future<void> maybeReport({bool force = false}) async {
    if (kIsWeb || _running) return;
    _running = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String version = AppCompat.version;
      if (!force &&
          !due(
            lastMs: prefs.getInt(DiagnosticsReporter._lastKey),
            nowMs: DateTime.now().millisecondsSinceEpoch,
            lastVersion: prefs.getString(DiagnosticsReporter._versionKey),
            version: version,
          )) {
        return;
      }
      await DiagnosticsReporter.report(await DiagnosticsProbe.collect(version: PackageVersion(version), light: true), force: true);
    } catch (_) {
    } finally {
      _running = false;
    }
  }
}
