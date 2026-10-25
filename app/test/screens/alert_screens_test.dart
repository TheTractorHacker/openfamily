import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/alert.dart';
import 'package:openfamily/screens/alert_received_screen.dart';
import 'package:openfamily/screens/alert_status_screen.dart';
import 'package:openfamily/screens/alerts_history_screen.dart';
import 'package:openfamily/services/alert_service.dart';
import 'package:openfamily/services/api_client.dart';

class FakeAlertService extends AlertService {
  FakeAlertService({this.details = const [], this.pages = const [], this.failList = false, this.failDetail = false, this.failAck = false});
  final List<AlertDetail> details;
  final List<AlertPage> pages;
  bool failList;
  bool failDetail;
  bool failAck;
  int detailCalls = 0;
  int acks = 0;
  int revokes = 0;
  int listCalls = 0;
  final List<String?> befores = [];

  @override
  Future<AlertDetail> detail(String id) async {
    detailCalls++;
    if (failDetail) throw Exception('offline');
    return details[(detailCalls - 1).clamp(0, details.length - 1)];
  }

  @override
  Future<AlertPage> list({int limit = 20, String? before}) async {
    befores.add(before);
    if (failList) throw Exception('offline');
    listCalls++;
    return pages[(listCalls - 1).clamp(0, pages.length - 1)];
  }

  @override
  Future<DateTime?> acknowledge(String id) async {
    acks++;
    if (failAck) throw const ApiException(500, 'x');
    return DateTime.now();
  }

  @override
  Future<void> revokeShare(String id) async => revokes++;
}

class FakeDialer extends EmergencyDialer {
  FakeDialer({this.ok = true});
  final bool ok;
  int dials = 0;
  @override
  bool get available => ok;
  @override
  Future<bool> dial() async {
    dials++;
    return true;
  }
}

AlertDetail detail(List<Map<String, dynamic>> rows, {String status = 'active'}) =>
    AlertDetail.fromJson(<String, dynamic>{
      'id': 'a1', 'type': 'sos', 'status': status, 'user_id': 'me', 'sender_name': 'Me',
      'created_at': '2026-10-25T10:00:00Z', 'deliveries': rows,
    });

Map<String, dynamic> row(String who, String ch, String st, {String err = ''}) => {
      'recipient_user_id': 'id-$who', 'recipient': who, 'channel': ch, 'state': st, 'error': err,
    };

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('status shows honest line, call button and updates states',
      (tester) async {
    final svc = FakeAlertService(details: [
      detail([row('Alex', 'push', 'queued')]),
      detail([row('Alex', 'push', 'sent')]),
      detail([row('Alex', 'push', 'acknowledged')]),
    ]);
    final dialer = FakeDialer();
    await tester.pumpWidget(host(AlertStatusScreen(
      alertId: 'a1', kind: AlertKind.sos, service: svc, dialer: dialer,
      pollInterval: const Duration(seconds: 1),
    )));
    await tester.pump();
    expect(find.text(kFamilyNotifiedLine), findsOneWidget);
    expect(find.text('Call emergency services'), findsOneWidget);
    expect(find.text('Notification: Waiting to send'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Notification: Sent (not confirmed)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Notification: Seen and acknowledged'), findsOneWidget);
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    await tester.tap(find.text('Call emergency services'));
    expect(dialer.dials, 1);
    // settled: no more polling
    final calls = svc.detailCalls;
    await tester.pump(const Duration(seconds: 10));
    expect(svc.detailCalls, calls);
  });

  testWidgets('failures are shown plainly with reason; call hidden when unavailable',
      (tester) async {
    final svc = FakeAlertService(details: [
      detail([row('Bo', 'push', 'failed', err: 'provider_error')]),
    ]);
    await tester.pumpWidget(host(AlertStatusScreen(
        alertId: 'a1', service: svc, dialer: FakeDialer(ok: false))));
    await tester.pump();
    expect(find.text('Notification: Failed'), findsOneWidget);
    expect(find.text('The delivery service had a problem.'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsWidgets);
    expect(find.text('Call emergency services'), findsNothing);
    expect(find.textContaining('call your local emergency number'), findsOneWidget);
  });

  testWidgets('offline load shows error and Retry recovers', (tester) async {
    final svc = FakeAlertService(
        details: [detail([row('Alex', 'ws', 'delivered')])], failDetail: true);
    await tester.pumpWidget(host(AlertStatusScreen(
        alertId: 'a1', service: svc, dialer: FakeDialer(),
        pollInterval: const Duration(seconds: 100))));
    await tester.pump();
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.text(kFamilyNotifiedLine), findsOneWidget);
    svc.failDetail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Live in app: Delivered to app'), findsOneWidget);
  });

  testWidgets('revoke link asks first then calls service', (tester) async {
    final svc = FakeAlertService(details: [
      AlertDetail.fromJson(<String, dynamic>{
        'id': 'a1', 'type': 'sos', 'status': 'active', 'user_id': 'me',
        'deliveries': [
          {'contact_id': 'c', 'recipient': 'Mum', 'channel': 'sms', 'state': 'sent'},
        ],
      }),
    ]);
    await tester.pumpWidget(host(AlertStatusScreen(
        alertId: 'a1', service: svc, dialer: FakeDialer())));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Turn off location link'), 200);
    await tester.tap(find.text('Turn off location link'));
    await tester.pumpAndSettle();
    expect(svc.revokes, 0);
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(svc.revokes, 1);
    expect(find.text('Location link turned off.'), findsOneWidget);
  });

  testWidgets('received screen acknowledges and is repeatable-safe',
      (tester) async {
    final svc = FakeAlertService();
    final a = AlertSummary.fromJson(<String, dynamic>{
      'id': 'a1', 'type': 'sos', 'status': 'active', 'user_id': 'u',
      'sender_name': 'Sam', 'created_at': DateTime.now().toIso8601String(),
    });
    await tester.pumpWidget(host(AlertReceivedScreen(
        alert: a, service: svc, dialer: FakeDialer(ok: false))));
    expect(find.text('Sam sent an SOS'), findsOneWidget);
    expect(find.textContaining('does not contact emergency services'), findsOneWidget);
    await tester.tap(find.text('Acknowledge'));
    await tester.pump();
    await tester.pump();
    expect(svc.acks, 1);
    expect(find.byKey(const ValueKey('ack-confirmation')), findsOneWidget);
    expect(find.text('Acknowledge'), findsNothing);
  });

  testWidgets('ack failure shows message and allows retry', (tester) async {
    final svc = FakeAlertService(failAck: true);
    final a = AlertSummary.fromJson(<String, dynamic>{
      'id': 'a1', 'type': 'help', 'status': 'active', 'user_id': 'u',
      'sender_name': 'Sam', 'created_at': DateTime.now().toIso8601String(),
    });
    await tester.pumpWidget(host(AlertReceivedScreen(
        alert: a, service: svc, dialer: FakeDialer(ok: false))));
    await tester.tap(find.text('Acknowledge'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('server had a problem'), findsOneWidget);
    expect(find.text('Acknowledge'), findsOneWidget);
  });

  AlertPage page(List<String> ids, {String? next}) => AlertPage.fromJson({
        'alerts': [
          for (final id in ids)
            {'id': id, 'type': 'sos', 'status': 'active', 'user_id': 'u2',
             'sender_name': 'Sam', 'created_at': DateTime.now().toIso8601String()},
        ],
        'next_before': next ?? '',
      });

  testWidgets('history: empty, error+retry, list and load more', (tester) async {
    final empty = FakeAlertService(pages: [page([])]);
    await tester.pumpWidget(host(AlertsHistoryScreen(service: empty, selfUserId: 'me')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No alerts yet'), findsOneWidget);

    final bad = FakeAlertService(pages: [page(['a'], next: 'a'), page(['b'])], failList: true);
    await tester.pumpWidget(host(AlertsHistoryScreen(key: const ValueKey('bad'), service: bad, selfUserId: 'me')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach'), findsOneWidget);
    bad.failList = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget);
    await tester.tap(find.text('Load older alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsNWidgets(2));
    expect(bad.befores.last, 'a');
    expect(find.text('Load older alerts'), findsNothing);
  });

  testWidgets('history tile for someone else opens the recipient screen',
      (tester) async {
    final svc = FakeAlertService(pages: [page(['a'])]);
    await tester.pumpWidget(host(AlertsHistoryScreen(service: svc, selfUserId: 'me')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sam'));
    await tester.pumpAndSettle();
    expect(find.text('Acknowledge'), findsOneWidget);
  });

  test('formatAlertTime', () {
    final now = DateTime(2026, 10, 25, 12, 0);
    expect(formatAlertTime(DateTime(2026, 10, 25, 11, 59, 40), now: now), 'just now');
    expect(formatAlertTime(DateTime(2026, 10, 25, 11, 30), now: now), '30 min ago');
    expect(formatAlertTime(DateTime(2026, 10, 25, 8, 5), now: now), 'today 08:05');
  });

  test('AlertEvents routes frames', () async {
    final alerts = <Map<String, dynamic>>[];
    final sub = AlertEvents.alerts.listen(alerts.add);
    AlertEvents.handleFrame({'type': 'alert', 'alert_id': 'x'});
    AlertEvents.handleFrame({'type': 'alert'});
    await Future<void>.delayed(Duration.zero);
    expect(alerts, hasLength(1));
    await sub.cancel();
  });
}
