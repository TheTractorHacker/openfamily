import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/utils/family_pulse.dart';

import '../support/location_fixtures.dart';

void main() {
  final DateTime now = DateTime(2026, 11, 12, 15);
  Member quiet(String name, {Duration? ago}) => Member(
        id: name,
        name: '$name Foley',
        position: kAtHome.position,
        status: MemberStatus.stopped,
        batteryPercent: 50,
        address: 'x',
        lastSeen: ago == null ? null : now.subtract(ago),
      );

  test('alone in the circle: no pulse, the pill keeps its plain line', () {
    expect(familyPulse(<Member>[kSelf], selfId: 'me', now: now), isNull);
  });

  test('everyone fine', () {
    final FamilyPulse p =
        familyPulse(<Member>[kSelf, kAtHome, kAtHome.copyWith(name: 'Sam Roe')], selfId: 'me', now: now)!;
    expect(p.text, 'Everyone is up to date');
    expect(p.needsAttention, isFalse);
    expect(familyPulse(<Member>[kSelf, kAtHome], selfId: 'me', now: now)!.text,
        'Maya is up to date');
  });

  test('a quiet phone says who and for how long, and asks for attention', () {
    final FamilyPulse p = familyPulse(
        <Member>[kSelf, quiet('Maya', ago: const Duration(minutes: 40))],
        selfId: 'me', now: now)!;
    expect(p.text, 'Maya quiet 40 min');
    expect(p.needsAttention, isTrue);
  });

  test('quiet comes first, then driving; many collapse to counts', () {
    final FamilyPulse p = familyPulse(<Member>[
      kSelf,
      quiet('Maya', ago: const Duration(hours: 2)),
      kDriver,
    ], selfId: 'me', now: now)!;
    expect(p.text, 'Maya quiet 2 h · Sam driving');
    expect(
        familyPulse(<Member>[kSelf, quiet('A'), quiet('B')], selfId: 'me', now: now)!.text,
        'A, B quiet');
    expect(
        familyPulse(<Member>[kSelf, quiet('A'), quiet('B'), quiet('C')], selfId: 'me', now: now)!.text,
        '3 quiet');
  });

  test('my own silence is not the family pulse', () {
    final FamilyPulse p = familyPulse(
        <Member>[kSelf.copyWith(status: MemberStatus.stopped), kAtHome],
        selfId: 'me', now: now)!;
    expect(p.needsAttention, isFalse);
  });
}
