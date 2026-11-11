// The background callbacks never throw, but they no longer fail silently: the isolate marks itself, and a failure
// leaves its exception TYPE (and a count) where the Diagnostics report can show it.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/background_location_service.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';
import 'package:openfamily/services/diagnostics/tracking_journal.dart';
import 'package:openfamily/services/diagnostics/tracking_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrackingStats.instance.resetForTest();
  });
  tearDown(() => TrackingJournal.setSourceForTest('app'));

  test('a heartbeat tick that cannot read its credentials does not throw, marks the isolate and records why', () async {
    await onHeartbeatTick(); // secure storage is not available in a unit test: the credential read fails
    expect(TrackingJournal.source, 'bg');
    await TrackingStats.instance.flush();
    final StatsSnapshot s = await TrackingStats.instance.read();
    expect(s.lastError, isNotNull, reason: 'the old empty catch left nothing');
    expect(s.lastError!.source, 'bg');
    expect(s.lastError!.where, anyOf('heartbeat', 'heartbeat_credentials'));
    expect(s.lastError!.type, isNot(contains(' ')));
    final List<JournalLine> j = await TrackingJournal.instance.readAll();
    expect(j.map((JournalLine l) => l.event), contains('bg_isolate_started'));
  });

  test('a heartbeat the server answers 204 does not count as "last upload ok"', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'api_base_url': 'https://example.invalid',
      'device_id': 'dev1',
      'ingest_key': 'key1',
    });
    final List<String> paths = <String>[];
    await http.runWithClient(
      () => onHeartbeatTick(),
      () => MockClient((http.Request r) async {
        paths.add(r.url.path);
        return http.Response('', 204);
      }),
    );
    await TrackingStats.instance.flush();
    final StatsSnapshot s = await TrackingStats.instance.read();
    expect(paths, contains('/devices/heartbeat'), reason: 'the test must really have sent the heartbeat');
    expect(s.hours.single[TrackCounter.heartbeatOk], 1);
    expect(s.lastUploadOkAt, isNull, reason: 'only a location upload that the server accepted is an upload');
  });
}
