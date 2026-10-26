import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'list_row.dart';

/// One option of a [DsChoiceSetting].
class DsChoice<T> {
  const DsChoice(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// Settings block that picks one of a few values: title, a calm description
/// of the current choice, then the options.
///
/// Normally a segmented control. At large text (over 130%) the segments would
/// squeeze their labels, so the options become full-width rows instead, with
/// a check mark AND the label marking the selected one.
class DsChoiceSetting<T> extends StatelessWidget {
  const DsChoiceSetting({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.description,
  });

  final String title;
  final String? description;
  final List<DsChoice<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool large = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.sm,
        AppSpace.xl,
        AppSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(header: true, child: Text(title, style: AppType.body)),
          if (description != null) ...<Widget>[
            const SizedBox(height: AppSpace.xs),
            Text(
              description!,
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          if (large)
            DsRowGroup(
              children: <Widget>[
                for (final DsChoice<T> o in options)
                  DsListRow(
                    title: o.label,
                    selected: o.value == selected,
                    leading: o.icon == null
                        ? null
                        : DsListRow.iconTile(context, o.icon!),
                    trailing: o.value == selected
                        ? const Icon(Icons.check, semanticLabel: 'Selected')
                        : null,
                    onTap: () => onChanged(o.value),
                  ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<T>(
                showSelectedIcon: false,
                segments: <ButtonSegment<T>>[
                  for (final DsChoice<T> o in options)
                    ButtonSegment<T>(
                      value: o.value,
                      label: Text(o.label),
                      icon: o.icon == null ? null : Icon(o.icon, size: 18),
                    ),
                ],
                selected: <T>{selected},
                onSelectionChanged: (Set<T> next) {
                  if (next.isEmpty) return;
                  onChanged(next.first);
                },
              ),
            ),
        ],
      ),
    );
  }
}
