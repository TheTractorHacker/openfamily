import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

enum DsPillStyle { filled, tonal, outlined, danger }

/// Fully rounded button. At least 48dp tall; grows with large text.
class DsPillButton extends StatelessWidget {
  const DsPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = DsPillStyle.filled,
    this.semanticLabel,
    this.floating = false,
    this.iconWidget,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Replaces [icon] with an arbitrary leading widget (e.g. an animated one).
  final Widget? iconWidget;
  final DsPillStyle style;
  final String? semanticLabel;

  /// Adds a drop shadow, for pills that sit over the map.
  final bool floating;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) =>
            _build(context, c.hasTightWidth),
      );

  Widget _build(BuildContext context, bool stretched) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    BorderSide side = BorderSide.none;
    switch (style) {
      case DsPillStyle.filled:
        bg = brand.accent;
        fg = brand.onAccent;
      case DsPillStyle.tonal:
        bg = brand.sheet;
        fg = cs.onSurface;
      case DsPillStyle.outlined:
        bg = Colors.transparent;
        fg = cs.onSurface;
        side = BorderSide(color: cs.outlineVariant, width: 1.5);
      case DsPillStyle.danger:
        bg = AppColors.sosRed;
        fg = Colors.white;
    }
    final Widget child = Row(
      mainAxisSize: stretched ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null || iconWidget != null) ...<Widget>[
          iconWidget ?? Icon(icon, size: 20),
          const SizedBox(width: AppSpace.sm),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: AppType.body.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: floating ? kFloatShadow : null,
          ),
          child: Material(
            color: bg,
            shape: StadiumBorder(side: side),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onPressed,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTarget),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.xl,
                    vertical: AppSpace.sm,
                  ),
                  child: IconTheme(
                    data: IconThemeData(color: fg),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: fg),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
