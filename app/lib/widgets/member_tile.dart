import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import 'member_avatar_bubble.dart';
import 'movement_icon.dart';

/// A single member rendered as a rich list row — the roster entry shared by
/// every surface that lists family members (the dedicated People screen).
///
/// Shows the member's avatar, name, and distinct glanceable status chips
/// (battery %, ETA, driving speed), the current address, and a movement badge.
/// Tapping the tile invokes [onTap] (e.g. to open the member's profile).
class MemberTile extends StatelessWidget {
  const MemberTile({super.key, required this.member, required this.onTap});

  final Member member;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: AppSpace.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusAvatar(member: member, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.name,
                    style: AppType.body,
                  ),
                  const SizedBox(height: 4),
                  // Distinct glanceable fields: battery %, ETA, speed — each
                  // its own chip, never collapsed into one ellipsized line.
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: _statusChips(),
                  ),
                  const SizedBox(height: 4),
                  // Address on its own line.
                  Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          member.position == null
                              ? 'No location yet'
                              : member.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (member.movement != MovementType.none) ...[
              const SizedBox(width: 8),
              MovementIcon(movement: member.movement, size: 20),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the distinct status chips: battery %, ETA, and driving speed.
  List<Widget> _statusChips() {
    final List<Widget> chips = <Widget>[];

    if (member.batteryPercent > 0) {
      chips.add(
        _StatusChip(
          icon: _batteryIcon(),
          color: _batteryColor(),
          label: '${member.batteryPercent}%',
        ),
      );
    } else if (member.status == MemberStatus.stopped) {
      chips.add(
        const _StatusChip(
          icon: Icons.battery_unknown,
          color: AppColors.statusGrey,
          label: 'Offline',
        ),
      );
    }

    if (member.eta != null) {
      chips.add(
        _StatusChip(
          icon: Icons.schedule,
          color: AppColors.purple,
          label: 'ETA ${member.eta}',
        ),
      );
    }

    if (member.movement == MovementType.car && member.speedMph != null) {
      chips.add(
        _StatusChip(
          icon: Icons.directions_car,
          color: member.isSpeeding ? const Color(0xFFE65100) : AppColors.purple,
          label: '${member.speedMph} mph',
        ),
      );
    }

    return chips;
  }

  IconData _batteryIcon() {
    if (member.batteryPercent <= 20) return Icons.battery_1_bar;
    if (member.batteryPercent <= 50) return Icons.battery_3_bar;
    if (member.batteryPercent <= 80) return Icons.battery_5_bar;
    return Icons.battery_full;
  }

  Color _batteryColor() {
    if (member.batteryPercent <= 20) return AppColors.statusRed;
    if (member.batteryPercent <= 50) return AppColors.statusOrange;
    return AppColors.statusGreen;
  }
}

/// A small pill chip showing one glanceable status field (battery %, ETA,
/// speed) with a leading icon, so each field stays visually distinct.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    this.color = AppColors.purple,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color foreground = dark && color == AppColors.statusGrey
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.28 : 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
