import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/speed_units.dart';

/// Minimum place radius (250 feet) in meters.
const double kMinPlaceRadiusMeters = 76.2;

/// Maximum place radius (2 miles) in meters.
const double kMaxPlaceRadiusMeters = 3218.69;

/// A saved Place (geofence): a named location with a map position, an address
/// label, and an arrive/leave radius. Shared with all family members.
///
/// This is the real data model produced by the onboarding "Add locations" step
/// (via [PlacePickerScreen]) — a lat/lon + radius, not a decorative toggle.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.icon,
    required this.address,
    required this.position,
    required this.radiusMeters,
    this.type = 'custom',
    this.alertsOn = false,
    this.geofenceId,
    this.circleId,
    this.circleName,
  });

  final String id;
  final String name;
  final IconData icon;
  final String address;
  final LatLng position;
  final double radiusMeters;

  /// Backend place type: "home", "work", "school", "gym", or "custom".
  final String type;
  final bool alertsOn;

  /// The id of the geofence backing [alertsOn], when one exists. Client-side
  /// only — never serialized to the backend.
  final String? geofenceId;

  /// The circle this place is shared with, or null for the whole family.
  final String? circleId;

  /// Display name of [circleId] (server-provided; may lag a rename).
  final String? circleName;

  /// Sentinel passed to [copyWith] to explicitly clear [geofenceId].
  static const Object clearGeofence = Object();

  /// Sentinel passed to [copyWith] as `circleId` to make the place family-wide.
  static const Object clearCircle = Object();

  /// Maps a backend place [type] to its Material icon.
  static IconData iconForType(String type) {
    switch (type) {
      case 'home':
        return Icons.home;
      case 'work':
        return Icons.business_center;
      case 'school':
        return Icons.school;
      case 'gym':
        return Icons.fitness_center;
      case 'custom':
      default:
        return Icons.place_outlined;
    }
  }

  /// Human-readable radius in the chosen unit system, e.g. "500 ft" / "150 m".
  String radiusLabelIn(UnitSystem u) => u.formatRadius(radiusMeters);

  /// [radiusLabelIn] for the current unit setting.
  String get radiusLabel => radiusLabelIn(UnitPreferenceService.units.value);

  Place copyWith({
    String? name,
    IconData? icon,
    String? address,
    LatLng? position,
    double? radiusMeters,
    String? type,
    bool? alertsOn,
    Object? geofenceId,
    Object? circleId,
    String? circleName,
  }) {
    return Place(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      address: address ?? this.address,
      position: position ?? this.position,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      type: type ?? this.type,
      alertsOn: alertsOn ?? this.alertsOn,
      geofenceId: identical(geofenceId, clearGeofence)
          ? null
          : (geofenceId as String? ?? this.geofenceId),
      circleId: identical(circleId, clearCircle)
          ? null
          : (circleId as String? ?? this.circleId),
      circleName: identical(circleId, clearCircle)
          ? null
          : (circleName ?? this.circleName),
    );
  }
}

/// The places that may label a member of the viewed circle: whole-family
/// places plus the places of THAT circle. Before, every place this phone knew
/// (other circles' places, Private circles' sealed places) could name where a
/// member is, so the owner saw "At <place>" labels the rest of the circle
/// never saw. [scope] null or 'all' (no single circle) keeps them all.
List<Place> placesForScope(List<Place> places, String? scope) {
  if (scope == null || scope == 'all') return places;
  return <Place>[
    for (final Place p in places)
      if (p.circleId == null || p.circleId == scope) p,
  ];
}
