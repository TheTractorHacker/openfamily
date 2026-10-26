import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/driving_detection_screen.dart';
import 'package:openfamily/services/driving/driving_settings.dart';
import 'package:openfamily/services/driving/driving_event_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_sensor_events_api.dart';

Future<void> pump(WidgetTester t, FakeSensorEventsApi api) async {
  // The outbox lock is a static future; one created in another test's fake
  // zone would never complete here.
  DrivingEventOutbox.resetLockForTest();
  await t.pumpWidget(MaterialApp(home: DrivingDetectionScreen(api: api)));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('defaults to ON with a plain-words privacy explanation',
      (WidgetTester t) async {
    await pump(t, FakeSensorEventsApi());
    expect(find.text('On: checking only while you drive'), findsOneWidget);
    expect(find.textContaining('on by default'), findsOneWidget);
    expect(find.textContaining('Raw sensor readings'), findsOneWidget);
    expect(await DrivingSettings.sensorEnabled(), isTrue);
    expect(await DrivingSettings.phoneUseEnabled(), isFalse,
        reason: 'screen activity stays off by default');
  });

  testWidgets('an explicit off shows as off; turning on tells the server',
      (WidgetTester t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{DrivingSettings.sensorKey: false});
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    await pump(t, api);
    expect(find.text('Off: nothing is recorded'), findsOneWidget);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(api.flags, <bool>[true]);
    expect(await DrivingSettings.sensorEnabled(), isTrue);
    expect(await DrivingSettings.serverSynced(), isTrue);
    expect(find.text('On: checking only while you drive'), findsOneWidget);
  });

  testWidgets('turning off stops locally at once and tells the server',
      (WidgetTester t) async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    await pump(t, api);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(api.flags, <bool>[false]);
    expect(await DrivingSettings.sensorEnabled(), isFalse);
    expect(find.text('Off: nothing is recorded'), findsOneWidget);
  });

  testWidgets('off while the server is unreachable stays off and retries later',
      (WidgetTester t) async {
    final FakeSensorEventsApi api = FakeSensorEventsApi()..offline = true;
    await pump(t, api);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(await DrivingSettings.sensorEnabled(), isFalse);
    expect(await DrivingSettings.serverSynced(), isFalse);
    expect(find.textContaining('as soon as it can'), findsOneWidget);
  });

  testWidgets('server failure while turning on leaves it off and explains',
      (WidgetTester t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{DrivingSettings.sensorKey: false});
    final FakeSensorEventsApi api = FakeSensorEventsApi()..offline = true;
    await pump(t, api);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(await DrivingSettings.sensorEnabled(), isFalse);
    expect(find.textContaining('stays off'), findsOneWidget);
  });

  testWidgets('phone-use switch needs the main switch and turning off clears it',
      (WidgetTester t) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      DrivingSettings.sensorKey: true,
      DrivingSettings.phoneUseKey: true,
    });
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    await pump(t, api);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(api.flags, <bool>[false]);
    expect(await DrivingSettings.phoneUseEnabled(), isFalse);
  });

  testWidgets('phone-use switch sends phone_use_enabled and resyncs on change',
      (WidgetTester t) async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    await pump(t, api);
    await t.ensureVisible(find.text('Count screen activity while moving'));
    await t.tap(find.text('Count screen activity while moving'));
    await t.pumpAndSettle();
    expect(api.phoneFlags, <bool>[true]);
    expect(api.flags, <bool>[true]);
    expect(await DrivingSettings.phoneUseEnabled(), isTrue);
    await t.tap(find.text('Count screen activity while moving'));
    await t.pumpAndSettle();
    expect(api.phoneFlags, <bool>[true, false]);
    expect(await DrivingSettings.phoneUseEnabled(), isFalse);
  });

  testWidgets('phone use stays off when the server cannot be told',
      (WidgetTester t) async {
    final FakeSensorEventsApi api = FakeSensorEventsApi()..offline = true;
    await pump(t, api);
    await t.ensureVisible(find.text('Count screen activity while moving'));
    await t.tap(find.text('Count screen activity while moving'));
    await t.pumpAndSettle();
    expect(await DrivingSettings.phoneUseEnabled(), isFalse);
    expect(find.textContaining('phone use stays off'), findsOneWidget);
  });
}
