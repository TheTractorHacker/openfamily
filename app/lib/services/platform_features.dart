import 'package:flutter/foundation.dart';

/// Which optional features exist on the current platform. The Android build has
/// all of them; the iPhone build (docs/design/IOS_RELEASE.md) lacks the ones
/// that need Android-only native code. UI hides or explains the missing ones
/// instead of showing a switch that does nothing.
class PlatformFeatures {
  const PlatformFeatures._();

  /// Tests set this to pretend to be another platform.
  @visibleForTesting
  static TargetPlatform? debugPlatform;

  static TargetPlatform get _platform => debugPlatform ?? defaultTargetPlatform;

  static bool get isIOS => !kIsWeb && _platform == TargetPlatform.iOS;
  static bool get isAndroid => !kIsWeb && _platform == TargetPlatform.android;

  /// On-device driving analysis: hard braking / acceleration from the motion
  /// sensors, the screen-activity ("phone use") estimate and crash detection.
  /// Its native feeds (GPS speed, screen state, call state) exist only in the
  /// Android `driving_native` plugin.
  static bool get drivingSensors => isAndroid;

  /// Home-screen widget (Android AppWidget). iOS WidgetKit is not built.
  static bool get homeWidget => isAndroid;

  /// Message shown where a feature is missing on iPhone.
  static const String notOnIphone = 'Not available on iPhone yet';
}
