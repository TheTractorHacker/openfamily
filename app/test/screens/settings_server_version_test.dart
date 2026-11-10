// The "Server x.y.z" line of Settings is cached per server: signing in to a
// different server (or a fresh test) never shows the previous server's release.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/size_matrix.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
        appName: 'Orbitly', packageName: 'test', version: '9.9.9', buildNumber: '1', buildSignature: '');
    resetSettingsServerVersionCache();
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'a', 'refresh_token_v2': 'r'});
  });

  testWidgets('a different server does not reuse the cached release; the same one does', (WidgetTester t) async {
    setWindow(t, const Size(412, 6000));
    final Map<String, int> asked = <String, int>{};
    Future<void> openOn(String base, String version) async {
      SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': base});
      await ServerConfig.instance.setUrl(base);
      ApiClient.invalidateConfig();
      await http.runWithClient(() async {
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(scaled(const SettingsScreen(), 1));
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('Server $version'), findsOneWidget, reason: base);
      }, () => MockClient((http.Request r) async {
            if (r.url.path == '/version') {
              asked[r.url.host] = (asked[r.url.host] ?? 0) + 1;
              return http.Response(jsonEncode(<String, String>{'version': version}), 200,
                  headers: <String, String>{'content-type': 'application/json'});
            }
            return http.Response(jsonEncode(<String, Object?>{}), 200, headers: <String, String>{'content-type': 'application/json'});
          }));
    }

    await openOn('https://one.test', '1.0.0');
    await openOn('https://two.test', '2.0.0');
    expect(asked['one.test'], 1);
    expect(asked['two.test'], 1);
    await openOn('https://two.test', '2.0.0');
    expect(asked['two.test'], 1, reason: 'same server: asked once per app run');
    await openOn('https://one.test', '1.0.0');
    expect(asked['one.test'], 2, reason: 'back on the first server the cache holds the second one, so it asks again');
  });
}
