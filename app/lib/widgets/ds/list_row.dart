import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Standard list row: leading (avatar or icon), title, optional status line,
/// optional trailing widget. At least 56dp tall, wraps instead of clipping
/// when the text is large.
class DsListRow extends StatelessWidget {
  const DsListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.destructive = false,
    this.chevron = false,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool destructive;

  /// Adds a trailing chevron (navigates somewhere).
  final bool chevron;
  final String? semanticLabel;

  /// Icon tile used as [leading] for settings-style rows.
  static Widget iconTile(BuildContext context, IconData icon, {Color? color}) {
    final BrandTheme brand = BrandTheme.of(context);
    final Color c = color ?? brand.accentInk;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(icon, size: 22, color: c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    final Color titleColor = destructive ? AppColors.sosRed : cs.onSurface;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: semanticLabel,
      container: true,
      child: Material(
        color: selected
            ? brand.accent.withValues(alpha: 0.14)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.xl,
                vertical: AppSpace.md,
              ),
              child: Row(
                children: <Widget>[
                  if (leading != null) ...<Widget>[
                    leading!,
                    const SizedBox(width: AppSpace.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          style: AppType.body.copyWith(color: titleColor),
                        ),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: AppSpace.xxs),
                          Text(
                            subtitle!,
                            style: AppType.secondary.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...<Widget>[
                    const SizedBox(width: AppSpace.sm),
                    // Never let a trailing chip squeeze the title away at
                    // large text sizes.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.4,
                      ),
                      child: trailing!,
                    ),
                  ],
                  if (chevron) ...<Widget>[
                    const SizedBox(width: AppSpace.xs),
                    Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded card that groups [DsListRow]s with hairline dividers. Use inside a
/// [DsPage] (the page already supplies the gutter).
class DsRowGroup extends StatelessWidget {
  const DsRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: BrandTheme.of(context).sheet,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0)
              Divider(height: 1, indent: AppSpace.xl, color: cs.outlineVariant),
            children[i],
          ],
        ],
      ),
    );
  }
}
