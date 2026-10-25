import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/alert.dart';
import 'package:openfamily/services/alert_service.dart';
import 'package:openfamily/services/api_client.dart';

Map<String, dynamic> detailJson() => <String, dynamic>{
      'id': 'a1',
      'type': 'sos',
      'status': 'active',
      'user_id': 'u1',
      'sender_name': 'Sam',
      'created_at': '2026-10-25T10:00:00Z',
      'deliveries': <Map<String, dynamic>>[
        {'recipient_user_id': 'u2', 'recipient': 'Alex', 'channel': 'push', 'state': 'sent'},
        {'recipient_user_id': 'u2', 'recipient': 'Alex', 'channel': 'ws', 'state': 'acknowledged',
         'acknowledged_at': '2026-10-25T10:01:00Z'},
        {'recipient_user_id': 'u3', 'recipient': 'Bo', 'channel': 'push', 'state': 'failed', 'error': 'provider_error'},
        {'contact_id': 'c1', 'recipient': 'Mum', 'channel': 'sms', 'state': 'queued'},
      ],
    };

void main() {
  test('parses detail and groups per recipient', () {
    final AlertDetail d = AlertDetail.fromJson(detailJson());
    expect(d.summary.kind, AlertKind.sos);
    expect(d.summary.isActive, isTrue);
    expect(d.deliveries, hasLength(4));
    final people = d.recipients;
    expect(people.map((p) => p.name), <String>['Alex', 'Bo', 'Mum']);
    expect(people[0].acknowledged, isTrue);
    expect(people[1].anyFailed, isTrue);
    expect(people[2].isContact, isTrue);
    expect(d.hasSms, isTrue);
    expect(d.isSettled, isFalse);
  });

  test('summary counts people, not channel rows', () {
    expect(AlertDetail.fromJson(detailJson()).summaryLine,
        '1 of 3 sent, 1 acknowledged, 1 failed, 1 waiting');
    expect(deliverySummary(const []), 'No one to notify yet');
  });

  test('sms stops at sent and counts as settled', () {
    final AlertDetail d = AlertDetail.fromJson(<String, dynamic>{
      'id': 'a', 'type': 'help', 'status': 'active', 'user_id': 'u',
      'deliveries': [
        {'contact_id': 'c', 'recipient': 'Mum', 'channel': 'sms', 'state': 'sent'},
        {'recipient_user_id': 'u2', 'recipient': 'Al', 'channel': 'ws', 'state': 'delivered'},
      ],
    });
    expect(d.isSettled, isTrue);
  });

  test('unknown values degrade safely', () {
    expect(alertKindFrom('weird'), AlertKind.unknown);
    expect(deliveryStateFrom(null), DeliveryState.queued);
    final AlertSummary s = AlertSummary.fromJson(<String, dynamic>{'id': 'x'});
    expect(s.senderName, 'A family member');
  });

  test('page parsing and cursor', () {
    final AlertPage p = AlertPage.fromJson(<String, dynamic>{
      'alerts': [
        {'id': 'a', 'type': 'check_in', 'status': 'resolved', 'user_id': 'u', 'sender_name': 'Sam', 'created_at': '2026-10-25T10:00:00Z'},
        {'type': 'help'},
      ],
      'next_before': '',
    });
    expect(p.alerts, hasLength(1));
    expect(p.nextBefore, isNull);
    expect(AlertPage.fromJson({'alerts': [], 'next_before': 'zz'}).nextBefore, 'zz');
  });

  test('wording is honest', () {
    expect(kFamilyNotifiedLine,
        'Your family was notified. Emergency services were NOT contacted.');
    expect(deliveryStateLabel(DeliveryState.sent), contains('not confirmed'));
    expect(deliveryErrorLabel('limit_sender_sms_per_day'), contains('daily'));
    expect(deliveryErrorLabel('invalid_phone'), contains('not valid'));
  });

  test('error messages are friendly', () {
    expect(alertErrorMessage(const ApiException(429, 'too many requests')),
        contains('wait a minute'));
    expect(
        alertErrorMessage(const ApiException(429,
            'your family was already notified of an SOS a moment ago; wait a couple of minutes before sending another')),
        startsWith('Your family was already notified'));
    expect(alertErrorMessage(const ApiException(503, 'x')), contains('server'));
    expect(alertErrorMessage(Exception('socket')), contains('Could not reach'));
    expect(isCooldownError(const ApiException(429, '')), isTrue);
  });
}
