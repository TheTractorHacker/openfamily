import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/permissions_screen.dart';
import 'package:openfamily/theme/app_theme.dart';

void main() {
  testWidgets('disclosure fits a small phone and precedes location consent',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <MethodCall>[];
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'requestPermissions') {
        requests.add(call);
        return {for (final id in call.arguments as List<dynamic>) id: 1};
      }
      return 1;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
        MaterialApp(theme: buildLightTheme(), home: const PermissionsScreen()));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.textContaining('collects and sends your precise location'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Allow Location'));
    await tester.pumpAndSettle();
    expect(requests, isNotEmpty);
    expect(find.text('Allow Notifications'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
