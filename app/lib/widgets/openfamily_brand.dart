import 'package:flutter/material.dart';

/// Theme-aware Orbitly brand mark backed by the shared project assets.
class OpenFamilyMark extends StatelessWidget {
  const OpenFamilyMark({
    super.key,
    this.size = 88,
    this.brightness,
    this.semanticLabel = 'Orbitly',
  });

  final double size;
  final Brightness? brightness;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Brightness resolvedBrightness =
        brightness ?? Theme.of(context).brightness;
    final String asset = resolvedBrightness == Brightness.dark
        ? 'assets/branding/orbitly-icon-dark.png'
        : 'assets/branding/orbitly-icon.png';

    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      semanticLabel: semanticLabel,
    );
  }
}
