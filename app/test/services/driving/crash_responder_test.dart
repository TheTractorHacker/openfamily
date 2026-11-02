import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/crash_detector.dart';
import 'package:openfamily/services/driving/crash_pending.dart';
import 'package:openfamily/services/driving/crash_responder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Sender implements CrashAlertSender {
  final List<CrashPending> sent = <CrashPending>[];
  bool fail = false;

  @override
  Future<String?> send(CrashPending crash) async {
    if (fail) return null;
    sent.add(crash);
    return 'crash-1';
  }
}

class _Notifier implements CrashNotifier {
  final List<String> log = <String>[];

  @override
  Future<void> showCountdown() async => log.add('countdown');
  @override
  Future<void> showSent() async => log.add('sent');
  @override
  Future<void> dismiss() async => log.add('dismiss');
}

const CrashSignal _signal = CrashSignal(
  tMs: 1,
  peakG: 8,
  speedBeforeMps: 18,
  speedAfterMps: 0.3,
  lat: 52,
  lon: 4,
);

void main() {
  late int now;
  late _Sender sender;
  late _Notifier notifier;
  late CrashResponder responder;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    now = 1000000;
    sender = _Sender();
    notifier = _Notifier();
    responder = CrashResponder(
      sender: sender,
      notifier: notifier,
      clock: () => now,
      retryEvery: const Duration(seconds: 10),
    );
  });

  tearDown(() => responder.dispose());

  test('countdown pending record and notification are created', () async {
    await responder.handle(_signal);
    final CrashPending? c = await CrashPendingStore.load();
    expect(c, isNotNull);
    expect(c!.phase(now), CrashPhase.counting);
    expect(c.secondsLeft(now), 30);
    expect(notifier.log, <String>['countdown']);
    expect(sender.sent, isEmpty);
  });

  test('nothing is sent before the countdown ends', () async {
    await responder.handle(_signal);
    now += 29000;
    await responder.poll();
    expect(sender.sent, isEmpty);
  });

  test('unanswered countdown sends once and records the server id', () async {
    await responder.handle(_signal);
    now += 30000;
    await responder.poll();
    expect(sender.sent, hasLength(1));
    expect(sender.sent.single.helpRequested, isFalse);
    final CrashPending? c = await CrashPendingStore.load();
    expect(c!.phase(now), CrashPhase.sent);
    expect(c.sentId, 'crash-1');
    expect(notifier.log.last, 'sent');
    now += 5000;
    await responder.poll();
    expect(sender.sent, hasLength(1));
  });

  test("tapping I'm OK cancels: nothing is ever sent", () async {
    await responder.handle(_signal);
    now += 10000;
    await CrashPendingStore.cancel();
    now += 60000;
    await responder.poll();
    expect(sender.sent, isEmpty);
    expect(notifier.log.last, 'dismiss');
    expect(responder.isRunning, isFalse);
  });

  test('I need help sends immediately with the help flag', () async {
    await responder.handle(_signal);
    now += 3000;
    await CrashPendingStore.requestHelp();
    await responder.poll();
    expect(sender.sent, hasLength(1));
    expect(sender.sent.single.helpRequested, isTrue);
    expect(sender.sent.single.toRequestBody()['help_requested'], isTrue);
  });

  test('a failed send is retried after the retry gap', () async {
    sender.fail = true;
    await responder.handle(_signal);
    now += 30000;
    await responder.poll();
    expect(sender.sent, isEmpty);
    sender.fail = false;
    now += 3000;
    await responder.poll(); // inside the retry gap
    expect(sender.sent, isEmpty);
    now += 8000;
    await responder.poll();
    expect(sender.sent, hasLength(1));
  });

  test('a second signal while one is live is ignored', () async {
    await responder.handle(_signal);
    now += 1000;
    await responder.handle(_signal);
    expect(notifier.log.where((String e) => e == 'countdown'), hasLength(1));
  });

  test('cancel cannot undo an alert that already went out', () async {
    await responder.handle(_signal);
    now += 30000;
    await responder.poll();
    final CrashPending? after = await CrashPendingStore.cancel();
    expect(after!.cancelled, isFalse);
    expect(after.sentId, 'crash-1');
  });

  group('CrashPending', () {
    test('request body carries the report fields', () {
      final CrashPending c = CrashPending.start(
        occurredAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        nowMs: 0,
        peakG: 7.5,
        speedBeforeMps: 20,
        speedAfterMps: 0,
        lat: 1,
        lon: 2,
      );
      final Map<String, dynamic> b = c.toRequestBody();
      expect(b['occurred_at'], '2026-01-01T00:00:00.000Z');
      expect(b['peak_g'], 7.5);
      expect(b['lat'], 1);
      expect(b['help_requested'], false);
    });

    test('json round trip and stale detection', () {
      final CrashPending c = CrashPending.start(
          occurredAtMs: 100, nowMs: 100, peakG: 5, speedBeforeMps: 9, speedAfterMps: 1);
      final CrashPending? r = CrashPending.fromJson(c.toJson());
      expect(r!.deadlineMs, c.deadlineMs);
      expect(c.isLive(100 + 60000), isTrue);
      expect(c.isLive(100 + 11 * 60000), isFalse);
      expect(CrashPending.fromJson('junk'), isNull);
    });
  });
}
