import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../token_storage.dart';
import 'diag_model.dart';
import 'diagnostics_probe.dart';

/// Tells the server how this phone is doing (PUT /devices/{id}/diagnostics), so
/// the admin Fleet health page and the "phone went silent" alert can explain
/// themselves. Sends only states and counts: no coordinates, no tokens.
class DiagnosticsReporter {
  DiagnosticsReporter._();

  static const String _lastKey = 'diag_last_report_at';
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
      final String? id = await TokenStorage.readDeviceId();
      if (id == null) return;
      await ApiClient.put('/devices/$id/diagnostics', body: body(f));
      await prefs.setInt(_lastKey, now);
    } catch (_) {
      // Best effort: a failed report must never disturb the app.
    }
  }
}

extension DiagnosticsAutoReport on DiagnosticsReporter {
  /// Collects and sends a report only when one is due (see [minGap]). Called
  /// when the app comes to the foreground; cheap when nothing is due.
  static Future<void> maybeReport() async {
    if (kIsWeb) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? last = prefs.getInt(DiagnosticsReporter._lastKey);
      if (last != null && DateTime.now().millisecondsSinceEpoch - last < DiagnosticsReporter.minGap.inMilliseconds) {
        return;
      }
      await DiagnosticsReporter.report(await DiagnosticsProbe.collect(), force: true);
    } catch (_) {}
  }
}
