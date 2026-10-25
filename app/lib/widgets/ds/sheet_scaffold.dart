import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The grab handle shown at the top of every bottom sheet.
class DsDragHandle extends StatelessWidget {
  const DsDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        width: 40,
        height: 5,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
    );
  }
}

/// Rounded bottom-sheet surface with a drag handle, optional title and a
/// body. Use directly inside `showModalBottomSheet`, or wrap a scrolling
/// body with the controller from a `DraggableScrollableSheet`.
class DsSheetScaffold extends StatelessWidget {
  const DsSheetScaffold({
    super.key,
    required this.child,
    this.title,
    this.header,
  });

  final String? title;

  /// Extra pinned content under the handle (tabs, search).
  final Widget? header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BrandTheme.of(context).sheet,
      elevation: 8,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheet),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(label: 'Drag handle', child: const DsDragHandle()),
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.xs,
                AppSpace.xl,
                AppSpace.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Semantics(
                  header: true,
                  child: Text(title!, style: AppType.headline),
                ),
              ),
            ),
          if (header != null) header!,
          Flexible(child: child),
        ],
      ),
    );
  }
}
