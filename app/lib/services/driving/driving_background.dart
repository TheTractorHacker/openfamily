import 'driving_events_service.dart';
import 'driving_platform_feed.dart';
import 'driving_runtime.dart';
import 'driving_settings.dart';

/// Entry point used from the background location isolate. Holds the single
/// [DrivingRuntime] of that isolate. Every call is non-throwing.
class DrivingBackground {
  DrivingBackground._();

  static DrivingRuntime? _runtime;

  static final DrivingEventsService _service =
      DrivingEventsService(const IngestKeySensorEventsApi());

  static DrivingRuntime get _rt => _runtime ??= DrivingRuntime(
        feed: PlatformDrivingFeed(),
        service: _service,
        syncOptIn: _service.syncOptIn,
        isEnabled: DrivingSettings.sensorEnabled,
        isPhoneUseEnabled: DrivingSettings.phoneUseEnabled,
      );

  /// Called from `onLocationUpdate` for every background fix. Cheap when the
  /// feature is off: one preferences read and nothing else.
  static Future<void> onLocationFix({
    required double speedMps,
    required double lat,
    required double lon,
  }) async {
    try {
      await _rt.onBackgroundFix(speedMps: speedMps, lat: lat, lon: lon);
    } catch (_) {
      // Never break location reporting.
    }
  }
}
