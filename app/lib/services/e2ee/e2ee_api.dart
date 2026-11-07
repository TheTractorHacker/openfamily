import 'dart:typed_data';

import '../api_client.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'lanes_wire.dart';

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

  /// Declares capabilities of one of the caller's own phone keys (monotonic on
  /// the server). Used to tell the circle "this app reads encrypted chat" for a
  /// key that was registered before the capability existed.
  Future<void> putCaps(String deviceId, List<String> caps) async {}

  // Trusted-server mode. Defaults keep older fakes (and servers without the
  // mode) working: the mode simply reports as off.
  Future<ServerMemberState> serverMemberState(String circleId) async => ServerMemberState.off;

  /// The admin's "trust this server by default" recommendation. Only a hint for
  /// the UI: it never grants or sends anything. False on older servers.
  Future<bool> trustedServerDefault() async => false;
  Future<void> putServerConsent(String circleId, Map<String, dynamic> body) async =>
      throw UnsupportedError('server mode is not available');

  /// Deployment profile and the pinned server key (GET /e2ee/server-device). Older servers: [ServerProfile.unknown].
  Future<ServerProfile> serverProfile() async => ServerProfile.unknown;
  /// The built-in server device's join request. Older servers: [ServerJoinInfo.none].
  Future<ServerJoinInfo> serverJoin() async => ServerJoinInfo.none;
  Future<void> approveServerJoin(Map<String, dynamic> body) async => throw UnsupportedError('the server cannot join from the app');
  Future<void> deleteServerConsent(String circleId) async {}
  Future<int> purgeServerCopies(String circleId, {bool wholeCircle = false}) async => 0;

  // Processing lanes (docs/design/PRIVACY_PROCESSING.md section 7 / 17). The
  // defaults keep older fakes and servers working: no lanes, nothing to do.
  // Paths and field names live in lanes_wire.dart.
  Future<ProcessingServerState> processingState(String circleId) async => ProcessingServerState.off;

  /// PUT .../processing/policy (circle admin). [body] = statement fields,
  /// `log_signature`, and for a new SK generation `sk_wraps` ({gen, wraps}).
  Future<void> putProcessingPolicy(String circleId, Map<String, dynamic> body) async =>
      throw UnsupportedError('processing lanes are not available');

  /// PUT .../processing/pref (own pref only; no endpoint writes another user's).
  Future<void> putProcessingPref(String circleId, Map<String, dynamic> body) async =>
      throw UnsupportedError('processing lanes are not available');

  /// GET .../pending?key_line=server: approved-or-waiting member keys that lack a
  /// wrap of the CURRENT SK generation (never the server key itself).
  Future<List<DeviceKey>> pendingLine(String circleId, int line) async => line == E2ee.linePhone ? pending(circleId) : <DeviceKey>[];

  /// POST wraps of a key line. [gen] is the SK generation for the server line.
  Future<int> submitLineWraps(String circleId, int line, int gen, List<Map<String, dynamic>> wraps) async =>
      throw UnsupportedError('processing lanes are not available');

  /// POST .../processing-upgrade (circle admin, legacy trusted-server circles only).
  Future<void> upgradeProcessing(String circleId, Map<String, dynamic> body) async =>
      throw UnsupportedError('processing lanes are not available');

  /// DELETE .../legacy-server-access (circle admin, after an upgrade). Irreversible.
  Future<void> endLegacyServerAccess(String circleId) async =>
      throw UnsupportedError('processing lanes are not available');
}

class ApiE2eeApi implements E2eeApi {
  const ApiE2eeApi();

  List<DeviceKey> _keys(dynamic r, String field) =>
      ((r as Map<String, dynamic>)[field] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(DeviceKey.fromJson)
          .toList();

  @override
  Future<void> putCaps(String deviceId, List<String> caps) async {
    await ApiClient.put('/e2ee/devices/$deviceId/caps', body: <String, dynamic>{'caps': caps});
  }

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
    // key_line=all: without it the server answers phone-line wraps only (old-app behaviour).
    final dynamic r = await ApiClient.get('/circles/$circleId/e2ee/wraps', query: <String, String>{'device_id': deviceId, LanesFields.keyLine: 'all'});
    return ((r as Map<String, dynamic>)['wraps'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(WrapRecord.tryParse)
        .whereType<WrapRecord>()
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
  Future<ServerMemberState> serverMemberState(String circleId) async => ServerMemberState.fromJson(
      (await ApiClient.get('/circles/$circleId/e2ee/server-member')) as Map<String, dynamic>);

  @override
  Future<bool> trustedServerDefault() async {
    final dynamic r = await ApiClient.get('/e2ee/server-device');
    return r is Map<String, dynamic> && r['trusted_server_default'] == true;
  }

  @override
  Future<ServerProfile> serverProfile() async {
    final dynamic r = await ApiClient.get('/e2ee/server-device');
    return r is Map<String, dynamic> ? ServerProfile.fromJson(r) : ServerProfile.unknown;
  }

  @override
  Future<ServerJoinInfo> serverJoin() async {
    try {
      final dynamic r = await ApiClient.get('/e2ee/server-join');
      return r is Map<String, dynamic> ? ServerJoinInfo.fromJson(r) : ServerJoinInfo.none;
    } catch (_) {
      return ServerJoinInfo.none;
    }
  }

  @override
  Future<void> approveServerJoin(Map<String, dynamic> body) => ApiClient.post('/e2ee/server-join/approve', body: body);

  @override
  Future<void> putServerConsent(String circleId, Map<String, dynamic> body) =>
      ApiClient.put('/circles/$circleId/e2ee/server-consent', body: body);

  @override
  Future<void> deleteServerConsent(String circleId) => ApiClient.delete('/circles/$circleId/e2ee/server-consent');

  @override
  Future<int> purgeServerCopies(String circleId, {bool wholeCircle = false}) async {
    final dynamic r = await ApiClient.delete('/circles/$circleId/e2ee/server-copies?scope=${wholeCircle ? 'circle' : 'mine'}');
    return r is Map<String, dynamic> ? (((r['items_deleted'] ?? r['locations_deleted']) as num?)?.toInt() ?? 0) : 0;
  }

  @override
  Future<List<DeviceKey>> pendingLine(String circleId, int line) async =>
      _keys(await ApiClient.get('/circles/$circleId/e2ee/pending', query: <String, String>{LanesFields.keyLine: E2ee.lineName(line)}), 'pending');

  @override
  Future<ProcessingServerState> processingState(String circleId) async => ProcessingServerState.fromJson(
      (await ApiClient.get(LanesPaths.state(circleId))) as Map<String, dynamic>);

  @override
  Future<void> putProcessingPolicy(String circleId, Map<String, dynamic> body) =>
      ApiClient.put(LanesPaths.policy(circleId), body: body);

  @override
  Future<void> putProcessingPref(String circleId, Map<String, dynamic> body) =>
      ApiClient.put(LanesPaths.pref(circleId), body: body);

  @override
  Future<void> upgradeProcessing(String circleId, Map<String, dynamic> body) =>
      ApiClient.post(LanesPaths.upgrade(circleId), body: body);

  @override
  Future<void> endLegacyServerAccess(String circleId) => ApiClient.delete(LanesPaths.legacyAccess(circleId));

  @override
  Future<int> submitLineWraps(String circleId, int line, int gen, List<Map<String, dynamic>> wraps) async {
    final dynamic r = await ApiClient.post(LanesPaths.wraps(circleId),
        body: <String, dynamic>{'epoch': gen, LanesFields.keyLine: E2ee.lineName(line), 'wraps': wraps});
    return ((r as Map<String, dynamic>)['stored'] as num?)?.toInt() ?? 0;
  }

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
