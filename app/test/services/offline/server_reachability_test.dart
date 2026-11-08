import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/offline/backoff.dart';
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/widgets/sync_status_chip.dart';

ServerReachability make(List<bool> answers, {List<DateTime>? times}) {
  int i = 0;
  return ServerReachability(
    probe: () async {
      times?.add(DateTime.now());
      final bool a = answers[min(i, answers.length - 1)];
      i++;
      return a;
    },
    backoff: Backoff(base: const Duration(seconds: 10), max: const Duration(minutes: 5), random: Random(3)),
  );
}

void main() {
  testWidgets('one failed request is confirmed by a probe and does not flip the state', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[true]);
    r.noteFailure();
    expect(r.state.value, SyncState.upToDate, reason: 'a single slow request says nothing');
    await t.pump(const Duration(seconds: 3));
    expect(r.probeCount, 1);
    expect(r.state.value, SyncState.upToDate);
    r.dispose();
  });

  testWidgets('a 5xx storm triggers one probe, not one per request', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false]);
    for (int i = 0; i < 200; i++) {
      r.noteFailure();
      r.noteResponse(503);
    }
    await t.pump(const Duration(seconds: 3));
    expect(r.probeCount, 1);
    expect(r.state.value, SyncState.unreachable);
    r.dispose();
  });

  testWidgets('while down, probes back off with jitter: no tight loop, no drain on the battery', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false]);
    r.noteFailure();
    // Ten simulated minutes of outage.
    for (int s = 0; s < 600; s++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(r.state.value, SyncState.unreachable);
    // 2 s confirm, then roughly 5-10 s, 10-20 s, 20-40 s ... capped at 5 min: about 8 probes, never hundreds.
    expect(r.probeCount, inInclusiveRange(4, 12));
    r.dispose();
  });

  testWidgets('recovery: the next probe that works flips back and runs the recovery callbacks once', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false, false, true]);
    int recovered = 0;
    r.onRecovered.add(() async => recovered++);
    r.setPending(3);
    r.noteFailure();
    await t.pump(const Duration(seconds: 3));
    expect(r.state.value, SyncState.unreachable);
    for (int s = 0; s < 120; s++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(r.state.value, SyncState.syncing, reason: '3 updates still waiting');
    expect(recovered, 1);
    r.setPending(0);
    expect(r.state.value, SyncState.upToDate);
    r.dispose();
  });

  testWidgets('any non-gateway answer from the server counts as alive, a 502/503/504 does not', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false]);
    r.noteResponse(404);
    r.noteResponse(401);
    r.noteResponse(500);
    await t.pump(const Duration(seconds: 5));
    expect(r.probeCount, 0, reason: 'the server answered');
    r.noteResponse(502);
    await t.pump(const Duration(seconds: 3));
    expect(r.probeCount, 1);
    expect(r.unreachable, isTrue);
    // A real answer while down means it is back.
    r.noteResponse(200);
    expect(r.state.value, SyncState.upToDate);
    r.dispose();
  });

  testWidgets('network coming back probes at once (debounced) only when the server was unreachable', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false, true]);
    r.connectivityChanged(connected: true);
    await t.pump(const Duration(seconds: 2));
    expect(r.probeCount, 0, reason: 'the server was fine, nothing to confirm');
    r.noteFailure();
    await t.pump(const Duration(seconds: 3));
    expect(r.unreachable, isTrue);
    for (int i = 0; i < 5; i++) {
      r.connectivityChanged(connected: true); // Wi-Fi flapping
    }
    await t.pump(const Duration(seconds: 1));
    expect(r.probeCount, 2, reason: 'one probe for the whole flap');
    expect(r.unreachable, isFalse);
    r.dispose();
  });

  testWidgets('manual Try again probes immediately and is single flight', (WidgetTester t) async {
    final ServerReachability r = make(<bool>[false, true]);
    r.noteFailure();
    await t.pump(const Duration(seconds: 3));
    final Future<bool> a = r.probeNow();
    final Future<bool> b = r.probeNow();
    await t.pump();
    await Future.wait(<Future<bool>>[a, b]);
    expect(r.probeCount, 2);
    r.dispose();
  });

  group('status chip', () {
    Future<void> show(WidgetTester t, ServerReachability r) => t.pumpWidget(MaterialApp(
          home: Scaffold(body: SyncStatusChip(reachability: r, flush: () async {})),
        ));

    testWidgets('hidden in normal operation', (WidgetTester t) async {
      final ServerReachability r = make(<bool>[true]);
      await show(t, r);
      expect(find.byKey(const Key('sync-status-chip')), findsNothing);
      r.dispose();
    });

    testWidgets('unreachable: plain words, count of waiting updates and a Try again button', (WidgetTester t) async {
      final ServerReachability r = make(<bool>[false, true]);
      r.setPending(3);
      await show(t, r);
      r.noteFailure();
      await t.pump(const Duration(seconds: 3));
      expect(find.textContaining('Server unreachable. Showing last known. Will sync when it is back.'), findsOneWidget);
      expect(find.textContaining('3 updates waiting'), findsOneWidget);
      await t.tap(find.byKey(const Key('sync-try-again')));
      await t.pump();
      await t.pump();
      expect(r.unreachable, isFalse);
      expect(find.textContaining('Syncing'), findsOneWidget);
      r.setPending(0);
      await t.pump();
      expect(find.text('Up to date'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(find.byKey(const Key('sync-status-chip')), findsNothing, reason: 'it hides itself again');
      r.dispose();
    });
  });
}
