// Resume restart: when the app comes back and tracking is wanted but the service is gone, it is started again
// (and journalled); never when sharing is off or "Allow all the time" is missing; never twice.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';
import 'package:openfamily/services/diagnostics/tracking_journal.dart';
import 'package:openfamily/services/tracking_resume.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late TrackingJournal journal;
  int starts = 0;
  int runningChecks = 0;
  final DateTime now = DateTime.utc(2026, 11, 10, 23);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrackingJournal.setSourceForTest('app');
    journal = TrackingJournal(clock: () => now);
    starts = 0;
    runningChecks = 0;
  });

  Future<ResumeOutcome> go({
    bool android = true,
    bool sharing = true,
    String perm = 'always',
    bool running = false,
    bool throwRunning = false,
    DateTime? startedAt,
    Future<void> Function()? start,
  }) =>
      TrackingResume.onResume(
        android: android,
        sharingOn: () => sharing,
        permission: () async => perm,
        isRunning: () async {
          runningChecks++;
          if (throwRunning) throw StateError('channel');
          return running;
        },
        start: start ?? () async => starts++,
        lastStartAt: () => startedAt,
        journal: journal,
        clock: () => now,
      );

  Future<List<String>> events() async => (await journal.readAll()).map((JournalLine l) => l.event).toList();

  test('wanted and not running: starts it once and journals service_restarted_on_resume', () async {
    expect(await go(), ResumeOutcome.restarted);
    expect(starts, 1);
    expect(await events(), contains('service_restarted_on_resume'));
  });

  test('already running: nothing is started, nothing is journalled as a restart', () async {
    expect(await go(running: true), ResumeOutcome.running);
    expect(starts, 0);
    expect(await events(), isNot(contains('service_restarted_on_resume')));
  });

  test('sharing off: never starts, and does not even ask whether it runs', () async {
    expect(await go(sharing: false), ResumeOutcome.sharingOff);
    expect(starts, 0);
    expect(runningChecks, 0);
  });

  test('permission missing (while in use, denied, unknown): never starts', () async {
    for (final String p in <String>['while_in_use', 'denied', 'unknown']) {
      expect(await go(perm: p), ResumeOutcome.noPermission, reason: p);
    }
    expect(starts, 0);
    expect(runningChecks, 0);
    // The permission change itself is journalled once per change.
    final List<String> d = (await journal.readAll()).where((JournalLine l) => l.event == 'permission_changed').map((JournalLine l) => l.detail).toList();
    expect(d.first, 'from=none to=while_in_use');
    expect(d.length, 3);
  });

  test('not Android: nothing', () async {
    expect(await go(android: false), ResumeOutcome.unsupported);
    expect(starts + runningChecks, 0);
  });

  test('the running state cannot be read: nothing is started on a guess', () async {
    expect(await go(throwRunning: true), ResumeOutcome.unknown);
    expect(starts, 0);
  });

  test('a start from a moment ago is not repeated', () async {
    expect(await go(startedAt: now.subtract(const Duration(seconds: 5))), ResumeOutcome.startedRecently);
    expect(starts, 0);
    expect(await go(startedAt: now.subtract(const Duration(minutes: 5))), ResumeOutcome.restarted);
  });

  test('idempotent: a second resume while the first check runs does nothing; afterwards it checks again', () async {
    final Completer<void> gate = Completer<void>();
    final Future<ResumeOutcome> first = go(start: () async {
      starts++;
      await gate.future;
    });
    await Future<void>.delayed(Duration.zero);
    expect(await go(), ResumeOutcome.busy);
    gate.complete();
    expect(await first, ResumeOutcome.restarted);
    expect(starts, 1);
    expect(await go(running: true), ResumeOutcome.running);
  });

  test('a start that throws never escapes', () async {
    expect(await go(start: () async => throw StateError('plugin')), ResumeOutcome.unknown);
    expect(await go(running: true), ResumeOutcome.running, reason: 'the guard is released after a failure');
  });
}
