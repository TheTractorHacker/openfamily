import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/alert.dart';
import 'package:openfamily/models/bubble.dart';
import 'package:openfamily/models/inbox.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/inbox_screen.dart';
import 'package:openfamily/screens/member_profile_screen.dart';
import 'package:openfamily/services/bubble_service.dart';
import 'package:openfamily/services/inbox_service.dart';

class FakeInboxService implements InboxService {
  FakeInboxService(this.items);
  final List<InboxItem> items;
  @override
  Future<List<InboxItem>> load() async => items;
}

class CountingBubbleService implements BubbleService {
  int lists = 0;
  @override
  Future<BubbleList> list() async {
    lists++;
    return const BubbleList();
  }

  @override
  Future<Bubble> create({
    required String subjectId,
    required int radiusM,
    required int durationMinutes,
    bool notifyReenter = false,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String id) async {}
}

final DateTime _now = DateTime(2026, 1, 1, 12);

InboxItem _checkIn() => InboxItem.fromCheckInJson(<String, dynamic>{
      'id': 'c1',
      'user_id': 'sam',
      'name': 'Sam',
      'note': 'At school',
      'lat': 51.5,
      'lon': -0.12,
      'created_at': _now.toUtc().toIso8601String(),
      'expires_at': _now.add(const Duration(days: 30)).toUtc().toIso8601String(),
    });

void main() {
  setUp(() => InboxStore.instance.reset());

  test('models: titles, merge order, ended shares dropped', () {
    final InboxItem ci = _checkIn();
    expect(ci.title, 'Sam checked in: At school');
    expect(ci.hasPin, isTrue);
    final InboxItem share = InboxItem.fromLiveShareJson(<String, dynamic>{
      'id': 's1',
      'user_id': 'ava',
      'name': 'Ava',
      'created_at': _now.add(const Duration(minutes: 5)).toUtc().toIso8601String(),
      'expires_at': _now.add(const Duration(hours: 1)).toUtc().toIso8601String(),
    });
    final InboxItem ended = InboxItem.fromLiveShareJson(<String, dynamic>{
      'id': 's2',
      'user_id': 'bo',
      'name': 'Bo',
      'created_at': _now.toUtc().toIso8601String(),
      'expires_at': _now.subtract(const Duration(minutes: 1)).toUtc().toIso8601String(),
    });
    expect(share.title, 'Ava is sharing their live location');
    final List<InboxItem> merged =
        mergeInbox(<InboxItem>[ci], <InboxItem>[ended, share], _now.add(const Duration(minutes: 10)));
    expect(merged.map((InboxItem i) => i.id), <String>['s1', 'c1']);
    expect(InboxItem.fromCheckInJson(<String, dynamic>{'id': 'x'}).title, 'A family member checked in');
  });

  testWidgets('lists received items and taps through to the member', (WidgetTester tester) async {
    InboxItem? opened;
    await tester.pumpWidget(MaterialApp(
      home: InboxScreen(
        service: FakeInboxService(<InboxItem>[_checkIn()]),
        onOpenMember: (BuildContext _, InboxItem i) => opened = i,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Sam checked in: At school'), findsOneWidget);
    await tester.tap(find.text('Sam checked in: At school'));
    expect(opened?.userId, 'sam');
  });

  testWidgets('empty state', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: InboxScreen(service: FakeInboxService(const <InboxItem>[]))));
    await tester.pumpAndSettle();
    expect(find.text('Nothing yet'), findsOneWidget);
  });

  testWidgets('banner shows the newest unseen item and hides once seen', (WidgetTester tester) async {
    bool opened = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: InboxBanner(onOpen: () => opened = true))));
    expect(find.byKey(const ValueKey<String>('inbox-banner')), findsNothing);
    final InboxItem fresh = InboxItem(
      id: 'c2', kind: InboxKind.checkIn, userId: 'sam', name: 'Sam', note: 'Home',
      at: DateTime.now().add(const Duration(seconds: 5)),
    );
    await InboxStore.instance.refresh(FakeInboxService(<InboxItem>[fresh]));
    await tester.pump();
    expect(find.text('Sam checked in: Home'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('inbox-banner')));
    expect(opened, isTrue);
    InboxStore.instance.markSeen();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('inbox-banner')), findsNothing);
  });

  test('a bubble frame reloads the bubble list; other frames do not', () async {
    final CountingBubbleService svc = CountingBubbleService();
    BubbleStore.instance.handleFrame(<String, dynamic>{'type': 'location'}, svc);
    expect(svc.lists, 0);
    BubbleStore.instance.handleFrame(<String, dynamic>{'type': 'bubble', 'event': 'created'}, svc);
    await Future<void>.delayed(Duration.zero);
    expect(svc.lists, 1);
  });

  test('alert history knows bubble kinds', () {
    expect(alertKindFrom('bubble_created'), AlertKind.bubbleCreated);
    expect(alertKindFrom('bubble_left').isBubble, isTrue);
    expect(alertKindFrom('sos').isBubble, isFalse);
  });

  group('own profile hides rows that would 400', () {
    const Member me = Member(
      id: 'me', name: 'Me', position: LatLng(51.5, -0.12),
      status: MemberStatus.normal, batteryPercent: 80, address: '',
    );
    Future<void> pump(WidgetTester tester, Member m, String? self) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: MemberProfileScreen(member: m, selfUserId: self)));
      await tester.pump();
    }

    testWidgets('self: no Bubble or Notifications row', (WidgetTester tester) async {
      await pump(tester, me, 'me');
      expect(find.text('Create Bubble'), findsNothing);
      expect(find.text('Notifications'), findsNothing);
    });

    testWidgets('someone else: both rows present', (WidgetTester tester) async {
      await pump(tester, me, 'someone-else');
      expect(find.text('Create Bubble'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
    });
  });
}
