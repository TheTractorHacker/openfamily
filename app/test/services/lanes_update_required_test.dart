import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/app_compat.dart';

void main() {
  setUp(AppCompat.debugReset);

  test('409 update_required_for_lanes shows the same update-required state as a 426', () {
    expect(AppCompat.state.value.status, isNot(CompatStatus.required));
    expect(
        () => ApiClient.debugThrowForError(http.Response(
            '{"error":"Update Orbitly to continue","code":"update_required_for_lanes","not_ready":["Sam"]}', 409)),
        throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 409)));
    expect(AppCompat.state.value.status, CompatStatus.required);
    expect(AppCompat.state.value.message, contains('Update Orbitly'));
  });

  test('other 409s do not claim the app is outdated', () {
    expect(() => ApiClient.debugThrowForError(http.Response('{"error":"x","code":"members_not_ready"}', 409)), throwsA(isA<ApiException>()));
    expect(AppCompat.state.value.status, isNot(CompatStatus.required));
  });
}
