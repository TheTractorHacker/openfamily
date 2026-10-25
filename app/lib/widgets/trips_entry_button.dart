import 'package:flutter/material.dart';

import '../models/member.dart';
import '../screens/trips_screen.dart';

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
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Trips and driving reports for ${member.name}',
      excludeSemantics: true,
      child: Material(
        color: Theme.of(context).cardColor.withValues(alpha: 0),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => openTrips(context, member),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.route_rounded, color: cs.onSurface),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Trips & driving',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
