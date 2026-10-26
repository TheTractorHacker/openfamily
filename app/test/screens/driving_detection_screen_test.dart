import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/driving_detection_screen.dart';
import 'package:openfamily/services/driving/driving_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_sensor_events_api.dart';

Future<void> pump(WidgetTester t, FakeSensorEventsApi api) async {
  await t.pumpWidget(MaterialApp(home: DrivingDetectionScreen(api: api)));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('defaults to OFF with a plain-words privacy explanation',
      (WidgetTester t) async {
    await pump(t, FakeSensorEventsApi());
    expect(find.text('Off: nothing is recorded'), findsOneWidget);
    expect(find.textContaining('Raw sensor readings'), findsOneWidget);
    expect(await DrivingSettings.sensorEnabled(), isFalse);
  });

  testWidgets('turning on tells the server and persists locally',
      (WidgetTester t) async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    await pump(t, api);
    await t.tap(find.text('Detect hard braking and acceleration'));
    await t.pumpAndSettle();
    expect(api.flags, <bool>[true]);
    expect(await DrivingSettings.sensorEnabled(), isTrue);
    expect(find.text('On: checking only while you drive'), findsOneWidget);
  });

  testWidgets('server failure leaves it off and explains',
      (WidgetTester t) async {
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
}
