import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' show navigatorKey;
import '../models/alert.dart';
import '../screens/alert_received_screen.dart';
import 'alert_service.dart';

/// Opens the recipient alert screen for alerts that arrive while the app is
/// open (WebSocket `alert` frames) and when the app returns to the foreground
/// after the user tapped an alert notification.
///
/// Push payloads deliberately carry no alert id or coordinates, so a
/// notification tap just opens the app; on resume we look up the newest
/// active alert from someone else that this device has not shown yet.
class AlertRouter with WidgetsBindingObserver {
  AlertRouter._();
  static final AlertRouter instance = AlertRouter._();

  AlertService service = const AlertService();
  final Set<String> _shown = <String>{};
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _started = false;
  bool _checking = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _sub = AlertEvents.alerts.listen(_onFrame);
  }

  @visibleForTesting
  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _sub = null;
    _started = false;
    _shown.clear();
  }

  /// Like [show], but first asks the phone's own memory of what was acknowledged (it survives restarts).
  Future<bool> showIfOpen(AlertSummary s) async {
    if (await AckedAlerts.has(s.id)) return false;
    return show(s);
  }

  void _onFrame(Map<String, dynamic> f) {
    final String? self = AlertEvents.selfUserId;
    if (self == null || f['user_id'] == self) return;
    final Object? at = f['created_at'];
    final AlertSummary s = AlertSummary.fromJson(<String, dynamic>{
      'id': f['alert_id'],
      'type': f['alert_type'],
      'status': 'active',
      'user_id': f['user_id'],
      'sender_name': f['name'],
      'note': f['note'],
      'created_at': at is String ? at : DateTime.now().toIso8601String(),
    });
    unawaited(showIfOpen(s));
  }

  /// Pushes the recipient screen once per alert id. An alert this person already acknowledged never opens again
  /// (see [showIfOpen] for the paths that cannot know that synchronously).
  bool show(AlertSummary s) {
    if (s.id.isEmpty || s.acknowledgedAt != null || _shown.contains(s.id)) return false;
    final NavigatorState? nav = navigatorKey.currentState;
    if (nav == null) return false; // not remembered: it can still be shown once the app has a screen
    _shown.add(s.id);
    nav.push(MaterialPageRoute<void>(
      builder: (_) => AlertReceivedScreen(alert: s, service: service),
    ));
    return true;
  }

  /// Opens one alert by id (tap on a direct-push notification). Falls back to
  /// the newest active alert when it cannot be loaded.
  Future<void> openById(String id) async {
    if (id.isEmpty) return checkActive();
    try {
      final AlertDetail d = await service.detail(id);
      if (!await showIfOpen(d.summary)) return;
    } catch (_) {
      await checkActive();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkActive());
  }

  /// Shows the newest unseen active alert from someone else, if any.
  Future<void> checkActive() async {
    if (_checking) return;
    _checking = true;
    try {
      final AlertPage p = await service.list(limit: 5);
      final String? self = AlertEvents.selfUserId;
      if (self == null) return;
      final DateTime cutoff = DateTime.now().subtract(const Duration(hours: 6));
      for (final AlertSummary a in p.alerts) {
        if (a.isActive &&
            a.userId != self &&
            a.createdAt.isAfter(cutoff) &&
            a.acknowledgedAt == null &&
            !_shown.contains(a.id) &&
            !await AckedAlerts.has(a.id)) {
          show(a);
          break;
        }
      }
    } catch (_) {
      // Not signed in or offline: nothing to show.
    } finally {
      _checking = false;
    }
  }
}
