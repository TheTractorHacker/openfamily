import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:openfamily/services/location_refresh_service.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 8, 25, 12);

  String command({
    String id = 'request-1',
    Duration expiresIn = const Duration(seconds: 30),
  }) =>
      jsonEncode(<String, dynamic>{
        'type': 'location_request',
        'request_id': id,
        'requested_at': now.toIso8601String(),
        'expires_at': now.add(expiresIn).toIso8601String(),
      });

  test('ignores ordinary notifications and expired commands', () async {
    final LocationRefreshHandler handler = _handler(now: now);

    expect(
      await handler.handle('Family member arrived at Home'),
      LocationRefreshResult.notCommand,
    );
    expect(
      await handler.handle(command(expiresIn: Duration.zero)),
      LocationRefreshResult.expired,
    );
  });

  test('deduplicates a redelivered request id', () async {
    final Set<String> processed = <String>{'request-1'};
    final LocationRefreshHandler handler = _handler(
      now: now,
      processed: processed,
    );

    expect(
      await handler.handle(command()),
      LocationRefreshResult.duplicate,
    );
  });

  test('posts one requested high-accuracy fix', () async {
    final List<(String, Map<String, dynamic>)> posts =
        <(String, Map<String, dynamic>)>[];
    final LocationRefreshHandler handler = _handler(now: now, posts: posts);

    expect(
      await handler.handle(command()),
      LocationRefreshResult.locationSent,
    );
    expect(posts, hasLength(1));
    expect(posts.single.$1, '/locations');
    expect(posts.single.$2['device_id'], 'device-1');
    expect(posts.single.$2['source'], 'requested');
    expect(posts.single.$2['lat'], 37.1);
    expect(posts.single.$2['battery_pct'], 73);
  });

  test('a requested fix without a speed never uploads a made-up 0', () async {
    final List<(String, Map<String, dynamic>)> posts =
        <(String, Map<String, dynamic>)>[];
    final LocationRefreshHandler handler = _handler(
      now: now,
      posts: posts,
      getPosition: () async => Position(
        longitude: -122.2,
        latitude: 37.1,
        timestamp: now,
        accuracy: 10,
        altitude: 12,
        altitudeAccuracy: 2,
        heading: 90,
        headingAccuracy: 4,
        speed: 0, // Android: "no speed" arrives as 0.0
        speedAccuracy: 0, // and no stated accuracy
      ),
    );
    await handler.handle(command());
    expect(posts.single.$2.containsKey('speed_mps'), isFalse);
  });

  test('falls back to a heartbeat when GPS has no fix', () async {
    final List<(String, Map<String, dynamic>)> posts =
        <(String, Map<String, dynamic>)>[];
    final LocationRefreshHandler handler = _handler(
      now: now,
      posts: posts,
      getPosition: () => throw StateError('no fix'),
    );

    expect(
      await handler.handle(command()),
      LocationRefreshResult.heartbeatSent,
    );
    expect(posts.single.$1, '/devices/heartbeat');
    expect(posts.single.$2['device_id'], 'device-1');
  });

  test('does not report when location sharing is disabled', () async {
    final List<(String, Map<String, dynamic>)> posts =
        <(String, Map<String, dynamic>)>[];
    final LocationRefreshHandler handler = _handler(
      now: now,
      posts: posts,
      sharingEnabled: false,
    );

    expect(
      await handler.handle(command()),
      LocationRefreshResult.sharingDisabled,
    );
    expect(posts, isEmpty);
  });
}

LocationRefreshHandler _handler({
  required DateTime now,
  Set<String>? processed,
  List<(String, Map<String, dynamic>)>? posts,
  bool sharingEnabled = true,
  Future<Position> Function()? getPosition,
}) {
  final Set<String> seen = processed ?? <String>{};
  final List<(String, Map<String, dynamic>)> sent =
      posts ?? <(String, Map<String, dynamic>)>[];
  return LocationRefreshHandler(
    now: () => now,
    sharingEnabled: () async => sharingEnabled,
    getPosition: getPosition ??
        () async => Position(
              longitude: -122.2,
              latitude: 37.1,
              timestamp: now,
              accuracy: 8,
              altitude: 12,
              altitudeAccuracy: 2,
              heading: 90,
              headingAccuracy: 4,
              speed: 1.5,
              speedAccuracy: 0.5,
            ),
    getDeviceId: () async => 'device-1',
    getBattery: () async => 73,
    post: (String path, Map<String, dynamic> body) async {
      sent.add((path, body));
      return null;
    },
    wasProcessed: (String id) async => seen.contains(id),
    markProcessed: (String id) async => seen.add(id),
  );
}
