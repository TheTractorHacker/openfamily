import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Harness of the real-server interop tests (docs/testing/E2E_LANES.md). The
// phones are the REAL Dart classes (E2eeService, LanesService, PrivateRuntime,
// ApiE2eeApi, HttpChannelApi, ApiClient) talking real HTTP to the real Go server
// started by scripts/e2e-lanes.sh. Only three things are test plumbing:
//  * ApiClient insists on an https base URL, so the app is configured with a
//    pretend https host and an http client (zone scoped) rewrites it to the
//    real server;
//  * ApiClient reads ONE token store, so the same client puts the token of the
//    phone the call belongs to (zone value) on the request;
//  * the OpenFamily server's own device is the real e2ee-bridge binary in
//    server mode, driven through its CLI.

const String kPretendBase = 'https://openfamily.e2e.test';

class E2eEnv {
  E2eEnv._(this.base, this.ingestToken, this.bridgeBin, this.probeBin, this.dbUrl);

  final String base;
  final String ingestToken;
  final String bridgeBin;
  final String probeBin;
  final String dbUrl;

  /// Null when the suite is not asked to run (the normal `flutter test` run).
  static E2eEnv? fromEnvironment() {
    final Map<String, String> e = Platform.environment;
    final String? base = e['E2E_BASE_URL'];
    if (base == null || base.isEmpty) return null;
    return E2eEnv._(base, e['E2E_INGEST_TOKEN'] ?? '', e['E2E_BRIDGE_BIN'] ?? '', e['E2E_PROBE_BIN'] ?? '', e['E2E_DATABASE_URL'] ?? '');
  }
}

/// Rewrites the pretend https host to the real server and authenticates as the
/// phone the calling zone belongs to.
class _PhoneRoutingClient extends http.BaseClient {
  _PhoneRoutingClient(this.realBase);
  final String realBase;
  final http.Client _inner = http.Client();
  final List<String> trace = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Phone? phone = Zone.current[#phone] as Phone?;
    final String url = request.url.toString().replaceFirst(kPretendBase, realBase);
    final http.Request out = http.Request(request.method, Uri.parse(url));
    out.headers.addAll(request.headers);
    if (request is http.Request) out.bodyBytes = request.bodyBytes;
    if (phone != null && phone.token != null) out.headers['Authorization'] = 'Bearer ${phone.token}';
    trace.add('${phone?.name ?? '-'} ${request.method} ${request.url.path}');
    return _inner.send(out);
  }
}

late _PhoneRoutingClient _routing;

/// One time test bootstrap: binding, mocks, app configuration.
Future<void> bootstrap(E2eEnv env) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // flutter_test stubs dart:io HTTP out
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': kPretendBase});
  TokenStorage.resetForTest();
  await ServerConfig.instance.load();
  _routing = _PhoneRoutingClient(env.base);
}

List<String> get httpTrace => _routing.trace;

/// Plain JSON call to the real server (setup only; the code under test never uses this).
Future<Map<String, dynamic>> rawJson(E2eEnv env, String method, String path, {Map<String, dynamic>? body, String? token}) async {
  final http.Request r = http.Request(method, Uri.parse('${env.base}$path'));
  r.headers['Content-Type'] = 'application/json';
  if (token != null) r.headers['Authorization'] = 'Bearer $token';
  if (body != null) r.body = jsonEncode(body);
  final http.Response res = await http.Response.fromStream(await http.Client().send(r));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw StateError('$method $path -> ${res.statusCode} ${res.body}');
  }
  return res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
}

Circle circleOf(String id, {int members = 3}) =>
    Circle(id: id, name: 'e2e', role: 'member', sharingEnabled: true, memberCount: members, e2eeMode: 'private');

/// One phone of one account: the real services over real HTTP.
class Phone {
  Phone(this.name, this.email, this.password) {
    service = E2eeService(api: const ApiE2eeApi(), vault: vault, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => userId);
  }

  final String name;
  final String email;
  final String password;
  late String userId;
  String? token;

  final MemoryVault vault = MemoryVault();
  final MemoryKv kv = MemoryKv();
  late final E2eeService service;
  PrivateRuntime? _runtime;
  final List<String> notes = <String>[];

  PrivateRuntime get runtime => _runtime!;
  LanesService get lanes => runtime.lanesService;
  LaneStore get store => lanes.store;

  /// Builds the runtime. [oldApp] makes this phone behave like a build that
  /// predates lanes: it registers without capabilities (see [registerOldApp]).
  void startRuntime() {
    final PrivateRuntime rt = PrivateRuntime(service: service, api: const ApiE2eeApi(), kv: kv);
    rt.lanesService.logTtl = Duration.zero;
    rt.notify = (String t, String b) async => notes.add(b);
    _runtime = rt;
  }

  /// Runs [f] as this phone: its token on every request, the pretend host mapped to the server.
  Future<T> run<T>(Future<T> Function() f) {
    final Completer<T> c = Completer<T>();
    runZonedGuarded(() {
      http.runWithClient(() => f().then(c.complete, onError: (Object e, StackTrace s) {
            if (!c.isCompleted) c.completeError(e, s);
          }), () => _routing);
    }, (Object e, StackTrace s) {
      if (!c.isCompleted) {
        c.completeError(e, s);
      } else {
        // ignore: avoid_print
        print('uncaught async error in phone $name: $e');
      }
    }, zoneValues: <Object?, Object?>{#phone: this});
    return c.future;
  }

  Future<void> signUpAndLogin(E2eEnv env) async {
    final Map<String, dynamic> reg = await rawJson(env, 'POST', '/auth/register', body: <String, dynamic>{'email': email, 'password': password, 'name': name});
    userId = (reg['id'] ?? (reg['user'] as Map<String, dynamic>?)?['id']) as String;
    final Map<String, dynamic> login = await rawJson(env, 'POST', '/auth/login', body: <String, dynamic>{'email': email, 'password': password});
    token = login['access_token'] as String;
  }

  Future<void> syncCircle(String circleId) => run(() async {
        await runtime.setCircles(<Circle>[circleOf(circleId)]);
      });

  /// The fix body PrivateRuntime.routeFix takes.
  Map<String, dynamic> fix(double lat, double lon, {DateTime? at}) => <String, dynamic>{
        'device_id': 'x', 'ts': (at ?? DateTime.now().toUtc()).toIso8601String(), 'lat': lat, 'lon': lon,
        'accuracy_meters': 8, 'speed_mps': 1.0, 'battery_pct': 71, 'motion_state': '', 'source': 'foreground',
      };

  /// routeFix + wait for the async seal + flush. Returns the number of uploaded items.
  Future<int> sendFix(double lat, double lon) => run(() async {
        await runtime.routeFix(fix(lat, lon));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return runtime.flush();
      });

  Future<List<ReceivedItem>> receiveAll(String circleId) => run(() async {
        final List<ReceivedItem> out = <ReceivedItem>[];
        await runtime.sync.resetCursor(circleId);
        await runtime.sync.catchUp(circleId, onItem: out.add);
        return out;
      });
}

/// What the server-device sidecar does: POST /internal/e2ee/ingest with the server token. Used to
/// exercise the server's own gating independent of the sidecar build. Returns the JSON answer
/// (and the status as `_status`).
Future<Map<String, dynamic>> directIngest(E2eEnv env, String circleId, String serverDeviceId, List<Map<String, dynamic>> points) async {
  final http.Request r = http.Request('POST', Uri.parse('${env.base}/internal/e2ee/ingest'));
  r.headers['Content-Type'] = 'application/json';
  r.headers['Authorization'] = 'Bearer ${env.ingestToken}';
  r.body = jsonEncode(<String, dynamic>{'circle_id': circleId, 'server_device_id': serverDeviceId, 'points': points});
  final http.Response res = await http.Response.fromStream(await http.Client().send(r));
  final Map<String, dynamic> m = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
  return <String, dynamic>{...m, '_status': res.statusCode};
}

Map<String, dynamic> ingestPoint(Phone p, String senderDeviceId, double lat, double lon) => <String, dynamic>{
      'kind': 'fix', 'user_id': p.userId, 'sender_device_id': senderDeviceId,
      'ts_ms': DateTime.now().toUtc().millisecondsSinceEpoch, 'lat': lat, 'lon': lon, 'acc': 8, 'bat': 71,
    };

/// The OpenFamily server's own device: the real e2ee-bridge binary in server mode.
class ServerDevice {
  ServerDevice(this.env, this.owner) : dir = Directory.systemTemp.createTempSync('of-e2e-bridge');
  final E2eEnv env;
  final Phone owner;
  final Directory dir;
  String deviceId = '';
  String fingerprintHex = '';

  File get _config => File('${dir.path}/config.json');

  Future<ProcessResult> _run(List<String> args, {Map<String, String> extra = const <String, String>{}}) => Process.run(
        env.bridgeBin,
        <String>[...args, '--state-dir', '${dir.path}/state'],
        environment: <String, String>{'E2EE_BRIDGE_PASSWORD': owner.password, 'E2EE_SERVER_INGEST_TOKEN': env.ingestToken, ...extra},
      );

  /// enroll (request code) -> the owner's phone approves -> enroll --approval.
  Future<void> enroll() async {
    final ProcessResult r1 = await _run(<String>['enroll', '--kind', 'server', '--server', env.base, '--email', owner.email]);
    expect(r1.exitCode, 0, reason: '${r1.stdout}${r1.stderr}');
    final String out = r1.stdout as String;
    final String code = out.split('\n').map((String l) => l.trim()).lastWhere((String l) => l.length > 80 && !l.contains(' '));
    final String approval = await owner.run(() async {
      final info = await owner.service.inspectViewerRequest(code);
      deviceId = info.deviceId;
      fingerprintHex = E2ee.hex(info.fingerprint);
      return owner.service.approveLinkRequest(info);
    });
    final ProcessResult r2 = await _run(<String>['enroll', '--kind', 'server', '--server', env.base, '--approval', approval]);
    expect(r2.exitCode, 0, reason: '${r2.stdout}${r2.stderr}');
    _config.writeAsStringSync(jsonEncode(<String, dynamic>{
      'mode': 'server', 'ingest': <String, String>{'url': env.base}, 'circles': <String>[], 'since': '', 'poll_seconds': 15,
    }));
    await Process.run('chmod', <String>['600', _config.path]);
  }

  /// One pass: pins the key as the server device, reads what it may, ingests.
  Future<ProcessResult> runOnce() async {
    final ProcessResult r = await _run(<String>['run', '--once', '--config', _config.path, '-v']);
    return r;
  }
}

/// Read-only SQL against the throwaway database through the probe binary.
class Db {
  Db(this.env);
  final E2eEnv env;

  Future<List<List<dynamic>>> query(String sql) async {
    final ProcessResult r = await Process.run(env.probeBin, <String>[sql], environment: <String, String>{'DATABASE_URL': env.dbUrl});
    if (r.exitCode != 0) throw StateError('probe failed: ${r.stderr}');
    return (jsonDecode(r.stdout as String) as List<dynamic>).map((dynamic x) => (x as List<dynamic>)).toList();
  }

  Future<int> count(String sql) async => (await query(sql)).single.single as int;

  /// Plaintext rows the server holds for a user (locations written by the server device).
  Future<int> locationsOf(String userId) => count(
      "SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = '$userId'");

  Future<int> positionRows(String userId) => count("SELECT count(*) FROM member_positions WHERE user_id = '$userId'");

  /// Plaintext rows of one user near a point (the database may be shared between runs).
  Future<int> userRowsNear(String userId, double lat, double lon) async {
    final int a = await count(
        "SELECT count(*) FROM locations l JOIN devices d ON d.id = l.device_id WHERE d.user_id = '$userId' AND abs(ST_Y(l.geom) - $lat) < 0.00001 AND abs(ST_X(l.geom) - $lon) < 0.00001");
    final int b = await count("SELECT count(*) FROM member_positions WHERE user_id = '$userId' AND abs(lat - $lat) < 0.00001 AND abs(lon - $lon) < 0.00001");
    return a + b;
  }

  /// Any plaintext row (locations or last position) within 1e-5 degrees of the point, for any user.
  Future<int> anyRowNear(double lat, double lon) async {
    final int a = await count(
        'SELECT count(*) FROM locations WHERE abs(ST_Y(geom) - $lat) < 0.00001 AND abs(ST_X(geom) - $lon) < 0.00001');
    final int b = await count('SELECT count(*) FROM member_positions WHERE abs(lat - $lat) < 0.00001 AND abs(lon - $lon) < 0.00001');
    return a + b;
  }
}
