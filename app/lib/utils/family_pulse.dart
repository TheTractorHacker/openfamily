import '../models/member.dart';
import '../services/driving_presence.dart';
import 'member_status.dart';

/// The one line under the circle name on the map: how the people in the circle are doing
/// right now, so "is everyone OK?" is answered without opening anyone's panel.
///
/// It replaces the old static "Location sharing: on" (same space, more information).
/// [needsAttention] is true when someone's phone has gone quiet; the pill paints it amber.
class FamilyPulse {
  const FamilyPulse(this.text, {this.needsAttention = false});

  final String text;
  final bool needsAttention;
}

/// Null when nobody else is in the circle (the caller keeps the plain sharing line).
FamilyPulse? familyPulse(
  List<Member> members, {
  String? selfId,
  DateTime? now,
}) {
  final DateTime n = now ?? DateTime.now();
  final List<Member> others =
      members.where((Member m) => m.id != selfId).toList(growable: false);
  if (others.isEmpty) return null;

  final List<Member> quiet = <Member>[];
  final List<Member> driving = <Member>[];
  for (final Member m in others) {
    if (m.status == MemberStatus.stopped) {
      quiet.add(m);
    } else if (m.movement == MovementType.car &&
        m.drivingView(now: n).isDriving) {
      driving.add(m);
    }
  }

  String first(Member m) => m.name.split(' ').first;
  final List<String> parts = <String>[];
  if (quiet.length == 1) {
    final DateTime? seen = quiet.first.lastSeen;
    final String age = seen == null
        ? ''
        : ' ${lastSeenAgo(seen, n).replaceFirst(' ago', '')}';
    parts.add(seen == null || n.difference(seen).inMinutes < 1
        ? '${first(quiet.first)} quiet'
        : '${first(quiet.first)} quiet$age');
  } else if (quiet.length == 2) {
    parts.add('${first(quiet[0])}, ${first(quiet[1])} quiet');
  } else if (quiet.length > 2) {
    parts.add('${quiet.length} quiet');
  }
  if (driving.length == 1) {
    parts.add('${first(driving.first)} driving');
  } else if (driving.length > 1) {
    parts.add('${driving.length} driving');
  }
  if (parts.isEmpty) {
    return FamilyPulse(
        others.length == 1 ? '${first(others.first)} is up to date' : 'Everyone is up to date');
  }
  return FamilyPulse(parts.join(' · '), needsAttention: quiet.isNotEmpty);
}
