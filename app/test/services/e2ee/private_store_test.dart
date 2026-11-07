@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ofstore');
    PrivateStore.reset();
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PrivateStore.channel = const MethodChannel('app.openfamily/store');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('FileKv', () {
    test('keys with slashes round trip, values replace atomically and leave no temp files', () async {
      final FileKv kv = FileKv(dir);
      await kv.set('queue/v1', '{"v":1}');
      await kv.set('lanes/own/c1', 'a');
      await kv.set('queue/v1', '{"v":2}');
      expect(await kv.get('queue/v1'), '{"v":2}');
      expect(await kv.getFresh('lanes/own/c1'), 'a');
      expect(await kv.get('nope'), isNull);
      expect((await kv.keys())..sort(), <String>['lanes/own/c1', 'queue/v1']);
      expect(dir.listSync().where((FileSystemEntity e) => e.path.endsWith('.tmp')), isEmpty);
      await kv.remove('lanes/own/c1');
      expect(await kv.get('lanes/own/c1'), isNull);
    });

    test('a half-written temp file is never read as the value', () async {
      final FileKv kv = FileKv(dir);
      await kv.set('k', 'good');
      File('${dir.path}/.${FileKv.nameOf('k')}.123.tmp').writeAsStringSync('partial');
      expect(await kv.get('k'), 'good');
    });

    test('two isolates\' queue objects over one directory do not lose items (versioned queue on files)', () async {
      final FileKv a = FileKv(dir), b = FileKv(Directory(dir.path));
      final SealedQueue qa = SealedQueue(kv: a), qb = SealedQueue(kv: b);
      WireItem it(int s) => WireItem(circleId: 'c', deviceId: 'd', seq: s, purpose: 'fix', epoch: 1, sizeBucket: 256, ciphertext: Uint8List.fromList(<int>[s]));
      await Future.wait(<Future<void>>[
        for (int i = 1; i <= 8; i++) (i.isOdd ? qa : qb).enqueue(it(i)),
      ]);
      final List<int> seqs = (await qa.peek()).map((WireItem w) => w.seq).toList()..sort();
      expect(seqs, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    });
  });

  group('migration from SharedPreferences', () {
    test('copies, verifies, deletes the old keys, and never overwrites newer file data', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'e2ee_chan_queue/v1': 'OLDQ',
        'e2ee_chan_hist/c/u': 'H',
        'e2ee_chan_lanes/own/c': 'L',
        'other_setting': 'keep',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final FileKv kv = FileKv(dir);
      await kv.set('queue/v1', 'NEWER'); // written by the other isolate already
      final int moved = await migratePrefsToFiles(prefs, kv);
      expect(moved, 3);
      expect(await kv.get('queue/v1'), 'NEWER');
      expect(await kv.get('hist/c/u'), 'H');
      expect(await kv.get('lanes/own/c'), 'L');
      expect(prefs.getKeys(), <String>{'other_setting'});
      expect(await migratePrefsToFiles(prefs, kv), 0, reason: 'one time');
    });
  });

  group('PrivateStore on iOS', () {
    test('uses the directory Swift returns and reports a CONFIRMED exclusion', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues(<String, Object>{'e2ee_chan_seq/c/d': '7'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(PrivateStore.channel, (MethodCall c) async {
        expect(c.method, 'prepare');
        return <String, Object?>{'path': dir.path, 'excluded': true, 'error': ''};
      });
      final FileKv? kv = await PrivateStore.files();
      expect(kv, isNotNull);
      expect(PrivateStore.status.filesInUse, isTrue);
      expect(PrivateStore.status.backupExcluded, isTrue);
      expect(await kv!.get('seq/c/d'), '7', reason: 'migrated');
    });

    test('exclusion not confirmed: the store still works and the status says NOT confirmed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(PrivateStore.channel, (MethodCall c) async {
        return <String, Object?>{'path': dir.path, 'excluded': false, 'error': 'reading the flag failed'};
      });
      final FileKv? kv = await PrivateStore.files();
      await kv!.set('a', 'b');
      expect(await kv.get('a'), 'b');
      expect(PrivateStore.status.backupExcluded, isFalse);
      expect(PrivateStore.status.error, contains('flag'));
    });

    test('no channel on iOS: not silently trusted, reported as not confirmed, prefs used', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(PrivateStore.channel, null);
      expect(await PrivateStore.files(), isNull);
      expect(PrivateStore.status.backupExcluded, isFalse);
      expect(PrivateStore.status.filesInUse, isFalse);
    });

    test('other platforms keep SharedPreferences and show no backup line', () async {
      expect(await PrivateStore.files(), isNull);
      expect(PrivateStore.status.backupExcluded, isNull);
    });
  });

  test('Diagnostics says "backup exclusion NOT confirmed" only when it is not', () {
    DiagFacts facts(bool? excluded) => DiagFacts(now: DateTime(2026), storeBackupExcluded: excluded, storeBackupError: 'x');
    expect(evaluateDiagnostics(facts(false)).any((DiagCheck c) => c.id == 'backup-exclusion' && c.detail.contains('NOT confirmed') && c.status == DiagStatus.warn), isTrue);
    expect(evaluateDiagnostics(facts(true)).any((DiagCheck c) => c.id == 'backup-exclusion' && c.status == DiagStatus.pass), isTrue);
    expect(evaluateDiagnostics(facts(null)).any((DiagCheck c) => c.id == 'backup-exclusion'), isFalse);
  });
}
