import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/offline/offline_cache.dart';

/// A vault that can be told to fail (locked phone, key invalidated).
class FlakyVault extends MemoryVault {
  bool failReads = false, failWrites = false;
  @override
  Future<Uint8List?> read(String name) async {
    if (failReads) throw StateError('keystore locked');
    return super.read(name);
  }

  @override
  Future<void> write(String name, Uint8List value) async {
    if (failWrites) throw StateError('keystore locked');
    return super.write(name, value);
  }
}

void main() {
  late FlakyVault vault;
  late OfflineCache cache;
  setUp(() {
    vault = FlakyVault();
    cache = OfflineCache(vault: vault, maxBytes: 1000);
  });

  test('remembers a document across a restart (new instance, same vault) with its save time', () async {
    expect(await cache.write('roster/all', <dynamic>[<String, dynamic>{'user_id': 'u1', 'lat': 52.5}]), isTrue);
    final CacheEntry? e = await OfflineCache(vault: vault).read('roster/all');
    expect((e!.data! as List).single['lat'], 52.5);
    expect(DateTime.now().toUtc().difference(e.savedAt).inMinutes, lessThan(1));
  });

  test('positions are never stored as plain text: only the vault holds them, under the offline/ prefix', () async {
    await cache.write('roster/all', <dynamic>[<String, dynamic>{'lat': 52.5}]);
    expect(vault.data.keys.single, startsWith('offline/v1/'));
  });

  test('a document over the size limit is not stored (bounded)', () async {
    expect(await cache.write('big', 'x' * 5000), isFalse);
    expect(vault.data, isEmpty);
  });

  test('groups keep only the newest N documents', () async {
    for (int i = 0; i < 5; i++) {
      await cache.writeInGroup('trips', 'trips/$i', <String, int>{'i': i}, max: 3);
    }
    expect(await cache.read('trips/0'), isNull);
    expect(await cache.read('trips/1'), isNull);
    expect(await cache.read('trips/4'), isNotNull);
    expect(vault.data.keys.where((String k) => k.contains('trips/')).length, 3);
  });

  group('fetch (stale-while-revalidate)', () {
    Future<Cached<String>> go(Future<String> Function() load) => cache.fetch<String>('k', load,
        encode: (String v) => v, decode: (Object? j) => j! as String);

    test('fresh answer is returned and remembered', () async {
      final Cached<String> r = await go(() async => 'live');
      expect(r.fromCache, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect((await cache.read('k'))!.data, 'live');
    });

    test('server unreachable (timeout, refused, 502, 503): the last copy is returned and marked as such', () async {
      await go(() async => 'old');
      await Future<void>.delayed(Duration.zero);
      for (final Object e in <Object>[const ApiException(0, 't'), const ApiException(502, 'x'), const ApiException(503, 'x'), TimeoutException('t')]) {
        final Cached<String> r = await go(() async => throw e);
        expect(r.value, 'old', reason: '$e');
        expect(r.fromCache, isTrue);
        expect(r.savedAt, isNotNull);
      }
    });

    test('no copy yet: the original error surfaces (the screen shows its retry card)', () async {
      await expectLater(go(() async => throw const ApiException(0, 'offline')), throwsA(isA<ApiException>()));
    });

    test('the server saying no (403/404) or a dead session never hides behind the cache', () async {
      await go(() async => 'old');
      await Future<void>.delayed(Duration.zero);
      await expectLater(go(() async => throw const ApiException(403, 'no')), throwsA(isA<ApiException>()));
      await expectLater(go(() async => throw const ApiException(404, 'gone')), throwsA(isA<ApiException>()));
      await expectLater(go(() async => throw const SessionExpiredException()), throwsA(isA<SessionExpiredException>()));
    });
  });

  test('a locked or invalidated key store means "no cache", never a crash', () async {
    await cache.write('k', 'v');
    final OfflineCache fresh = OfflineCache(vault: vault);
    vault.failReads = true;
    expect(await fresh.read('k'), isNull);
    vault.failWrites = true;
    expect(await fresh.write('k2', 'v'), isFalse);
    await fresh.clearAll();
  });

  test('sign-out clears the snapshot (and only the snapshot)', () async {
    await vault.write('circle/key', Uint8List.fromList(<int>[1, 2, 3]));
    await cache.write('roster/all', <int>[1]);
    await cache.write('places', <int>[2]);
    await cache.clearAll();
    expect(await OfflineCache(vault: vault).read('places'), isNull);
    expect(vault.data.keys.toList(), <String>['circle/key']);
  });
}
