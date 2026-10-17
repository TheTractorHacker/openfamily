import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/server_config_screen.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ServerConfig.instance.debugReset();
  });

  testWidgets('explains that server URLs must use HTTPS', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ServerConfigScreen()),
    );
    await tester.enterText(find.byType(TextField), 'http://family.example.com');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.text('Enter a valid HTTPS server URL.'), findsOneWidget);
    expect(ServerConfig.instance.isConfigured, isFalse);
  });
}
