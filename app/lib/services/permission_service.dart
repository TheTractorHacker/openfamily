import 'package:flutter/foundation.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:permission_handler/permission_handler.dart';

/// The three onboarding permissions, in the order the app walks through them.
enum OnboardingPermission { location, notifications, motion }

/// A permission request result, decoupled from the plugin's enum so the UI
/// renders a consistent, explainable state.
enum PermissionState { granted, denied, permanentlyDenied, restricted }

/// Wraps [permission_handler] so the onboarding flow can request each
/// permission and explain WHY it is needed (privacy-first).
class PermissionService {
  PermissionService._();

  /// Requests [p] and returns the resulting state.
  static Future<PermissionState> request(OnboardingPermission p) async {
    final PermissionStatus status = await _request(p);
    return _map(status);
  }

  /// Reads the current state without prompting.
  static Future<PermissionState> current(OnboardingPermission p) async {
    return _map(await _permission(p).status);
  }

  /// Whether the current device supports the motion & fitness permission.
  ///
  /// iOS: false for now. Motion is only needed for the Android-only driving
  /// detection (PlatformFeatures.drivingSensors), and asking for Core Motion
  /// access for a feature that cannot run would be misleading and invites an
  /// App Review question. On Android, activity recognition requires
  /// Google Play Services, so we only request it when Play Services is
  /// actually available — "on some devices", as the brand bar specifies.
  /// Other platforms (web, desktop) do not support it.
  static Future<bool> supportsMotion() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return false;
      case TargetPlatform.android:
        try {
          final GooglePlayServicesAvailability availability =
              await GoogleApiAvailability.instance
                  .checkGooglePlayServicesAvailability();
          return availability == GooglePlayServicesAvailability.success;
        } catch (_) {
          return false;
        }
      default:
        return false;
    }
  }

  /// Opens the app's system settings page so the user can grant a permission
  /// that was permanently denied (the OS no longer shows a prompt for it).
  static Future<void> openSettings() => openAppSettings();

  static Future<PermissionStatus> _request(OnboardingPermission p) async {
    switch (p) {
      case OnboardingPermission.location:
        // "Always Allow" is the key one for background tracking. On iOS we
        // must request WhenInUse first, then Always. On Android, Always
        // requires the ACCESS_BACKGROUND_LOCATION manifest entry.
        final PermissionStatus whenInUse =
            await Permission.locationWhenInUse.request();
        if (whenInUse.isGranted || whenInUse.isLimited) {
          return Permission.locationAlways.request();
        }
        return whenInUse;
      case OnboardingPermission.notifications:
        return Permission.notification.request();
      case OnboardingPermission.motion:
        // Android: activity recognition. iOS: Core Motion (sensors).
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          return Permission.sensors.request();
        }
        return Permission.activityRecognition.request();
    }
  }

  static Permission _permission(OnboardingPermission p) {
    switch (p) {
      case OnboardingPermission.location:
        return Permission.locationAlways;
      case OnboardingPermission.notifications:
        return Permission.notification;
      case OnboardingPermission.motion:
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          return Permission.sensors;
        }
        return Permission.activityRecognition;
    }
  }

  static PermissionState _map(PermissionStatus s) {
    if (s.isGranted || s.isLimited) return PermissionState.granted;
    if (s.isPermanentlyDenied) return PermissionState.permanentlyDenied;
    if (s.isRestricted) return PermissionState.restricted;
    return PermissionState.denied;
  }
}
