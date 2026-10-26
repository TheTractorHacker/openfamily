import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Small caps section label used above grouped list rows.
class DsSectionHeader extends StatelessWidget {
  const DsSectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpace.xl,
      AppSpace.xl,
      AppSpace.xl,
      AppSpace.xs,
    ),
  });

  /// Defaults to the list-row gutter; pass less inside a [DsPage].
  final EdgeInsetsGeometry padding;

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: padding,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: AppType.label.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
