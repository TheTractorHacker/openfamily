import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/member_detail_screen.dart';
import 'package:openfamily/screens/people_screen.dart';

/// A member with no position so no FlutterMap preview is built in member
/// profile navigation tests (avoiding tile-network code paths).
const Member _frank = Member(
  id: 'frank',
  name: 'Frank',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 82,
  address: 'Home',
);

const Member _june = Member(
  id: 'june',
  name: 'June',
  position: null,
  status: MemberStatus.stopped,
  batteryPercent: 0,
  address: 'Work',
);

Widget _app(ValueNotifier<List<Member>> roster, {VoidCallback? onInvite}) {
  return MaterialApp(
    home: PeopleScreen(
      circleName: 'Frank Family',
      members: roster,
      onInvite: onInvite,
    ),
  );
}

void main() {
  testWidgets('renders the member roster header and each member row',
      (WidgetTester tester) async {
    final roster = ValueNotifier<List<Member>>(const [_frank, _june]);
    addTearDown(roster.dispose);

    await tester.pumpWidget(_app(roster));

    // Header shows the family name and member count.
    expect(find.text('Frank Family'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);

    // Both members are listed with their glanceable status chips. Their
    // address line falls back to the "no location yet" placeholder (both test
    // members have no position).
    expect(find.text('Frank'), findsOneWidget);
    expect(find.text('June'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget); // battery chip
    expect(find.text('Offline'), findsOneWidget); // stopped + no battery
    expect(find.text('No location yet'), findsNWidgets(2));

    // No runtime overflow / layout errors.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a member opens their detail screen', (
    WidgetTester tester,
  ) async {
    final roster = ValueNotifier<List<Member>>(const [_frank]);
    addTearDown(roster.dispose);

    await tester.pumpWidget(_app(roster));
    await tester.tap(find.text('Frank'));
    // The detail screen loads the day from the network; one frame is enough to
    // see the route pushed without waiting on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MemberDetailScreen), findsOneWidget);
  });

  testWidgets('empty roster shows an invite state that calls onInvite', (
    WidgetTester tester,
  ) async {
    final roster = ValueNotifier<List<Member>>(const []);
    addTearDown(roster.dispose);

    int invites = 0;
    await tester.pumpWidget(_app(roster, onInvite: () => invites++));

    expect(find.textContaining('No one is in'), findsOneWidget);
    await tester.ensureVisible(find.text('Invite someone'));
    await tester.tap(find.text('Invite someone'));
    await tester.pump();

    expect(invites, 1);
  });

  testWidgets('the app bar invite action triggers the invite callback', (
    WidgetTester tester,
  ) async {
    final roster = ValueNotifier<List<Member>>(const [_frank]);
    addTearDown(roster.dispose);

    int invites = 0;
    await tester.pumpWidget(_app(roster, onInvite: () => invites++));

    await tester.tap(find.byTooltip('Invite someone'));
    await tester.pump();

    expect(invites, 1);
  });

  testWidgets('roster reflects live member updates',
      (WidgetTester tester) async {
    final roster = ValueNotifier<List<Member>>(const [_frank]);
    addTearDown(roster.dispose);

    await tester.pumpWidget(_app(roster));
    expect(find.text('June'), findsNothing);

    roster.value = const [_frank, _june];
    await tester.pump();

    expect(find.text('June'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);
  });
}
