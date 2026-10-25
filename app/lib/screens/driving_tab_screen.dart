import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../utils/member_status.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_avatar_bubble.dart';
import 'trips_screen.dart';

/// The Driving tab: who is driving right now, and a door into each person's
/// trips and driving report (the existing [TripsScreen]).
class DrivingTabScreen extends StatelessWidget {
  const DrivingTabScreen({
    super.key,
    required this.members,
    required this.userId,
    this.tripsApi,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;
  final TripsApi? tripsApi;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driving'),
        centerTitle: false,
        titleTextStyle: AppType.title.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      body: ValueListenableBuilder<String?>(
        valueListenable: userId,
        builder: (BuildContext context, String? me, _) {
          return ValueListenableBuilder<List<Member>>(
            valueListenable: members,
            builder: (BuildContext context, List<Member> all, _) {
              if (all.isEmpty) {
                return const DsEmptyState(
                  icon: Icons.directions_car_outlined,
                  title: 'No drivers yet',
                  message:
                      'Trips and driving reports appear here once '
                      'people in your circle share their location.',
                );
              }
              final List<Member> sorted = <Member>[
                ...all.where((Member m) => m.id == me),
                ...all.where((Member m) => m.id != me),
              ];
              final List<Member> driving = sorted
                  .where((Member m) => m.movement == MovementType.car)
                  .toList();
              return ListView(
                children: <Widget>[
                  if (driving.isNotEmpty) ...<Widget>[
                    const DsSectionHeader('Driving now'),
                    for (final Member m in driving) _row(context, m, me),
                  ],
                  const DsSectionHeader('Trips and reports'),
                  for (final Member m in sorted) _row(context, m, me),
                  const SizedBox(height: AppSpace.xxl),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, Member m, String? me) {
    final bool self = m.id == me;
    final Member shown = self ? m.copyWith(name: 'You') : m;
    final bool driving = m.movement == MovementType.car;
    return DsListRow(
      title: shown.name,
      subtitle: driving ? memberStatusLine(m) : 'Not driving',
      leading: StatusAvatar(member: shown, size: 44),
      trailing: driving
          ? DsStatusChip(
              label: m.isSpeeding ? 'Fast' : 'On the road',
              icon: Icons.directions_car,
              color: m.isSpeeding
                  ? AppColors.statusOrange
                  : AppColors.statusGreen,
            )
          : null,
      chevron: true,
      semanticLabel: 'Trips and driving report for ${shown.name}',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TripsScreen(member: m, api: tripsApi),
        ),
      ),
    );
  }
}
