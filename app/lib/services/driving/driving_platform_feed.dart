import 'dart:async';

import 'package:driving_native/driving_native.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'driving_runtime.dart';
import 'phone_use_tracker.dart';

/// Real sensor feed: accelerometer + gyroscope via `sensors_plus`
/// (Android SensorManager, no Google Play Services), 1 Hz GPS and screen
/// broadcasts via the local `driving_native` plugin.
///
/// Sampling is 50 Hz (20 ms), below Android's 200 Hz limit, so no
/// HIGH_SAMPLING_RATE_SENSORS permission is needed. `sensors_plus` registers a
/// plain SensorManager listener without a max-report-latency, so hardware
/// FIFO batching (which would let the CPU sleep between deliveries) is not
/// used; this is acceptable only because the feed runs just while driving.
///
/// Every subscription is cancelled in [stop], which unregisters the native
/// listeners, so nothing samples while parked or walking.
class PlatformDrivingFeed implements DrivingFeed {
  PlatformDrivingFeed({
    this.samplingPeriod = const Duration(milliseconds: 20),
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Duration samplingPeriod;
  final int Function() _clock;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  @override
  void start(DrivingFeedSink sink, {required bool withScreen}) {
    unawaited(stop());
    _subs.add(accelerometerEventStream(samplingPeriod: samplingPeriod).listen(
      (AccelerometerEvent e) => sink.onAccel(_clock(), e.x, e.y, e.z),
      onError: (Object _) {},
      cancelOnError: false,
    ));
    _subs.add(gyroscopeEventStream(samplingPeriod: samplingPeriod).listen(
      (GyroscopeEvent e) => sink.onGyro(_clock(), e.x, e.y, e.z),
      onError: (Object _) {}, // Some phones have no gyroscope.
      cancelOnError: false,
    ));
    _subs.add(DrivingNative.gpsFixes.listen(
      (NativeGpsFix f) {
        if (f.mock || f.speedMps < 0) return; // Spoofed or no Doppler speed.
        sink.onGps(f.timeMs, f.speedMps, f.lat, f.lon);
      },
      onError: (Object _) {},
      cancelOnError: false,
    ));
    if (withScreen) {
      _subs.add(DrivingNative.screenEvents.listen(
        (ScreenBroadcast b) {
          switch (b.type) {
            case 'screen_on':
              sink.onScreen(b.timeMs, ScreenSignal.screenOn);
            case 'screen_off':
              sink.onScreen(b.timeMs, ScreenSignal.screenOff);
            case 'user_present':
              sink.onScreen(b.timeMs, ScreenSignal.userPresent);
          }
        },
        onError: (Object _) {},
        cancelOnError: false,
      ));
    }
  }

  @override
  Future<void> stop() async {
    final List<StreamSubscription<Object?>> subs =
        List<StreamSubscription<Object?>>.of(_subs);
    _subs.clear();
    for (final StreamSubscription<Object?> s in subs) {
      await s.cancel();
    }
  }
}
