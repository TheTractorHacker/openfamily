// Opens and closes key screens 50 times with leak_tracker on (Flutter test VM, not a phone).
// Fails when a State, controller, focus node or other tracked object stays alive after its screen is closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:openfamily/screens/privacy_policy_screen.dart';
import 'package:openfamily/screens/server_config_screen.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  LeakTesting.enable();

  testWidgets('server settings and privacy policy: 50 open/close cycles leave nothing behind',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ServerConfig.instance.debugReset();
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      theme: buildLightTheme(),
      home: const ServerConfigScreen(),
    ));
    for (int i = 0; i < 50; i++) {
      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPolicyScreen), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}
