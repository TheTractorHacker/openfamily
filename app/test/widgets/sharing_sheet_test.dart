import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/sharing_service.dart';
import 'package:openfamily/widgets/sharing_sheet.dart';

class _FakeSharing implements SharingService {
  SharingPause pauseState = const SharingPause(paused: false);
  LiveShares shares = const LiveShares();
  final List<String> calls = <String>[];
  Object? failCheckIn;
  List<ShareLink> links = <ShareLink>[];
  Object? failCreate;
  int nextLink = 1;

  @override
  Future<ShareLink> createShareLink({required int minutes, String label = ''}) async {
    if (failCreate != null) throw failCreate!;
    calls.add('link $minutes');
    final ShareLink l = ShareLink(
        id: 'l$nextLink',
        expiresAt: DateTime(2030, 1, 1, 9).add(Duration(minutes: minutes)),
        url: 'https://of.example/s/tok${nextLink++}');
    links = <ShareLink>[...links, ShareLink(id: l.id, expiresAt: l.expiresAt)];
    return l;
  }

  @override
  Future<List<ShareLink>> shareLinks() async => links;

  @override
  Future<void> stopShareLink(String id) async {
    calls.add('stop $id');
    links = links.where((ShareLink l) => l.id != id).toList();
  }

  @override
  Future<SharingPause> pauseStatus() async => pauseState;

  @override
  Future<SharingPause> pause({int? minutes, DateTime? until}) async {
    calls.add('pause minutes=$minutes until=${until != null}');
    pauseState = SharingPause(
        paused: true,
        until: until ?? DateTime(2031).add(Duration(minutes: minutes ?? 0)));
    return pauseState;
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    pauseState = const SharingPause(paused: false);
  }

  @override
  Future<void> checkIn({
    required List<String> recipientIds,
    String note = '',
    double? lat,
    double? lon,
  }) async {
    if (failCheckIn != null) throw failCheckIn!;
    calls.add('checkin ${recipientIds.join(",")} "$note" $lat,$lon');
  }

  @override
  Future<LiveShares> liveShares() async => shares;

  @override
  Future<void> shareLive({required String viewerId, required int minutes}) async {
    calls.add('share $viewerId $minutes');
    shares = LiveShares(outgoing: <LiveShare>[
      LiveShare(
          id: 's1',
          userId: viewerId,
          name: 'Sam',
          expiresAt: DateTime(2031).add(Duration(minutes: minutes))),
    ]);
  }

  @override
  Future<void> endLiveShare(String id) async {
    calls.add('end $id');
    shares = const LiveShares();
  }
}

const List<Member> _members = <Member>[
  Member(id: 'me', name: 'Me', position: null, status: MemberStatus.normal, batteryPercent: 90, address: ''),
  Member(id: 'sam', name: 'Sam', position: null, status: MemberStatus.normal, batteryPercent: 90, address: ''),
  Member(id: 'ella', name: 'Ella', position: null, status: MemberStatus.normal, batteryPercent: 90, address: ''),
];

Widget _host(_FakeSharing svc, {List<String>? shared}) => MaterialApp(
      home: Scaffold(
        body: SharingSheet(
          members: _members,
          selfId: 'me',
          service: svc,
          showPreviewMap: false,
          shareUrl: (String url) async => shared?.add(url),
          locate: () async => (lat: 1.5, lon: 2.5),
          clock: () => DateTime(2030, 1, 1, 9),
        ),
      ),
    );

void main() {
  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> open(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the link flow first with the required copy',
      (WidgetTester tester) async {
    bigScreen(tester);
    await tester.pumpWidget(_host(_FakeSharing()));
    await tester.pump();
    expect(find.text('Share your live location with anyone, no app needed'),
        findsOneWidget);
    expect(
        find.text('Anyone with the link can see your live location, name, '
            'photo, and battery status. You can stop sharing at any time.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('link-duration')), findsOneWidget);
    expect(find.text('1 hour'), findsOneWidget); // default duration
    expect(find.widgetWithText(FilledButton, 'Start sharing'), findsOneWidget);
  });

  testWidgets('start sharing creates a link with the chosen duration and shares its URL',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    final List<String> shared = <String>[];
    await tester.pumpWidget(_host(svc, shared: shared));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('link-duration')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 hours').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('start-link')));
    await tester.pumpAndSettle();

    expect(svc.calls, <String>['link 240']);
    expect(shared, <String>['https://of.example/s/tok1']);
    expect(find.text('Active links'), findsOneWidget);
    expect(find.text('4 h left'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('link-share-again')), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Stop sharing'));
    await tester.pumpAndSettle();
    expect(svc.calls.last, 'stop l1');
    expect(find.text('Active links'), findsNothing);
  });

  testWidgets('custom duration is capped at 72 hours', (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('link-duration')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom (up to 72 h)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey<String>('custom-hours')), '99');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();
    // Out of range: dialog stays open.
    expect(find.text('Custom duration'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey<String>('custom-hours')), '72');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('start-link')));
    await tester.pumpAndSettle();
    expect(svc.calls, <String>['link 4320']);
  });

  testWidgets('a failed link creation is reported and nothing is shared',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing()..failCreate = const ApiExceptionStub();
    final List<String> shared = <String>[];
    await tester.pumpWidget(_host(svc, shared: shared));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('start-link')));
    await tester.pumpAndSettle();
    expect(shared, isEmpty);
    expect(find.textContaining('Could not create the link'), findsOneWidget);
  });

  testWidgets('fits a small phone at 2x text scale without overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakeSharing svc = _FakeSharing();
    svc.links = <ShareLink>[
      ShareLink(id: 'a', expiresAt: DateTime(2030, 1, 1, 18), label: 'Dinner with the whole family'),
    ];
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(2)),
      child: _host(svc),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final String t in <String>["I'm here", 'Pause sharing', 'Share live with one person']) {
      await open(tester, t);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('check-in needs a recipient, excludes self, sends location and note',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await open(tester, "I'm here");

    expect(find.byKey(const ValueKey<String>('checkin-me')), findsNothing);
    final Finder send = find.widgetWithText(FilledButton, 'Send check-in');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey<String>('checkin-sam')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), ' at the park ');
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(svc.calls, <String>['checkin sam "at the park" 1.5,2.5']);
    expect(find.text('Check-in sent.'), findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
  });

  testWidgets('a failed check-in is reported, never shown as sent',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing()
      ..failCheckIn = const ApiExceptionStub();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await open(tester, "I'm here");
    await tester.tap(find.byKey(const ValueKey<String>('checkin-ella')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Send check-in'));
    await tester.pumpAndSettle();
    expect(find.text('Check-in sent.'), findsNothing);
    expect(find.textContaining('Could not send your check-in'), findsOneWidget);
  });

  testWidgets('pause 1 hour then resume', (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await open(tester, 'Pause sharing');

    await tester.tap(find.widgetWithText(ActionChip, '1 hour'));
    await tester.pumpAndSettle();
    expect(svc.calls.last, 'pause minutes=60 until=false');
    expect(find.text('Resume sharing'), findsOneWidget);
    expect(find.textContaining('SOS still shares it'), findsWidgets);

    await tester.tap(find.text('Resume sharing'));
    await tester.pumpAndSettle();
    expect(svc.calls.last, 'resume');
    expect(find.widgetWithText(ActionChip, 'Until tomorrow'), findsOneWidget);
  });

  testWidgets('until tomorrow sends an absolute end time',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await open(tester, 'Pause sharing');
    await tester.tap(find.widgetWithText(ActionChip, 'Until tomorrow'));
    await tester.pumpAndSettle();
    expect(svc.calls.last, 'pause minutes=null until=true');
  });

  testWidgets('live share starts for the chosen person and can be stopped',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();
    await open(tester, 'Share live with one person');

    final Finder start = find.byKey(const ValueKey<String>('start-person-share'));
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey<String>('share-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sam').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '4 hours'));
    await tester.pump();
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(svc.calls.last, 'share sam 240');
    expect(find.text('Sharing with Sam'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(svc.calls.last, 'end s1');
    expect(find.text('Sharing with Sam'), findsNothing);
  });
}

/// A 5xx-style failure without importing the network layer's internals.
class ApiExceptionStub implements Exception {
  const ApiExceptionStub();
}
