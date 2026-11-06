import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/diagnostics_screen.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';

void main() {
  testWidgets('shows plain-language problems with a fix button, and copies a redacted report', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
      return null;
    });
    final DateTime now = DateTime.utc(2026, 3, 10, 12);
    await tester.pumpWidget(MaterialApp(
      home: DiagnosticsScreen(
        collect: () async => DiagFacts(
          now: now,
          manufacturer: 'Samsung',
          model: 'S23',
          osRelease: '14',
          locationService: true,
          locationPermission: 'while_in_use',
          preciseLocation: true,
          notificationsGranted: true,
          ignoringBatteryOptimizations: false,
          backgroundRestricted: false,
          networkOnline: true,
          server: ServerState.ok,
          serverHost: 'family.example.com',
          lastReportAt: now.subtract(const Duration(hours: 9)),
          outboxPending: 0,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Your phone is probably not reporting'), findsOneWidget);
    expect(find.text('Location permission'), findsOneWidget);
    expect(find.textContaining('Allow all the time'), findsWidgets);
    expect(find.text('Open app permissions'), findsOneWidget);
    expect(find.text('Open battery settings'), findsOneWidget);

    await tester.tap(find.text('Copy diagnostic report'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, contains('[FAIL] Location permission'));
    expect(copied, contains('[WARN] Battery and background limits'));
    expect(copied!.split('\nThis report contains').first.toLowerCase(), isNot(contains('token')));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
