import '../api_client.dart';
import '../background_credential_store.dart';
import 'driving_event.dart';
import 'driving_event_outbox.dart';
import 'driving_settings.dart';

/// Server reply to `POST /trips/sensor-events`.
class SensorEventsResult {
  const SensorEventsResult({
    this.accepted = 0,
    this.duplicate = 0,
    this.rejected = 0,
  });

  factory SensorEventsResult.fromJson(Map<String, dynamic> j) =>
      SensorEventsResult(
        accepted: (j['accepted'] as num?)?.toInt() ?? 0,
        duplicate: (j['duplicate'] as num?)?.toInt() ?? 0,
        rejected: (j['rejected'] as num?)?.toInt() ?? 0,
      );

  final int accepted;
  final int duplicate;
  final int rejected;
}

/// Transport for sensor events (real implementations below, fake in tests).
/// Implementations throw [ApiException] for HTTP errors and any other
/// exception for transport failures.
abstract class SensorEventsApi {
  Future<SensorEventsResult> post(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  });
}

/// Foreground transport: account session (Bearer token).
class SessionSensorEventsApi implements SensorEventsApi {
  const SessionSensorEventsApi();

  @override
  Future<SensorEventsResult> post(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  }) async {
    return SensorEventsResult.fromJson(
        await ApiClient.postSensorEvents(events,
            sensorEnabled: sensorEnabled, phoneUseEnabled: phoneUseEnabled));
  }
}

/// Background-isolate transport: device ingest key only, no account tokens.
class IngestKeySensorEventsApi implements SensorEventsApi {
  const IngestKeySensorEventsApi();

  @override
  Future<SensorEventsResult> post(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  }) async {
    final String? base = await BackgroundCredentialStore.readApiBaseUrl();
    final String? device = await BackgroundCredentialStore.readDeviceId();
    final String? key = await BackgroundCredentialStore.readIngestKey();
    if (base == null ||
        base.isEmpty ||
        device == null ||
        device.isEmpty ||
        key == null ||
        key.isEmpty) {
      // Same as an auth failure: keep queued until the app re-provisions.
      throw const ApiException(401, 'no ingest credentials');
    }
    return SensorEventsResult.fromJson(
      await ApiClient.postSensorEventsWithIngestKey(
        apiBaseUrl: base,
        deviceId: device,
        ingestKey: key,
        events: events,
        sensorEnabled: sensorEnabled,
        phoneUseEnabled: phoneUseEnabled,
      ),
    );
  }
}

/// Queues detected events and uploads them in batches (retry + idempotency:
/// the outbox de-duplicates on (kind, started_at) and so does the server).
class DrivingEventsService {
  DrivingEventsService(this.api);

  final SensorEventsApi api;

  /// Stores [events] for upload.
  Future<void> queue(List<DrivingEvent> events) =>
      DrivingEventOutbox.enqueue(events);

  /// Uploads everything queued. Returns the number of events delivered.
  Future<int> uploadQueued() {
    return DrivingEventOutbox.drain(
      send: (List<Map<String, dynamic>> batch) async {
        try {
          await api.post(batch,
              sensorEnabled: true,
              phoneUseEnabled: await DrivingSettings.phoneUseEnabled());
          return DrivingSendOutcome.ok;
        } on ApiException catch (e) {
          final bool transient = e.status == 401 ||
              e.status == 403 ||
              e.status == 408 ||
              e.status == 429 ||
              e.status >= 500;
          return transient
              ? DrivingSendOutcome.retry
              : DrivingSendOutcome.drop;
        }
      },
    );
  }

  /// Tells the server whether the sensor feature is on for this user. Turning
  /// it off also discards anything still queued on the device.
  Future<void> setServerOptIn(bool enabled) async {
    if (!enabled) await DrivingEventOutbox.clear();
    await api.post(const <Map<String, dynamic>>[],
        sensorEnabled: enabled,
        phoneUseEnabled: enabled && await DrivingSettings.phoneUseEnabled());
  }

  /// Tells the server whether phone-use detection (screen activity while the
  /// car moves) is on. Needs the sensor to be on. The server rejects
  /// phone_use events unless this was sent as true.
  Future<void> setServerPhoneUse(bool enabled) async {
    await api.post(const <Map<String, dynamic>>[],
        sensorEnabled: true, phoneUseEnabled: enabled);
  }

  /// Makes sure the server knows the effective on-device setting. Detection is
  /// on by default, so on first run (or after an update) the preference is
  /// missing and the server has not been told: this sends
  /// `sensor_enabled=true` (and the phone-use flag) once and then persists the effective value. It
  /// also redelivers a switch-off whose first call failed. A failed call
  /// leaves the state unsynced so the next call retries. Never throws.
  /// Returns true when the server is known to be in sync.
  Future<bool> syncOptIn() async {
    try {
      if (await DrivingSettings.serverSynced()) return true;
      final bool enabled = await DrivingSettings.sensorEnabled();
      if (!enabled) await DrivingEventOutbox.clear();
      final bool phone = enabled && await DrivingSettings.phoneUseEnabled();
      await api.post(const <Map<String, dynamic>>[],
          sensorEnabled: enabled, phoneUseEnabled: phone);
      await DrivingSettings.markSynced(enabled, phoneUse: phone);
      return true;
    } catch (_) {
      return false;
    }
  }
}
