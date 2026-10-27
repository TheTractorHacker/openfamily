import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Curated accent choices offered in Settings. The first is the built-in
/// green, which is also what "no custom color" resolves to.
const List<({String name, Color color})> kAccentChoices =
    <({String name, Color color})>[
  (name: 'Lime', color: Color(0xFF8FD400)),
  (name: 'Teal', color: Color(0xFF14B8A6)),
  (name: 'Sky', color: Color(0xFF0EA5E9)),
  (name: 'Indigo', color: Color(0xFF6366F1)),
  (name: 'Violet', color: Color(0xFF8B5CF6)),
  (name: 'Pink', color: Color(0xFFEC4899)),
  (name: 'Orange', color: Color(0xFFF97316)),
  (name: 'Amber', color: Color(0xFFF59E0B)),
];

/// Parses "#RRGGBB" (the only form the server sends); null when malformed.
Color? parseAccentHex(Object? raw) {
  if (raw is! String) return null;
  final String s = raw.trim();
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(s)) return null;
  return Color(0xFF000000 | int.parse(s.substring(1), radix: 16));
}

String accentToHex(Color c) {
  final int v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

bool _isBuiltInGreen(Color c) =>
    (c.toARGB32() & 0xFFFFFF) == (AppColors.accent.toARGB32() & 0xFFFFFF);

/// WCAG contrast ratio between two opaque colors.
double accentContrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Dark ink or white, whichever reads better on [fill].
Color onAccentFor(Color fill) => accentContrast(fill, AppColors.onAccent) >=
        accentContrast(fill, Colors.white)
    ? AppColors.onAccent
    : Colors.white;

/// Nudges [c] lighter or darker, in the direction that favors the better
/// label color, until that label reads at 4.5:1.
Color _readableFill(Color c) {
  final Color label = onAccentFor(c);
  final double step = label == Colors.white ? -0.02 : 0.02;
  Color out = c;
  double l = HSLColor.fromColor(c).lightness;
  for (int i = 0; i < 30 && accentContrast(out, onAccentFor(out)) < 4.5; i++) {
    l = (l + step).clamp(0.0, 1.0);
    out = _withLightness(c, l);
  }
  return out;
}

Color _withLightness(Color c, double l) {
  final HSLColor h = HSLColor.fromColor(c);
  return h.withLightness(l.clamp(0.0, 1.0)).toColor();
}

/// Darkens [c] until it reads at 4.5:1 against [bg] (for glyphs and labels).
Color _inkOn(Color c, Color bg) {
  Color out = c;
  double l = HSLColor.fromColor(c).lightness;
  while (accentContrast(out, bg) < 4.5 && l > 0.05) {
    l -= 0.03;
    out = _withLightness(c, l);
  }
  return out;
}

/// Ice (light) palette derived from [accent]; null means the built-in green.
BrandTheme iceBrandFor(Color? accent) {
  if (accent == null || _isBuiltInGreen(accent)) return BrandTheme.ice;
  final Color fill = _readableFill(accent);
  final HSLColor h = HSLColor.fromColor(fill);
  return BrandTheme.ice.copyWith(
    accent: fill,
    accentInk: _inkOn(accent, AppColors.iceSurface),
    onAccent: onAccentFor(fill),
    spark: _withLightness(accent, (h.lightness + 0.2).clamp(0.0, 0.9)),
    accentPressed: _withLightness(fill, (h.lightness - 0.08).clamp(0.0, 1.0)),
  );
}

/// Night (dark) palette derived from [accent]: a step brighter so it holds
/// on charcoal.
BrandTheme nightBrandFor(Color? accent) {
  if (accent == null || _isBuiltInGreen(accent)) return BrandTheme.night;
  final HSLColor h = HSLColor.fromColor(accent);
  final Color bright = _readableFill(
      _withLightness(accent, (h.lightness + 0.08).clamp(0.58, 0.74)));
  return BrandTheme.night.copyWith(
    accent: bright,
    accentInk: bright,
    onAccent: onAccentFor(bright),
    spark: _withLightness(accent, (h.lightness + 0.25).clamp(0.0, 0.9)),
    accentPressed:
        _withLightness(bright, HSLColor.fromColor(bright).lightness - 0.1),
  );
}
