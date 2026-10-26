import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A screen signal from the Android system.
class ScreenBroadcast {
  const ScreenBroadcast(this.type, this.timeMs);

  /// `screen_on`, `screen_off` or `user_present`.
  final String type;

  /// Epoch milliseconds (wall clock) when the broadcast was received.
  final int timeMs;
}

/// One GPS fix from the platform LocationManager.
class NativeGpsFix {
  const NativeGpsFix({
    required this.timeMs,
    required this.lat,
    required this.lon,
    required this.speedMps,
    required this.accuracyM,
    required this.mock,
  });

  final int timeMs;
  final double lat;
  final double lon;

  /// Doppler ground speed (m/s), or -1 when the fix carries none.
  final double speedMps;
  final double accuracyM;
  final bool mock;
}

/// Android-only native feeds used by the driving detection. On other
/// platforms the streams are empty. Each stream registers the underlying
/// Android listener on subscribe and removes it on cancel.
class DrivingNative {
  DrivingNative._();

  static const EventChannel _screen =
      EventChannel('app.openfamily/driving_native/screen');
  static const EventChannel _gps =
      EventChannel('app.openfamily/driving_native/gps');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<ScreenBroadcast> get screenEvents {
    if (!_supported) return const Stream<ScreenBroadcast>.empty();
    return _screen.receiveBroadcastStream().map((dynamic e) {
      final Map<dynamic, dynamic> m = e as Map<dynamic, dynamic>;
      return ScreenBroadcast(m['type'] as String, (m['t'] as num).toInt());
    });
  }

  /// ~1 Hz GPS fixes (1 s minimum interval, no distance filter).
  static Stream<NativeGpsFix> get gpsFixes {
    if (!_supported) return const Stream<NativeGpsFix>.empty();
    return _gps.receiveBroadcastStream().map((dynamic e) {
      final Map<dynamic, dynamic> m = e as Map<dynamic, dynamic>;
      return NativeGpsFix(
        timeMs: (m['t'] as num).toInt(),
        lat: (m['lat'] as num).toDouble(),
        lon: (m['lon'] as num).toDouble(),
        speedMps: (m['speed'] as num).toDouble(),
        accuracyM: (m['accuracy'] as num).toDouble(),
        mock: m['mock'] == true,
      );
    });
  }
}
