import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/background_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('sync persists the base URL and device id in secure storage', () async {
    await BackgroundCredentialStore.sync(
      apiBaseUrl: 'https://family.example.com',
      deviceId: 'device-1',
    );

    expect(await BackgroundCredentialStore.readApiBaseUrl(),
        'https://family.example.com');
    expect(await BackgroundCredentialStore.readDeviceId(), 'device-1');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('the ingest key round-trips and never touches shared_preferences',
      () async {
    await BackgroundCredentialStore.saveIngestKey('ingest-key-1');
    expect(await BackgroundCredentialStore.readIngestKey(), 'ingest-key-1');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('clear removes every credential but keeps the user server URL',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://family.example.com',
    });
    await BackgroundCredentialStore.sync(
      apiBaseUrl: 'https://family.example.com',
      deviceId: 'device-1',
    );
    await BackgroundCredentialStore.saveIngestKey('ingest-key-1');

    await BackgroundCredentialStore.clear();

    expect(await BackgroundCredentialStore.readApiBaseUrl(), isNull);
    expect(await BackgroundCredentialStore.readDeviceId(), isNull);
    expect(await BackgroundCredentialStore.readIngestKey(), isNull);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wb_api_base_url'), 'https://family.example.com');
  });

  test('migrateLegacyPrefs moves the ingest key and deletes plaintext keys',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_access_token': 'jwt',
      'wb_device_id': 'device-9',
      'wb_ingest_key': 'legacy-key',
      'wb_api_base_url': 'https://family.example.com',
    });

    await BackgroundCredentialStore.migrateLegacyPrefs();

    expect(await BackgroundCredentialStore.readIngestKey(), 'legacy-key');
    expect(await BackgroundCredentialStore.readDeviceId(), 'device-9');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('wb_access_token'), isFalse);
    expect(prefs.containsKey('wb_device_id'), isFalse);
    expect(prefs.containsKey('wb_ingest_key'), isFalse);
    expect(prefs.getString('wb_api_base_url'), 'https://family.example.com');
  });
}
