import 'package:flutter/foundation.dart';

import '../models/circle.dart';
import '../utils/member_status.dart' show formatClock;
import 'api_client.dart';

/// Why a member's updates are (not) arriving in a Private circle, from
/// `GET /circles/{id}/delivery`. The server answers from metadata it already
/// holds (key wraps, receipt times, app version, sharing switch). It never
/// sees or sends a position.
enum DeliveryReason { ok, sharingPaused, updateNeeded, noDevice, notApproved, noKeyWrap, neverSent, quiet, unknown }

DeliveryReason deliveryReasonFrom(String? code) {
  switch (code) {
    case 'ok':
      return DeliveryReason.ok;
    case 'sharing_paused':
      return DeliveryReason.sharingPaused;
    case 'update_needed':
      return DeliveryReason.updateNeeded;
    case 'no_device':
      return DeliveryReason.noDevice;
    case 'not_approved':
      return DeliveryReason.notApproved;
    case 'no_key_wrap':
      return DeliveryReason.noKeyWrap;
    case 'never_sent':
      return DeliveryReason.neverSent;
    case 'quiet':
      return DeliveryReason.quiet;
  }
  return DeliveryReason.unknown;
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

class MemberDelivery {
  const MemberDelivery({
    required this.userId,
    required this.name,
    required this.you,
    required this.reason,
    this.sharingEnabled = true,
    this.appVersion = '',
    this.appBucket = 'unknown',
    this.lastItemAt,
    this.lastContactAt,
    this.lane = 'phone',
  });

  factory MemberDelivery.fromJson(Map<String, dynamic> j) => MemberDelivery(
        userId: (j['user_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'Someone',
        you: j['you'] == true,
        reason: deliveryReasonFrom(j['reason'] as String?),
        sharingEnabled: j['sharing_enabled'] != false,
        appVersion: (j['app_version'] as String?) ?? '',
        appBucket: (j['app_bucket'] as String?) ?? 'unknown',
        lastItemAt: _time(j['last_item_at']),
        lastContactAt: _time(j['last_contact_at']),
        lane: (j['lane'] as String?) ?? 'phone',
      );

  final String userId;
  final String name;
  final bool you;
  final DeliveryReason reason;
  final bool sharingEnabled;
  final String appVersion;
  final String appBucket;

  /// When the server last received an encrypted update from this member (to the minute).
  final DateTime? lastItemAt;

  /// When the server last heard anything at all from this member's phone.
  final DateTime? lastContactAt;
  final String lane;
}

class CircleDelivery {
  const CircleDelivery({required this.circleId, required this.summary, required this.members, required this.at});

  factory CircleDelivery.fromJson(Map<String, dynamic> j, {DateTime? at}) => CircleDelivery(
        circleId: (j['circle_id'] as String?) ?? '',
        summary: (j['summary'] as String?) ?? '',
        members: ((j['members'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MemberDelivery.fromJson)
            .toList(),
        at: at ?? DateTime.now(),
      );

  final String circleId;

  /// ok | nobody_sending | some_not_sending | normal
  final String summary;
  final List<MemberDelivery> members;
  final DateTime at;

  bool get nobodySending => summary == 'nobody_sending';
}

/// "9:02 am" for today, "yesterday 9:02 am", or "Nov 5, 9:02 am".
String deliveryTimeLabel(DateTime utc, {DateTime? now}) {
  final DateTime t = utc.toLocal();
  final DateTime n = (now ?? DateTime.now()).toLocal();
  final int days = DateTime(n.year, n.month, n.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days <= 0) return formatClock(t);
  if (days == 1) return 'yesterday ${formatClock(t)}';
  const List<String> months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[t.month - 1]} ${t.day}, ${formatClock(t)}';
}

/// Plain words for one member, or null when nothing is wrong. [first] is the first name.
String? describeMemberDelivery(MemberDelivery m, {DateTime? now}) {
  final String n = m.name.trim().isEmpty ? 'This person' : m.name.trim().split(' ').first;
  switch (m.reason) {
    case DeliveryReason.ok:
    case DeliveryReason.unknown:
      return null;
    case DeliveryReason.sharingPaused:
      return 'Location sharing paused by $n';
    case DeliveryReason.updateNeeded:
      return '$n needs to update the app${m.appVersion.isEmpty ? '' : ' (v${m.appVersion} is too old)'}';
    case DeliveryReason.noDevice:
      return "$n hasn't set up encryption on a phone yet";
    case DeliveryReason.notApproved:
      return "$n's phone is waiting for an admin to approve it";
    case DeliveryReason.noKeyWrap:
      return "$n's phone has not received the circle key yet";
    case DeliveryReason.neverSent:
      return "$n hasn't sent an encrypted update yet (their phone may be off or the app closed)";
    case DeliveryReason.quiet:
      final DateTime? at = m.lastItemAt;
      return at == null
          ? "$n hasn't sent an encrypted update lately (their phone may be off or the app closed)"
          : "$n hasn't sent an encrypted update since ${deliveryTimeLabel(at, now: now)} (their phone may be off or the app closed)";
  }
}

/// What to do about it, in a sentence.
String? deliveryAdvice(MemberDelivery m) {
  switch (m.reason) {
    case DeliveryReason.updateNeeded:
      return 'Ask them to update Orbitly from the store.';
    case DeliveryReason.noKeyWrap:
    case DeliveryReason.notApproved:
      return 'An admin can fix this in Settings, Security, Encryption keys.';
    case DeliveryReason.neverSent:
    case DeliveryReason.quiet:
      return 'Ask them to open Orbitly once; it sends a fresh position straight away.';
    case DeliveryReason.sharingPaused:
      return 'They can turn sharing back on in the circle settings.';
    default:
      return null;
  }
}

/// The one-line banner for "everyone is silent".
const String kNobodySendingText = 'You are in private mode and nobody has sent an update.';

/// App-wide store of the latest delivery reports, so every place that would
/// say "No location yet" can say why instead.
class DeliveryHints {
  DeliveryHints._();

  static final ValueNotifier<Map<String, CircleDelivery>> reports = ValueNotifier<Map<String, CircleDelivery>>(<String, CircleDelivery>{});

  /// The circles the reports belong to (the banner opens the screen for one of them).
  static final Map<String, Circle> circleById = <String, Circle>{};

  static void put(CircleDelivery d) {
    reports.value = <String, CircleDelivery>{...reports.value, d.circleId: d};
  }

  static void clear() {
    circleById.clear();
    reports.value = <String, CircleDelivery>{};
  }

  /// The explanation for [userId] across the known Private circles, or null. If the member
  /// is fine in any circle there is no hint (their position may simply not have been decrypted yet).
  static String? hintFor(String userId, {DateTime? now}) {
    String? found;
    for (final CircleDelivery d in reports.value.values) {
      for (final MemberDelivery m in d.members) {
        if (m.userId != userId || m.you) continue;
        final String? t = describeMemberDelivery(m, now: now);
        if (t == null) return null;
        found ??= t;
      }
    }
    return found;
  }

  /// True when some Private circle reports that nobody is sending.
  static bool get nobodySending => reports.value.values.any((CircleDelivery d) => d.nobodySending);
}

/// Fetches the delivery report of every Private circle. Never throws (an older server has no such endpoint).
class DeliveryMonitor {
  DeliveryMonitor._();

  static Future<CircleDelivery?> fetch(String circleId) async {
    try {
      final dynamic r = await ApiClient.get('/circles/$circleId/delivery');
      if (r is! Map<String, dynamic>) return null;
      return CircleDelivery.fromJson(r);
    } catch (_) {
      return null;
    }
  }

  static Future<void> refresh(List<Circle> circles) async {
    final Iterable<Circle> priv = circles.where((Circle c) => c.isPrivate);
    if (priv.isEmpty) {
      DeliveryHints.clear();
      return;
    }
    for (final Circle c in priv) {
      final CircleDelivery? d = await fetch(c.id);
      if (d != null) {
        DeliveryHints.circleById[c.id] = c;
        DeliveryHints.put(d);
      }
    }
  }
}
