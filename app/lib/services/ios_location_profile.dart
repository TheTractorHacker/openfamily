/// iOS side of the adaptive cadence: maps a [CadenceProfile] to what the
/// native plugin applies to its `CLLocationManager`, and decides what to do
/// with coarse fixes while the cheap "still" request is active.
///
/// Pure Dart (no plugin calls, no clock), so every decision is unit-tested.
/// The native plugin only translates these values (see
/// `app/packages/background_locator_2/ios/Classes/BackgroundLocatorPlugin.m`)
/// and arms the wake-up region. Rationale and the manual test plan:
/// docs/developers/ios-location.md.
library;

import 'package:background_locator_2/settings/ios_settings.dart';
import 'package:background_locator_2/settings/locator_settings.dart';

import 'tracking_cadence.dart';

/// Tunables of the iOS mapping.
class IosLocationConfig {
  const IosLocationConfig({
    this.sosDistanceFilterM = 0,
    this.boostDistanceFilterM = 5,
    this.drivingDistanceFilterM = 10,
    this.walkingDistanceFilterM = 15,
    this.slowDistanceFilterM = 25,
    this.lowBatteryDistanceFilterM = 25,
    this.stillDistanceFilterM = 200,
    this.stillRegionRadiusM = 150,
    this.coarseAccuracyM = 100,
  });

  /// SOS: every fix, best accuracy.
  final double sosDistanceFilterM;

  /// Someone is watching live: near-every fix, but no jitter while parked.
  final double boostDistanceFilterM;

  /// Driving: at 1 Hz and >= 3 m/s a 10 m filter drops nothing while moving
  /// and silences the receiver at red lights.
  final double drivingDistanceFilterM;
  final double walkingDistanceFilterM;

  /// "Stationary" tier (no movement evidence yet, not idle for long enough):
  /// the slow request, also used for registration and every native wake-up.
  final double slowDistanceFilterM;

  /// Walking / driving below the low-battery threshold.
  final double lowBatteryDistanceFilterM;

  /// Idle tier ("still"): 3 km accuracy (cell only, no GPS) with this filter,
  /// plus an exit region of [stillRegionRadiusM] around the last good fix.
  final double stillDistanceFilterM;

  /// Apple: radii "between 1 and 400 meters work better"; 150 m keeps a
  /// departure from home noticeable within a short walk.
  final double stillRegionRadiusM;

  /// Fixes with a horizontal accuracy worse than this (or unknown) are cell
  /// fixes; they are not reported while the still request is active.
  final double coarseAccuracyM;
}

/// The request for [profile] on iOS. iOS has no interval: the cadence comes
/// from the distance filter and the accuracy (which decides whether the GPS
/// receiver is used at all).
IOSLocationRequest iosRequestFor(
  CadenceProfile profile, {
  IosLocationConfig config = const IosLocationConfig(),
}) {
  switch (profile.tier) {
    case CadenceTier.sos:
      return IOSLocationRequest(
        accuracy: IOSAccuracy.best,
        distanceFilterM: config.sosDistanceFilterM,
        activityType: IOSActivityType.otherNavigation,
      );
    case CadenceTier.boosted:
      return IOSLocationRequest(
        accuracy: IOSAccuracy.best,
        distanceFilterM: config.boostDistanceFilterM,
        activityType: IOSActivityType.otherNavigation,
      );
    case CadenceTier.driving:
      if (profile.lowBatteryBackoff) {
        return IOSLocationRequest(
          accuracy: IOSAccuracy.nearestTenMeters,
          distanceFilterM: config.lowBatteryDistanceFilterM,
          activityType: IOSActivityType.automotiveNavigation,
        );
      }
      return IOSLocationRequest(
        accuracy: IOSAccuracy.best,
        distanceFilterM: config.drivingDistanceFilterM,
        activityType: IOSActivityType.automotiveNavigation,
      );
    case CadenceTier.walking:
      return IOSLocationRequest(
        accuracy: IOSAccuracy.nearestTenMeters,
        distanceFilterM: profile.lowBatteryBackoff
            ? config.lowBatteryDistanceFilterM
            : config.walkingDistanceFilterM,
        activityType: IOSActivityType.fitness,
      );
    case CadenceTier.stationary:
      return iosSlowRequest(config: config);
    case CadenceTier.idle:
      return IOSLocationRequest(
        accuracy: IOSAccuracy.threeKilometers,
        distanceFilterM: config.stillDistanceFilterM,
        activityType: IOSActivityType.other,
        stillRegionRadiusM: config.stillRegionRadiusM,
      );
  }
}

/// The slow request: registration, relaunch and every native wake-up use it,
/// so it must equal [iosRequestFor] of the stationary tier.
IOSLocationRequest iosSlowRequest({
  IosLocationConfig config = const IosLocationConfig(),
}) =>
    IOSLocationRequest(
      accuracy: IOSAccuracy.nearestTenMeters,
      distanceFilterM: config.slowDistanceFilterM,
      activityType: IOSActivityType.other,
    );

/// The registration settings matching [iosSlowRequest] (the registration call
/// only knows the older accuracy scale: BALANCED = nearest ten meters).
IOSSettings iosRegistrationSettings({
  IosLocationConfig config = const IosLocationConfig(),
}) =>
    IOSSettings(
      accuracy: LocationAccuracy.BALANCED,
      distanceFilter: config.slowDistanceFilterM,
      showsBackgroundLocationIndicator: true,
      stopWithTerminate: false,
    );

/// What to do with one incoming fix on iOS before the cadence sees it.
enum IosFixDecision {
  /// Normal path (quality filter, cadence, post).
  accept,

  /// Coarse cell fix while still: not reported, nothing changes.
  drop,

  /// Not reported, but it proves the phone left the still spot (or the
  /// native side woke up): leave the still request now.
  dropAndWake,
}

/// Decides about a fix while the still request may be active.
///
/// * A good fix always goes through: the cadence itself leaves the idle tier
///   when it lies beyond the idle radius.
/// * A coarse fix (3 km accuracy mode, significant-change fix) is never
///   reported while still or right after a native wake-up: a cell fix can be
///   kilometers off and would make the person jump on the family map.
/// * A coarse fix still wakes the phone when even its error circle lies
///   outside the wake region (backup for a region exit that never fires).
IosFixDecision iosFixDecision({
  required bool stillRequestActive,
  required bool nativeReset,
  required double accuracyM,
  double? distanceFromAnchorM,
  IosLocationConfig config = const IosLocationConfig(),
}) {
  final bool coarse =
      accuracyM.isNaN || accuracyM < 0 || accuracyM > config.coarseAccuracyM;
  if (!coarse) return IosFixDecision.accept;
  if (nativeReset) return IosFixDecision.dropAndWake;
  if (!stillRequestActive) return IosFixDecision.accept;
  final double? d = distanceFromAnchorM;
  if (d != null &&
      accuracyM >= 0 &&
      d - accuracyM > config.stillRegionRadiusM) {
    return IosFixDecision.dropAndWake;
  }
  return IosFixDecision.drop;
}
