import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_avatar_bubble.dart';
import 'circles_screen.dart';
import 'invite_screen.dart';
import 'places_screen.dart';
import 'profile_screen.dart';
import 'security_screen.dart';
import 'settings_screen.dart';

/// The Circle tab: you, your circles, people, places and settings.
class CircleTabScreen extends StatelessWidget {
  const CircleTabScreen({
    super.key,
    required this.members,
    required this.userId,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circle'),
        centerTitle: false,
        titleTextStyle: AppType.title.copyWith(color: cs.onSurface),
      ),
      body: ListView(
        children: <Widget>[
          ValueListenableBuilder<String?>(
            valueListenable: userId,
            builder: (BuildContext context, String? me, _) {
              return ValueListenableBuilder<List<Member>>(
                valueListenable: members,
                builder: (BuildContext context, List<Member> all, _) {
                  Member? self;
                  for (final Member m in all) {
                    if (m.id == me) self = m;
                  }
                  return DsListRow(
                    title: self?.name ?? 'My profile',
                    subtitle: 'Photo, name, phone and password',
                    leading: self == null
                        ? DsListRow.iconTile(context, Icons.person_outline)
                        : StatusAvatar(member: self, size: 48),
                    chevron: true,
                    onTap: () => _push(context, const ProfileScreen()),
                  );
                },
              );
            },
          ),
          const DsSectionHeader('Your circle'),
          DsListRow(
            title: 'Circles',
            subtitle: 'Create, join and manage circles',
            leading: DsListRow.iconTile(context, Icons.groups_outlined),
            chevron: true,
            onTap: () => _push(context, const CirclesScreen()),
          ),
          DsListRow(
            title: 'Invite people',
            subtitle: 'Share a code to add someone',
            leading: DsListRow.iconTile(
              context,
              Icons.person_add_alt_1_outlined,
            ),
            chevron: true,
            onTap: () => _push(context, const InviteScreen()),
          ),
          DsListRow(
            title: 'Places',
            subtitle: 'Home, school, work and arrival alerts',
            leading: DsListRow.iconTile(context, Icons.place_outlined),
            chevron: true,
            onTap: () => _push(context, const PlacesScreen()),
          ),
          const DsSectionHeader('Account'),
          DsListRow(
            title: 'Security',
            subtitle: 'Two-factor, sessions, password, your data',
            leading: DsListRow.iconTile(context, Icons.shield_outlined),
            chevron: true,
            onTap: () => _push(context, const SecurityScreen()),
          ),
          DsListRow(
            title: 'Settings',
            subtitle: 'Location, notifications, appearance',
            leading: DsListRow.iconTile(context, Icons.settings_outlined),
            chevron: true,
            onTap: () => _push(context, const SettingsScreen()),
          ),
          const SizedBox(height: AppSpace.xxl),
        ],
      ),
    );
  }
}
