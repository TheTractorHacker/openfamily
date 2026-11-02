import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import 'member_avatar_bubble.dart';
import 'member_tile.dart';

/// The member drawer that lives above the map's persistent action bar.
///
/// Its compact, always-visible header is a calm "People" rail. The entire
/// surface is one [CustomScrollView] attached to the controller supplied by
/// [DraggableScrollableSheet], including the header. This is important: it
/// means the drawer can be expanded from the header even when there is only
/// one person (or no scrollable member rows yet).
class MemberListSheet extends StatelessWidget {
  const MemberListSheet({
    super.key,
    required this.scrollController,
    required this.circleName,
    required this.members,
    required this.onMemberTap,
    required this.onAddPerson,
    required this.onToggle,
    required this.expanded,
  });

  final ScrollController scrollController;
  final String circleName;
  final List<Member> members;
  final ValueChanged<Member> onMemberTap;
  final VoidCallback onAddPerson;
  final VoidCallback onToggle;
  final bool expanded;

  /// The pinned header's height. It grows with the user's text scaling so the
  /// two-line People label and its 48px actions never clip at large type.
  static double compactRailHeight(BuildContext context) {
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final double textHeight =
        textScaler.scale(16) * 1.3 + textScaler.scale(12) * 1.3;
    final double rowHeight = textHeight > 48 ? textHeight : 48;
    // Handle (20) + row's bottom gap (8) + the accessible header row.
    return 28 + rowHeight;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // Quiet Ice / Night paper. Lime stays on actions, not this sheet.
        color: BrandTheme.of(context).sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 16,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: CustomScrollView(
          controller: scrollController,
          // With one member the list itself has no scroll extent. Always
          // scrollable physics still hands an upward drag to the enclosing
          // DraggableScrollableSheet, making the drawer reliably swipeable.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _PeopleHeaderDelegate(
                extent: compactRailHeight(context),
                child: _PeopleHeader(
                  circleName: circleName,
                  members: members,
                  expanded: expanded,
                  onToggle: onToggle,
                  onAddPerson: onAddPerson,
                ),
              ),
            ),
            // Keep the collapsed rail intentionally quiet: member rows only
            // enter once the drawer has left its compact state, so a partial
            // row never peeks out beneath the header.
            if (expanded && members.isEmpty)
              const SliverToBoxAdapter(child: _EmptyMemberList())
            else if (expanded)
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index.isOdd) {
                    return const Divider(
                      height: 1,
                      indent: 76,
                      color: Color(0x11000000),
                    );
                  }
                  final Member member = members[index ~/ 2];
                  return MemberTile(
                    member: member,
                    onTap: () => onMemberTap(member),
                  );
                }, childCount: members.length * 2 - 1),
              ),
            if (expanded) const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }
}

/// Compact, explicit entry point for the member drawer. It is still part of
/// the scroll view, so a vertical drag from anywhere in this rail can grow the
/// sheet; tapping its title or chevron is a reliable non-gesture alternative.
class _PeopleHeader extends StatelessWidget {
  const _PeopleHeader({
    required this.circleName,
    required this.members,
    required this.expanded,
    required this.onToggle,
    required this.onAddPerson,
  });

  final String circleName;
  final List<Member> members;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onAddPerson;

  @override
  Widget build(BuildContext context) {
    final String countLabel =
        '${members.length} ${members.length == 1 ? 'member' : 'members'}';
    final String stateLabel = expanded ? 'expanded' : 'collapsed';

    return SizedBox(
      height: MemberListSheet.compactRailHeight(context),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: '$circleName people, $countLabel, $stateLabel',
                      hint: expanded
                          ? 'Double tap to collapse the people drawer'
                          : 'Double tap to expand the people drawer',
                      child: InkWell(
                        onTap: onToggle,
                        borderRadius: BorderRadius.circular(16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              _AvatarStack(members: members),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'People',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      countLabel,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onAddPerson,
                    tooltip: 'Invite someone to $circleName',
                    icon: Icon(
                      Icons.person_add_alt_1,
                      color: BrandTheme.of(context).accentInk,
                    ),
                  ),
                  IconButton(
                    onPressed: onToggle,
                    tooltip: expanded ? 'Collapse people' : 'Expand people',
                    icon: Icon(
                      expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: BrandTheme.of(context).accentInk,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps People and Invite visible while the member rows scroll underneath.
class _PeopleHeaderDelegate extends SliverPersistentHeaderDelegate {
  _PeopleHeaderDelegate({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(color: BrandTheme.of(context).sheet, child: child);
  }

  @override
  bool shouldRebuild(covariant _PeopleHeaderDelegate oldDelegate) {
    return extent != oldDelegate.extent || child != oldDelegate.child;
  }
}

/// A compact, overlapping snapshot of up to three members. The identities are
/// visible without repeating the family name or creating a separate avatar bar.
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({required this.members});

  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: BrandTheme.of(context).accent.withValues(alpha: 0.10),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.people_alt_outlined,
          size: 21,
          color: BrandTheme.of(context).accentInk,
        ),
      );
    }

    final List<Member> visibleMembers = members.take(3).toList();
    const double avatarSize = 40;
    const double overlap = 13;
    final double stackWidth =
        avatarSize + (visibleMembers.length - 1) * (avatarSize - overlap);

    return SizedBox(
      width: stackWidth,
      height: avatarSize,
      child: Stack(
        children: [
          for (int index = 0; index < visibleMembers.length; index++)
            Positioned(
              left: index * (avatarSize - overlap),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: BrandTheme.of(context).sheet,
                  shape: BoxShape.circle,
                ),
                child: StatusAvatar(member: visibleMembers[index], size: 36),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyMemberList extends StatelessWidget {
  const _EmptyMemberList();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Text(
        'Invite someone to see them on your map.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
