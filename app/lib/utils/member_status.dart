import '../models/member.dart';
import '../services/delivery_status.dart' show DeliveryHints;
import '../services/driving_presence.dart';
import '../services/speed_units.dart';

/// "3:10 pm" (12-hour, locale-neutral, no intl dependency).
String formatClock(DateTime t) {
  final int h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final String m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'am' : 'pm'}';
}

/// "At Home since 3:42 PM" / "Left Work 25 min ago" for [p], relative to [now]
/// (defaults to the current time). Arrivals before today carry the day:
/// "At Home since yesterday 6:10 PM" / "since Oct 3".
String placePresenceLabel(PlacePresence p, {DateTime? now}) {
  final DateTime n = (now ?? DateTime.now()).toLocal();
  final DateTime t = p.since.toLocal();
  if (p.isAt) {
    final DateTime today = DateTime(n.year, n.month, n.day);
    final int days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
    final String clock = formatClock(t).toUpperCase();
    if (days <= 0) return 'At ${p.placeName} since $clock';
    if (days == 1) return 'At ${p.placeName} since yesterday $clock';
    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
    ];
    return 'At ${p.placeName} since ${months[t.month - 1]} ${t.day}';
  }
  final Duration age = n.difference(t);
  final String ago;
  if (age.inMinutes < 1) {
    ago = 'just now';
  } else if (age.inMinutes < 60) {
    ago = '${age.inMinutes} min ago';
  } else if (age.inHours < 24) {
    ago = '${age.inHours} hr ago';
  } else {
    ago = '${age.inDays} d ago';
  }
  return 'Left ${p.placeName} $ago';
}

/// One-line, human status for a person row, e.g. "Driving 42 mph",
/// "At Home", "Location sharing paused".
///
/// [sharingPaused] is only known for the signed-in user (their own sharing
/// switch); other members who stop reporting show "Updates stopped".
String memberStatusLine(
  Member m, {
  bool sharingPaused = false,
  double? speedMps,
  UnitSystem units = UnitSystem.imperial,
  DateTime? now,
}) {
  if (sharingPaused) return 'Location sharing paused';
  // A Private circle explains itself: the server knows why a member is silent (no key yet, old app, phone off).
  if (m.position == null) return DeliveryHints.hintFor(m.id) ?? 'No location yet';
  if (m.status == MemberStatus.stopped) {
    final String? why = DeliveryHints.hintFor(m.id);
    final DateTime? seen = m.lastSeen;
    // The reason and, whenever any position was ever received, how old it is (never a blank).
    if (why != null) return seen == null ? why : '$why · last seen ${lastSeenAgo(seen, DateTime.now())}';
    if (seen == null) return 'Updates stopped';
    // Older than a day a clock time alone is misleading ("3:12 pm" of which day?): say how long ago.
    return DateTime.now().difference(seen) >= const Duration(hours: 24)
        ? 'Updates stopped, last seen ${lastSeenAgo(seen, DateTime.now())}'
        : 'Updates stopped, last seen ${formatClock(seen.toLocal())}';
  }
  String untagged() {
    final PlacePresence? presence = m.placePresence;
    if (presence != null) return placePresenceLabel(presence);
    // A car tag the rule retired but the stored address still says "Driving".
    final String where =
        m.movement == MovementType.car && m.address == 'Driving' ? 'Stationary' : m.address;
    return where.isEmpty ? 'Location shared' : where;
  }

  switch (m.movement) {
    case MovementType.car:
      // The one driving rule: "Driving 42 mph", "Driving", "Stopped", or no
      // longer driving at all (stale car tag, parked).
      final DrivingView d = m.drivingView(liveSpeedMps: speedMps, now: now);
      return d.isDriving ? d.line(units) : untagged();
    case MovementType.bike:
    case MovementType.boat:
    case MovementType.plane:
    case MovementType.home:
    case MovementType.work:
    case MovementType.gym:
    case MovementType.star:
      return m.movement.label;
    case MovementType.none:
      return untagged();
  }
}

/// "Updated 3:10 pm" for the row's trailing caption, or null when unknown.
String? memberUpdatedLabel(Member m) {
  final DateTime? seen = m.lastSeen;
  if (seen == null) return null;
  return 'Updated ${formatClock(seen.toLocal())}';
}

/// "Battery 18%" when known and low, otherwise null (only low battery
/// deserves attention in the list). A charging phone is never flagged.
String? memberBatteryAlert(Member m) {
  if (m.charging) return null;
  if (m.batteryPercent > 0 && m.batteryPercent <= 20) {
    return 'Battery ${m.batteryPercent}%';
  }
  return null;
}

/// "2 min ago", "1 h ago", "3 d ago": how old the last known position of a silent member is.
String lastSeenAgo(DateTime seen, DateTime now) {
  final Duration d = now.difference(seen);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
