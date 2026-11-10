import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Status chips ([DsStatusChip], a private-circle badge...) laid out the one way: start-aligned
/// on the page gutter, 8 dp apart both ways, wrapping onto a second line at large text.
/// Never a chip sitting alone against the screen edge or centred under a left-aligned title.
/// The caller supplies the gutter (a [DsSettingsList] or page padding); this adds none.
///
/// Leave a chip out when the same fact is already shown nearby (the circle pill already says
/// "Location sharing: on").
class DsChipRow extends StatelessWidget {
  const DsChipRow({super.key, required this.children, this.alignment = WrapAlignment.start});

  final List<Widget> children;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: alignment,
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
