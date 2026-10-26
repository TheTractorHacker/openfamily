import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'create_circle_screen.dart';
import 'join_circle_screen.dart';
import 'app_shell.dart';

/// Onboarding step: create a new family or join an existing one with an
/// invite code.
class CreateOrJoinCircleScreen extends StatelessWidget {
  const CreateOrJoinCircleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Your family',
      showBack: false,
      step: 3,
      children: <Widget>[
        const DsHeading(
          'Create or join a family',
          subtitle:
              'A family is the group of people you share your location with.',
        ),
        DsOptionCard(
          icon: Icons.add,
          title: 'Create a new family',
          subtitle: 'Start a new family to share locations.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const CreateCircleScreen(),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        DsOptionCard(
          icon: Icons.group_add_outlined,
          title: 'Join a family',
          subtitle: 'Enter an invite code from a family member.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => JoinCircleScreen(
                step: 4,
                onDone: () => Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute<void>(builder: (_) => const AppShell()),
                  (route) => false,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
