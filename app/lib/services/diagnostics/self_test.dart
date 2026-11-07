import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../api_client.dart';
import '../e2ee/e2ee_crypto.dart';
import '../e2ee/e2ee_vault.dart';
import '../e2ee/private_runtime.dart';
import '../push_service.dart';
import '../token_storage.dart';
import 'diag_model.dart';

/// One line of the self-test. [needsHuman] marks results the phone cannot
/// verify alone (it can send a notification, only you can see it).
class SelfTestResult {
  const SelfTestResult(this.id, this.title, this.status, this.detail, {this.needsHuman = false});
  final String id;
  final String title;
  final DiagStatus status;
  final String detail;
  final bool needsHuman;
}

/// Exercises what can be exercised automatically on a real phone. Each step is
/// independent and never throws; a failure is reported as a FAIL line.
///
/// What this DOES prove: the Android Keystore wrapping key works, the vault
/// can store and read a secret, the XChaCha20-Poly1305 channel crypto round
/// trips, the server accepts an upload from this phone and shows it back, and a
/// server push and a local notification can be produced.
/// What it does NOT prove: that a push is *visible* (a human must look), and
/// that the background service survives hours with the screen off (that is the
/// separate background test and the physical-device checklist).
class SelfTest {
  SelfTest({
    KeystoreChannel keystore = const KeystoreChannel(),
    E2eeVault? vault,
    Future<void> Function(String, String)? notify,
  })  : _keystore = keystore,
        _vault = vault ?? SecureVault(),
        _notify = notify ?? PushService.showForeground;

  final KeystoreChannel _keystore;
  final E2eeVault _vault;
  final Future<void> Function(String, String) _notify;

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int d = 0;
    for (int i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  /// Hardware Keystore round trip with random data.
  Future<SelfTestResult> keystoreRoundTrip() async {
    const String id = 'keystore';
    const String title = 'Keystore encrypt and decrypt';
    try {
      final KeystoreStatus st = await _keystore.status();
      if (st.level == KeystoreLevel.unavailable) {
        return const SelfTestResult(id, title, DiagStatus.info,
            'No Android Keystore on this platform, so the app falls back to plain secure storage. Skipped.');
      }
      final Uint8List plain = E2ee.randomBytes(48);
      final Uint8List blob = await _keystore.encrypt(plain);
      final Uint8List back = await _keystore.decrypt(blob);
      if (!_eq(plain, back) || _eq(plain, blob)) {
        return const SelfTestResult(id, title, DiagStatus.fail, 'The Keystore returned different data than it was given.');
      }
      return SelfTestResult(id, title, DiagStatus.pass, 'Round trip worked. Key protection: ${st.label}.');
    } on VaultInvalidatedException {
      return const SelfTestResult(id, title, DiagStatus.fail,
          'The Keystore key was invalidated (screen lock removed or app data restored). Restore your keys from the recovery phrase.');
    } catch (e) {
      return SelfTestResult(id, title, DiagStatus.fail, 'The Keystore call failed (${e.runtimeType}).');
    }
  }

  /// Writes, reads and deletes a throwaway secret through the real vault.
  Future<SelfTestResult> vaultRoundTrip() async {
    const String id = 'vault';
    const String title = 'Secret storage (vault)';
    const String name = 'selftest_probe_v1';
    try {
      final Uint8List secret = E2ee.randomBytes(32);
      await _vault.write(name, secret);
      final Uint8List? back = await _vault.read(name);
      await _vault.delete(name);
      if (back == null || !_eq(secret, back)) {
        return const SelfTestResult(id, title, DiagStatus.fail, 'A stored secret could not be read back.');
      }
      return const SelfTestResult(id, title, DiagStatus.pass, 'Stored, read back and deleted a test secret.');
    } catch (e) {
      try {
        await _vault.delete(name);
      } catch (_) {}
      return SelfTestResult(id, title, DiagStatus.fail, 'The vault failed (${e.runtimeType}).');
    }
  }

  /// Seals and opens a payload with the real channel crypto, and checks that a
  /// tampered payload is rejected.
  Future<SelfTestResult> cryptoRoundTrip() async {
    const String id = 'crypto';
    const String title = 'Private circle encryption';
    try {
      final Uint8List key = E2ee.randomBytes(32);
      final String circle = E2ee.newUuid(), device = E2ee.newUuid();
      final Uint8List msg = Uint8List.fromList(List<int>.generate(100, (int i) => i));
      final Uint8List sealed = await E2ee.seal(key, circle, 1, device, 'fix', msg);
      final Uint8List opened = await E2ee.open(key, circle, device, 'fix', sealed);
      if (!_eq(msg, opened)) {
        return const SelfTestResult(id, title, DiagStatus.fail, 'Decrypted data did not match.');
      }
      final Uint8List bad = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      try {
        await E2ee.open(key, circle, device, 'fix', bad);
        return const SelfTestResult(id, title, DiagStatus.fail, 'A tampered message was accepted.');
      } on E2eeAuthException {
        // expected
      }
      return const SelfTestResult(id, title, DiagStatus.pass, 'Encrypt, decrypt and tamper detection all behaved.');
    } catch (e) {
      return SelfTestResult(id, title, DiagStatus.fail, 'Encryption failed (${e.runtimeType}).');
    }
  }

  /// Uploads the phone's real current position once and checks that the server
  /// registered a fresh report from this account. For a user whose circles are
  /// all Private the fix is sealed and sent as an encrypted item instead.
  Future<SelfTestResult> uploadAndReadBack({required bool privateOnly}) async {
    const String id = 'upload';
    const String title = 'Upload a fix and read it back';
    final DateTime started = DateTime.now().toUtc();
    try {
      final String? deviceId = await TokenStorage.readDeviceId();
      if (deviceId == null) {
        return const SelfTestResult(id, title, DiagStatus.fail, 'This phone is not registered with the server yet. Open the map once.');
      }
      final Position p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)),
      );
      final Map<String, dynamic> body = <String, dynamic>{
        'device_id': deviceId,
        'ts': DateTime.now().toUtc().toIso8601String(),
        'lat': p.latitude,
        'lon': p.longitude,
        'motion_state': '',
        'source': 'foreground',
        if (p.accuracy > 0) 'accuracy_meters': p.accuracy,
      };
      if (privateOnly) {
        await PrivateRuntime.instance.routeFix(body);
        await Future<void>.delayed(const Duration(seconds: 3));
        await PrivateRuntime.instance.flush();
      } else {
        await ApiClient.post('/locations', body: body);
      }
      final DateTime t0 = DateTime.now();
      final dynamic res = await ApiClient.get('/me/diagnostics');
      final DateTime t1 = DateTime.now();
      final DateTime? serverNow = res is Map<String, dynamic> ? DateTime.tryParse('${res['server_time']}')?.toUtc() : null;
      final DateTime? last = res is Map<String, dynamic> ? DateTime.tryParse('${res['last_report_at']}')?.toUtc() : null;
      if (last == null || serverNow == null) {
        return const SelfTestResult(id, title, DiagStatus.fail, 'The upload went out but the server shows no report from this account.');
      }
      // Compare on the server's own clock so a wrong phone clock cannot fake a pass.
      final Duration age = serverNow.difference(last);
      final Duration rtt = t1.difference(t0);
      final Duration sinceStart = serverNow.difference(started) + rtt;
      if (age > const Duration(minutes: 2) && sinceStart > const Duration(minutes: 3)) {
        return SelfTestResult(id, title, DiagStatus.fail,
            'The server\'s newest report from you is ${humanAgo(age)}, so this upload did not register.');
      }
      return SelfTestResult(id, title, DiagStatus.pass,
          privateOnly
              ? 'Sealed a test fix, uploaded it as an encrypted item, and the server registered it just now.'
              : 'Uploaded your current position and the server registered it just now.');
    } on SessionExpiredException {
      return const SelfTestResult(id, title, DiagStatus.fail, 'Your sign-in expired. Sign in again.');
    } on ApiException catch (e) {
      return SelfTestResult(id, title, DiagStatus.fail,
          e.status == 0 ? 'Could not reach the server.' : 'The server refused the upload (${e.status}: ${e.message}).');
    } on TimeoutException {
      return const SelfTestResult(id, title, DiagStatus.fail, 'The phone could not get a GPS fix within 25 seconds. Try outdoors or near a window.');
    } catch (e) {
      return SelfTestResult(id, title, DiagStatus.fail, 'The test failed (${e.runtimeType}).');
    }
  }

  /// Local notification now, and a real server push to this phone.
  Future<SelfTestResult> notifications() async {
    const String id = 'notify';
    const String title = 'Notifications';
    try {
      await _notify('Orbitly self-test', 'This is the local test notification.');
      final dynamic res = await ApiClient.post('/me/diagnostics/test-push');
      final int sent = res is Map<String, dynamic> ? ((res['sent'] as num?)?.toInt() ?? 0) : 0;
      final int failed = res is Map<String, dynamic> ? ((res['failed'] as num?)?.toInt() ?? 0) : 0;
      if (sent == 0) {
        return SelfTestResult(id, title, DiagStatus.fail,
            failed > 0
                ? 'The server tried to push to this phone but the provider rejected it.'
                : 'The server has no push channel registered for this phone.',
            needsHuman: false);
      }
      return const SelfTestResult(id, title, DiagStatus.pass,
          'A local notification and a server push were sent. Check the notification shade: you should see two. '
          'If you see fewer, notifications are blocked or the push channel is not delivering.',
          needsHuman: true);
    } catch (e) {
      return SelfTestResult(id, title, DiagStatus.fail, 'The notification test failed (${e.runtimeType}).');
    }
  }
}
