import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/crash_countdown_screen.dart';
import 'package:openfamily/services/driving/crash_pending.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late int now;

  Future<void> seed() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CrashPendingStore.save(CrashPending.start(
      occurredAtMs: now,
      nowMs: now,
      peakG: 8,
      speedBeforeMps: 18,
      speedAfterMps: 0,
      lat: 1,
      lon: 2,
    ));
  }

  setUp(() => now = 5000000);

  testWidgets("shows the countdown and I'm OK cancels without sending",
      (WidgetTester tester) async {
    await seed();
    final List<CrashPending> sent = <CrashPending>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
            builder: (_) => CrashCountdownScreen(
              now: () => now,
              haptics: false,
              send: (CrashPending p) async {
                sent.add(p);
                return 'id';
              },
            ),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Are you OK?'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('I need help'), findsOneWidget);

    now += 10000;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('20'), findsOneWidget);

    await tester.tap(find.byKey(const Key('crash-ok')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Are you OK?'), findsNothing);
    expect(sent, isEmpty);
    expect((await CrashPendingStore.load())!.cancelled, isTrue);
  });

  testWidgets('after the deadline it sends and offers a false-alarm button',
      (WidgetTester tester) async {
    await seed();
    final List<String> statuses = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: CrashCountdownScreen(
        now: () => now,
        haptics: false,
        send: (CrashPending p) async => 'id-9',
        markStatus: (String id, String status) async =>
            statuses.add('$id:$status'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    now += 31000;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Alert sent'), findsOneWidget);
    await tester.tap(find.byKey(const Key('crash-false-alarm')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(statuses, <String>['id-9:false_alarm']);
  });
}
