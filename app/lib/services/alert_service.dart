import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert.dart';
import 'api_client.dart';
import 'error_copy.dart';
import 'native_uri_opener.dart';

/// Thin wrapper over the alerts endpoints. Screens take one so tests can
/// substitute a fake.
class AlertService {
  const AlertService();

  Future<AlertPage> list({int limit = 20, String? before}) async =>
      AlertPage.fromJson(await ApiClient.listAlerts(limit: limit, before: before));

  Future<AlertDetail> detail(String id) async =>
      AlertDetail.fromJson(await ApiClient.getAlert(id));

  /// Idempotent: repeating it returns the original acknowledgement time.
  Future<DateTime?> acknowledge(String id) async {
    final Map<String, dynamic> r = await ApiClient.ackAlert(id);
    // Remembered on this phone for good: the pop-up for this alert never comes back, even after a restart,
    // even if the list call fails or the alert is still open for others.
    await AckedAlerts.add(id);
    final Object? at = r['acknowledged_at'];
    return at is String ? DateTime.tryParse(at)?.toLocal() : null;
  }

  Future<void> revokeShare(String id) => ApiClient.revokeAlertShare(id);
}

/// The alerts this phone's owner already acknowledged (kept across restarts, newest 200).
class AckedAlerts {
  AckedAlerts._();
  static const String _key = 'acked_alert_ids_v1';
  static Set<String>? _mem;

  static Future<Set<String>> all() async {
    final Set<String>? m = _mem;
    if (m != null) return m;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return _mem = (p.getStringList(_key) ?? const <String>[]).toSet();
    } catch (_) {
      return _mem = <String>{};
    }
  }

  static Future<bool> has(String id) async => (await all()).contains(id);

  static Future<void> add(String id) async {
    final Set<String> s = await all();
    if (!s.add(id)) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final List<String> l = s.toList();
      await p.setStringList(_key, l.length > 200 ? l.sublist(l.length - 200) : l);
    } catch (_) {}
  }

  @visibleForTesting
  static void resetMemory() => _mem = null;
}

/// Friendly text for a failed alert call. Never blames the user for a
/// cooldown and never hides that a send did not go out.
String alertErrorMessage(Object e, {String action = 'send the alert'}) {
  if (e is ApiException) {
    switch (e.status) {
      case 429:
        return e.message.isNotEmpty && e.message != 'too many requests'
            ? '${e.message[0].toUpperCase()}${e.message.substring(1)}.'
            : 'You just sent an alert. Please wait a minute before sending '
                'another. If it is urgent, call your family or emergency '
                'services directly.';
      case 404:
        return 'That alert is no longer available.';
      case 410:
        return 'That link was already turned off.';
      case 401:
      case 403:
        return 'You do not have access to this. Sign in again and retry.';
    }
    if (e.status >= 500) {
      return 'The server had a problem. Try again in a moment.';
    }
    if (e.status != 0) return e.message;
  }
  return actionFailedMessage(e, action);
}

/// True when [e] is a 429 cooldown/rate-limit.
bool isCooldownError(Object e) => e is ApiException && e.status == 429;

/// Emergency number for a region (ISO 3166-1 alpha-2 country code). Covers the
/// common non-112 regions; everything else falls back to 112, the GSM-standard
/// number that phones route to the local service almost everywhere.
String emergencyNumberForCountry(String? countryCode) {
  switch (countryCode?.toUpperCase()) {
    case 'US':
    case 'CA':
    case 'MX':
    case 'PR':
    case 'GU':
    case 'VI':
    case 'AS':
    case 'MP':
      return '911';
    case 'GB':
    case 'GG':
    case 'JE':
    case 'IM':
    case 'HK':
    case 'SG':
      return '999';
    case 'AU':
      return '000';
    case 'NZ':
      return '111';
    case 'JP':
      return '110';
    case 'IN':
      return '112';
    default:
      return '112';
  }
}

/// Opens the phone's dialer pre-filled with an emergency number. It only
/// opens the dialer; the user must press call, and Orbitly never places the
/// call. Android uses android_intent_plus (ACTION_DIAL needs no permission),
/// iOS the `tel:` handler through LinkBridge.swift. The number follows the
/// phone's region.
class EmergencyDialer {
  const EmergencyDialer();

  String get number =>
      emergencyNumberForCountry(PlatformDispatcher.instance.locale.countryCode);

  bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<bool> dial() async {
    if (!available) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return NativeUriOpener.open('tel:$number');
    }
    try {
      await AndroidIntent(
        action: 'android.intent.action.DIAL',
        data: 'tel:$number',
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Live alert frames from the family WebSocket, fed by FamilyService.
class AlertEvents {
  AlertEvents._();

  static final StreamController<Map<String, dynamic>> _alerts =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<Map<String, dynamic>> _acks =
      StreamController<Map<String, dynamic>>.broadcast();

  /// `{"type":"alert", alert_id, alert_type, user_id, name, ...}` frames.
  static Stream<Map<String, dynamic>> get alerts => _alerts.stream;

  /// `{"type":"alert_ack", alert_id, user_id, name, acknowledged_at}` frames.
  static Stream<Map<String, dynamic>> get acks => _acks.stream;

  /// This device's user id (from the WebSocket welcome frame).
  static String? selfUserId;

  static void handleFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'alert':
        if (frame['alert_id'] is String) _alerts.add(frame);
        break;
      case 'alert_ack':
        if (frame['alert_id'] is String) _acks.add(frame);
        break;
    }
  }
}
