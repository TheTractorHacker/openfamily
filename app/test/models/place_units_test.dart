import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/services/speed_units.dart';

void main() {
  const Place home = Place(
    id: 'p1',
    name: 'Home',
    icon: Icons.home,
    address: '',
    position: LatLng(40.5, -75.25),
    radiusMeters: 152.4,
    type: 'home',
    alertsOn: true,
    geofenceId: 'g1',
  );

  tearDown(UnitPreferenceService.resetForTest);

  test('place radius follows the one unit setting (miles by default)', () {
    UnitPreferenceService.resetForTest();
    expect(home.radiusLabel, '500 ft');
    expect(home.radiusLabelIn(UnitSystem.metric), '152 m');
    UnitPreferenceService.units.value = UnitSystem.metric;
    expect(home.radiusLabel, '152 m');
    expect(home.copyWith(radiusMeters: 3218.69).radiusLabel, '3.2 km');
    UnitPreferenceService.units.value = UnitSystem.imperial;
    expect(home.copyWith(radiusMeters: 3218.69).radiusLabel, '2 mi');
  });
}
