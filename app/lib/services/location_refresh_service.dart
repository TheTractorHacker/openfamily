import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'battery_report.dart';
import 'device_service.dart';
import 'e2ee/private_runtime.dart';
import 'location_sharing_service.dart';
import 'tracking_wake.dart';

enum LocationRefreshResult {
  notCommand,
  expired,
  duplicate,
  sharingDisabled,
  locationSent,
  heartbeatSent,
  failed,

  /// A Private-circle wake-up was handled (anything to show was raised as a
  /// local notification by the runtime; the raw push is never shown).
  wakeHandled,
}

class LocationRefreshCommand {
  const LocationRefreshCommand({
    required this.requestId,
    required this.expiresAt,
  });

  final String requestId;
  final DateTime expiresAt;

  static LocationRefreshCommand? parse(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['type'] != 'location_request') {
        return null;
      }
      final String? requestId = decoded['request_id'] as String?;
      final String? expiresAt = decoded['expires_at'] as String?;
      final DateTime? expiry = DateTime.tryParse(expiresAt ?? '')?.toUtc();
      if (requestId == null ||
          requestId.isEmpty ||
          requestId.length > 128 ||
          expiry == null) {
        return null;
      }
      return LocationRefreshCommand(
        requestId: requestId,
        expiresAt: expiry,
      );
    } catch (_) {
      return null;
    }
  }
}

typedef RefreshSharingEnabled = Future<bool> Function();
typedef RefreshGetPosition = Future<Position> Function();
typedef RefreshGetDeviceId = Future<String> Function();
typedef RefreshGetBattery = Future<int?> Function();
typedef RefreshGetCharging = Future<bool?> Function();
typedef RefreshPost = Future<dynamic> Function(
  String path,
  Map<String, dynamic> body,
);
typedef RefreshWasProcessed = Future<bool> Function(String requestId);
typedef RefreshMarkProcessed = Future<void> Function(String requestId);

/// Executes a short-lived location request received over UnifiedPush.
///
/// Dependencies are injectable so expiry, duplicate delivery, GPS failure,
/// and successful uploads can be unit tested without native plugins.
class LocationRefreshHandler {
  LocationRefreshHandler({
    required this.sharingEnabled,
    required this.getPosition,
    required this.getDeviceId,
    required this.getBattery,
    required this.post,
    required this.wasProcessed,
    required this.markProcessed,
    RefreshGetCharging? getCharging,
    DateTime Function()? now,
  })  : getCharging = getCharging ?? (() async => null),
        now = now ?? (() => DateTime.now().toUtc());

  final RefreshSharingEnabled sharingEnabled;
  final RefreshGetPosition getPosition;
  final RefreshGetDeviceId getDeviceId;
  final RefreshGetBattery getBattery;

  /// Charging state sent with the battery level; null when unknown.
  final RefreshGetCharging getCharging;
  final RefreshPost post;
  final RefreshWasProcessed wasProcessed;
  final RefreshMarkProcessed markProcessed;
  final DateTime Function() now;

  Future<LocationRefreshResult> handle(String raw) async {
    final LocationRefreshCommand? command = LocationRefreshCommand.parse(raw);
    if (command == null) return LocationRefreshResult.notCommand;
    if (!command.expiresAt.isAfter(now())) return LocationRefreshResult.expired;
    if (await wasProcessed(command.requestId)) {
      return LocationRefreshResult.duplicate;
    }
    await markProcessed(command.requestId);
    if (!await sharingEnabled()) return LocationRefreshResult.sharingDisabled;

    String deviceId;
    int? batteryPct;
    bool? charging;
    try {
      deviceId = await getDeviceId();
      batteryPct = await getBattery();
    } catch (_) {
      return LocationRefreshResult.failed;
    }
    try {
      charging = batteryPct == null ? null : await getCharging();
    } catch (_) {
      charging = null;
    }

    try {
      final Position position = await getPosition();
      if (position.isMocked) return LocationRefreshResult.failed;
      final Map<String, dynamic> body = <String, dynamic>{
        'device_id': deviceId,
        'ts': position.timestamp.toUtc().toIso8601String(),
        'lat': position.latitude,
        'lon': position.longitude,
        'accuracy_meters': position.accuracy,
        'altitude_meters': position.altitude,
        'source': 'requested',
      };
      if (position.speed >= 0) body['speed_mps'] = position.speed;
      if (position.heading >= 0) body['heading_deg'] = position.heading;
      addBatteryFields(body, batteryPct, charging);
      await post('/locations', body);
      return LocationRefreshResult.locationSent;
    } catch (_) {
      // A heartbeat lets viewers distinguish a reachable phone from one that
      // is entirely offline, without inventing or moving its last position.
      try {
        final Map<String, dynamic> body = <String, dynamic>{
          'device_id': deviceId,
        };
        addBatteryFields(body, batteryPct, charging);
        await post('/devices/heartbeat', body);
        return LocationRefreshResult.heartbeatSent;
      } catch (_) {
        return LocationRefreshResult.failed;
      }
    }
  }
}

class LocationRefreshService {
  LocationRefreshService._();

  static const String _processedKey = 'processed_location_request_ids';
  static const int _maxProcessedIds = 32;

  static final LocationRefreshHandler _handler = LocationRefreshHandler(
    sharingEnabled: LocationSharingService.load,
    getPosition: () async {
      final LocationPermission permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always) {
        throw StateError('background location permission is not granted');
      }
      return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
    },
    getDeviceId: DeviceService.ensureRegistered,
    getBattery: () async {
      try {
        return await Battery().batteryLevel;
      } catch (_) {
        return null;
      }
    },
    getCharging: readCharging,
    post: (String path, Map<String, dynamic> body) async {
      // A location a member asked for follows the same rule as every fix: sealed
      // for Private circles, plaintext only for standard ones.
      if (path == '/locations') {
        try {
          if (!await PrivateRuntime.instance.routeFix(body)) return <String, dynamic>{};
        } catch (_) {}
      }
      return ApiClient.post(path, body: body);
    },
    wasProcessed: _wasProcessed,
    markProcessed: _markProcessed,
  );

  static Future<LocationRefreshResult> handlePush(String body) {
    // Content-free wake-up of a Private circle ({"type":"e2ee_wake","circle_id"}):
    // fetch what is waiting, decrypt it here and raise any local notification.
    final String? wake = _wakeCircle(body);
    if (wake != null) {
      return PrivateRuntime.instance.catchUp(wake).then((_) => LocationRefreshResult.wakeHandled,
          onError: (Object _) => LocationRefreshResult.failed);
    }
    // A location request is also a wake-up of this process: bring the tracking
    // service back if it should be running and is not (the answer is journalled;
    // Android may refuse a background start). Never delays or fails the fix.
    final LocationRefreshCommand? command = LocationRefreshCommand.parse(body);
    if (command != null && command.expiresAt.isAfter(DateTime.now().toUtc())) {
      unawaited(TrackingWake.fromPush());
    }
    return _handler.handle(body);
  }

  static String? _wakeCircle(String raw) {
    try {
      final dynamic d = jsonDecode(raw);
      if (d is Map<String, dynamic> && d['type'] == 'e2ee_wake') {
        final Object? c = d['circle_id'];
        if (c is String && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(c)) return c.toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>> request(String memberId) async {
    final dynamic response = await ApiClient.post(
      '/family/members/${Uri.encodeComponent(memberId)}/location-request',
    );
    return response as Map<String, dynamic>;
  }

  static Future<bool> _wasProcessed(String requestId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_processedKey) ?? const <String>[])
        .contains(requestId);
  }

  static Future<void> _markProcessed(String requestId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> ids = <String>[
      requestId,
      ...(prefs.getStringList(_processedKey) ?? const <String>[])
          .where((String id) => id != requestId),
    ];
    await prefs.setStringList(
      _processedKey,
      ids.take(_maxProcessedIds).toList(growable: false),
    );
  }
}
