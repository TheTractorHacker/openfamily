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

  testWidgets('changing host while configured signs out first', (tester) async {
    await ServerConfig.instance.setUrl('https://old.example.com');
    int signOuts = 0;
    String? urlAtSignOut;
    await tester.pumpWidget(MaterialApp(
      home: ServerConfigScreen(signOut: () async {
        signOuts++;
        urlAtSignOut = ServerConfig.instance.apiBaseUrl;
      }),
    ));
    await tester.enterText(find.byType(TextField), 'https://new.example.com');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(signOuts, 1);
    expect(urlAtSignOut, contains('old.example.com'));
  });
}
