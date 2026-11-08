import 'package:background_locator_2/keys.dart';

import 'locator_settings.dart';

class IOSSettings extends LocatorSettings {
  /// [accuracy] The accuracy of location, Default is max accuracy NAVIGATION.
  ///
  /// [distanceFilter] distance in meter to trigger location update, Default is 0 meter.
  ///
  /// [showsBackgroundLocationIndicator] The background location usage indicator is a blue bar or a blue pill in the status bar on iOS. Default is false.
  ///
  /// [stopWithTerminate] stops the location usage when the app is on background

  final bool showsBackgroundLocationIndicator;
  final bool stopWithTerminate;
  
  const IOSSettings({
    LocationAccuracy accuracy = LocationAccuracy.NAVIGATION,
    double distanceFilter = 0,
    this.showsBackgroundLocationIndicator = false,
    this.stopWithTerminate = false,
  }) : super(accuracy: accuracy, distanceFilter: distanceFilter); //minutes

  Map<String, dynamic> toMap() {
    return {
      Keys.SETTINGS_ACCURACY: accuracy.value,
      Keys.SETTINGS_DISTANCE_FILTER: distanceFilter,
      Keys.SETTINGS_IOS_SHOWS_BACKGROUND_LOCATION_INDICATOR:
          showsBackgroundLocationIndicator,
      Keys.SETTINGS_IOS_STOP_WITH_TERMINATE: stopWithTerminate,
    };
  }
}

/// Core Location accuracy for [IOSLocationRequest]. [code] is the channel
/// contract with `+[Util requestAccuracy:]` in the iOS plugin: change both
/// together.
enum IOSAccuracy {
  threeKilometers(0),
  kilometer(1),
  hundredMeters(2),
  nearestTenMeters(3),
  best(4),
  bestForNavigation(5);

  const IOSAccuracy(this.code);
  final int code;
}

/// `CLActivityType` for [IOSLocationRequest]. [code] is the channel contract
/// with `+[Util activityType:]` in the iOS plugin.
enum IOSActivityType {
  other(0),
  automotiveNavigation(1),
  fitness(2),
  otherNavigation(3);

  const IOSActivityType(this.code);
  final int code;
}

/// The iOS half of `BackgroundLocator.updateLocationRequest`: exactly what the
/// native plugin applies to its `CLLocationManager`. The native side makes no
/// decisions of its own except one: when [stillRegionRadiusM] is positive it
/// arms an exit-only region of that radius around the last good fix and, on
/// exit, switches back to the registration request by itself (the app may be
/// suspended at that moment).
class IOSLocationRequest {
  const IOSLocationRequest({
    required this.accuracy,
    required this.distanceFilterM,
    required this.activityType,
    this.stillRegionRadiusM = 0,
  });

  final IOSAccuracy accuracy;

  /// Meters; 0 = `kCLDistanceFilterNone`.
  final double distanceFilterM;
  final IOSActivityType activityType;

  /// Radius of the wake-up region in still mode; 0 = not still (no region).
  final double stillRegionRadiusM;

  bool get isStill => stillRegionRadiusM > 0;

  Map<String, dynamic> toMap() => <String, dynamic>{
        Keys.ARG_REQUEST_IOS_ACCURACY: accuracy.code,
        Keys.ARG_REQUEST_IOS_DISTANCE_FILTER: distanceFilterM,
        Keys.ARG_REQUEST_IOS_ACTIVITY_TYPE: activityType.code,
        Keys.ARG_REQUEST_IOS_STILL_REGION_M: stillRegionRadiusM,
      };

  @override
  bool operator ==(Object other) =>
      other is IOSLocationRequest &&
      other.accuracy == accuracy &&
      other.distanceFilterM == distanceFilterM &&
      other.activityType == activityType &&
      other.stillRegionRadiusM == stillRegionRadiusM;

  @override
  int get hashCode =>
      Object.hash(accuracy, distanceFilterM, activityType, stillRegionRadiusM);

  @override
  String toString() => 'IOSLocationRequest(${accuracy.name}, '
      'df=${distanceFilterM}m, ${activityType.name}, '
      'still=${stillRegionRadiusM}m)';
}
