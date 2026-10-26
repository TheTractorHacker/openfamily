import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/speed_units.dart' show kMpsToMph;
import '../theme/app_theme.dart';

/// Speed (mph) at or above which a driving member is shown as a
/// "race car with flames".
const int kSpeedingMph = 70;

/// Health/accuracy state of a member's location, mapped to the colored
/// status circle shown on their avatar bubble and list row.
enum MemberStatus {
/// Green — live, real-time, accurate location.
  normal,

  /// Orange — low battery or location-accuracy issue (warning).
  warning,

  /// Purple — GPS accuracy issue; app can't lock an exact spot.
  gpsIssue,

  /// Grey — location updates stopped (phone off / no signal).
  stopped,

  /// Red — location error (slow internet / settings).
  error,
}

/// What a member is currently doing / where they are, shown as a small
/// movement icon badge next to their avatar.
enum MovementType {
  /// Driving — car icon, speed shown in mph (race car + flames if speeding).
  car,

  /// Cycling.
  bike,

  /// On a boat.
  boat,

  /// On a plane — no speed shown.
  plane,

  /// Arrived at saved "Home".
  home,

  /// At "Work".
  work,

  /// At the "Gym".
  gym,

  /// Most-visited place (yellow star).
  star,

  /// No movement context.
  none,
}

/// Whether [mps] reads as speeding, using the displayed (rounded) mph so the
/// flag and the number on screen can never disagree.
bool isSpeedingMps(double? mps) =>
    mps != null && (mps * kMpsToMph).round() >= kSpeedingMph;

/// A single past location in a member's day, shown on the Day Detail
/// location-history timeline.
class LocationHistoryEntry {
  const LocationHistoryEntry({
    required this.time,
    required this.address,
    this.movement = MovementType.none,
    this.position,
  });

  /// When the member was at this location.
  final DateTime time;

  /// Human-readable place / address label.
  final String address;

  /// What the member was doing (driving, at home, at work, etc.).
  final MovementType movement;

  /// Optional geographic position for a map trail.
  final LatLng? position;
}

/// A single family member rendered on the map and in the bottom sheet.
class Member {
  const Member({
    required this.id,
    required this.name,
    required this.position,
    required this.status,
    required this.batteryPercent,
    required this.address,
    this.hasAvatar = false,
    this.avatarUpdatedAt,
    this.avatarVersion = 0,
    this.avatarColor = AppColors.purple,
    this.movement = MovementType.none,
    int? speedMph,
    double? speedMps,
    this.headingDeg,
    this.fixTime,
    this.eta,
    this.waypoints,
    this.history = const [],
    this.lastSeen,
    this.accuracyMeters,
  }) : speedMps = speedMps ?? (speedMph == null ? null : speedMph / kMpsToMph);

  final String id;
  final String name;

  /// Geographic position pinned on the map (the "home" / base position).
  ///
  /// Nullable: a member who has never reported a location has no position yet
  /// and is rendered without a map bubble (see [MemberStatus.stopped]).
  final LatLng? position;

  final MemberStatus status;

  /// Battery percentage (0–100).
  final int batteryPercent;

  /// Human-readable current address / place label.
  final String address;

  /// Whether this member has uploaded a profile photo.
  ///
  /// Avatar bytes are always loaded through the authenticated family-avatar
  /// endpoint; the member payload deliberately never carries a public URL.
  final bool hasAvatar;

  /// Server timestamp for the current avatar. This is retained for display
  /// compatibility; [avatarVersion] is the durable cache and ordering value.
  final DateTime? avatarUpdatedAt;

  /// Monotonically increasing server-side revision for the member's avatar.
  ///
  /// Both uploads and removals increment this value. It is intentionally used
  /// instead of a timestamp to order WebSocket frames, so rapid changes cannot
  /// be mistaken for one another when timestamps have the same resolution.
  final int avatarVersion;

  /// Fill color for the initials fallback avatar.
  final Color avatarColor;

  final MovementType movement;

  /// GPS speed of the freshest fix in meters per second (0 is a real 0:
  /// stopped; null means the fix carried no speed). Only meaningful for
  /// display when [movement] is [MovementType.car].
  final double? speedMps;

  /// Speed in whole mph derived from [speedMps], kept for screens that only
  /// need an integer. Prefer [speedMps] and the user's unit setting.
  int? get speedMph =>
      speedMps == null ? null : (speedMps! * kMpsToMph).round();

  /// Direction of travel in degrees clockwise from north, when the backend
  /// supplied one (`heading_deg`).
  final double? headingDeg;

  /// GPS fix time (backend `ts`); [lastSeen] may be newer (heartbeats).
  final DateTime? fixTime;

  /// Estimated time of arrival, e.g. "12m" or "6:42 PM".
  final String? eta;

  /// Optional closed loop of waypoints used to simulate live movement.
  /// When present, the map animates the member along this path.
  final List<LatLng>? waypoints;

  /// The member's location history for the day (Day Detail timeline).
  /// Empty unless a caller has loaded it; Day Detail fetches from the API.
  final List<LocationHistoryEntry> history;

  /// When this member last reported a location (the backend `ts`), or null if
  /// they have never reported. Used to re-evaluate staleness on a timer so a
  /// member whose updates stop transitions to the grey "stopped" status.
  final DateTime? lastSeen;

  /// GPS accuracy in meters — the uncertainty radius of the reported fix.
  /// Null when the backend didn't provide an accuracy value. Used to draw the
  /// blue "range" circle around the member and to label their accuracy.
  final double? accuracyMeters;

  /// Whether this member is driving fast enough to show as "speeding".
  bool get isSpeeding =>
      movement == MovementType.car && isSpeedingMps(speedMps);

  /// Whether the map pin should render a numeric speed caption.
  bool get hasDrivingSpeed =>
      movement == MovementType.car && speedMps != null;

  /// Initials used while no avatar is available.
  String get initials {
    final List<String> parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  /// Returns a copy of this member with the given fields replaced. Used to
  /// apply live location updates without mutating the immutable member.
  ///
  /// Note: nullable fields ([position], [speedMph], [eta], [lastSeen]) cannot
  /// be cleared here — pass a value to change them, omit to keep the current
  /// one. Live updates always carry a fresh position, so clearing is never
  /// needed.
  Member copyWith({
    LatLng? position,
    MemberStatus? status,
    int? batteryPercent,
    String? address,
    String? name,
    MovementType? movement,
    double? speedMps,
    bool clearSpeed = false,
    double? headingDeg,
    DateTime? fixTime,
    String? eta,
    DateTime? lastSeen,
    double? accuracyMeters,
  }) {
    return Member(
      id: id,
      name: name ?? this.name,
      position: position ?? this.position,
      status: status ?? this.status,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      address: address ?? this.address,
      hasAvatar: hasAvatar,
      avatarUpdatedAt: avatarUpdatedAt,
      avatarVersion: avatarVersion,
      avatarColor: avatarColor,
      movement: movement ?? this.movement,
      speedMps: clearSpeed ? null : (speedMps ?? this.speedMps),
      headingDeg: headingDeg ?? this.headingDeg,
      fixTime: fixTime ?? this.fixTime,
      eta: eta ?? this.eta,
      waypoints: waypoints,
      history: history,
      lastSeen: lastSeen ?? this.lastSeen,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
    );
  }

  /// Returns a copy with only the family-avatar metadata changed.
  ///
  /// Unlike [copyWith], this method permits clearing [avatarUpdatedAt] when a
  /// member removes their photo.
  Member copyWithAvatar({
    required bool hasAvatar,
    required int avatarVersion,
    DateTime? avatarUpdatedAt,
  }) {
    return Member(
      id: id,
      name: name,
      position: position,
      status: status,
      batteryPercent: batteryPercent,
      address: address,
      hasAvatar: hasAvatar,
      avatarUpdatedAt: hasAvatar ? avatarUpdatedAt : null,
      avatarVersion: avatarVersion,
      avatarColor: avatarColor,
      movement: movement,
      speedMps: speedMps,
      headingDeg: headingDeg,
      fixTime: fixTime,
      eta: eta,
      waypoints: waypoints,
      history: history,
      lastSeen: lastSeen,
      accuracyMeters: accuracyMeters,
    );
  }
}

/// Maps a [MemberStatus] to its display color.
extension MemberStatusColor on MemberStatus {
  Color get color {
    switch (this) {
      case MemberStatus.normal:
        return AppColors.statusGreen;
      case MemberStatus.warning:
        return AppColors.statusOrange;
      case MemberStatus.gpsIssue:
        return AppColors.statusPurple;
      case MemberStatus.stopped:
        return AppColors.statusGrey;
      case MemberStatus.error:
        return AppColors.statusRed;
    }
  }

  /// Short human-readable label for the list row.
  String get label {
    switch (this) {
      case MemberStatus.normal:
        return 'Live';
      case MemberStatus.warning:
        return 'Low battery / accuracy';
      case MemberStatus.gpsIssue:
        return 'GPS issue';
      case MemberStatus.stopped:
        return 'Updates stopped';
      case MemberStatus.error:
        return 'Location error';
    }
  }

  /// Longer, colorblind-safe description used for tooltips / semantics.
  String get description {
    switch (this) {
      case MemberStatus.normal:
        return 'Live — real-time, accurate location';
      case MemberStatus.warning:
        return 'Low battery or location-accuracy issue';
      case MemberStatus.gpsIssue:
        return 'GPS accuracy issue — approximate location';
      case MemberStatus.stopped:
        return 'Location updates stopped';
      case MemberStatus.error:
        return 'Location error';
    }
  }
}

/// Maps a [MovementType] to its icon and display color.
extension MovementTypeIcon on MovementType {
  IconData get icon {
    switch (this) {
      case MovementType.car:
        return Icons.directions_car;
      case MovementType.bike:
        return Icons.directions_bike;
      case MovementType.boat:
        return Icons.directions_boat;
      case MovementType.plane:
        return Icons.flight;
      case MovementType.home:
        return Icons.home;
      case MovementType.work:
        return Icons.business_center;
      case MovementType.gym:
        return Icons.fitness_center;
      case MovementType.star:
        return Icons.star;
      case MovementType.none:
        // No movement icon is defined for "none"; MovementIcon renders
        // nothing for this state, so this fallback is never shown.
        return Icons.person_outline;
    }
  }

  /// Accent color for the movement icon; the "most-visited place" star is
  /// yellow, everything else uses the brand purple.
  Color get color {
    switch (this) {
      case MovementType.star:
        return AppColors.starYellow;
      default:
        return AppColors.purple;
    }
  }

  /// Short human-readable label used in tooltips / semantics.
  String get label {
    switch (this) {
      case MovementType.car:
        return 'Driving';
      case MovementType.bike:
        return 'Biking';
      case MovementType.boat:
        return 'On a boat';
      case MovementType.plane:
        return 'Flying';
      case MovementType.home:
        return 'At Home';
      case MovementType.work:
        return 'At Work';
      case MovementType.gym:
        return 'At Gym';
      case MovementType.star:
        return 'Most-visited place';
      case MovementType.none:
        return '';
    }
  }
}
