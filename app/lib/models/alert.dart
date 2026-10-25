/// Models and plain-language wording for the safety alerts API
/// (`/alerts`, `/alerts/{id}`, `/alerts/{id}/ack`). See docs/safety.md.

/// The sentence every sender-side status screen leads with. OpenFamily never
/// contacts emergency services.
const String kFamilyNotifiedLine =
    'Your family was notified. Emergency services were NOT contacted.';

enum AlertKind { checkIn, help, sos, unknown }

AlertKind alertKindFrom(Object? raw) {
  switch (raw) {
    case 'check_in':
      return AlertKind.checkIn;
    case 'help':
      return AlertKind.help;
    case 'sos':
      return AlertKind.sos;
  }
  return AlertKind.unknown;
}

String alertKindLabel(AlertKind k) {
  switch (k) {
    case AlertKind.checkIn:
      return 'Check-in';
    case AlertKind.help:
      return 'Help request';
    case AlertKind.sos:
      return 'SOS';
    case AlertKind.unknown:
      return 'Alert';
  }
}

enum DeliveryState { queued, sent, delivered, failed, acknowledged }

DeliveryState deliveryStateFrom(Object? raw) {
  switch (raw) {
    case 'sent':
      return DeliveryState.sent;
    case 'delivered':
      return DeliveryState.delivered;
    case 'failed':
      return DeliveryState.failed;
    case 'acknowledged':
      return DeliveryState.acknowledged;
  }
  return DeliveryState.queued;
}

/// Short state label. "Sent" is deliberately not "Delivered": the provider
/// accepted the message, which is not proof the phone received it.
String deliveryStateLabel(DeliveryState s) {
  switch (s) {
    case DeliveryState.queued:
      return 'Waiting to send';
    case DeliveryState.sent:
      return 'Sent (not confirmed)';
    case DeliveryState.delivered:
      return 'Delivered to app';
    case DeliveryState.failed:
      return 'Failed';
    case DeliveryState.acknowledged:
      return 'Seen and acknowledged';
  }
}

String deliveryChannelLabel(String channel) {
  switch (channel) {
    case 'push':
      return 'Notification';
    case 'ws':
      return 'Live in app';
    case 'sms':
      return 'Text message';
  }
  return channel;
}

/// Plain wording for the stable server error codes.
String deliveryErrorLabel(String code) {
  switch (code) {
    case 'invalid_phone':
      return 'The phone number is not valid.';
    case 'provider_error':
      return 'The delivery service had a problem.';
    case 'rejected_by_provider':
      return 'The delivery service refused the message.';
    case 'sms_not_configured':
      return 'This server cannot send text messages.';
    case 'limit_recipients_per_alert':
      return 'Skipped: too many contacts for one alert.';
    case 'limit_sender_sms_per_day':
      return 'Skipped: daily text message limit reached.';
    case 'limit_family_sms_per_hour':
      return 'Skipped: hourly text message limit reached.';
  }
  return code.isEmpty ? 'Unknown problem.' : 'Problem: $code';
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class AlertDelivery {
  const AlertDelivery({
    required this.recipient,
    required this.channel,
    required this.state,
    this.recipientUserId = '',
    this.contactId = '',
    this.error = '',
    this.acknowledgedAt,
  });

  factory AlertDelivery.fromJson(Map<String, dynamic> j) => AlertDelivery(
        recipient: (j['recipient'] as String?)?.trim().isNotEmpty == true
            ? (j['recipient'] as String).trim()
            : 'Family member',
        channel: j['channel'] as String? ?? '',
        state: deliveryStateFrom(j['state']),
        recipientUserId: j['recipient_user_id'] as String? ?? '',
        contactId: j['contact_id'] as String? ?? '',
        error: j['error'] as String? ?? '',
        acknowledgedAt: _time(j['acknowledged_at']),
      );

  final String recipient;
  final String channel;
  final DeliveryState state;
  final String recipientUserId;
  final String contactId;
  final String error;
  final DateTime? acknowledgedAt;

  bool get isSettled =>
      state == DeliveryState.delivered ||
      state == DeliveryState.failed ||
      state == DeliveryState.acknowledged ||
      // SMS never moves past `sent` (no provider callbacks).
      (state == DeliveryState.sent && channel == 'sms');

  String get recipientKey =>
      recipientUserId.isNotEmpty ? 'u:$recipientUserId' : 'c:$contactId:$recipient';
}

/// One person (or emergency contact) with every channel row for them.
class RecipientDeliveries {
  const RecipientDeliveries(this.name, this.rows, {required this.isContact});
  final String name;
  final List<AlertDelivery> rows;
  final bool isContact;

  bool get acknowledged =>
      rows.any((AlertDelivery d) => d.state == DeliveryState.acknowledged);
  bool get anyFailed =>
      rows.any((AlertDelivery d) => d.state == DeliveryState.failed);
}

class AlertSummary {
  const AlertSummary({
    required this.id,
    required this.kind,
    required this.status,
    required this.userId,
    required this.senderName,
    required this.createdAt,
    this.note = '',
    this.resolvedAt,
  });

  factory AlertSummary.fromJson(Map<String, dynamic> j) => AlertSummary(
        id: j['id'] as String? ?? '',
        kind: alertKindFrom(j['type']),
        status: j['status'] as String? ?? '',
        userId: j['user_id'] as String? ?? '',
        senderName: (j['sender_name'] as String?)?.trim().isNotEmpty == true
            ? (j['sender_name'] as String).trim()
            : 'A family member',
        note: j['note'] as String? ?? '',
        createdAt: _time(j['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        resolvedAt: _time(j['resolved_at']),
      );

  final String id;
  final AlertKind kind;
  final String status;
  final String userId;
  final String senderName;
  final String note;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  bool get isActive => status == 'active';
}

class AlertPage {
  const AlertPage(this.alerts, this.nextBefore);

  factory AlertPage.fromJson(Map<String, dynamic> j) {
    final List<dynamic> raw = (j['alerts'] as List<dynamic>?) ?? const [];
    final String next = j['next_before'] as String? ?? '';
    return AlertPage(
      raw
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> m) =>
              AlertSummary.fromJson(Map<String, dynamic>.from(m)))
          .where((AlertSummary a) => a.id.isNotEmpty)
          .toList(),
      next.isEmpty ? null : next,
    );
  }

  final List<AlertSummary> alerts;

  /// Pass as `before` to fetch the next page; null on the last page.
  final String? nextBefore;
}

class AlertDetail {
  const AlertDetail({required this.summary, required this.deliveries});

  factory AlertDetail.fromJson(Map<String, dynamic> j) {
    final List<dynamic> raw = (j['deliveries'] as List<dynamic>?) ?? const [];
    return AlertDetail(
      summary: AlertSummary.fromJson(j),
      deliveries: raw
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> m) =>
              AlertDelivery.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }

  final AlertSummary summary;
  final List<AlertDelivery> deliveries;

  /// Groups channel rows per recipient, keeping server order.
  List<RecipientDeliveries> get recipients {
    final Map<String, List<AlertDelivery>> byKey =
        <String, List<AlertDelivery>>{};
    for (final AlertDelivery d in deliveries) {
      byKey.putIfAbsent(d.recipientKey, () => <AlertDelivery>[]).add(d);
    }
    return byKey.values
        .map((List<AlertDelivery> rows) => RecipientDeliveries(
              rows.first.recipient,
              rows,
              isContact: rows.first.recipientUserId.isEmpty,
            ))
        .toList();
  }

  bool get hasSms =>
      deliveries.any((AlertDelivery d) => d.channel == 'sms');

  /// True once nothing is still expected to change.
  bool get isSettled =>
      deliveries.isNotEmpty &&
      deliveries.every((AlertDelivery d) => d.isSettled);

  /// e.g. "2 of 3 people reached, 1 failed". Counts people, not channel rows.
  String get summaryLine => deliverySummary(recipients);
}

/// A person counts as reached if any channel was sent/delivered/acknowledged.
String deliverySummary(List<RecipientDeliveries> people) {
  if (people.isEmpty) return 'No one to notify yet';
  int reached = 0, failed = 0, acked = 0, waiting = 0;
  for (final RecipientDeliveries p in people) {
    final bool ok = p.rows.any((AlertDelivery d) =>
        d.state == DeliveryState.sent ||
        d.state == DeliveryState.delivered ||
        d.state == DeliveryState.acknowledged);
    if (p.acknowledged) acked++;
    if (ok) {
      reached++;
    } else if (p.anyFailed) {
      failed++;
    } else {
      waiting++;
    }
  }
  final List<String> parts = <String>[
    '$reached of ${people.length} sent',
    if (acked > 0) '$acked acknowledged',
    if (failed > 0) '$failed failed',
    if (waiting > 0) '$waiting waiting',
  ];
  return parts.join(', ');
}
