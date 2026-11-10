import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'list_row.dart';

/// Small caps section label used above grouped list rows.
///
/// Keep the title to a short noun phrase (1 to 3 words, no question mark: "Members", "Default").
/// One calm line of context goes in [caption] (shown under the label in the normal
/// sentence case); anything longer belongs behind an (i) on the row it explains.
///
/// With no [padding] the header lines up with the rows of the [DsRowGroup] below it when it
/// sits in a [DsSettingsList], and keeps the old full-bleed gutter elsewhere.
class DsSectionHeader extends StatelessWidget {
  const DsSectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.caption,
    this.padding,
  });

  /// Overrides the automatic gutter (pass less inside a [DsPage]).
  final EdgeInsetsGeometry? padding;

  final String title;
  final Widget? trailing;

  /// One short supporting line under the label.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final DsRowScope? scope = DsRowScope.maybeOf(context);
    final EdgeInsetsGeometry pad = padding ??
        (scope == null
            ? const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.xs)
            : EdgeInsets.fromLTRB(scope.inset, AppSpace.xxl, scope.inset, AppSpace.sm));
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: AppType.label.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          if (caption != null) ...<Widget>[
            const SizedBox(height: AppSpace.xxs),
            Text(caption!, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

/// A quiet note under a group: secondary type, muted, on the same left edge as the section
/// headers (inside a [DsSettingsList]). Two or three lines at most; longer text goes behind an (i).
class DsFootnote extends StatelessWidget {
  const DsFootnote(this.text, {super.key, this.padding, this.icon});

  final String text;
  final EdgeInsetsGeometry? padding;

  /// Optional small leading icon (info, lock).
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final DsRowScope? scope = DsRowScope.maybeOf(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget label = Text(text, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant));
    return Padding(
      padding: padding ??
          (scope == null
              ? const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.sm)
              : EdgeInsets.fromLTRB(scope.inset, AppSpace.sm, scope.inset, AppSpace.sm)),
      child: icon == null
          ? label
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 16, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: label),
              ],
            ),
    );
  }
}
