import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_tile.dart';
import 'invite_screen.dart';
import 'member_profile_screen.dart';

/// The dedicated, full-screen home for a family's members.
///
/// This is the replacement for the old map drawer: a proper [Scaffold] with an
/// app bar (mirroring Places / Safety), reached from the map's bottom
/// action bar. It shows the live member roster — the same rich `MemberTile`
/// rows the drawer used — plus an Invite action and a tap-through to each
/// member's profile.
///
/// The list is driven by a [ValueListenable] so status chips (battery, ETA,
/// movement) stay live while the screen is open, fed by the map screen's
/// single WebSocket subscription rather than a second connection.
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({
    super.key,
    required this.circleName,
    required this.members,
    this.onInvite,
  });

  /// The family name, shown in the roster header.
  final String circleName;

  /// Live family members from the map screen's single family subscription.
  final ValueListenable<List<Member>> members;

  /// Optionally override the invite action (used by tests). Defaults to
  /// pushing the standard [InviteScreen].
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          IconButton(
            onPressed: _invite(context),
            tooltip: 'Invite someone',
            constraints: const BoxConstraints(
              minWidth: kMinTarget,
              minHeight: kMinTarget,
            ),
            icon: Icon(
              Icons.person_add_alt_1,
              color: BrandTheme.of(context).accentInk,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<Member>>(
          valueListenable: members,
          builder: (context, roster, _) {
            if (roster.isEmpty) {
              return DsEmptyState(
                icon: Icons.people_alt_outlined,
                title: 'No one is in $circleName yet',
                message: 'Invite family to share their location and see them '
                    'on your map.',
                actionLabel: 'Invite someone',
                onAction: _invite(context),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.only(
                top: AppSpace.xs,
                bottom: AppSpace.xxl,
              ),
              itemCount: roster.length + 1,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                indent: 76,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              itemBuilder: (context, index) {
                // Row 0 is the roster header; the rest are members.
                if (index == 0) {
                  return _RosterHeader(
                    circleName: circleName,
                    count: roster.length,
                  );
                }
                final Member member = roster[index - 1];
                return MemberTile(
                  member: member,
                  onTap: () => _openMember(context, member),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// The invite callback: the injected override wins, otherwise push the
  /// standard Invite flow.
  VoidCallback _invite(BuildContext context) {
    final VoidCallback? override = onInvite;
    if (override != null) return override;
    return () {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => InviteScreen(circleName: circleName),
        ),
      );
    };
  }

  void _openMember(BuildContext context, Member member) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(member: member),
      ),
    );
  }
}

/// The roster header: which family is shown and how many members it has.
class _RosterHeader extends StatelessWidget {
  const _RosterHeader({required this.circleName, required this.count});

  final String circleName;
  final int count;

  @override
  Widget build(BuildContext context) {
    final String countLabel = '$count ${count == 1 ? 'member' : 'members'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.md,
        AppSpace.xl,
        AppSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            circleName,
            style: AppType.secondary.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.xxs),
          Semantics(
            header: true,
            child: Text(countLabel, style: AppType.headline),
          ),
        ],
      ),
    );
  }
}
