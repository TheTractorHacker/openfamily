import 'dart:typed_data';

import '../api_client.dart';
import 'e2ee_models.dart';

/// Server calls of the E2EE foundation. Abstract so tests can fake the server.
/// Every payload is a public key or ciphertext; nothing secret is ever sent.
abstract class E2eeApi {
  Future<DeviceKey> register(Map<String, dynamic> body);
  Future<List<DeviceKey>> myKeys();
  Future<void> revoke(String deviceId, Map<String, dynamic> signedAction);
  Future<List<DeviceKey>> userKeys(String userId);
  Future<CircleE2eeState> circleState(String circleId);
  Future<List<WrapRecord>> myWraps(String circleId, String deviceId);
  Future<List<DeviceKey>> pending(String circleId);
  Future<void> enable(String circleId, Map<String, dynamic> body);
  Future<void> bumpEpoch(String circleId, Map<String, dynamic> body);
  Future<void> disable(String circleId, Map<String, dynamic> signedAction);
  Future<int> submitWraps(String circleId, int epoch, List<Map<String, dynamic>> wraps);
  Future<void> approve(String circleId, Map<String, dynamic> body);
  Future<({List<LogEntry> entries, LogHead head})> log(int after);
}

class ApiE2eeApi implements E2eeApi {
  const ApiE2eeApi();

  List<DeviceKey> _keys(dynamic r, String field) =>
      ((r as Map<String, dynamic>)[field] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(DeviceKey.fromJson)
          .toList();

  @override
  Future<DeviceKey> register(Map<String, dynamic> body) async =>
      DeviceKey.fromJson((await ApiClient.post('/e2ee/devices', body: body)) as Map<String, dynamic>);

  @override
  Future<List<DeviceKey>> myKeys() async => _keys(await ApiClient.get('/e2ee/me'), 'devices');

  @override
  Future<void> revoke(String deviceId, Map<String, dynamic> signedAction) =>
      ApiClient.delete('/e2ee/devices/$deviceId', body: signedAction);

  @override
  Future<List<DeviceKey>> userKeys(String userId) async =>
      _keys(await ApiClient.get('/e2ee/users/$userId/devices'), 'devices');

  @override
  Future<CircleE2eeState> circleState(String circleId) async => CircleE2eeState.fromJson(
      (await ApiClient.get('/circles/$circleId/e2ee')) as Map<String, dynamic>);

  @override
  Future<List<WrapRecord>> myWraps(String circleId, String deviceId) async {
    final dynamic r = await ApiClient.get('/circles/$circleId/e2ee/wraps', query: <String, String>{'device_id': deviceId});
    return ((r as Map<String, dynamic>)['wraps'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(WrapRecord.fromJson)
        .toList();
  }

  @override
  Future<List<DeviceKey>> pending(String circleId) async =>
      _keys(await ApiClient.get('/circles/$circleId/e2ee/pending'), 'pending');

  @override
  Future<void> enable(String circleId, Map<String, dynamic> body) =>
      ApiClient.post('/circles/$circleId/e2ee/enable', body: body);

  @override
  Future<void> bumpEpoch(String circleId, Map<String, dynamic> body) =>
      ApiClient.post('/circles/$circleId/e2ee/epoch', body: body);

  @override
  Future<void> disable(String circleId, Map<String, dynamic> signedAction) =>
      ApiClient.post('/circles/$circleId/e2ee/disable', body: signedAction);

  @override
  Future<int> submitWraps(String circleId, int epoch, List<Map<String, dynamic>> wraps) async {
    final dynamic r = await ApiClient.post('/circles/$circleId/e2ee/wraps',
        body: <String, dynamic>{'epoch': epoch, 'wraps': wraps});
    return ((r as Map<String, dynamic>)['stored'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> approve(String circleId, Map<String, dynamic> body) =>
      ApiClient.post('/circles/$circleId/e2ee/approvals', body: body);

  @override
  Future<({List<LogEntry> entries, LogHead head})> log(int after) async {
    final Map<String, dynamic> r = (await ApiClient.get('/e2ee/log', query: <String, String>{'after': '$after'})) as Map<String, dynamic>;
    final Map<String, dynamic> h = r['head'] as Map<String, dynamic>;
    final String hash = (h['hash'] as String?) ?? '';
    return (
      entries: ((r['entries'] as List<dynamic>?) ?? <dynamic>[])
          .cast<Map<String, dynamic>>()
          .map(LogEntry.fromJson)
          .toList(),
      head: LogHead((h['seq'] as num?)?.toInt() ?? 0, hash.isEmpty ? Uint8List(32) : Uint8List.fromList(List<int>.generate(32, (int i) => int.parse(hash.substring(i * 2, i * 2 + 2), radix: 16)))),
    );
  }
}
