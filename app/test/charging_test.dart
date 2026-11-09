import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/battery_report.dart';
import 'package:openfamily/services/e2ee/last_positions.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/location_reporter.dart';
import 'package:openfamily/services/member_mapper.dart';
import 'package:openfamily/utils/member_status.dart';
import 'package:openfamily/widgets/member_avatar_bubble.dart';
import 'package:openfamily/widgets/member_tile.dart';

// "Show it charging": the optional `charging` flag from report to bolt.

Map<String, dynamic> _json({num? battery, Object? charging, bool withCharging = true}) => <String, dynamic>{
      'id': 'u1',
      'name': 'Sam',
      'lat': 51.5,
      'lon': -0.1,
      'ts': DateTime.now().toUtc().toIso8601String(),
      if (battery != null) 'battery_pct': battery,
      if (withCharging) 'charging': charging,
    };

Member _member({int battery = 60, bool charging = false}) => Member(
      id: 'u1',
      name: 'Sam',
      position: const LatLng(51.5, -0.1),
      status: MemberStatus.normal,
      batteryPercent: battery,
      charging: charging,
      address: 'Home',
    );

Position _pos() => Position(
      latitude: 1,
      longitude: 2,
      timestamp: DateTime.utc(2026, 1, 1, 12),
      accuracy: 5,
      altitude: 3,
      altitudeAccuracy: 1,
      heading: 90,
      headingAccuracy: 1,
      speed: 0,
      speedAccuracy: 0.5,
    );

void main() {
  group('member model', () {
    test('parses charging; absent or malformed means not charging', () {
      expect(memberFromJson(_json(battery: 40, charging: true)).charging, isTrue);
      expect(memberFromJson(_json(battery: 40, charging: false)).charging, isFalse);
      expect(memberFromJson(_json(battery: 40, withCharging: false)).charging, isFalse);
      expect(memberFromJson(_json(battery: 40, charging: 'yes')).charging, isFalse);
    });

    test('a charging phone at low battery is not flagged as a warning', () {
      final Member low = memberFromJson(_json(battery: 8, withCharging: false));
      expect(low.status, MemberStatus.warning);
      expect(memberBatteryAlert(low), 'Battery 8%');
      final Member plugged = memberFromJson(_json(battery: 8, charging: true));
      expect(plugged.status, MemberStatus.normal);
      expect(memberBatteryAlert(plugged), isNull);
      expect(plugged.showsCharging, isTrue);
    });

    test('showsCharging needs a known battery level', () {
      expect(_member(battery: 0, charging: true).showsCharging, isFalse);
      expect(_member(battery: 50, charging: true).showsCharging, isTrue);
    });

    test('live frames: the flag follows the battery reading', () {
      final Member m = _member(battery: 50, charging: true);
      // Position-only frame: keep what we knew.
      expect(memberFromLocationUpdate(m, <String, dynamic>{'lat': 1, 'lon': 2}).charging, isTrue);
      // Battery without the flag (older app): unknown.
      expect(memberFromLocationUpdate(m, <String, dynamic>{'lat': 1, 'lon': 2, 'battery_pct': 51}).charging, isFalse);
      // Explicit unplug.
      expect(
          memberFromLocationUpdate(m, <String, dynamic>{'lat': 1, 'lon': 2, 'battery_pct': 51, 'charging': false}).charging,
          isFalse);
      final Member off = _member(battery: 50);
      final Member p = memberFromPresenceUpdate(off, <String, dynamic>{
        'user_id': 'u1',
        'ts': DateTime.now().toUtc().toIso8601String(),
        'battery_pct': 52,
        'charging': true,
      });
      expect(p.charging, isTrue);
      expect(p.batteryPercent, 52);
    });

    test('copyWith keeps or replaces charging', () {
      final Member m = _member(charging: true);
      expect(m.copyWith(address: 'x').charging, isTrue);
      expect(m.copyWith(charging: false).charging, isFalse);
      expect(m.copyWithAvatar(hasAvatar: false, avatarVersion: 2).charging, isTrue);
    });
  });

  group('reports', () {
    test('battery state mapping', () {
      expect(chargingFromState(BatteryState.charging), isTrue);
      expect(chargingFromState(BatteryState.full), isTrue);
      expect(chargingFromState(BatteryState.discharging), isFalse);
      expect(chargingFromState(BatteryState.connectedNotCharging), isFalse);
      expect(chargingFromState(BatteryState.unknown), isNull);
    });

    test('the flag is sent only alongside a battery reading and only when known', () {
      final Map<String, dynamic> withFlag =
          LocationReporter.buildBody(_pos(), deviceId: 'd', batteryPct: 40, charging: true);
      expect(withFlag['battery_pct'], 40);
      expect(withFlag['charging'], isTrue);
      final Map<String, dynamic> unknown = LocationReporter.buildBody(_pos(), deviceId: 'd', batteryPct: 40);
      expect(unknown.containsKey('charging'), isFalse);
      final Map<String, dynamic> noBattery =
          LocationReporter.buildBody(_pos(), deviceId: 'd', charging: true);
      expect(noBattery.containsKey('charging'), isFalse);
      expect(noBattery.containsKey('battery_pct'), isFalse);
    });

    test('sealed fix body: chg only when the flag is a real bool', () {
      final Map<String, dynamic> base = <String, dynamic>{'lat': 1.0, 'lon': 2.0, 'battery_pct': 30};
      expect(PrivateRuntime.fixBodyFromLocation(<String, dynamic>{...base, 'charging': true})['chg'], isTrue);
      expect(PrivateRuntime.fixBodyFromLocation(<String, dynamic>{...base, 'charging': false})['chg'], isFalse);
      expect(PrivateRuntime.fixBodyFromLocation(base).containsKey('chg'), isFalse);
      expect(PrivateRuntime.fixBodyFromLocation(<String, dynamic>{...base, 'charging': null}).containsKey('chg'), isFalse);
    });

    test('last known private position keeps the flag and reads older saved entries', () {
      const LastPosition p =
          LastPosition(circleId: 'c', userId: 'u', tsMs: 1000, lat: 1, lon: 2, bat: 20, chg: true);
      final LastPosition back = LastPosition.fromJson(p.toJson())!;
      expect(back.chg, isTrue);
      expect(back.toFrame()['charging'], isTrue);
      // Saved by a build without the flag (10 entries).
      final LastPosition old = LastPosition.fromJson(<dynamic>['c', 'u', 1000, 1.0, 2.0, null, 20, null, null, null])!;
      expect(old.chg, isNull);
      expect(old.toFrame().containsKey('charging'), isFalse);
      expect(old.toJson().length, 10);
    });
  });

  group('ui', () {
    testWidgets('map bubble shows a bolt only while charging', (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Center(child: MemberAvatarBubble(member: _member(charging: true))))));
      expect(find.byKey(const Key('member_charging_badge')), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Center(child: MemberAvatarBubble(member: _member())))));
      expect(find.byKey(const Key('member_charging_badge')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('member tile battery chip shows the charging icon', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MemberTile(member: _member(battery: 12, charging: true), onTap: () {}))));
      expect(find.text('12%'), findsOneWidget);
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);
      expect(find.byIcon(Icons.battery_1_bar), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Battery 12%, charging')), findsOneWidget);
      semantics.dispose();

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MemberTile(member: _member(battery: 12), onTap: () {}))));
      expect(find.byIcon(Icons.battery_charging_full), findsNothing);
      expect(find.byIcon(Icons.battery_1_bar), findsOneWidget);
    });
  });
}
