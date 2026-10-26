import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/driving/driving_events_service.dart';

/// Records posts; can be told to fail with an HTTP status or a transport error.
class FakeSensorEventsApi implements SensorEventsApi {
  final List<List<Map<String, dynamic>>> batches =
      <List<Map<String, dynamic>>>[];
  final List<bool> flags = <bool>[];
  final List<bool> phoneFlags = <bool>[];

  /// Throw this status as an [ApiException] while non-null.
  int? failStatus;

  /// Throw a transport error while true.
  bool offline = false;

  final Set<String> _seen = <String>{};

  @override
  Future<SensorEventsResult> post(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  }) async {
    if (offline) throw Exception('offline');
    if (failStatus != null) throw ApiException(failStatus!, 'fail');
    batches.add(events);
    flags.add(sensorEnabled);
    phoneFlags.add(phoneUseEnabled);
    int accepted = 0, dup = 0;
    for (final Map<String, dynamic> e in events) {
      if (_seen.add('${e['kind']}|${e['started_at']}')) {
        accepted++;
      } else {
        dup++;
      }
    }
    return SensorEventsResult(accepted: accepted, duplicate: dup);
  }

  int get totalEvents =>
      batches.fold(0, (int a, List<Map<String, dynamic>> b) => a + b.length);
}
