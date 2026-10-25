import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';

import '../models/alert.dart';
import 'api_client.dart';

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
    final Object? at = r['acknowledged_at'];
    return at is String ? DateTime.tryParse(at)?.toLocal() : null;
  }

  Future<void> revokeShare(String id) => ApiClient.revokeAlertShare(id);
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
    return e.message;
  }
  return 'Could not reach the server, so we could not $action. Check your '
      'connection and try again.';
}

/// True when [e] is a 429 cooldown/rate-limit.
bool isCooldownError(Object e) => e is ApiException && e.status == 429;

/// Opens the phone's dialer pre-filled with an emergency number. It only
/// opens the dialer; the user must press call, and OpenFamily never places the
/// call. Android only, via the existing android_intent_plus dependency
/// (ACTION_DIAL needs no permission). 112 is the GSM-standard emergency number
/// that phones route to the local service almost everywhere. iOS has no
/// equivalent dependency, so [available] is false there.
class EmergencyDialer {
  const EmergencyDialer();

  static const String number = '112';

  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> dial() async {
    if (!available) return false;
    try {
      await const AndroidIntent(
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
