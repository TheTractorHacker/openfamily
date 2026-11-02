import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A compact family-name control at the top of the map.
///
/// With one family it is simply contextual information plus a small join
/// action; rendering a full segmented control when there is nothing to switch
/// makes the map header feel oversized and non-functional. If several families
/// are available, it grows into a switcher.
class CircleSwitcher extends StatelessWidget {
  const CircleSwitcher({
    super.key,
    required this.circles,
    required this.selectedIndex,
    required this.onSelected,
    this.onJoinCircle,
    this.alignment = Alignment.center,
  });

  final List<String> circles;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback? onJoinCircle;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    if (circles.length == 1) {
      return _SingleCircleContext(
        label: circles.single,
        onJoinCircle: onJoinCircle,
        alignment: alignment,
      );
    }

    return Align(
      alignment: alignment,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 10,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < circles.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              _CircleChip(
                label: circles[i],
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
            ],
            if (onJoinCircle != null) ...[
              const SizedBox(width: 4),
              _JoinChip(onTap: onJoinCircle!),
            ],
          ],
        ),
      ),
    );
  }
}

/// The single-family state is intentionally not a fake tab. The name tells
/// the user whose locations they are viewing, while the adjacent circular
/// affordance keeps joining another family available without competing with
/// the map or member drawer.
class _SingleCircleContext extends StatelessWidget {
  const _SingleCircleContext({
    required this.label,
    required this.alignment,
    this.onJoinCircle,
  });

  final String label;
  final VoidCallback? onJoinCircle;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The map reserves a right-hand rail for layer/location controls.
        // Let a long family name shrink inside the remaining width instead of
        // extending underneath those controls on a narrow screen.
        final double availableWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320;
        final double fixedWidth = onJoinCircle == null ? 54 : 106;
        final double labelWidth =
            (availableWidth - fixedWidth).clamp(64.0, 150.0).toDouble();

        return Align(
          alignment: alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: 'Current family: $label',
                child: Material(
                  color: BrandTheme.of(context).sheet,
                  borderRadius: BorderRadius.circular(22),
                  elevation: 3,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.group_outlined,
                          size: 19,
                          color: BrandTheme.of(context).accentInk,
                        ),
                        const SizedBox(width: 7),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: labelWidth),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (onJoinCircle != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Join a family',
                  child: Semantics(
                    button: true,
                    label: 'Join a family',
                    child: Material(
                      color: BrandTheme.of(context).sheet,
                      shape: const CircleBorder(),
                      elevation: 3,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onJoinCircle,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.add,
                            color: BrandTheme.of(context).accentInk,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CircleChip extends StatelessWidget {
  const _CircleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? BrandTheme.of(context).accent : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? BrandTheme.of(context).onAccent
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

/// A labeled "Join a family" chip that opens the join-family flow.
class _JoinChip extends StatelessWidget {
  const _JoinChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).accentInk.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 18, color: BrandTheme.of(context).accentInk),
            const SizedBox(width: 4),
            Text(
              'Join a family',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: BrandTheme.of(context).accentInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
