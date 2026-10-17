import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/privacy_policy_screen.dart';
import 'package:openfamily/screens/server_config_screen.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('privacy is accessible before server setup or sign-in',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    ServerConfig.instance.debugReset();
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: const ServerConfigScreen(),
    ));
    expect(find.textContaining('Requires a self-hosted'), findsOneWidget);
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
    expect(find.text('Your server and its operator'), findsOneWidget);
    expect(ServerConfig.instance.isConfigured, isFalse);
    await tester.scrollUntilVisible(
      find.text('Retention and deletion'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(PrivacyPolicyScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('Settings → Delete account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
