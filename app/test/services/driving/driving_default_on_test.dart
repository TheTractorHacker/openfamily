import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/driving/driving_events_service.dart';
import 'package:openfamily/services/driving/driving_settings.dart';
import 'package:openfamily/services/driving/driving_event_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_sensor_events_api.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DrivingEventOutbox.resetLockForTest();
  });

  test('a missing preference means detection is ON, phone use stays OFF',
      () async {
    expect(await DrivingSettings.sensorEnabled(), isTrue);
    expect(await DrivingSettings.phoneUseEnabled(), isFalse);
  });

  test('an explicit off is respected and clears phone use', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      DrivingSettings.sensorKey: false,
      DrivingSettings.phoneUseKey: true,
    });
    expect(await DrivingSettings.sensorEnabled(), isFalse);
    await DrivingSettings.setSensorEnabled(false);
    expect(await DrivingSettings.phoneUseEnabled(), isFalse);
  });

  test('first sync sends sensor_enabled=true once and persists the state',
      () async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    final DrivingEventsService svc = DrivingEventsService(api);
    expect(await svc.syncOptIn(), isTrue);
    expect(api.flags, <bool>[true]);
    expect(api.batches.single, isEmpty);
    final SharedPreferences p = await SharedPreferences.getInstance();
    expect(p.getBool(DrivingSettings.sensorKey), isTrue);
    expect(p.getBool(DrivingSettings.syncedKey), isTrue);
    // Already acknowledged: nothing more is sent.
    expect(await svc.syncOptIn(), isTrue);
    expect(api.flags, <bool>[true]);
  });

  test('a failed first sync is retried until it succeeds', () async {
    final FakeSensorEventsApi api = FakeSensorEventsApi()..offline = true;
    final DrivingEventsService svc = DrivingEventsService(api);
    expect(await svc.syncOptIn(), isFalse);
    expect(await svc.syncOptIn(), isFalse);
    expect(api.flags, isEmpty);
    final SharedPreferences p = await SharedPreferences.getInstance();
    expect(p.getBool(DrivingSettings.syncedKey), isNull);
    // Detection still counts as on while the server has not been told.
    expect(await DrivingSettings.sensorEnabled(), isTrue);
    api.offline = false;
    expect(await svc.syncOptIn(), isTrue);
    expect(api.flags, <bool>[true]);
  });

  test('turning off sends false, and a failed off call is redelivered',
      () async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    final DrivingEventsService svc = DrivingEventsService(api);
    await svc.syncOptIn();
    await DrivingSettings.setSensorEnabled(false);
    api.offline = true;
    expect(await svc.syncOptIn(), isFalse);
    expect(await DrivingSettings.sensorEnabled(), isFalse,
        reason: 'sampling stays off even if the server was not told');
    api.offline = false;
    expect(await svc.syncOptIn(), isTrue);
    expect(api.flags, <bool>[true, false]);
    expect(await svc.syncOptIn(), isTrue);
    expect(api.flags.length, 2);
  });

  test('a choice made during the call is not marked as synced', () async {
    await DrivingSettings.markSynced(true);
    await DrivingSettings.setSensorEnabled(false);
    await DrivingSettings.markSynced(true); // stale ack for the old value
    expect(await DrivingSettings.serverSynced(), isFalse);
  });

  test('disclosure seen flag is local and sticky', () async {
    expect(await DrivingSettings.disclosureSeen(), isFalse);
    await DrivingSettings.markDisclosureSeen();
    expect(await DrivingSettings.disclosureSeen(), isTrue);
  });

  test('request body carries phone_use_enabled and a change is re-sent',
      () async {
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    final DrivingEventsService svc = DrivingEventsService(api);
    expect(
      ApiClient.sensorEventsBody(const <Map<String, dynamic>>[],
          sensorEnabled: true, phoneUseEnabled: false),
      <String, dynamic>{
        'events': <Map<String, dynamic>>[],
        'sensor_enabled': true,
        'phone_use_enabled': false,
      },
    );
    expect(await svc.syncOptIn(), isTrue);
    expect(api.phoneFlags, <bool>[false]);
    expect(await svc.syncOptIn(), isTrue);
    expect(api.phoneFlags, hasLength(1), reason: 'already in sync');
    await DrivingSettings.setPhoneUseEnabled(true);
    expect(await DrivingSettings.serverSynced(), isFalse);
    expect(await svc.syncOptIn(), isTrue);
    expect(api.phoneFlags, <bool>[false, true]);
    expect(api.flags, <bool>[true, true]);
    // A stale ack for the old phone value does not mark it synced.
    await DrivingSettings.setPhoneUseEnabled(false);
    await DrivingSettings.markSynced(true, phoneUse: true);
    expect(await DrivingSettings.serverSynced(), isFalse);
  });
}
