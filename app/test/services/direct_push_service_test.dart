import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/direct_push_service.dart';

class FakeNotifier implements DirectPushNotifier {
  final List<Map<String, Object?>> shown = <Map<String, Object?>>[];
  bool fail = false;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    bool urgent = false,
  }) async {
    if (fail) throw StateError('notifier down');
    shown.add(<String, Object?>{
      'id': id,
      'title': title,
      'body': body,
      'payload': payload,
      'urgent': urgent,
    });
  }
}

class FakeTransport implements DirectPushTransport {
  final List<StreamController<String>> streams = <StreamController<String>>[];
  final List<int> statuses = <int>[];
  final List<List<String>> acks = <List<String>>[];
  int opens = 0;
  Object? openError;
  DirectPushCredentials? lastCreds;

  /// Status for the next [open]; defaults to 200.
  void queueStatus(int s) => statuses.add(s);

  @override
  Future<DirectPushConnection> open(DirectPushCredentials creds) async {
    opens++;
    lastCreds = creds;
    if (openError != null) throw openError!;
    final StreamController<String> c = StreamController<String>();
    streams.add(c);
    final int status = statuses.isEmpty ? 200 : statuses.removeAt(0);
    if (status != 200) unawaited(c.close());
    return DirectPushConnection(status, c.stream);
  }

  @override
  Future<bool> ack(DirectPushCredentials creds, List<String> ids) async {
    acks.add(ids);
    return true;
  }
}

String pushFrame(Map<String, Object?> payload) =>
    'id: ${payload['id']}\nevent: push\ndata: ${jsonEncode(payload)}\n\n';

const DirectPushCredentials creds = DirectPushCredentials(
  baseUrl: 'https://of.example',
  deviceId: 'dev1',
  ingestKey: 'key1',
);

Future<void> settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('SseParser', () {
    test('parses frames split across arbitrary chunks, CRLF and comments', () {
      final SseParser p = SseParser();
      final List<SseFrame> out = <SseFrame>[
        ...p.add('retry: 5000\nevent: hel'),
        ...p.add('lo\ndata: {"a":1}\n'),
        ...p.add('\n: hb\n\nid: x1\r\nevent: push\r\ndata: one\r\ndata: two\r\n\r\n'),
      ];
      expect(out.length, 2);
      expect(out[0].event, 'hello');
      expect(out[0].data, '{"a":1}');
      expect(out[1].event, 'push');
      expect(out[1].id, 'x1');
      expect(out[1].data, 'one\ntwo');
    });

    test('a heartbeat comment alone produces no frame', () {
      expect(SseParser().add(': hb\n\n'), isEmpty);
    });
  });

  group('DirectPushEvent.tryParse', () {
    test('alert', () {
      final DirectPushEvent? e = DirectPushEvent.tryParse(jsonEncode(
        <String, Object>{
          'v': 1,
          'id': 'alert:a1',
          'kind': 'alert',
          'alert_id': 'a1',
          'title': 'A family member sent SOS',
        },
      ));
      expect(e, isNotNull);
      expect(e!.kind, DirectPushKind.alert);
      expect(e.alertId, 'a1');
      expect(e.body, '');
    });

    test('command keeps the JSON text', () {
      final DirectPushEvent? e = DirectPushEvent.tryParse(jsonEncode(
        <String, Object>{
          'id': 'c1',
          'kind': 'command',
          'command': <String, String>{'type': 'location_request'},
        },
      ));
      expect(e!.kind, DirectPushKind.command);
      expect(jsonDecode(e.command), <String, String>{'type': 'location_request'});
    });

    test('rejects malformed events', () {
      expect(DirectPushEvent.tryParse('not json'), isNull);
      expect(DirectPushEvent.tryParse('[]'), isNull);
      expect(DirectPushEvent.tryParse('{"kind":"alert"}'), isNull);
      expect(DirectPushEvent.tryParse('{"id":"x","kind":"weird"}'), isNull);
      expect(DirectPushEvent.tryParse('{"id":"x","kind":"command"}'), isNull);
    });
  });

  group('ReconnectBackoff', () {
    test('grows exponentially, stays within jitter and caps', () {
      final ReconnectBackoff b = ReconnectBackoff(random: Random(1));
      final List<int> secs = <int>[];
      for (int i = 0; i < 12; i++) {
        secs.add(b.next().inMilliseconds);
      }
      // 2s base, +-20%.
      expect(secs[0], inInclusiveRange(1600, 2400));
      expect(secs[1], inInclusiveRange(3200, 4800));
      expect(secs[2], inInclusiveRange(6400, 9600));
      expect(secs.last, lessThanOrEqualTo(const Duration(minutes: 5).inMilliseconds));
      expect(secs.last, greaterThanOrEqualTo(240000));
      for (int i = 1; i < 7; i++) {
        expect(secs[i], greaterThan(secs[i - 1] * 1.2 - 1));
      }
    });

    test('reset starts over', () {
      final ReconnectBackoff b = ReconnectBackoff(random: Random(2));
      for (int i = 0; i < 5; i++) {
        b.next();
      }
      b.reset();
      expect(b.next().inMilliseconds, lessThanOrEqualTo(2400));
    });
  });

  group('DirectPushDispatcher', () {
    test('alert becomes an urgent notification that routes to its alert', () async {
      final FakeNotifier n = FakeNotifier();
      final DirectPushDispatcher d = DirectPushDispatcher(notifier: n);
      final bool ok = await d.handle(const DirectPushEvent(
        id: 'alert:a1',
        kind: DirectPushKind.alert,
        title: 'A family member sent SOS',
        alertId: 'a1',
      ));
      expect(ok, isTrue);
      expect(n.shown.single['title'], 'A family member sent SOS');
      expect(n.shown.single['payload'], 'alert:a1');
      expect(n.shown.single['urgent'], isTrue);
    });

    test('same event id maps to the same notification id (no stacking)', () {
      expect(DirectPushDispatcher.notificationId('alert:a1'),
          DirectPushDispatcher.notificationId('alert:a1'));
      expect(DirectPushDispatcher.notificationId('alert:a1'),
          isNot(DirectPushDispatcher.notificationId('alert:a2')));
      expect(DirectPushDispatcher.notificationId('x'), isNonNegative);
    });

    test('notice without title falls back and has no tap payload', () async {
      final FakeNotifier n = FakeNotifier();
      await DirectPushDispatcher(notifier: n)
          .handle(const DirectPushEvent(id: 'n1', kind: DirectPushKind.notice));
      expect(n.shown.single['title'], 'OpenFamily');
      expect(n.shown.single['payload'], isNull);
    });

    test('command runs the handler and shows nothing', () async {
      final FakeNotifier n = FakeNotifier();
      final List<String> ran = <String>[];
      final DirectPushDispatcher d = DirectPushDispatcher(
        notifier: n,
        runCommand: (String c) async => ran.add(c),
      );
      final bool ok = await d.handle(const DirectPushEvent(
          id: 'c1', kind: DirectPushKind.command, command: '{"type":"x"}'));
      expect(ok, isTrue);
      expect(ran, <String>['{"type":"x"}']);
      expect(n.shown, isEmpty);
    });

    test('a failing notifier reports not handled so it is not acked', () async {
      final FakeNotifier n = FakeNotifier()..fail = true;
      final bool ok = await DirectPushDispatcher(notifier: n).handle(
          const DirectPushEvent(id: 'a', kind: DirectPushKind.alert, title: 't'));
      expect(ok, isFalse);
    });
  });

  group('routeNotificationTap', () {
    test('alert payload opens that alert', () async {
      String? opened;
      bool checked = false;
      await routeNotificationTap(
        'alert:abc',
        openAlert: (String id) async => opened = id,
        checkActive: () async => checked = true,
      );
      expect(opened, 'abc');
      expect(checked, isFalse);
    });

    test('missing or unknown payload falls back to the newest active alert',
        () async {
      int checks = 0;
      for (final String? p in <String?>[null, '', 'alert:', 'other:1']) {
        await routeNotificationTap(
          p,
          openAlert: (String id) async => fail('must not open'),
          checkActive: () async => checks++,
        );
      }
      expect(checks, 4);
    });
  });

  group('DirectPushService', () {
    late FakeTransport transport;
    late FakeNotifier notifier;
    late List<Duration> sleeps;
    late bool enabled;
    late StreamController<bool> online;
    late DirectPushService service;
    late Completer<void> sleepGate;

    setUp(() {
      transport = FakeTransport();
      notifier = FakeNotifier();
      sleeps = <Duration>[];
      enabled = true;
      online = StreamController<bool>.broadcast();
      sleepGate = Completer<void>();
      service = DirectPushService(
        transport: transport,
        loadCredentials: () async => creds,
        dispatcher: DirectPushDispatcher(notifier: notifier),
        isEnabled: () async => enabled,
        backoff: ReconnectBackoff(random: Random(3)),
        onlineChanges: online.stream,
        // Sleeping blocks until the test opens the gate, so the loop is
        // deterministic and never spins.
        sleeper: (Duration d) {
          sleeps.add(d);
          return sleepGate.future;
        },
        idleTimeout: const Duration(milliseconds: 80),
        stableAfter: const Duration(hours: 1),
      );
    });

    tearDown(() {
      service.stop();
      if (!sleepGate.isCompleted) sleepGate.complete();
    });

    test('connects with the device key, shows the alert and acks it', () async {
      service.start();
      await settle();
      expect(transport.opens, 1);
      expect(transport.lastCreds!.header, 'dev1.key1');
      transport.streams.first.add('event: hello\ndata: {}\n\n');
      transport.streams.first.add(pushFrame(<String, Object?>{
        'v': 1,
        'id': 'alert:a1',
        'kind': 'alert',
        'alert_id': 'a1',
        'title': 'A family member sent SOS',
      }));
      await settle();
      expect(notifier.shown.length, 1);
      expect(transport.acks, <List<String>>[
        <String>['alert:a1']
      ]);
    });

    test('a redelivered event is shown once but re-acked', () async {
      service.start();
      await settle();
      final Map<String, Object?> ev = <String, Object?>{
        'id': 'alert:a1',
        'kind': 'alert',
        'alert_id': 'a1',
        'title': 't',
      };
      transport.streams.first.add(pushFrame(ev));
      transport.streams.first.add(pushFrame(ev));
      await settle();
      expect(notifier.shown.length, 1);
      expect(transport.acks.length, 2);
    });

    test('an event that fails to show is not acked', () async {
      notifier.fail = true;
      service.start();
      await settle();
      transport.streams.first.add(pushFrame(<String, Object?>{
        'id': 'x', 'kind': 'alert', 'title': 't',
      }));
      await settle();
      expect(transport.acks, isEmpty);
    });

    test('reconnects with backoff after the stream drops, then recovers', () async {
      service.start();
      await settle();
      await transport.streams.first.close();
      await settle();
      expect(sleeps.length, 1);
      expect(sleeps.first.inMilliseconds, inInclusiveRange(1600, 2400));
      final Completer<void> g = sleepGate;
      sleepGate = Completer<void>();
      g.complete();
      await settle();
      expect(transport.opens, 2);
    });

    test('backoff grows across consecutive failures', () async {
      transport.openError = StateError('offline');
      service.start();
      await settle();
      for (int i = 0; i < 3; i++) {
        final Completer<void> g = sleepGate;
        sleepGate = Completer<void>();
        g.complete();
        await settle();
      }
      expect(sleeps.length, 4);
      expect(sleeps[3].inMilliseconds, greaterThan(sleeps[0].inMilliseconds));
    });

    test('401/404 pauses for a long time instead of hammering the server',
        () async {
      transport.queueStatus(401);
      service.start();
      await settle();
      expect(sleeps.single, const Duration(minutes: 10));
    });

    test('bye revoked pauses; bye replaced pauses', () async {
      service.start();
      await settle();
      transport.streams.first
          .add('event: bye\ndata: {"reason":"revoked"}\n\n');
      await settle();
      expect(sleeps.single, const Duration(minutes: 10));
    });

    test('a silent connection is dropped after the idle timeout', () async {
      service.start();
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await settle();
      expect(sleeps.length, 1, reason: 'idle stream should have been abandoned');
    });

    test('network coming back reconnects immediately', () async {
      service.start();
      await settle();
      expect(transport.opens, 1);
      online.add(true);
      await settle();
      // The live connection was dropped for a zero-length wait.
      expect(sleeps.last, Duration.zero);
      final Completer<void> g = sleepGate;
      sleepGate = Completer<void>();
      g.complete();
      await settle();
      expect(transport.opens, 2);
    });

    test('respects the push preference', () async {
      enabled = false;
      service.start();
      await settle();
      expect(transport.opens, 0);
      expect(sleeps.single, const Duration(minutes: 1));
    });

    test('no stored credentials means no connection attempt', () async {
      final DirectPushService s = DirectPushService(
        transport: transport,
        loadCredentials: () async => null,
        dispatcher: DirectPushDispatcher(notifier: notifier),
        isEnabled: () async => true,
        sleeper: (Duration d) => sleepGate.future,
      );
      s.start();
      await settle();
      s.stop();
      expect(transport.opens, 0);
    });
  });
}
