import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/diagnostics/self_test.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

class _FakeKeystore implements KeystoreChannel {
  _FakeKeystore({this.level = KeystoreLevel.tee, this.corrupt = false});
  final KeystoreLevel level;
  final bool corrupt;

  @override
  Future<Uint8List> encrypt(Uint8List plain) async => Uint8List.fromList(plain.map((int b) => b ^ 0x5a).toList());

  @override
  Future<Uint8List> decrypt(Uint8List blob) async {
    final Uint8List out = Uint8List.fromList(blob.map((int b) => b ^ 0x5a).toList());
    if (corrupt) out[0] ^= 1;
    return out;
  }

  @override
  Future<KeystoreStatus> status() async => KeystoreStatus(level: level);

  @override
  Future<void> recreateKey({required bool requireUserAuth}) async {}

  @override
  Future<Uint8List> decryptLegacy(Uint8List blob) => decrypt(blob);

  @override
  Future<void> deleteLegacy() async {}
}

void main() {
  test('crypto round trip passes and detects tampering', () async {
    final SelfTestResult r = await SelfTest(vault: MemoryVault()).cryptoRoundTrip();
    expect(r.status, DiagStatus.pass, reason: r.detail);
  });

  test('vault round trip leaves nothing behind', () async {
    final MemoryVault v = MemoryVault();
    final SelfTestResult r = await SelfTest(vault: v).vaultRoundTrip();
    expect(r.status, DiagStatus.pass, reason: r.detail);
    expect(await v.names(), isEmpty);
  });

  test('keystore round trip: pass, fail on corruption, info without a keystore', () async {
    expect((await SelfTest(keystore: _FakeKeystore(), vault: MemoryVault()).keystoreRoundTrip()).status, DiagStatus.pass);
    expect((await SelfTest(keystore: _FakeKeystore(corrupt: true), vault: MemoryVault()).keystoreRoundTrip()).status, DiagStatus.fail);
    expect((await SelfTest(keystore: _FakeKeystore(level: KeystoreLevel.unavailable), vault: MemoryVault()).keystoreRoundTrip()).status,
        DiagStatus.info);
  });
}
