import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'body.dart';
import 'info_hint.dart';

/// The side inset of rows and section text, shared by a [DsRowGroup] (its rows)
/// and a [DsSettingsList] (the headers and footnotes between the groups), so
/// a header, a row's icon tile and a footnote all start on one left edge.
/// Outside both, rows keep their old full-bleed gutter.
class DsRowScope extends InheritedWidget {
  const DsRowScope({super.key, required this.inset, required super.child});

  /// Distance from the group (card) edge to the row content.
  final double inset;

  static DsRowScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DsRowScope>();

  /// 16 dp, 12 dp on a narrow screen or at large text.
  static double insetFor(BuildContext context) => DsListRow.compactFor(context) ? AppSpace.md : AppSpace.lg;

  @override
  bool updateShouldNotify(DsRowScope old) => inset != old.inset;
}

/// Joins the short facts of a row's second line with a middle dot, skipping empty ones:
/// `dsMeta(['2 people', 'Admin'])` is "2 people · Admin". Keep it to two or three parts
/// that fit one line at normal text size.
String dsMeta(Iterable<String?> parts) =>
    parts.whereType<String>().where((String p) => p.trim().isNotEmpty).join(' \u00B7 ');

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
    this.checked,
    this.info,
    this.infoTitle,
  });

  /// Longer explanation, shown in a bottom sheet from a small (i) button. Keeps [subtitle] to one short line.
  final String? info;

  /// Sheet title; defaults to [title].
  final String? infoTitle;

  /// Non-null makes the row one option of a mutually exclusive group (a radio): the value is whether it is chosen.
  final bool? checked;

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
    final double inset = DsRowScope.maybeOf(context)?.inset ?? (compact ? AppSpace.lg : AppSpace.xl);
    final Widget? lead = compact && leading is DsIconTile && (leading as DsIconTile).decorative ? null : leading;
    return Semantics(
      button: onTap != null,
      selected: selected,
      checked: checked,
      inMutuallyExclusiveGroup: checked == null ? null : true,
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
                horizontal: inset,
                // The 48 dp (i) button sets the row height; less padding then keeps a row with an
                // (i) as tall as its neighbours without one.
                vertical: info != null ? AppSpace.sm : AppSpace.md,
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

/// Rounded card that groups [DsListRow]s with hairline dividers. Sits on the page
/// gutter (see [DsSettingsList]); its rows use [DsRowScope.insetFor] so every
/// row inside starts on the same left edge.
class DsRowGroup extends StatelessWidget {
  const DsRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double inset = DsRowScope.insetFor(context);
    return DsRowScope(
      inset: inset,
      child: Material(
        color: BrandTheme.of(context).sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) Divider(height: 1, indent: inset, color: cs.outlineVariant),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One option of a "pick one" group of rows: a radio mark, the option's name, at most one
/// short line under it and, for the long explanation, the (i) [info] sheet. Put several in a
/// [DsRowGroup]. The chosen row shows the filled mark AND is announced as checked; there is no
/// heavy coloured card around it. A null [onTap] disables the row (read-only).
class DsRadioRow extends StatelessWidget {
  const DsRadioRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.info,
    this.infoTitle,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final String? info;
  final String? infoTitle;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DsListRow(
      title: title,
      subtitle: subtitle,
      checked: selected,
      selected: selected,
      wash: false,
      onTap: onTap,
      info: info,
      infoTitle: infoTitle,
      leading: ExcludeSemantics(
        child: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 24,
          // Read-only (null onTap): a quieter mark, no offscreen layer.
          color: selected && onTap != null ? brand.accentInk : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Page body for a settings-style screen: a readable-width scrolling list on the page
/// gutter (16 dp, 12 dp when narrow) holding [DsSectionHeader]s, [DsRowGroup]s, [DsFootnote]s
/// and the odd note. One left edge for all of them. Replaces `ListView(padding: all(20))`.
class DsSettingsList extends StatelessWidget {
  const DsSettingsList({super.key, required this.children, this.listKey, this.controller, this.physics});

  final List<Widget> children;
  final Key? listKey;
  final ScrollController? controller;

  /// For a pull-to-refresh page that must scroll even when short (`AlwaysScrollableScrollPhysics`).
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final double gutter = DsListRow.compactFor(context) ? AppSpace.md : AppSpace.lg;
    return DsBody(
      child: DsRowScope(
        inset: DsRowScope.insetFor(context),
        child: ListView(
          key: listKey,
          controller: controller,
          physics: physics,
          padding: EdgeInsets.fromLTRB(gutter, AppSpace.sm, gutter, AppSpace.xxl),
          children: children,
        ),
      ),
    );
  }
}
