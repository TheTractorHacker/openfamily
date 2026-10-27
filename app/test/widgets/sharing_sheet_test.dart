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

Widget _host(_FakeSharing svc) => MaterialApp(
      home: Scaffold(
        body: SharingSheet(
          members: _members,
          selfId: 'me',
          service: svc,
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

  testWidgets('check-in needs a recipient, excludes self, sends location and note',
      (WidgetTester tester) async {
    bigScreen(tester);
    final _FakeSharing svc = _FakeSharing();
    await tester.pumpWidget(_host(svc));
    await tester.pump();

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

    final Finder start = find.widgetWithText(FilledButton, 'Start sharing');
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
