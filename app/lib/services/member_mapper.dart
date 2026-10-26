import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../models/place.dart';

/// Maps backend member JSON (from `GET /family/members` and the `/ws/stream`
/// `members` frame) into a [Member].
///
/// The backend's location fields are all nullable: a member who has never
/// reported a location has null `lat`/`lon`/`ts`. `speed_mps` is meters/second
/// and is converted to mph for display. `motion_state` is a free string.
Member memberFromJson(Map<String, dynamic> json) {
  final num? lat = json['lat'] as num?;
  final num? lon = json['lon'] as num?;
  final dynamic ts = json['ts'];
  final num? batteryPct = json['battery_pct'] as num?;
  final num? speedMps = json['speed_mps'] as num?;
  final String? motion = json['motion_state'] as String?;
  final num? accuracy = json['accuracy_meters'] as num?;
  final bool hasAvatar = json['has_avatar'] == true;
  final DateTime? avatarUpdatedAt =
      hasAvatar ? _parseTs(json['avatar_updated_at']) : null;
  final int avatarVersion = _parseAvatarVersion(json['avatar_version']) ?? 0;

  final LatLng? position = (lat != null && lon != null)
      ? LatLng(lat.toDouble(), lon.toDouble())
      : null;
  final DateTime? timestamp = _parseTs(ts);
  // The backend also reports `last_seen_at` (the freshest device
  // heartbeat/ingest time across the member's devices), which can be newer
  // than `ts` when the member is stationary and only heartbeats arrive.
  // Liveness ("last seen") is derived from whichever is newer so a parked,
  // reporting phone does not flip to grey "stopped".
  final DateTime? lastSeenAt = _parseTs(json['last_seen_at']);
  final DateTime? effectiveLastSeen = _newer(timestamp, lastSeenAt);
  final MovementType movement = _movementFrom(motion) ??
      _movementFromSpeed(speedMps) ??
      MovementType.none;

  return Member(
    id: (json['id'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'Member',
    position: position,
    status: _statusFrom(
      position: position,
      lastSeen: effectiveLastSeen,
      batteryPct: batteryPct,
      accuracy: accuracy,
    ),
    batteryPercent: (batteryPct ?? 0).round(),
    address: _addressFrom(
      position: position,
      lastSeen: effectiveLastSeen,
      movement: movement,
    ),
    hasAvatar: hasAvatar,
    avatarUpdatedAt: avatarUpdatedAt,
    avatarVersion: avatarVersion,
    movement: movement,
    speedMps: speedMps?.toDouble(),
    headingDeg: _parseHeading(json['heading_deg']),
    fixTime: timestamp,
    lastSeen: effectiveLastSeen,
    accuracyMeters: accuracy?.toDouble(),
  );
}

/// Applies a WebSocket `avatar` frame to [existing].
///
/// Avatar frames carry metadata only — the actual bytes are fetched from the
/// authenticated member-avatar endpoint. Ignore malformed frames rather than
/// accidentally dropping a currently visible avatar.
Member memberFromAvatarUpdate(Member existing, Map<String, dynamic> json) {
  final dynamic rawHasAvatar = json['has_avatar'];
  final int? avatarVersion = _parseAvatarVersion(json['avatar_version']);
  if (rawHasAvatar is! bool ||
      avatarVersion == null ||
      avatarVersion <= existing.avatarVersion) {
    return existing;
  }

  return existing.copyWithAvatar(
    hasAvatar: rawHasAvatar,
    avatarUpdatedAt: rawHasAvatar ? _parseTs(json['avatar_updated_at']) : null,
    avatarVersion: avatarVersion,
  );
}

/// Applies a single `/ws/stream` `location` frame to [existing], returning a
/// new [Member] with the updated position/battery/speed/motion/status.
///
/// A `location` frame always carries a fresh `lat`/`lon`, so the position is
/// updated in place; the other fields fall back to the existing values when
/// the frame omits them.
Member memberFromLocationUpdate(Member existing, Map<String, dynamic> json) {
  final num? lat = json['lat'] as num?;
  final num? lon = json['lon'] as num?;
  final dynamic ts = json['ts'];
  final num? batteryPct = json['battery_pct'] as num?;
  final num? speedMps = json['speed_mps'] as num?;
  final String? motion = json['motion_state'] as String?;
  final num? accuracy = json['accuracy_meters'] as num?;

  final LatLng? position = (lat != null && lon != null)
      ? LatLng(lat.toDouble(), lon.toDouble())
      : existing.position;
  // Location time describes the fix; last_seen_at describes when the server
  // heard from the phone. Never let an older/delayed fix regress liveness that
  // a newer heartbeat already established.
  final DateTime? fixTimestamp = _parseTs(ts);
  final DateTime? timestamp = _newer(
    existing.lastSeen,
    _newer(fixTimestamp, _parseTs(json['last_seen_at'])),
  );
  // A `location` frame may carry no motion classification: the backend emits
  // null when `motion_state` is empty (every iOS device), and the frame itself
  // can omit the field. Prefer the authoritative Android motion state, then a
  // confident speed inference, then keep the existing badge rather than
  // dropping a driving member back to "none".
  final MovementType movement = _movementFrom(motion) ??
      _movementFromSpeed(speedMps) ??
      existing.movement;

  // For status derivation, fall back to the member's last-known battery when
  // the frame omits it, so a member at 10% does not flip to "normal" (the
  // default 100) on a frame that carries only a position. A member who has
  // never reported battery (0) stays null so _statusFrom defaults to 100.
  final num? effectiveBattery = batteryPct ??
      (existing.batteryPercent > 0 ? existing.batteryPercent : null);

  return existing.copyWith(
    position: position,
    status: _statusFrom(
      position: position,
      lastSeen: timestamp,
      batteryPct: effectiveBattery,
      accuracy: accuracy,
    ),
    batteryPercent:
        batteryPct != null ? batteryPct.round() : existing.batteryPercent,
    address: _addressFrom(
      position: position,
      lastSeen: timestamp,
      movement: movement,
    ),
    movement: movement,
    // The speed belongs to THIS fix: a frame without one clears the old value
    // rather than keeping a stale number on screen.
    speedMps: speedMps?.toDouble(),
    clearSpeed: speedMps == null,
    headingDeg: _parseHeading(json['heading_deg']),
    fixTime: fixTimestamp,
    lastSeen: timestamp,
    accuracyMeters: accuracy?.toDouble() ?? existing.accuracyMeters,
  );
}

/// Applies a `/ws/stream` `presence` frame to [existing].
///
/// Presence frames announce liveness without a position change (stationary
/// dedup or heartbeat): the member's "last seen" freshness advances but the
/// pin, speed, and movement stay untouched, and they come back from grey
/// "stopped" if a stale member starts reporting again. Malformed frames return
/// [existing] unchanged.
Member memberFromPresenceUpdate(Member existing, Map<String, dynamic> json) {
  if (json['user_id'] is! String) return existing;
  final DateTime? ts = _parseTs(json['ts']);
  if (ts == null) return existing;

  // Ignore an equal-or-older presence frame than what we already know: it
  // cannot make the member fresher.
  final DateTime? current = existing.lastSeen;
  if (current != null && !ts.isAfter(current)) return existing;

  final num? batteryPct = json['battery_pct'] as num?;
  return existing.copyWith(
    status: MemberStatus.normal,
    batteryPercent:
        batteryPct != null ? batteryPct.round() : existing.batteryPercent,
    address: _addressFrom(
      position: existing.position,
      lastSeen: ts,
      movement: existing.movement,
    ),
    lastSeen: ts,
  );
}

/// A member is "stale" when their last report is older than this.
const Duration kStaleAfter = Duration(minutes: 10);

/// Battery percentage at or below which a member is flagged as a warning.
const int kLowBatteryThreshold = 15;

/// Accuracy (meters) at or above which a member is flagged as a GPS issue.
const double kGpsIssueAccuracyMeters = 100.0;

/// Derives the [MemberStatus] from the raw backend fields. [lastSeen] is the
/// effective liveness time (location `ts` or device heartbeat, whichever is
/// newer).
MemberStatus _statusFrom({
  required LatLng? position,
  required DateTime? lastSeen,
  required num? batteryPct,
  required num? accuracy,
}) {
  if (position == null) return MemberStatus.stopped;
  if (lastSeen == null ||
      DateTime.now().toUtc().difference(lastSeen) > kStaleAfter) {
    return MemberStatus.stopped;
  }
  if ((batteryPct ?? 100) < kLowBatteryThreshold) return MemberStatus.warning;
  if ((accuracy ?? 0) > kGpsIssueAccuracyMeters) return MemberStatus.gpsIssue;
  return MemberStatus.normal;
}

/// Derives a human-readable label (reverse geocoding is deferred). [lastSeen]
/// is the effective liveness time (see [_statusFrom]).
///
/// Must stay in lockstep with web `addressFrom`: a fresh fix with no driving /
/// cycling context is "Stationary", not "Moving". Callers overlay a saved
/// place name (Home, Work, …) via [applyPlaceAddress] when the member is
/// inside a place radius.
///
/// When the member's reports are stale, the label deliberately describes the
/// PIN ("Position from 8h ago") rather than repeating the liveness "Last seen"
/// wording — the profile shows the address row and the list shows the same
/// string, so identical "Last seen" text would read as a duplicated field.
String _addressFrom({
  required LatLng? position,
  required DateTime? lastSeen,
  required MovementType movement,
}) {
  if (position == null) return 'No location yet';
  if (movement == MovementType.car) return 'Driving';
  if (movement == MovementType.bike) return 'Biking';
  if (lastSeen == null) return 'No location yet';
  final Duration age = DateTime.now().toUtc().difference(lastSeen);
  if (age > kStaleAfter) return 'Position from ${_formatAgo(age)} ago';
  return 'Stationary';
}

/// The saved place (if any) whose radius contains [position]. When several
/// overlap, the smallest radius wins — same rule as the backend history
/// matcher, so a "Home" pin inside a larger neighborhood place stays Home.
Place? placeContaining(LatLng? position, List<Place> places) {
  if (position == null || places.isEmpty) return null;
  const Distance dist = Distance();
  Place? best;
  double bestR = double.infinity;
  for (final Place place in places) {
    if (place.radiusMeters <= 0) continue;
    final double d = dist.as(LengthUnit.Meter, position, place.position);
    if (d <= place.radiusMeters && place.radiusMeters < bestR) {
      best = place;
      bestR = place.radiusMeters;
    }
  }
  return best;
}

/// Replaces a stationary/activity-free address with the saved place the
/// member is standing in (e.g. "Home"). Driving and cycling keep their
/// activity labels; stale "Position from …" pin-age labels are left alone.
Member applyPlaceAddress(Member member, List<Place> places) {
  if (places.isEmpty) return member;
  if (member.movement == MovementType.car ||
      member.movement == MovementType.bike) {
    return member;
  }
  if (isStaleAddress(member.address)) return member;
  final Place? place = placeContaining(member.position, places);
  if (place == null || member.address == place.name) return member;
  return member.copyWith(address: place.name);
}

/// Whether an address string is the stale-report fallback (the "Position from
/// 8h ago" pin-age label) rather than a real place or activity. Mirrors the
/// guard in [applyPlaceAddress] so callers can skip place overlays for stale
/// members without duplicating the prefix knowledge.
bool isStaleAddress(String address) => address.startsWith('Position from');

/// Returns the later of two timestamps, treating null as "unknown" (the other
/// value wins; both null → null).
DateTime? _newer(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}

/// Maps the backend's free-form `motion_state` string to a [MovementType].
///
/// Returns null when the frame carries no motion classification (null/empty or
/// the server omits the field) so callers can fall back to a weaker signal —
/// see [_movementFromSpeed]. Explicitly-quiet states ("still", "walking",
/// ...) map to [MovementType.none], matching the Android activity classes'
/// presentation (there is no walking badge in the UI).
MovementType? _movementFrom(String? motion) {
  if (motion == null || motion.isEmpty) return null;
  switch (motion) {
    case 'driving':
      return MovementType.car;
    case 'cycling':
      return MovementType.bike;
    default:
      return MovementType.none;
  }
}

/// Speed-based movement fallback for devices that report `speed_mps` but no
/// `motion_state` — currently every iOS device: the vendored
/// background_locator_2 fills `motion_state` only from Android's activity
/// recognition, so without this fallback iOS members would never show a
/// movement badge at all.
///
/// Only *confident upgrades* are inferred: ≥5 m/s (18 km/h) is unambiguously
/// vehicle speed. Lower speeds return null (keep the previous badge) — GPS
/// jitter around walking pace must not invent a moving badge, and a red-light
/// speed dip must not clear a mid-drive one. The badge clears for real when
/// [refreshStaleness] greys the member out after [kStaleAfter] without a
/// report (a parked iOS device stops emitting fixes entirely at its 50 m
/// distance filter).
MovementType? _movementFromSpeed(num? speedMps) {
  if (speedMps == null || speedMps < 5.0) return null;
  return MovementType.car;
}

/// Parses `heading_deg` (degrees clockwise from north); null when absent or
/// not a finite number. Normalised to [0, 360).
double? _parseHeading(dynamic v) {
  if (v is! num || !v.isFinite) return null;
  final double d = v.toDouble() % 360;
  return d < 0 ? d + 360 : d;
}

/// Parses the backend `ts` field, which may be an ISO-8601 string or a Unix
/// timestamp (seconds or milliseconds). Returns null when absent/unparseable.
DateTime? _parseTs(dynamic ts) {
  if (ts == null) return null;
  if (ts is num) {
    final double v = ts.toDouble();
    final double ms = v < 1e12 ? v * 1000 : v;
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }
  if (ts is String) {
    return DateTime.tryParse(ts)?.toUtc();
  }
  return null;
}

/// Parses the durable, monotonically increasing backend avatar revision.
///
/// Snapshot rows created before the migration may omit it, in which case their
/// caller uses revision zero. Live avatar frames must carry a valid revision
/// so an unorderable frame cannot replace newer metadata.
int? _parseAvatarVersion(dynamic value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is num && value.isFinite) {
    final int parsed = value.toInt();
    return value == parsed && parsed >= 0 ? parsed : null;
  }
  return null;
}

/// Compact "Xm ago" / "Xh ago" / "Xd ago" label for a stale location.
String _formatAgo(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Re-evaluates [member]'s staleness from [Member.lastSeen], returning a new
/// [Member] with the grey "stopped" status (and a "Position from Xm ago"
/// address) once their last report is older than [kStaleAfter]. Returns
/// [member] unchanged when they are still fresh or have never reported.
///
/// Called on a periodic timer so a member whose updates stop (phone off / no
/// signal) transitions to "stopped" even though no `location` frame arrives.
/// The address uses the pin-age wording (not the "Last seen" liveness label)
/// so it never reads as a duplicate of the last-seen field.
Member refreshStaleness(Member member) {
  final DateTime? lastSeen = member.lastSeen;
  if (member.position == null || lastSeen == null) return member;
  final Duration age = DateTime.now().toUtc().difference(lastSeen);
  if (age <= kStaleAfter) return member;
  final String label = 'Position from ${_formatAgo(age)} ago';
  // Already stopped with the current label and no movement badge — no change,
  // so the staleness timer does not fire a spurious `onMembersChanged`. The
  // label still advances ("10m" → "1h" → "1d") on later ticks because it is
  // recomputed each time.
  if (member.status == MemberStatus.stopped &&
      member.address == label &&
      member.movement == MovementType.none) {
    return member;
  }
  // Clear the movement badge along with the liveness: a stale "driving" badge
  // reads as still-on-the-road. Matters most on iOS, whose location stream
  // carries speed but no motion state — a parked device stops emitting fixes
  // at its distance filter, so only this transition retires the last badge.
  return member.copyWith(
    status: MemberStatus.stopped,
    address: label,
    movement: MovementType.none,
  );
}
