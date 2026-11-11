// What the Diagnostics report says about the tracking service: process exits, standby bucket, per-hour counters,
// the last upload and error, and the journal. Pure text: no locations, no tokens.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/diagnostics/diagnostics_probe.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';

final DateTime now = DateTime.utc(2026, 11, 10, 23, 30);

ProcessExit exit(int reason, {DateTime? at, int importance = 125, int status = 0, String name = 'app.openfamily', String note = ''}) =>
    ProcessExit(at: at ?? DateTime.utc(2026, 11, 10, 22, 36, 4), reason: reason, importance: importance, status: status, processName: name, description: note);

void main() {
  group('names', () {
    test('exit reasons, importances and buckets have their Android names; unknown numbers stay readable', () {
      expect(exitReasonName(14), 'FREEZER');
      expect(exitReasonName(3), 'LOW_MEMORY');
      expect(exitReasonName(10), 'USER_REQUESTED');
      expect(exitReasonName(4), 'CRASH');
      expect(exitReasonName(99), 'REASON_99');
      expect(processImportanceName(125), 'FOREGROUND_SERVICE');
      expect(processImportanceName(400), 'CACHED');
      expect(standbyBucketName(10), 'ACTIVE');
      expect(standbyBucketName(45), 'RESTRICTED');
      expect(standbyBucketName(7), 'BUCKET_7');
    });
  });

  group('parsing what the phone sends', () {
    test('an exit keeps only numbers and short Android text, flattened', () {
      final ProcessExit? e = ProcessExit.fromMap(<String, Object?>{
        'timestamp': DateTime.utc(2026, 11, 10, 22, 36).millisecondsSinceEpoch,
        'reason': 14,
        'importance': 125,
        'status': 9,
        'processName': 'app.openfamily',
        'description': 'freezer\n  killed ${'x' * 200}',
      });
      expect(e!.reason, 14);
      expect(e.status, 9);
      expect(e.description.contains('\n'), isFalse);
      expect(e.description.length, lessThanOrEqualTo(83));
    });

    test('garbage is skipped, a missing list is "unavailable", an empty one is "none"', () {
      expect(ProcessExit.fromMap('nope'), isNull);
      expect(ProcessExit.fromMap(<String, Object?>{'reason': 3}), isNull);
      expect(DiagnosticsProbe.parseExits(null), isNull);
      expect(DiagnosticsProbe.parseExits('x'), isNull);
      expect(DiagnosticsProbe.parseExits(<Object?>[]), isEmpty);
      expect(DiagnosticsProbe.parseExits(<Object?>[1, null, <String, Object?>{'timestamp': 5, 'reason': 3}])!.length, 1);
    });

    test('native journal lines parse; bad ones are dropped', () {
      final List<JournalLine> l = DiagnosticsProbe.parseNativeJournal(<Object?>[
        <String, Object?>{'t': 1000, 'e': 'service_created', 'd': '', 'n': 1, 'l': null},
        <String, Object?>{'t': 2000, 'e': 'heartbeat_dropped', 'd': 'reason=no_engine', 'n': 3, 'l': 9000},
        <String, Object?>{'e': 'no_time'},
        'junk',
      ]);
      expect(l.length, 2);
      expect(l[0].source, 'native');
      expect(l[1].count, 3);
      expect(l[1].last, DateTime.fromMillisecondsSinceEpoch(9000, isUtc: true));
      expect(DiagnosticsProbe.parseNativeJournal(null), isEmpty);
    });
  });

  group('the report text', () {
    test('process exits show the reason, local time and UTC', () {
      final String s = renderTrackingHealth(
        TrackingHealthFacts(
          exits: <ProcessExit>[exit(14, note: 'freezer'), exit(3, at: DateTime.utc(2026, 11, 9, 5)), exit(10), exit(4)],
          standbyBucket: 40,
          ignoringBatteryOptimizations: false,
          utcOffset: const Duration(hours: -5),
        ),
        now,
      );
      expect(s, contains('Recent process exits'));
      expect(s, contains('FREEZER importance=FOREGROUND_SERVICE'));
      expect(s, contains('LOW_MEMORY'));
      expect(s, contains('USER_REQUESTED'));
      expect(s, contains('CRASH'));
      expect(s, contains('local 2026-11-10 17:36:04 / UTC 2026-11-10 22:36:04Z'));
      expect(s, contains('note="freezer"'));
      expect(s, contains('local time zone UTC-05:00'));
      expect(s, contains('standby_bucket=RARE (40)'));
      expect(s, contains('battery_optimisation_ignored=no'));
    });

    test('a missing method says so, and nothing recorded says so', () {
      final String s = renderTrackingHealth(const TrackingHealthFacts(), now);
      expect(s, contains('unavailable on this Android version'));
      expect(s, contains('standby_bucket=unknown'));
      expect(s, contains('battery_optimisation_ignored=unknown'));
      expect(s, contains('last_upload_ok: never recorded'));
      expect(s, contains('last_seal_or_identity_error: none'));
      expect(s, contains('(nothing counted yet)'));
      expect(s, contains('(empty)'));
      expect(renderTrackingHealth(const TrackingHealthFacts(exits: <ProcessExit>[]), now), contains('(none recorded)'));
    });

    test('last upload, last errors and the hourly counts', () {
      final String s = renderTrackingHealth(
        TrackingHealthFacts(
          stats: StatsSnapshot(
            hours: <HourCounts>[
              const HourCounts('2026-11-10T21', <int>[40, 10, 2, 28, 0, 1, 6, 0]),
              const HourCounts('2026-11-10T22', <int>[16, 0, 9, 7, 3, 4, 1, 5]),
            ],
            lastUploadOkAt: DateTime.utc(2026, 11, 10, 22, 35, 10),
            lastUploadOkSource: 'bg',
            lastSealError: StatsError(at: DateTime.utc(2026, 11, 10, 22, 36), where: 'seal:unreadable', type: 'LocalKeyException', source: 'bg'),
            lastError: StatsError(at: DateTime.utc(2026, 11, 10, 22, 37), where: 'post_location', type: 'SocketException', source: 'bg'),
          ),
        ),
        now,
      );
      expect(s, contains('last_upload_ok: 2026-11-10 22:35:10Z (bg), 54 min ago'));
      expect(s, contains('last_seal_or_identity_error: LocalKeyException in seal:unreadable (bg) at 2026-11-10 22:36:00Z'));
      expect(s, contains('last_callback_error: SocketException in post_location (bg)'));
      expect(s, contains('2026-11-10T22Z received=16 dropped=0 parked=9 posted=7 credential_failures=3 seal_errors=4 heartbeat_ok=1 heartbeat_failed=5'));
      expect(s, contains('2026-11-10T21Z received=40 dropped=10 parked=2 posted=28'));
    });

    test('the journal is last, oldest first, folded repeats show a count, and it is cut to 100 lines', () {
      final List<JournalLine> j = <JournalLine>[
        for (int i = 0; i < 130; i++) JournalLine(at: DateTime.utc(2026, 11, 10, 20).add(Duration(minutes: i)), source: i.isEven ? 'app' : 'native', event: 'e$i'),
        JournalLine(at: DateTime.utc(2026, 11, 10, 23), source: 'native', event: 'heartbeat_dropped', detail: 'reason=no_engine', count: 6, last: DateTime.utc(2026, 11, 10, 23, 20)),
      ];
      final String s = renderTrackingHealth(TrackingHealthFacts(journal: j), now);
      expect(s, contains('Tracking journal (last 100'));
      expect(s, isNot(contains(' e0\n')));
      expect(s, contains('[native] heartbeat_dropped reason=no_engine x6 (last 2026-11-10 23:20:00Z)'));
      expect(s.trimRight().split('\n').last, contains('heartbeat_dropped'));
    });

    test('the full report carries the tracking section before its closing line, and holds no coordinates or tokens', () {
      final DiagFacts f = DiagFacts(
        now: now,
        manufacturer: 'samsung',
        model: 'SM-S948U1',
        tracking: TrackingHealthFacts(exits: <ProcessExit>[exit(14)], journal: <JournalLine>[JournalLine(at: now, source: 'app', event: 'app_resumed', detail: 'away_s=3600')]),
      );
      final String r = buildDiagnosticReport(f, evaluateDiagnostics(f), storageEvents: 'Storage events (last 0, oldest first):\n  (none)\n');
      expect(r, contains('Recent process exits'));
      expect(r.indexOf('Storage events'), lessThan(r.indexOf('Tracking journal')));
      expect(r.indexOf('Tracking journal'), lessThan(r.indexOf('This report contains no locations')));
      expect(r, isNot(contains('lat=')));
      expect(r, isNot(contains('lon=')));
      // Without the facts (the light probe) nothing about tracking is printed.
      final DiagFacts light = DiagFacts(now: now);
      expect(buildDiagnosticReport(light, evaluateDiagnostics(light)), isNot(contains('Recent process exits')));
    });
  });

  group('the probe tolerates a missing platform method', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel ch = MethodChannel('app.openfamily/diagnostics');
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));

    test('no handler at all: exits are unknown, the rest is still collected', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
      final TrackingHealthFacts t = await DiagnosticsProbe.collectTracking(native: <String, dynamic>{'ignoringBatteryOptimizations': true});
      expect(t.exits, isNull);
      expect(t.standbyBucket, isNull);
      expect(t.ignoringBatteryOptimizations, true);
    });

    test('a handler that answers: exits, standby bucket and the native journal arrive', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (MethodCall c) async {
        switch (c.method) {
          case 'exitReasons':
            return <Object?>[
              <String, Object?>{'timestamp': 1000, 'reason': 14, 'importance': 125, 'status': 0, 'processName': 'app.openfamily', 'description': 'freezer'},
            ];
          case 'trackingJournal':
            return <Object?>[<String, Object?>{'t': 500, 'e': 'service_created', 'd': '', 'n': 1}];
        }
        throw MissingPluginException();
      });
      final TrackingHealthFacts t = await DiagnosticsProbe.collectTracking(native: <String, dynamic>{'standbyBucket': 30});
      expect(t.exits!.single.reason, 14);
      expect(t.standbyBucket, 30);
      expect(t.journal.map((JournalLine l) => l.event), contains('service_created'));
      expect(jsonEncode(t.journal.map((JournalLine l) => l.source).toSet().toList()), contains('native'));
    });
  });
}
