import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import 'member_avatar_bubble.dart';

/// Overlapping member avatars in a slim strip below the Driving page's scroll
/// view (in flow, so it never covers a card). Tapping one opens that member's
/// trips.
class DrivingMemberDock extends StatelessWidget {
  const DrivingMemberDock({
    super.key,
    required this.members,
    required this.onTap,
  });

  final List<Member> members;
  final ValueChanged<Member> onTap;

  static const double _slot = kMinTarget;
  static const double _step = 34;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color ring = BrandTheme.of(context).sheet;
    final List<Member> shown = members.take(6).toList();
    final double width = _slot + (shown.length - 1) * _step;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gutter,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: BrandTheme.of(context).sheet,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(children: <Widget>[
        SizedBox(
      width: width,
      height: _slot,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (int i = 0; i < shown.length; i++)
            Positioned(
              left: i * _step,
              top: 0,
              child: Semantics(
                button: true,
                label: 'Open ${shown[i].name} driving',
                excludeSemantics: true,
                onTap: () => onTap(shown[i]),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(shown[i]),
                  child: Container(
                    width: _slot,
                    height: _slot,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: ring,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: dark ? 0.4 : 0.18),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: StatusAvatar(member: shown[i], size: _slot - 4),
                  ),
                ),
              ),
            ),
        ],
      ),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Text(
            'Open a driver',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}
