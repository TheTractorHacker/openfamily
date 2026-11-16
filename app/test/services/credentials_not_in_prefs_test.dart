// The saved password (and the e-mail it belongs to) live only in the Keystore-backed store, never in plain
// SharedPreferences. The session-token copy "D" in plain app-private prefs is a documented, deliberate
// survive-an-update fallback and holds tokens only, never the password.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saveCredentials writes nothing secret to SharedPreferences', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TokenStorage.resetForTest();
    await TokenStorage.saveCredentials(email: 'someone@example.test', password: 'hunter2-correct-horse');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String k in prefs.getKeys()) {
      final Object? v = prefs.get(k);
      expect('$v', isNot(contains('hunter2-correct-horse')), reason: 'key $k');
      expect('$v', isNot(contains('someone@example.test')), reason: 'key $k');
    }
    final creds = await TokenStorage.readCredentials();
    expect(creds?.password, 'hunter2-correct-horse');
  });
}
