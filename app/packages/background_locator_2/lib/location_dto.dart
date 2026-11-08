import 'keys.dart';
// dart:io does not exist on the web (the app imports this file when built
// for the browser); use the web-compatible platform shim instead.
import 'utils/platform_is.dart';

class LocationDto {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double speed;
  final double speedAccuracy;
  final double heading;
  final double time;
  final bool isMocked;
  final String provider;

  /// The latest activity-recognition classification ("driving", "walking",
  /// "stationary", ... or "" when unknown), attached by the native side at
  /// delivery time.
  final String motionState;

  /// True on the first fix after the native side changed the location
  /// request on its own (iOS: registration, relaunch after termination, exit
  /// of the still-mode wake region). The caller should forget which request
  /// it last applied and treat the fix as possible movement.
  final bool nativeReset;

  LocationDto._(
    this.latitude,
    this.longitude,
    this.accuracy,
    this.altitude,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.time,
    this.isMocked,
    this.provider,
    this.motionState,
    this.nativeReset,
  );

  factory LocationDto.fromJson(Map<dynamic, dynamic> json) {
    bool isLocationMocked =
        isAndroid ? json[Keys.ARG_IS_MOCKED] : false;
    return LocationDto._(
      json[Keys.ARG_LATITUDE],
      json[Keys.ARG_LONGITUDE],
      json[Keys.ARG_ACCURACY],
      json[Keys.ARG_ALTITUDE],
      json[Keys.ARG_SPEED],
      json[Keys.ARG_SPEED_ACCURACY],
      json[Keys.ARG_HEADING],
      json[Keys.ARG_TIME],
      isLocationMocked,
      json[Keys.ARG_PROVIDER] ?? '',
      json[Keys.ARG_MOTION_STATE] ?? '',
      json[Keys.ARG_NATIVE_RESET] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      Keys.ARG_LATITUDE: this.latitude,
      Keys.ARG_LONGITUDE: this.longitude,
      Keys.ARG_ACCURACY: this.accuracy,
      Keys.ARG_ALTITUDE: this.altitude,
      Keys.ARG_SPEED: this.speed,
      Keys.ARG_SPEED_ACCURACY: this.speedAccuracy,
      Keys.ARG_HEADING: this.heading,
      Keys.ARG_TIME: this.time,
      Keys.ARG_IS_MOCKED: this.isMocked,
      Keys.ARG_PROVIDER: this.provider,
      Keys.ARG_MOTION_STATE: this.motionState,
      Keys.ARG_NATIVE_RESET: this.nativeReset,
    };
  }

  @override
  String toString() {
    return 'LocationDto{latitude: $latitude, longitude: $longitude, accuracy: $accuracy, altitude: $altitude, speed: $speed, speedAccuracy: $speedAccuracy, heading: $heading, time: $time, isMocked: $isMocked, provider: $provider, motionState: $motionState, nativeReset: $nativeReset}';
  }
}
