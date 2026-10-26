import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'ds/status_chip.dart';
import 'member_avatar_bubble.dart';
import 'live_speed.dart';
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: AppSpace.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusAvatar(member: member, size: 44),
            const SizedBox(width: AppSpace.md),
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
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: _statusChips(context),
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
                          style: AppType.secondary.copyWith(
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
      ),
    );
  }

  /// Builds the distinct status chips: battery %, ETA, and driving speed.
  List<Widget> _statusChips(BuildContext context) {
    final Color accent = BrandTheme.of(context).accentInk;
    final List<Widget> chips = <Widget>[];

    if (member.batteryPercent > 0) {
      chips.add(
        DsStatusChip(
          icon: _batteryIcon(),
          color: _batteryColor(),
          label: '${member.batteryPercent}%',
        ),
      );
    } else if (member.status == MemberStatus.stopped) {
      chips.add(
        const DsStatusChip(
          icon: Icons.battery_unknown,
          color: AppColors.statusGrey,
          label: 'Offline',
        ),
      );
    }

    if (member.eta != null) {
      chips.add(
        DsStatusChip(
          icon: Icons.schedule,
          color: accent,
          label: 'ETA ${member.eta}',
        ),
      );
    }

    if (member.movement == MovementType.car && member.speedMps != null) {
      chips.add(
        LiveSpeedBuilder(
          member: member,
          builder: (BuildContext _, double? mps, UnitSystem units) =>
              DsStatusChip(
            icon: Icons.directions_car,
            color: isSpeedingMps(mps) ? AppColors.statusOrange : accent,
            label: speedText(mps, units) ?? '—',
          ),
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
