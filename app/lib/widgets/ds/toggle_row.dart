import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'list_row.dart';

/// A list row with a trailing [Switch]. The whole row toggles.
class DsToggleRow extends StatelessWidget {
  const DsToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.subtitleColor,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;

  /// Null disables the row.
  final ValueChanged<bool>? onChanged;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ValueChanged<bool>? cb = onChanged;
    return Semantics(
      toggled: value,
      enabled: cb != null,
      label: title,
      container: true,
      child: MergeSemantics(
        child: Opacity(
          opacity: cb == null ? 0.6 : 1,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: cb == null ? null : () => cb(!value),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.xl,
                    vertical: AppSpace.sm,
                  ),
                  child: Row(
                    children: <Widget>[
                      if (icon != null) ...<Widget>[
                        DsListRow.iconTile(context, icon!),
                        const SizedBox(width: AppSpace.md),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(title, style: AppType.body),
                            if (subtitle != null) ...<Widget>[
                              const SizedBox(height: AppSpace.xxs),
                              Text(
                                subtitle!,
                                style: AppType.secondary.copyWith(
                                  color: subtitleColor ?? cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Switch(value: value, onChanged: cb),
                    ],
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
