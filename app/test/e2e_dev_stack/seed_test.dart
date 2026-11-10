@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';

import '../e2e_real_server/harness.dart';
import 'support.dart';

// Seeds the dev stack (scripts/dev/dev-stack.sh seed) through the real HTTP API with the app's own crypto
// client: the owner (the platform admin from the stack's secrets), two family members, and a Private circle
// with server processing on. Writes <state>/seed.json for the humans and for the status command.
//
// The phones here are test phones: their keys live in memory and are gone when this process ends. A real phone
// that signs in as one of these accounts registers ITS OWN key (the first key of an account is approved
// automatically; later keys need approval from an existing key), so for real devices use `reset --no-seed`
// and let the real app create the Private circle itself.

const String seedPassword = 'dev-password-1234';

void main() {
  final DevEnv? env = DevEnv.fromEnvironment();
  if (env == null) {
    test('seed the dev stack', () {}, skip: skipReason);
    return;
  }

  test('owner, two family members, a Private circle with server processing on', () async {
    await bootstrap(env.e2e);
    final DevStack stack = DevStack(env);
    final Phone owner = await stack.ownerPhone('Owner');
    final Map<String, dynamic> me = await rawJson(env.e2e, 'GET', '/me', token: owner.token, ip: owner.ip);
    final String? familyId = (me['family_id'] ?? (me['user'] as Map<String, dynamic>?)?['family_id']) as String?;
    expect(familyId, isNotNull, reason: 'the platform admin has a family from the bootstrap: $me');

    final Phone mia = await stack.newUser('Mia', familyId: familyId, email: 'mia@dev.orbitly.test', password: seedPassword);
    final Phone leo = await stack.newUser('Leo', familyId: familyId, email: 'leo@dev.orbitly.test', password: seedPassword);
    final String circle = await stack.createCircle(owner, <Phone>[mia, leo], name: 'Dev Private circle');
    await stack.makePrivate(circle, owner, <Phone>[mia, leo]);

    // The server's own key asks to join; the owner's phone approves it, then switches the policy on and
    // puts the owner on the server lane (the app's "Add server" flow, one OK).
    await addServerThroughApp(owner, circle);

    final String fingerprint = (await owner.run(() => const ApiE2eeApi().processingState(circle))).serverFingerprint!;
    await mia.run(() => mia.lanes.refresh(circle, force: true));
    await mia.run(() => mia.lanes.setLane(circle, E2ee.lineServer, confirmServerFingerprintHex: fingerprint));
    await owner.run(() => owner.lanes.maintain(circle));
    expect(await mia.run(() => mia.store.status(circle)), LaneStatus.serverAssisted);
    final ProcessingServerState proc = await owner.run(() => const ApiE2eeApi().processingState(circle));
    expect(proc.serverAssist, isTrue);
    expect(proc.inEffect, isTrue, reason: 'the server holds the server key and a member is on the server lane');

    final Map<String, dynamic> seed = <String, dynamic>{
      'api': env.base,
      'circle_id': circle,
      'family_id': familyId,
      'owner': <String, String>{'email': owner.email, 'id': owner.userId},
      'members': <Map<String, String>>[
        <String, String>{'email': mia.email, 'password': seedPassword, 'id': mia.userId, 'lane': 'server'},
        <String, String>{'email': leo.email, 'password': seedPassword, 'id': leo.userId, 'lane': 'phone'},
      ],
    };
    File('${env.stateDir}/seed.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(seed));
  });
}
