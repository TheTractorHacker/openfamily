import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/driving_detection_screen.dart';
import 'package:openfamily/services/driving/crash_watcher.dart';
import 'package:openfamily/services/driving/driving_background.dart';
import 'package:openfamily/services/driving/driving_events_service.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/native_uri_opener.dart';
import 'package:openfamily/services/permission_service.dart';
import 'package:openfamily/services/platform_features.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stand-in for SecureKeyChannel.swift (and KeystoreChannel.kt): same channel
/// name and method contract. "Encryption" is a reversible byte transform; the
/// real ECIES lives in native code and cannot run here.
class FakeNativeKeystore {
  FakeNativeKeystore({this.level = 'secure_enclave'});
  String level;
  bool userAuth = false;
  bool keyPresent = true;
  String? decryptError; // PlatformException code to throw
  final List<String> calls = <String>[];
  final List<bool> secure = <bool>[];

  Future<Object?> handle(MethodCall c) async {
    calls.add(c.method);
    switch (c.method) {
      case 'encrypt':
        return Uint8List.fromList((c.arguments as Uint8List).map((int b) => b ^ 0x5a).toList());
      case 'decrypt':
        if (decryptError != null) throw PlatformException(code: decryptError!);
        if (!keyPresent) throw PlatformException(code: 'invalidated');
        return Uint8List.fromList((c.arguments as Uint8List).map((int b) => b ^ 0x5a).toList());
      case 'status':
        return <String, dynamic>{
          'level': level,
          'unlockedDeviceRequired': userAuth,
          'userAuthRequired': userAuth,
        };
      case 'recreateKey':
        userAuth = (c.arguments as Map<dynamic, dynamic>)['requireUserAuth'] == true;
        keyPresent = true;
        return null;
      case 'setSecure':
        secure.add(c.arguments == true);
        return null;
    }
    throw MissingPluginException();
  }
}

const MethodChannel _chan = MethodChannel('test/keystore');

void mock(Future<Object?> Function(MethodCall) h) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_chan, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PlatformFeatures.debugPlatform = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_chan, null);
  });

  group('KeystoreChannel (iOS levels)', () {
    for (final MapEntry<String, KeystoreLevel> e in <String, KeystoreLevel>{
      'secure_enclave': KeystoreLevel.secureEnclave,
      'keychain': KeystoreLevel.keychain,
      'strongbox': KeystoreLevel.strongBox,
      'tee': KeystoreLevel.tee,
      'software': KeystoreLevel.software,
      'something-new': KeystoreLevel.unavailable,
    }.entries) {
      test('maps "${e.key}" to ${e.value}', () async {
        final FakeNativeKeystore f = FakeNativeKeystore(level: e.key);
        mock(f.handle);
        final KeystoreStatus s = await const KeystoreChannel(channel: _chan).status();
        expect(s.level, e.value);
      });
    }

    test('reports unlockedDeviceRequired / userAuthRequired after recreateKey', () async {
      final FakeNativeKeystore f = FakeNativeKeystore();
      mock(f.handle);
      const KeystoreChannel ch = KeystoreChannel(channel: _chan);
      expect((await ch.status()).userAuthRequired, isFalse);
      await ch.recreateKey(requireUserAuth: true);
      final KeystoreStatus s = await ch.status();
      expect(s.userAuthRequired, isTrue);
      expect(s.unlockedDeviceRequired, isTrue);
    });

    test('a missing native implementation reads as unavailable, not an error', () async {
      // No mock handler registered: MissingPluginException.
      final KeystoreStatus s = await const KeystoreChannel(channel: _chan).status();
      expect(s.level, KeystoreLevel.unavailable);
      expect(s.label, contains('Not available'));
    });

    test('labels are honest about Secure Enclave vs Keychain software key', () {
      expect(const KeystoreStatus(level: KeystoreLevel.secureEnclave).label, contains('Secure Enclave'));
      expect(const KeystoreStatus(level: KeystoreLevel.keychain).label, contains('software key'));
      expect(const KeystoreStatus(level: KeystoreLevel.keychain).label, isNot(startsWith('Secure Enclave')));
      expect(const KeystoreStatus(level: KeystoreLevel.secureEnclave).label, isNot(contains('StrongBox')));
    });

    test("'invalidated' fails closed; 'auth' and 'locked' do not claim invalidation", () async {
      final FakeNativeKeystore f = FakeNativeKeystore();
      mock(f.handle);
      const KeystoreChannel ch = KeystoreChannel(channel: _chan);
      f.keyPresent = false;
      await expectLater(ch.decrypt(Uint8List.fromList(<int>[1, 2])), throwsA(isA<VaultInvalidatedException>()));
      f.keyPresent = true;
      for (final String code in <String>['auth', 'locked']) {
        f.decryptError = code;
        await expectLater(
            ch.decrypt(Uint8List.fromList(<int>[1, 2])),
            throwsA(isA<PlatformException>().having((PlatformException e) => e.code, 'code', code)));
      }
    });
  });

  group('SecureVault with the native key channel', () {
    test('wraps with the channel, stores flag byte 1, round-trips, lists only vault names', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final FakeNativeKeystore f = FakeNativeKeystore();
      mock(f.handle);
      final FlutterSecureStorage storage = const FlutterSecureStorage();
      final SecureVault v = SecureVault(storage: storage, channel: const KeystoreChannel(channel: _chan));
      final Uint8List secret = Uint8List.fromList(List<int>.generate(32, (int i) => i));
      await v.write('seed', secret);
      final String raw = (await storage.read(key: 'seed'))!;
      final Uint8List stored = base64.decode(raw);
      expect(stored[0], 1);
      expect(stored.sublist(1), isNot(equals(secret)), reason: 'plaintext must not hit disk');
      expect(await v.read('seed'), secret);
      expect(await v.names(), <String>['seed']);
      expect((await v.status()).level, KeystoreLevel.secureEnclave);
      await v.delete('seed');
      expect(await v.read('seed'), isNull);
    });

    test('without the native channel it falls back to plain secure storage (flag byte 0)', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final FlutterSecureStorage storage = const FlutterSecureStorage();
      final SecureVault v = SecureVault(storage: storage, channel: const KeystoreChannel(channel: _chan));
      await v.write('k', Uint8List.fromList(<int>[9, 8, 7]));
      expect(base64.decode((await storage.read(key: 'k'))!)[0], 0);
      expect(await v.read('k'), Uint8List.fromList(<int>[9, 8, 7]));
      expect((await v.status()).level, KeystoreLevel.unavailable);
    });

    test('a lost wrapping key makes reads throw VaultInvalidatedException', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final FakeNativeKeystore f = FakeNativeKeystore();
      mock(f.handle);
      final SecureVault v =
          SecureVault(storage: const FlutterSecureStorage(), channel: const KeystoreChannel(channel: _chan));
      await v.write('seed', Uint8List.fromList(<int>[1, 2, 3]));
      f.keyPresent = false; // e.g. restored from backup: ThisDeviceOnly key did not come along
      await expectLater(v.read('seed'), throwsA(isA<VaultInvalidatedException>()));
    });

    test('iOS Keychain options: own namespace, after first unlock, this device only, no iCloud', () {
      final Map<String, String> m = SecureVault.iosVaultOptions.toMap();
      expect(m['accessibility'], 'first_unlock_this_device');
      expect(m['synchronizable'], 'false');
      expect(m['accountName'], 'openfamily_e2ee');
    });
  });

  group('ScreenSecurity (recovery phrase screens)', () {
    test('forwards setSecure to the native side', () async {
      final FakeNativeKeystore f = FakeNativeKeystore();
      mock(f.handle);
      const ScreenSecurity s = ScreenSecurity(channel: _chan);
      await s.setSecure(true);
      await s.setSecure(false);
      expect(f.secure, <bool>[true, false]);
    });

    test('never throws when the platform has no implementation', () async {
      await const ScreenSecurity(channel: _chan).setSecure(true);
    });
  });

  group('NativeUriOpener (iOS tel:/sms:/otpauth:)', () {
    test('returns the native result and tolerates a missing channel', () async {
      NativeUriOpener.channel = _chan;
      String? opened;
      mock((MethodCall c) async {
        opened = c.arguments as String;
        return true;
      });
      expect(await NativeUriOpener.open('tel:112'), isTrue);
      expect(opened, 'tel:112');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_chan, null);
      expect(await NativeUriOpener.open('tel:112'), isFalse);
    });
  });

  group('Android-only features degrade on iPhone', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('PlatformFeatures', () {
      PlatformFeatures.debugPlatform = TargetPlatform.iOS;
      expect(PlatformFeatures.drivingSensors, isFalse);
      expect(PlatformFeatures.homeWidget, isFalse);
      expect(PlatformFeatures.isIOS, isTrue);
      PlatformFeatures.debugPlatform = TargetPlatform.android;
      expect(PlatformFeatures.drivingSensors, isTrue);
      expect(PlatformFeatures.homeWidget, isTrue);
    });

    testWidgets('driving detection screen shows an honest not-available state', (WidgetTester t) async {
      PlatformFeatures.debugPlatform = TargetPlatform.iOS;
      await t.pumpWidget(const MaterialApp(home: DrivingDetectionScreen()));
      await t.pump();
      expect(find.byKey(const Key('driving-unavailable')), findsOneWidget);
      expect(find.text('Not available on iPhone yet'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('driving detection screen keeps its switches on Android', (WidgetTester t) async {
      PlatformFeatures.debugPlatform = TargetPlatform.android;
      await t.pumpWidget(const MaterialApp(home: DrivingDetectionScreen()));
      await t.pump();
      expect(find.byKey(const Key('driving-unavailable')), findsNothing);
    });

    test('the opt-in sync is a no-op on iPhone (never tells the server about sensors)', () async {
      PlatformFeatures.debugPlatform = TargetPlatform.iOS;
      final _CountingApi api = _CountingApi();
      expect(await DrivingEventsService(api).syncOptIn(), isTrue);
      expect(api.posts, 0);
    });

    test('background driving hook and crash watcher do nothing on iPhone', () async {
      PlatformFeatures.debugPlatform = TargetPlatform.iOS;
      await DrivingBackground.onLocationFix(speedMps: 30, lat: 1, lon: 2); // must not throw or arm sensors
      final CrashWatcher w = CrashWatcher(() => throw StateError('no context'));
      w.start(); // no timer, no context access
      w.stop();
    });

    test('motion permission step is not offered on iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(await PermissionService.supportsMotion(), isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

class _CountingApi implements SensorEventsApi {
  int posts = 0;
  @override
  Future<SensorEventsResult> post(List<Map<String, dynamic>> events,
      {required bool sensorEnabled, required bool phoneUseEnabled}) async {
    posts++;
    throw StateError('should not be called');
  }
}
