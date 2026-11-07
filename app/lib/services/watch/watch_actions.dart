import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/alert.dart';
import '../alert_service.dart';
import '../api_client.dart';
import '../chat_service.dart';
import '../circle_service.dart';
import '../e2ee/private_runtime.dart';
import '../location_reporter.dart';
import '../location_service.dart';
import '../sharing_service.dart';
import 'watch_snapshot.dart';

/// Things the phone knows besides the live roster, fetched at most once a
/// minute while a watch is listening.
class WatchExtras {
  const WatchExtras({
    this.circles = const <WatchCircle>[],
    this.alerts = const <WatchAlert>[],
    this.pausedUntil,
    this.paused = false,
  });

  final List<WatchCircle> circles;
  final List<WatchAlert> alerts;
  final bool paused;
  final DateTime? pausedUntil;
}

/// A command failed in a way the watch should show in plain words.
class WatchCommandException implements Exception {
  const WatchCommandException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the watch is allowed to make the phone do. The phone runs these with
/// its own credentials and keys; the watch never holds either. Tests fake it.
abstract class WatchPhoneActions {
  Future<WatchExtras> extras();
  Future<void> sos();
  Future<void> resolveSos();
  Future<void> checkIn(List<String> recipientIds);
  Future<void> pause(int minutes);
  Future<void> resume();
  Future<void> reply(String circleId, String text);
  Future<void> markRead(String circleId);
}

/// The real thing, on top of the app's own services.
class DefaultWatchActions implements WatchPhoneActions {
  const DefaultWatchActions();

  static const String _alertIdKey = 'sos_active_alert_id';
  static const String _alertAtKey = 'sos_active_alert_at';

  @override
  Future<WatchExtras> extras() async {
    List<WatchCircle> circles = const <WatchCircle>[];
    List<WatchAlert> alerts = const <WatchAlert>[];
    bool paused = false;
    DateTime? until;
    try {
      final Map<String, int> unread = await ChatService.instance.unread();
      final list = await CircleService.instance.listCircles();
      circles = <WatchCircle>[
        for (final c in list) WatchCircle(id: c.id, name: c.name, unread: unread[c.id] ?? 0),
      ];
    } catch (_) {}
    try {
      final AlertPage page = await const AlertService().list(limit: kWatchAlertCap);
      alerts = <WatchAlert>[
        for (final AlertSummary a in page.alerts.where((AlertSummary a) => !a.kind.isBubble))
          WatchAlert(
            id: a.id,
            kind: a.kind.name,
            title: '${alertKindLabel(a.kind)} from ${a.senderName}',
            body: a.note,
            ts: a.createdAt,
            active: a.isActive,
          ),
      ];
    } catch (_) {}
    try {
      final SharingPause p = await const SharingService().pauseStatus();
      paused = p.activeAt(DateTime.now());
      until = paused ? p.until : null;
    } catch (_) {}
    return WatchExtras(circles: circles, alerts: alerts, paused: paused, pausedUntil: until);
  }

  @override
  Future<void> sos() async {
    final position = await LocationService.currentPosition();
    final Map<String, dynamic> body = <String, dynamic>{};
    if (position != null) {
      body['lat'] = position.latitude;
      body['lon'] = position.longitude;
    }
    final dynamic response = await ApiClient.post('/alerts/sos', body: body);
    unawaited(PrivateRuntime.instance.sealAlertPosition('sos', body['lat'] as double?, body['lon'] as double?));
    if (response is Map && response['id'] is String && (response['id'] as String).isNotEmpty) {
      // The same keys the phone's own SOS screen restores from.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_alertIdKey, response['id'] as String);
      await prefs.setInt(_alertAtKey, DateTime.now().millisecondsSinceEpoch);
    }
    LocationReporter.startSosBurst();
  }

  @override
  Future<void> resolveSos() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? id = prefs.getString(_alertIdKey);
    if (id == null || id.isEmpty) throw const WatchCommandException('No active SOS on the iPhone.');
    await ApiClient.post('/alerts/$id/resolve');
    await prefs.remove(_alertIdKey);
    await prefs.remove(_alertAtKey);
    LocationReporter.stopSosBurst();
  }

  @override
  Future<void> checkIn(List<String> recipientIds) async {
    if (recipientIds.isEmpty) {
      throw const WatchCommandException('Open Orbitly on the iPhone once, then try again.');
    }
    final position = await LocationService.currentPosition();
    await const SharingService().checkIn(
      recipientIds: recipientIds,
      note: 'I\'m OK',
      lat: position?.latitude,
      lon: position?.longitude,
    );
  }

  @override
  Future<void> pause(int minutes) async {
    await const SharingService().pause(minutes: minutes);
  }

  @override
  Future<void> resume() => const SharingService().resume();

  @override
  Future<void> reply(String circleId, String text) async {
    // Only the fixed phrases, so a rogue message cannot send free text.
    if (!kWatchQuickReplies.contains(text)) {
      throw const WatchCommandException('That reply is not available.');
    }
    await ChatService.instance.send(circleId, text);
  }

  @override
  Future<void> markRead(String circleId) => ChatService.instance.markRead(circleId);
}
