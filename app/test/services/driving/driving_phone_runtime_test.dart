import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/driving_events_service.dart';
import 'package:openfamily/services/driving/driving_runtime.dart';
import 'package:openfamily/services/driving/phone_context.dart';
import 'package:openfamily/services/driving/phone_use_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_sensor_events_api.dart';

class _Feed implements DrivingFeed {
  DrivingFeedSink? sink;
  bool withScreen = false;
  @override
  void start(DrivingFeedSink sink, {required bool withScreen}) {
    this.sink = sink;
    this.withScreen = withScreen;
  }

  @override
  Future<void> stop() async => sink = null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// One drive at 20 m/s. Gyro/accel are fed at 50 Hz the whole time, with
  /// hand-like rotation between 20 s and 45 s; the screen is on 25..45 s.
  Future<List<Map<String, dynamic>>> drive({
    required bool handle,
    PhoneContext? context,
  }) async {
    final int base = DateTime.now().millisecondsSinceEpoch - 300000;
    int now = base;
    final _Feed feed = _Feed();
    final FakeSensorEventsApi api = FakeSensorEventsApi();
    final DrivingRuntime rt = DrivingRuntime(
      feed: feed,
      service: DrivingEventsService(api),
      isEnabled: () async => true,
      isPhoneUseEnabled: () async => true,
      clock: () => now,
      tickEvery: const Duration(hours: 1),
    );
    await rt.onBackgroundFix(speedMps: 20);
    await Future<void>.delayed(Duration.zero);
    expect(feed.withScreen, isTrue);
    final DrivingFeedSink s = feed.sink!;
    for (int sec = 1; sec <= 70; sec++) {
      final int t0 = base + sec * 1000;
      now = t0;
      s.onGps(t0, 20, 40.0, -75.0);
      if (context != null && sec == 22) s.onContext(context.copyWith(tMs: t0));
      if (sec == 25) {
        s.onScreen(t0, ScreenSignal.screenOn);
        s.onScreen(t0, ScreenSignal.userPresent);
      }
      if (sec == 45) s.onScreen(t0, ScreenSignal.screenOff);
      for (int i = 0; i < 50; i++) {
        final int t = t0 + i * 20;
        final bool hand = handle && sec >= 20 && sec < 45;
        final double w = hand ? 1.2 * math.sin(t / 150.0) : 0;
        s.onAccel(t, hand ? 2 * math.sin(t / 90.0) : 0, 0, 9.81);
        s.onGyro(t, w * 0.8, w * 0.6, 0.02);
      }
    }
    now = base + 200000;
    await rt.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return <Map<String, dynamic>>[
      for (final List<Map<String, dynamic>> b in api.batches) ...b
    ];
  }

  test('screen use with the phone handled becomes one phone_use event',
      () async {
    final List<Map<String, dynamic>> ev = await drive(handle: true);
    final List<Map<String, dynamic>> phone = ev
        .where((Map<String, dynamic> e) => e['kind'] == 'phone_use')
        .toList();
    expect(phone, hasLength(1));
    expect(phone.single['max_speed_mps'], 20.0);
    expect(phone.single['activity'], 'screen');
    expect(phone.single['magnitude'], greaterThan(10));
  });

  test('the same unlock on a phone that stays still (mounted) is mostly '
      'discarded', () async {
    final List<Map<String, dynamic>> ev = await drive(handle: false);
    final Iterable<Map<String, dynamic>> phone =
        ev.where((Map<String, dynamic> e) => e['kind'] == 'phone_use');
    for (final Map<String, dynamic> e in phone) {
      expect(e['magnitude'], lessThanOrEqualTo(12.5));
      expect(e['confidence'], lessThan(0.5));
    }
  });

  test('a hands-free call context never produces an event', () async {
    final List<Map<String, dynamic>> ev = await drive(
      handle: false,
      context: const PhoneContext(
          callMode: CallMode.call, route: AudioRoute.bluetooth),
    );
    expect(
        ev.where((Map<String, dynamic> e) =>
            e['kind'] == 'phone_use' && e['activity'] == 'call'),
        isEmpty);
  });
}
