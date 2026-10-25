import 'package:flutter/material.dart';

/// Spacing scale (dp). Use these instead of ad-hoc numbers.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// Horizontal page gutter.
  static const double gutter = 16;
}

/// Corner radius scale.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  /// Top corners of bottom sheets.
  static const BorderRadius sheet = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

/// Minimum interactive size (Material / WCAG 2.2 target).
const double kMinTarget = 48;

/// Type scale. Sizes scale with the user's text setting, so layouts built
/// from these must never assume a fixed height.
abstract final class AppType {
  static const TextStyle title = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.3,
    height: 1.2,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle secondary = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    height: 1.2,
  );
}

/// Motion tokens. Always route durations through [AppMotion.of] so the
/// OS "remove animations" setting is honoured.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);

  /// [d] unless the platform asks to disable animations.
  static Duration of(BuildContext context, [Duration d = normal]) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// Elevation shadow for floating map controls.
const List<BoxShadow> kFloatShadow = <BoxShadow>[
  BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 2)),
];
