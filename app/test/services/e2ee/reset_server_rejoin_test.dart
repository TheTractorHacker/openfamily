import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/link_device_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';

/// The API's built-in server device, as GET /e2ee/server-join and POST /e2ee/server-join/approve show it: one key
/// of kind `server`; once the account that owns it revokes it (a key reset), the device makes a new one that
/// names the old one in `replaces` and waits for a phone's signature.
class ServerSim {
  ServerSim(this.server);
  final FakeE2eeServer server;
  ViewerFixture? dev;
  bool registered = false;
  String replaces = '';
  final Set<String> admins = <String>{uA};

  /// Polls of GET /e2ee/server-join before a revoked key is replaced (0 = at once).
  int replaceAfterPolls = 0;
  int polls = 0;

  /// What the next new key looks like (tests override this to send something odd).
  Future<String> Function(ViewerFixture d) requestFor = (ViewerFixture d) => d.request(kind: 'server', name: 'Orbitly server');
  Future<ViewerFixture> Function() newKey = () => ViewerFixture.create(uA);
  final List<Map<String, dynamic>> approvals = <Map<String, dynamic>>[];

  bool _revoked() {
    if (dev == null || !registered) return false;
    return server.findActive(dev!.deviceId) == null;
  }

  Future<ServerJoinInfo> info(String uid) async {
    polls++;
    if (_revoked() && polls > replaceAfterPolls) {
      replaces = dev!.deviceId;
      dev = await newKey();
      registered = false;
    }
    final bool waiting = !registered;
    final bool admin = admins.contains(uid);
    return ServerJoinInfo(
      builtin: true,
      waiting: waiting,
      canApprove: admin,
      requestCode: admin && waiting ? await requestFor(dev!) : '',
      deviceId: waiting ? dev!.deviceId : '',
      replaces: admin && waiting ? replaces : '',
    );
  }

  Future<void> approve(String uid, Map<String, dynamic> body) async {
    approvals.add(body);
    final String code = base64Url.encode(utf8.encode(jsonEncode(<String, String>{'a': body['actor_device_id'] as String, 's': body['log_signature'] as String})));
    await dev!.register(server, code, kind: 'server', label: 'Orbitly server');
    registered = true;
  }
}

class JoinClient extends FakeE2eeClient {
  JoinClient(super.s, super.uid, this.sim);
  final ServerSim sim;

  @override
  Future<ServerJoinInfo> serverJoin() => sim.info(uid);

  @override
  Future<void> approveServerJoin(Map<String, dynamic> body) => sim.approve(uid, body);
}

void main() {
  late FakeE2eeServer server;
  late ServerSim sim;

  E2eeService phone(String uid) =>
      E2eeService(api: JoinClient(server, uid, sim), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uid);

  DeviceKey key(String uid, String id) => server.keys[uid]!.firstWhere((DeviceKey k) => k.deviceId == id);

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    sim = ServerSim(server);
    // Alice runs the server: her phone approved the server's first key.
    final E2eeService old = phone(uA);
    await old.registerThisDevice(label: 'This phone');
    sim.dev = await ViewerFixture.create(uA);
    sim.approvals.clear();
    await old.approveServerJoin();
    expect(sim.registered, isTrue);
    sim.approvals.clear();
    sim.polls = 0;
  });

  test('the owner reset approves the server\'s new key with the new phone, no prompt', () async {
    final String oldServer = sim.dev!.deviceId;
    final E2eeService fresh = phone(uA);
    expect(await fresh.accountHoldsServerKey(), isTrue);
    final KeyResetResult r = await fresh.resetThisDevice(serverWait: const Duration(seconds: 2), step: Duration.zero);
    expect(r.serverKeyRevoked, isTrue);
    expect(r.serverRejoined, isTrue);
    expect(sim.approvals, hasLength(1));
    expect(key(uA, oldServer).isActive, isFalse);
    final DeviceKey k = key(uA, sim.dev!.deviceId);
    expect(k.isActive, isTrue);
    expect(k.kind, 'server');
    expect(k.registeredByDeviceId, r.key.deviceId, reason: 'signed by the phone that made the reset');
    expect(sim.approvals.single['actor_device_id'], r.key.deviceId);
    expect(sim.approvals.single.keys.toSet(), <String>{'device_id', 'actor_device_id', 'log_signature'}, reason: 'public data only');
  });

  test('waits for the server to make its new key', () async {
    sim.replaceAfterPolls = 3;
    final KeyResetResult r = await phone(uA).resetThisDevice(serverWait: const Duration(seconds: 5), step: Duration.zero);
    expect(r.serverRejoined, isTrue);
    expect(sim.polls, greaterThanOrEqualTo(4));
  });

  test('gives up after the wait: nothing signed, the usual prompt stays', () async {
    sim.replaceAfterPolls = 1 << 30;
    final KeyResetResult r = await phone(uA).resetThisDevice(serverWait: const Duration(milliseconds: 50), step: const Duration(milliseconds: 5));
    expect(r.serverKeyRevoked, isTrue);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
  });

  test('another member\'s reset never touches or approves the server key', () async {
    final E2eeService bob = phone(uB);
    await bob.registerThisDevice(label: 'This phone');
    sim.admins.add(uB);
    final KeyResetResult r = await phone(uB).resetThisDevice(serverWait: const Duration(milliseconds: 50), step: Duration.zero);
    expect(r.serverKeyRevoked, isFalse);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
    expect(sim.polls, 0, reason: 'no server key of Bob\'s was revoked, so his phone does not even ask');
  });

  test('a resetting owner who is not a server administrator gets no request and signs nothing', () async {
    sim.admins.clear();
    final KeyResetResult r = await phone(uA).resetThisDevice(serverWait: const Duration(milliseconds: 50), step: Duration.zero);
    expect(r.serverKeyRevoked, isTrue);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
  });

  test('a waiting key that does not replace the revoked key is not approved', () async {
    final String oldServer = sim.dev!.deviceId;
    sim.newKey = () => ViewerFixture.create(uA);
    final E2eeService fresh = phone(uA);
    // The server claims to replace some other key.
    sim.requestFor = (ViewerFixture d) async {
      sim.replaces = '99999999-9999-4999-8999-999999999999';
      return d.request(kind: 'server', name: 'Orbitly server');
    };
    final KeyResetResult r = await fresh.resetThisDevice(serverWait: const Duration(milliseconds: 50), step: Duration.zero);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
    expect(oldServer, isNot(sim.dev!.deviceId));
  });

  test('a request that is not of kind server is not approved', () async {
    sim.requestFor = (ViewerFixture d) => d.request(kind: 'web', name: 'Browser');
    final KeyResetResult r = await phone(uA).resetThisDevice(serverWait: const Duration(milliseconds: 50), step: Duration.zero);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
  });

  test('a request bound to another account is not approved', () async {
    sim.newKey = () => ViewerFixture.create(uB);
    final KeyResetResult r = await phone(uA).resetThisDevice(serverWait: const Duration(milliseconds: 50), step: Duration.zero);
    expect(r.serverRejoined, isFalse);
    expect(sim.approvals, isEmpty);
  });

  test('rejoinServerAfterReset signs nothing without a revoked server key of this account', () async {
    final E2eeService fresh = phone(uA);
    await fresh.resetThisDevice(serverWait: Duration.zero, step: Duration.zero);
    sim.approvals.clear();
    expect(await fresh.rejoinServerAfterReset(<String>{}), isFalse);
    expect(sim.approvals, isEmpty);
  });

  group('reset copy', () {
    test('the confirmation says the server key goes too, and what happens next', () {
      final String m = resetConfirmMessage(serverKey: true);
      expect(m, contains('removes the key your Orbitly server uses'));
      expect(m, contains('this phone approves it for you'));
      expect(resetConfirmMessage(serverKey: false), isNot(contains('server')));
    });

    test('the note after the reset', () {
      final DeviceKey k = server.keys[uA]!.first;
      expect(resetDoneMessage(KeyResetResult(k)), isNull);
      expect(resetDoneMessage(KeyResetResult(k, serverKeyRevoked: true, serverRejoined: true)), contains('approved your server'));
      expect(resetDoneMessage(KeyResetResult(k, serverKeyRevoked: true)), contains('Your server wants to join'));
    });

    testWidgets('the reset dialog of the server owner names the server key', (WidgetTester tester) async {
      final E2eeService fresh = phone(uA);
      await tester.pumpWidget(MaterialApp(home: LinkDeviceScreen(service: fresh)));
      final Finder reset = find.text('Reset my keys');
      await tester.scrollUntilVisible(reset, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(find.text('Reset your encryption keys?'), findsOneWidget);
      expect(find.textContaining('removes the key your Orbitly server uses'), findsOneWidget);
    });
  });
}
