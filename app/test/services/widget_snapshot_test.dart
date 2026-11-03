import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/widget_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

Member _m(
  String name, {
  MovementType movement = MovementType.none,
  double? speedMps,
  PlacePresence? presence,
  LatLng? position = const LatLng(1.5, 2.5),
  int battery = 80,
}) =>
    Member(
      id: 'id-$name',
      name: name,
      position: position,
      status: MemberStatus.normal,
      batteryPercent: battery,
      address: '12 Secret Street',
      avatarColor: Colors.teal,
      movement: movement,
      speedMps: speedMps,
      placePresence: presence,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initials', () {
    expect(widgetInitials('Blake Foley'), 'BF');
    expect(widgetInitials('madonna'), 'M');
    expect(widgetInitials('  '), '?');
  });

  test('status strings', () {
    final DateTime now = DateTime(2026, 1, 1, 12);
    expect(
        widgetStatusLine(_m('A', movement: MovementType.car, speedMps: 18.8),
            now: now),
        startsWith('Driving 4'));
    expect(widgetStatusLine(_m('A'), now: now), 'Stationary');
    expect(widgetStatusLine(_m('A', position: null), now: now),
        'No location yet');
    expect(
        widgetStatusLine(
            _m('A',
                presence: PlacePresence(
                    placeId: 'p',
                    placeName: 'Home',
                    isAt: true,
                    since: DateTime(2026, 1, 1, 8))),
            now: now),
        'At Home');
    expect(
        widgetStatusLine(
            _m('A',
                presence: PlacePresence(
                    placeId: 'p',
                    placeName: 'Work',
                    isAt: false,
                    since: now.subtract(const Duration(minutes: 25)))),
            now: now),
        'Left Work 25 min ago');
  });

  test('cap, no coordinates or street address', () {
    final List<Member> ms = <Member>[
      for (int i = 0; i < 9; i++) _m('Person $i', battery: 150),
    ];
    final Map<String, dynamic> snap = buildWidgetSnapshot(ms);
    expect((snap['members'] as List<dynamic>).length, kWidgetMemberCap);
    expect(snap['total'], 9);
    final String json = jsonEncode(snap);
    expect(json.contains('Secret'), isFalse);
    expect(json.contains('1.5'), isFalse);
    expect(json.contains('id-'), isFalse);
    expect((snap['members'] as List<dynamic>).first['battery'], 100);
  });

  group('HomeWidgetService', () {
    final List<String> calls = <String>[];
    setUp(() {
      calls.clear();
      HomeWidgetService.resetForTest();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app.openfamily/widget'),
              (MethodCall c) async {
        calls.add(c.method);
        return true;
      });
    });

    test('throttles writes to once per 30 s', () async {
      final DateTime t = DateTime(2026, 1, 1, 12);
      await HomeWidgetService.update(<Member>[_m('A')],
          now: t, supported: true);
      await HomeWidgetService.update(<Member>[_m('A')],
          now: t.add(const Duration(seconds: 10)), supported: true);
      await HomeWidgetService.update(<Member>[_m('A')],
          now: t.add(const Duration(seconds: 31)), supported: true);
      expect(calls, <String>['write', 'write']);
    });

    test('clear (logout) calls native clear', () async {
      await HomeWidgetService.clear(supported: true);
      expect(calls, <String>['clear']);
    });

    test('disabled setting suppresses writes', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'widget_show_family': false});
      await HomeWidgetService.update(<Member>[_m('A')], supported: true);
      expect(calls, isEmpty);
    });
  });
}
