import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'info_hint.dart';

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
    this.wash = true,
    this.info,
    this.infoTitle,
  });

  /// Longer explanation, shown in a bottom sheet from a small (i) button. Keeps [subtitle] to one short line.
  final String? info;

  /// Sheet title; defaults to [title].
  final String? infoTitle;

  /// Paint the selected tint; false when the parent paints a bigger one.
  final bool wash;

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
  /// With [decorative] the tile only decorates (the words say the same), so
  /// a compact row may leave it out. Without it the icon carries meaning
  /// (a device kind, an alert type) and stays.
  static Widget iconTile(BuildContext context, IconData icon, {Color? color, bool decorative = false}) =>
      DsIconTile(icon, color: color, decorative: decorative);

  /// Rows are compact on narrow screens (a folded phone's cover display is
  /// about 344 dp) and at large text: icon tiles drop away and the gutter
  /// shrinks, so the title and the switch get the room.
  static bool compactFor(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360 ||
      MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;

  @override
  Widget build(BuildContext context) {
    final bool compact = compactFor(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    final Color titleColor = destructive ? AppColors.sosRed : cs.onSurface;
    final Widget? lead = compact && leading is DsIconTile && (leading as DsIconTile).decorative ? null : leading;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: semanticLabel,
      container: true,
      child: Material(
        color: selected && wash
            ? brand.accent.withValues(alpha: 0.09)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? AppSpace.lg : AppSpace.xl,
                vertical: AppSpace.md,
              ),
              child: Row(
                children: <Widget>[
                  if (lead != null) ...<Widget>[
                    lead,
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
                  if (info != null) InfoHint(title: infoTitle ?? title, body: info!),
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

/// The small rounded icon square at the start of a settings row.
class DsIconTile extends StatelessWidget {
  const DsIconTile(this.icon, {super.key, this.color, this.decorative = false});

  final IconData icon;
  final Color? color;

  /// Purely decorative: compact rows may leave it out.
  final bool decorative;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? BrandTheme.of(context).accentInk;
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
}

/// A settings row: title, at most one short line, optional (i) with the long text. Same widget as [DsListRow].
typedef SettingRow = DsListRow;

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
