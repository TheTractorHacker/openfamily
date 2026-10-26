import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/driving_event.dart';
import 'package:openfamily/services/driving/driving_event_outbox.dart';
import 'package:openfamily/services/driving/driving_events_service.dart';
import 'package:openfamily/services/driving/driving_runtime.dart';
import 'package:openfamily/services/driving/driving_session.dart';
import 'package:openfamily/services/driving/phone_use_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_sensor_events_api.dart';

DrivingEvent ev(DrivingEventKind k, int startMs) => DrivingEvent(
    kind: k,
    startedAtMs: startMs,
    endedAtMs: startMs + 1500,
    magnitude: 4.2,
    lat: 1,
    lon: 2);

class FakeFeed implements DrivingFeed {
  int starts = 0;
  int stops = 0;
  bool withScreen = false;
  DrivingFeedSink? sink;

  @override
  void start(DrivingFeedSink sink, {required bool withScreen}) {
    starts++;
    this.sink = sink;
    this.withScreen = withScreen;
  }

  @override
  Future<void> stop() async {
    stops++;
    sink = null;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('DrivingSessionController', () {
    test('starts on speed, stays through a red light, stops when stationary',
        () {
      int starts = 0, stops = 0;
      final DrivingSessionController c = DrivingSessionController(
          onStart: () => starts++, onStop: () => stops++);
      c.onSpeed(0, 1.4); // walking
      c.tick(60000);
      expect(starts, 0);
      c.onSpeed(1000, 12);
      expect(starts, 1);
      for (int t = 2000; t <= 12000; t += 1000) {
        c.onSpeed(t, 12);
      }
      expect(c.isConfirmed, isTrue);
      c.onSpeed(13000, 0);
      c.tick(13000 + 100000); // red light, < 120 s
      expect(stops, 0);
      c.tick(13000 + 125000);
      expect(stops, 1);
      expect(c.isActive, isFalse);
    });

    test('a start that never turns into sustained driving stops', () {
      int stops = 0;
      final DrivingSessionController c =
          DrivingSessionController(onStart: () {}, onStop: () => stops++);
      c.onSpeed(0, 6);
      c.onSpeed(1000, 0.5);
      c.tick(95000);
      expect(stops, 1);
    });
  });

  group('PhoneUseTracker', () {
    test('unlock while moving then screen off is one event', () {
      final PhoneUseTracker t = PhoneUseTracker();
      t.onSpeed(0, 20, 5, 6);
      t.onScreen(1000, ScreenSignal.screenOn);
      t.onScreen(2000, ScreenSignal.userPresent);
      t.onScreen(14000, ScreenSignal.screenOff);
      final List<DrivingEvent> e = t.takeEvents();
      expect(e, hasLength(1));
      expect(e.single.kind, DrivingEventKind.phoneUse);
      expect(e.single.magnitude, closeTo(12, 0.01));
      expect(e.single.lat, 5);
    });

    test('screen-on without unlock, parked unlock and short taps do not count',
        () {
      final PhoneUseTracker t = PhoneUseTracker();
      t.onSpeed(0, 20, null, null);
      t.onScreen(1000, ScreenSignal.screenOn); // notification wake
      t.onScreen(5000, ScreenSignal.screenOff);
      t.onScreen(6000, ScreenSignal.userPresent);
      t.onScreen(7000, ScreenSignal.screenOff); // 1 s
      t.onSpeed(8000, 0, null, null);
      t.onScreen(9000, ScreenSignal.userPresent); // parked
      t.onScreen(30000, ScreenSignal.screenOff);
      expect(t.takeEvents(), isEmpty);
    });

    test('stopping the car ends the interaction; long ones are capped', () {
      final PhoneUseTracker t = PhoneUseTracker();
      t.onSpeed(0, 20, null, null);
      t.onScreen(1000, ScreenSignal.userPresent);
      t.onSpeed(6000, 0.5, null, null);
      expect(t.takeEvents().single.magnitude, closeTo(5, 0.01));
      t.onSpeed(10000, 20, null, null);
      t.onScreen(11000, ScreenSignal.userPresent);
      t.onSpeed(400000, 20, null, null);
      expect(t.takeEvents().single.magnitude, closeTo(120, 0.01));
    });
  });

  group('DrivingEventOutbox + service', () {
    test('dedupes on kind+started_at and uploads in batches of <= 100',
        () async {
      final DateTime now = DateTime.now().toUtc();
      final int base = now.millisecondsSinceEpoch - 60000;
      final List<DrivingEvent> events = <DrivingEvent>[
        for (int i = 0; i < 230; i++) ev(DrivingEventKind.hardBrake, base + i),
      ];
      final FakeSensorEventsApi api = FakeSensorEventsApi();
      final DrivingEventsService s = DrivingEventsService(api);
      await s.queue(events);
      await s.queue(events.take(10).toList()); // duplicates
      expect(await DrivingEventOutbox.pendingCount(), 230);
      expect(await s.uploadQueued(), 230);
      expect(api.batches.map((b) => b.length), <int>[100, 100, 30]);
      expect(await DrivingEventOutbox.pendingCount(), 0);
      expect(api.batches.first.first.keys,
          containsAll(<String>['kind', 'started_at', 'ended_at', 'magnitude']));
    });

    test('offline keeps the queue; recovery delivers; 4xx drops', () async {
      final int base = DateTime.now().millisecondsSinceEpoch - 5000;
      final FakeSensorEventsApi api = FakeSensorEventsApi();
      final DrivingEventsService s = DrivingEventsService(api);
      await s.queue(<DrivingEvent>[ev(DrivingEventKind.rapidAccel, base)]);
      api.offline = true;
      expect(await s.uploadQueued(), 0);
      expect(await DrivingEventOutbox.pendingCount(), 1);
      api.offline = false;
      api.failStatus = 401; // key rejected: keep for later
      expect(await s.uploadQueued(), 0);
      expect(await DrivingEventOutbox.pendingCount(), 1);
      api.failStatus = null;
      expect(await s.uploadQueued(), 1);
      await s.queue(<DrivingEvent>[ev(DrivingEventKind.hardBrake, base + 9)]);
      api.failStatus = 400;
      await s.uploadQueued();
      expect(await DrivingEventOutbox.pendingCount(), 0); // dropped
    });

    test('opting out tells the server and discards the queue', () async {
      final FakeSensorEventsApi api = FakeSensorEventsApi();
      final DrivingEventsService s = DrivingEventsService(api);
      await s.queue(<DrivingEvent>[
        ev(DrivingEventKind.hardBrake, DateTime.now().millisecondsSinceEpoch)
      ]);
      await s.setServerOptIn(false);
      expect(api.flags, <bool>[false]);
      expect(api.batches.single, isEmpty);
      expect(await DrivingEventOutbox.pendingCount(), 0);
    });

    test('prune drops entries older than 3 days', () {
      final DateTime now = DateTime.utc(2026, 1, 10);
      final List<Map<String, dynamic>> r = drivingOutboxPrune(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'hard_brake',
            'started_at': '2026-01-01T00:00:00Z'
          },
          <String, dynamic>{
            'kind': 'hard_brake',
            'started_at': '2026-01-09T00:00:00Z'
          },
        ],
        now: now,
      );
      expect(r, hasLength(1));
    });
  });

  group('DrivingRuntime', () {
    late FakeFeed feed;
    late FakeSensorEventsApi api;
    late int now;
    late bool enabled;
    late DrivingRuntime rt;

    setUp(() {
      feed = FakeFeed();
      api = FakeSensorEventsApi();
      now = 1700000000000;
      enabled = true;
      rt = DrivingRuntime(
        feed: feed,
        service: DrivingEventsService(api),
        isEnabled: () async => enabled,
        isPhoneUseEnabled: () async => false,
        clock: () => now,
        tickEvery: const Duration(hours: 1),
      );
    });

    test('nothing starts while disabled, parked or walking', () async {
      enabled = false;
      await rt.onBackgroundFix(speedMps: 20);
      expect(feed.starts, 0);
      enabled = true;
      await rt.onBackgroundFix(speedMps: 1.2);
      await rt.onBackgroundFix(speedMps: 0);
      expect(feed.starts, 0);
      expect(rt.sensorsRunning, isFalse);
    });

    test('driving fix starts the feed; switching off stops it', () async {
      await rt.onBackgroundFix(speedMps: 14);
      await Future<void>.delayed(Duration.zero);
      expect(rt.sensorsRunning, isTrue);
      expect(feed.starts, 1);
      enabled = false;
      await rt.onBackgroundFix(speedMps: 14);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rt.sensorsRunning, isFalse);
      expect(feed.stops, greaterThanOrEqualTo(1));
    });

    test('a start with the phone-use switch off does not subscribe to screen',
        () async {
      await rt.onBackgroundFix(speedMps: 14);
      await Future<void>.delayed(Duration.zero);
      expect(feed.withScreen, isFalse);
    });
  });
}
