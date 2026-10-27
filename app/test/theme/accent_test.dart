import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';

void main() {
  test('no accent keeps the built-in green', () {
    expect(iceBrandFor(null).accent, AppColors.accent);
    expect(nightBrandFor(null).accent, AppColors.accentBright);
    expect(iceBrandFor(AppColors.accent), same(BrandTheme.ice));
  });

  test('parseAccentHex accepts only #RRGGBB', () {
    expect(parseAccentHex('#14B8A6'), const Color(0xFF14B8A6));
    expect(parseAccentHex('14B8A6'), isNull);
    expect(parseAccentHex('#FFF'), isNull);
    expect(parseAccentHex(null), isNull);
    expect(accentToHex(const Color(0xFF14B8A6)), '#14B8A6');
  });

  test('every choice has readable ink and button text', () {
    for (final c in kAccentChoices) {
      final BrandTheme ice = iceBrandFor(c.color);
      final BrandTheme night = nightBrandFor(c.color);
      expect(accentContrast(ice.accentInk, AppColors.iceSurface),
          greaterThanOrEqualTo(4.5),
          reason: c.name);
      expect(
          accentContrast(ice.accent, ice.onAccent), greaterThanOrEqualTo(4.5),
          reason: c.name);
      expect(accentContrast(night.accent, night.onAccent),
          greaterThanOrEqualTo(4.5),
          reason: c.name);
      expect(accentContrast(night.accentInk, AppColors.nightPaper),
          greaterThanOrEqualTo(4.5),
          reason: c.name);
    }
  });
}
