import '../models/member.dart';
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
}) {
  if (sharingPaused) return 'Location sharing paused';
  if (m.position == null) return 'No location yet';
  if (m.status == MemberStatus.stopped) {
    final DateTime? seen = m.lastSeen;
    return seen == null
        ? 'Updates stopped'
        : 'Updates stopped, last seen ${formatClock(seen.toLocal())}';
  }
  switch (m.movement) {
    case MovementType.car:
      final double? v = speedMps ?? m.speedMps;
      return v == null ? 'Driving' : 'Driving ${units.formatSpeed(v)}';
    case MovementType.bike:
    case MovementType.boat:
    case MovementType.plane:
    case MovementType.home:
    case MovementType.work:
    case MovementType.gym:
    case MovementType.star:
      return m.movement.label;
    case MovementType.none:
      final PlacePresence? presence = m.placePresence;
      if (presence != null) return placePresenceLabel(presence);
      return m.address.isEmpty ? 'Location shared' : m.address;
  }
}

/// "Updated 3:10 pm" for the row's trailing caption, or null when unknown.
String? memberUpdatedLabel(Member m) {
  final DateTime? seen = m.lastSeen;
  if (seen == null) return null;
  return 'Updated ${formatClock(seen.toLocal())}';
}

/// "Battery 18%" when known and low, otherwise null (only low battery
/// deserves attention in the list).
String? memberBatteryAlert(Member m) {
  if (m.batteryPercent > 0 && m.batteryPercent <= 20) {
    return 'Battery ${m.batteryPercent}%';
  }
  return null;
}
