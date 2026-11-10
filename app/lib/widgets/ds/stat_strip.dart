import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One figure of a [DsStatStrip]: a value ("28 mi") and its label ("Distance").
class DsStat {
  const DsStat({required this.value, required this.label, this.semanticLabel});

  final String value;
  final String label;

  /// What a screen reader says when it differs from "label: value" (for example the long
  /// "Max GPS speed" behind the short visible "Top speed").
  final String? semanticLabel;
}

/// Figures side by side in EQUAL columns: the value on top (headline), the label under it
/// (secondary), everything on one left edge. Never a ragged wrap with a lone item.
///
/// How many columns it uses is decided by the room, not the item count:
///  * all items in one row when each column keeps at least [minColumnWidth] dp (scaled with
///    the text size);
///  * otherwise the most columns that still split the items into full rows (4 items: 2 + 2),
///    never leaving one item alone in the last row;
///  * and when that is not possible either (3 items on a folded phone's cover display, or at
///    large text) a compact list: label on the left, value on the right, one per line.
/// Each figure is one semantic node reading "label: value".
class DsStatStrip extends StatelessWidget {
  const DsStatStrip({super.key, required this.stats, this.minColumnWidth = 72});

  final List<DsStat> stats;

  /// Narrowest a column may get at normal text size before the strip regroups.
  final double minColumnWidth;

  /// The column count for [n] items in [width] dp where one column needs [minCol] dp.
  /// 1 means the stacked list. Exposed for tests.
  static int columnsFor(int n, double width, double minCol) {
    for (int c = n; c >= 2; c--) {
      if (width / c < minCol) continue;
      final int rest = n % c;
      if (rest == 0 || rest >= 2) return c;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    final double minCol = MediaQuery.textScalerOf(context).scale(minColumnWidth);
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
      final int cols = columnsFor(stats.length, box.maxWidth, minCol);
      if (cols == 1) return _stacked(context);
      final List<Widget> rows = <Widget>[];
      for (int i = 0; i < stats.length; i += cols) {
        if (i > 0) rows.add(const SizedBox(height: AppSpace.md));
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int j = i; j < i + cols; j++)
              Expanded(
                child: j < stats.length
                    ? Padding(padding: const EdgeInsets.only(right: AppSpace.sm), child: _cell(context, stats[j]))
                    : const SizedBox.shrink(),
              ),
          ],
        ));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    });
  }

  Widget _cell(BuildContext context, DsStat s) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: s.semanticLabel ?? '${s.label}: ${s.value}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(s.value, maxLines: 1, style: AppType.headline),
          ),
          Text(s.label, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _stacked(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < stats.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpace.sm),
            child: Semantics(
              container: true,
              label: stats[i].semanticLabel ?? '${stats[i].label}: ${stats[i].value}',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Expanded(
                    child: Text(stats[i].label, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text(stats[i].value, style: AppType.headline),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
