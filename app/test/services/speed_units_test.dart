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

  test('radius formatting follows the unit system', () {
    expect(UnitSystem.imperial.formatRadius(152.4), '500 ft');
    expect(UnitSystem.imperial.formatRadius(1609.344), '1 mi');
    expect(UnitSystem.imperial.formatRadius(2414), '1.5 mi');
    expect(UnitSystem.metric.formatRadius(150), '150 m');
    expect(UnitSystem.metric.formatRadius(2000), '2 km');
    expect(UnitSystem.metric.formatRadius(1500), '1.5 km');
  });

  test('miles by default; server choice and instance default layer correctly',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.resetForTest();
    expect(await UnitPreferenceService.load(), UnitSystem.imperial);
    // Operator default applies while the person has not chosen.
    UnitPreferenceService.applyInstanceDefault(UnitSystem.metric);
    expect(UnitPreferenceService.units.value, UnitSystem.metric);
    // Their server-side choice beats the operator default.
    UnitPreferenceService.applyServerChoice(UnitSystem.imperial);
    expect(UnitPreferenceService.units.value, UnitSystem.imperial);
    // A local choice beats both and is mirrored to the server.
    UnitSystem? sent;
    UnitPreferenceService.onUserChange = (UnitSystem u) async => sent = u;
    await UnitPreferenceService.setUnits(UnitSystem.metric);
    expect(sent, UnitSystem.metric);
    UnitPreferenceService.applyServerChoice(UnitSystem.imperial);
    UnitPreferenceService.applyInstanceDefault(UnitSystem.imperial);
    expect(UnitPreferenceService.units.value, UnitSystem.metric);
    // Reloading remembers the local choice.
    UnitPreferenceService.units.value = UnitSystem.imperial;
    expect(await UnitPreferenceService.load(), UnitSystem.metric);
    UnitPreferenceService.resetForTest();
  });

  test('parseUnitSystem accepts only the wire values', () {
    expect(parseUnitSystem('metric'), UnitSystem.metric);
    expect(parseUnitSystem('imperial'), UnitSystem.imperial);
    expect(parseUnitSystem(''), isNull);
    expect(parseUnitSystem(null), isNull);
  });
}
