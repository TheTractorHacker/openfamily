import 'package:flutter/material.dart';

import '../models/member.dart';
import '../screens/trips_screen.dart';
import 'ds/ds.dart';

void openTrips(BuildContext context, Member member) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => TripsScreen(member: member)),
  );
}

/// Row used on the member profile to open the member's trips.
class TripsEntryButton extends StatelessWidget {
  const TripsEntryButton({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.route_rounded),
      title: 'Trips & driving',
      subtitle: 'Drives and driving reports',
      chevron: true,
      semanticLabel: 'Trips and driving reports for ${member.name}',
      onTap: () => openTrips(context, member),
    );
  }
}

/// App-bar shortcut from the day detail screen.
class TripsAppBarAction extends StatelessWidget {
  const TripsAppBarAction({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Trips',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: const Icon(Icons.route_rounded),
      onPressed: () => openTrips(context, member),
    );
  }
}
