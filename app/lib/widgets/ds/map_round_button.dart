import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Floating circular control that sits over the map (settings, layers,
/// locate...). 48dp target, tooltip doubles as the accessible label.
class DsMapButton extends StatelessWidget {
  const DsMapButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.iconColor,
    this.badge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Defaults to the sheet surface colour.
  final Color? color;
  final Color? iconColor;

  /// Small attention dot (e.g. unread alerts).
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        onTap: onPressed,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            DecoratedBox(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: kFloatShadow,
              ),
              child: Material(
                color: color ?? brand.sheet,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onPressed,
                  child: SizedBox(
                    width: kMinTarget,
                    height: kMinTarget,
                    child: Icon(
                      icon,
                      size: 24,
                      color: iconColor ?? brand.accentInk,
                    ),
                  ),
                ),
              ),
            ),
            if (badge)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.statusRed,
                    shape: BoxShape.circle,
                    border: Border.all(color: brand.sheet, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
