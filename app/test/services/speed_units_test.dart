import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openfamily/services/speed_units.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('m/s to mph and km/h', () {
    expect(UnitSystem.imperial.formatSpeed(31.3), '70 mph');
    expect(UnitSystem.metric.formatSpeed(31.3), '113 km/h');
    expect(UnitSystem.metric.mpsFromSpeed(36), closeTo(10, 1e-9));
    expect(
      UnitSystem.imperial.mpsFromSpeed(UnitSystem.imperial.speedFromMps(20)),
      closeTo(20, 1e-9),
    );
  });

  test('distance formatting', () {
    expect(UnitSystem.imperial.formatDistance(1609.344), '1.0 mi');
    expect(UnitSystem.metric.formatDistance(21450), '21 km');
    expect(UnitSystem.metric.formatDistance(2500), '2.5 km');
    expect(UnitSystem.metric.formatDistance(40), '40 m');
    expect(UnitSystem.imperial.formatDistance(100), '328 ft');
  });

  test('duration formatting', () {
    expect(formatTripDuration(const Duration(seconds: 30)), '30 s');
    expect(formatTripDuration(const Duration(minutes: 7)), '7 min');
    expect(formatTripDuration(const Duration(minutes: 65)), '1 h 05 min');
  });

  test('units and threshold persist', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await UnitPreferenceService.load(), UnitSystem.imperial);
    await UnitPreferenceService.setUnits(UnitSystem.metric);
    UnitPreferenceService.units.value = UnitSystem.imperial;
    expect(await UnitPreferenceService.load(), UnitSystem.metric);
    expect(
      await UnitPreferenceService.loadThreshold(),
      UnitPreferenceService.defaultThresholdMps,
    );
    await UnitPreferenceService.saveThreshold(25);
    expect(await UnitPreferenceService.loadThreshold(), 25);
  });
}
