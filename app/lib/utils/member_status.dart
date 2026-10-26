import '../models/member.dart';
import '../services/speed_units.dart';

/// "3:10 pm" (12-hour, locale-neutral, no intl dependency).
String formatClock(DateTime t) {
  final int h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final String m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'am' : 'pm'}';
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
