import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:openfamily/services/location_reporter.dart';
import 'package:openfamily/services/perf/perf_monitor.dart';
import 'package:openfamily/services/tracking_cadence.dart';

Position pos({double speed = 0, double acc = 5, double speedAcc = 0.5}) =>
    Position(
      latitude: 1,
      longitude: 2,
      timestamp: DateTime.utc(2026, 1, 1, 12),
      accuracy: acc,
      altitude: 3,
      altitudeAccuracy: 1,
      heading: 90,
      headingAccuracy: 1,
      speed: speed,
      speedAccuracy: speedAcc,
    );

void main() {
  test('body includes speed 0 and speed_accuracy for an accurate still fix', () {
    final Map<String, dynamic> b =
        LocationReporter.buildBody(pos(), deviceId: 'd', batteryPct: 50);
    expect(b['speed_mps'], 0);
    expect(b['speed_accuracy'], 0.5);
    expect(b['heading_deg'], 90);
    expect(b['source'], 'foreground');
  });

  test('body omits speed 0 when accuracy is poor', () {
    final Map<String, dynamic> b = LocationReporter.buildBody(pos(acc: 120),
        deviceId: 'd');
    expect(b.containsKey('speed_mps'), isFalse);
  });

  test('settingsFor follows the profile (1 Hz drive, 10 m stationary)', () {
    final TrackingCadence c = TrackingCadence();
    final LocationSettings still = LocationReporter.settingsFor(c.profile(DateTime.utc(2026)));
    expect(still.distanceFilter, 10);
    c.startBoost(const Duration(seconds: 30), DateTime.utc(2026));
    final LocationSettings fast = LocationReporter.settingsFor(c.profile(DateTime.utc(2026)));
    expect(fast.distanceFilter, 0);
  });

  test('PerfMonitor records fixes per minute and cadence in the report', () {
    final PerfMonitor m = PerfMonitor.forTest();
    DateTime now = DateTime.utc(2026, 1, 1, 12, 0, 10);
    m.clock = () => now;
    for (int i = 0; i < 50; i++) {
      m.recordFixSent();
    }
    now = DateTime.utc(2026, 1, 1, 12, 1, 5);
    m.recordFixSent();
    m.cadenceProfile = 'driving';
    expect(m.fixesLastMinute, 50);
    expect(m.fixesThisMinute, 1);
    final String r = m.buildReport();
    expect(r, contains('location reporting: profile driving'));
    expect(r, contains('fixes sent 51'));
  });
}
