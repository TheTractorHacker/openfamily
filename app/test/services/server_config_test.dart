import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openfamily/services/server_config.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ServerConfig.instance.debugReset();
  });

  test('stored preference wins over an empty dart-define', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://family.example.com',
    });
    await ServerConfig.instance.load();
    expect(ServerConfig.instance.apiBaseUrl, 'https://family.example.com');
    expect(ServerConfig.instance.isConfigured, isTrue);
  });

  test('setUrl strips a trailing slash', () async {
    await ServerConfig.instance.setUrl('https://family.example.com/');
    expect(ServerConfig.instance.apiBaseUrl, 'https://family.example.com');
  });

  test('setUrl rejects cleartext HTTP', () async {
    await expectLater(
      ServerConfig.instance.setUrl('http://family.example.com'),
      throwsArgumentError,
    );
    expect(ServerConfig.instance.isConfigured, isFalse);
  });

  test('load removes a previously saved HTTP server URL', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'http://family.example.com',
    });
    await ServerConfig.instance.load();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(ServerConfig.instance.isConfigured, isFalse);
    expect(prefs.containsKey('wb_api_base_url'), isFalse);
  });

  test('setUrl rejects URLs with embedded credentials or query strings',
      () async {
    await expectLater(
      ServerConfig.instance.setUrl('https://user:secret@family.example.com'),
      throwsArgumentError,
    );
    await expectLater(
      ServerConfig.instance.setUrl('https://family.example.com?token=secret'),
      throwsArgumentError,
    );
  });

  test('clear forgets the stored URL', () async {
    await ServerConfig.instance.setUrl('https://family.example.com');
    await ServerConfig.instance.clear();
    expect(ServerConfig.instance.isConfigured, isFalse);
  });
}
