import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/bubble.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/bubble_create_screen.dart';
import 'package:openfamily/screens/bubbles_screen.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/bubble_service.dart';
import 'package:openfamily/widgets/ds/ds.dart';

class FakeBubbleService implements BubbleService {
  FakeBubbleService({this.list0 = const BubbleList(), this.createFail});

  BubbleList list0;
  Object? createFail;
  final List<Map<String, Object?>> created = <Map<String, Object?>>[];
  final List<String> cancelled = <String>[];

  @override
  Future<BubbleList> list() async => list0;

  @override
  Future<Bubble> create({
    required String subjectId,
    required int radiusM,
    required int durationMinutes,
    bool notifyReenter = false,
  }) async {
    if (createFail != null) throw createFail!;
    created.add(<String, Object?>{
      'subject': subjectId,
      'radius': radiusM,
      'minutes': durationMinutes,
      'reenter': notifyReenter,
    });
    return Bubble(
      id: 'b1',
      subjectId: subjectId,
      subjectName: 'Sam',
      center: const LatLng(51.5, -0.12),
      radiusM: radiusM,
      expiresAt: DateTime.now().add(Duration(minutes: durationMinutes)),
    );
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
    list0 = BubbleList(
      mine: list0.mine.where((Bubble b) => b.id != id).toList(),
      aboutMe: list0.aboutMe,
    );
  }
}

const Member _sam = Member(
  id: 'sam',
  name: 'Sam',
  position: LatLng(51.5, -0.12),
  status: MemberStatus.normal,
  batteryPercent: 80,
  address: '',
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  group('bubble model helpers', () {
    test('slider maps to the allowed radius range and round-trips', () {
      expect(bubbleRadiusFromSlider(0), kMinBubbleRadiusM);
      expect(bubbleRadiusFromSlider(1), kMaxBubbleRadiusM);
      expect(bubbleRadiusFromSlider(-3), kMinBubbleRadiusM);
      expect(bubbleRadiusFromSlider(9), kMaxBubbleRadiusM);
      for (final int r in <int>[100, 200, 500, 1000, 2000]) {
        expect(bubbleRadiusFromSlider(bubbleSliderFromRadius(r)), r);
      }
      double prev = 0;
      for (double t = 0; t <= 1; t += 0.05) {
        final int r = bubbleRadiusFromSlider(t);
        expect(r, greaterThanOrEqualTo(prev));
        prev = r.toDouble();
      }
    });

    test('formatting and zoom', () {
      expect(formatBubbleRadius(200), '200 m');
      expect(formatBubbleRadius(1500), '1.5 km');
      expect(bubbleZoomFor(100, 51.5, 400), greaterThan(bubbleZoomFor(3000, 51.5, 400)));
    });

    test('duration options: until tonight only while it is far enough away', () {
      final List<String> noon =
          bubbleDurationOptions(DateTime(2026, 1, 1, 12)).map((BubbleDuration d) => d.label).toList();
      expect(noon, <String>['1 hour', '4 hours', 'Until tonight', '24 hours']);
      expect(bubbleDurationOptions(DateTime(2026, 1, 1, 12))[2].minutes, 11 * 60);
      final List<String> late =
          bubbleDurationOptions(DateTime(2026, 1, 1, 22, 50)).map((BubbleDuration d) => d.label).toList();
      expect(late, <String>['1 hour', '4 hours', '24 hours']);
    });

    test('parses lists, hides expired, subject view has no geometry', () {
      final BubbleList l = BubbleList.fromJson(<String, dynamic>{
        'bubbles': <Object>[
          <String, dynamic>{
            'id': 'a', 'subject_id': 's', 'subject_name': 'Sam', 'lat': 1.5, 'lon': 2.5,
            'radius_m': 300, 'notify_reenter': true, 'inside': false,
            'expires_at': '2030-01-01T10:00:00Z',
          },
          <String, dynamic>{
            'id': 'old', 'subject_id': 's', 'lat': 1.0, 'lon': 2.0, 'radius_m': 100,
            'expires_at': '2020-01-01T10:00:00Z',
          },
        ],
        'about_me': <Object>[
          <String, dynamic>{'id': 'x', 'creator_id': 'c', 'creator_name': 'Ann', 'expires_at': '2030-01-01T10:00:00Z'},
        ],
      });
      expect(l.mine.first.notifyReenter, isTrue);
      expect(l.mine.first.inside, isFalse);
      expect(l.aboutMe.single.creatorName, 'Ann');
      expect(l.withoutExpired(DateTime.utc(2025)).mine.map((Bubble b) => b.id), <String>['a']);
    });

    test('error messages are friendly', () {
      expect(bubbleErrorMessage(const ApiException(404, '')), contains('sharing'));
      expect(bubbleErrorMessage(const ApiException(409, '')), contains('recent location'));
      expect(bubbleErrorMessage(const ApiException(429, '')), contains('too many'));
      expect(bubbleErrorMessage(Exception('x'), action: 'save'), contains('Could not save'));
    });
  });

  group('BubbleCreateScreen', () {
    testWidgets('slider step then duration step then create', (WidgetTester tester) async {
      _tall(tester);
      final FakeBubbleService svc = FakeBubbleService();
      await tester.pumpWidget(_wrap(BubbleCreateScreen(
        member: _sam,
        service: svc,
        now: () => DateTime(2026, 1, 1, 12),
      )));
      expect(find.text('Use the slider to adjust the size of your Bubble'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('Radius: 200 m'), findsOneWidget);

      await tester.drag(find.byType(Slider), const Offset(300, 0));
      await tester.pump();
      expect(find.text('Radius: 200 m'), findsNothing);

      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('1 hour'), findsOneWidget);
      expect(find.text('Until tonight'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      // Subject is told, with no location.
      expect(find.textContaining('never where it is'), findsOneWidget);

      await tester.tap(find.text('4 hours'));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.widgetWithText(DsBusyButton, 'Create Bubble'));
      await tester.pumpAndSettle();
      expect(svc.created.single['subject'], 'sam');
      expect(svc.created.single['minutes'], 240);
      expect(svc.created.single['reenter'], true);
      expect(svc.created.single['radius'], greaterThan(200));
    });

    testWidgets('shows a friendly error and stays when creation fails', (WidgetTester tester) async {
      _tall(tester);
      final FakeBubbleService svc = FakeBubbleService(createFail: const ApiException(404, 'x'));
      await tester.pumpWidget(_wrap(BubbleCreateScreen(member: _sam, service: svc)));
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.tap(find.widgetWithText(DsBusyButton, 'Create Bubble'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sharing'), findsOneWidget);
      expect(svc.created, isEmpty);
    });

    testWidgets('back from the duration step returns to the slider', (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(BubbleCreateScreen(member: _sam, service: FakeBubbleService())));
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);
    });
  });

  group('BubblesScreen', () {
    testWidgets('lists mine with cancel and the ones around me without a location', (WidgetTester tester) async {
      _tall(tester);
      final DateTime now = DateTime(2026, 1, 1, 12);
      final FakeBubbleService svc = FakeBubbleService(
        list0: BubbleList(
          mine: <Bubble>[
            Bubble(
              id: 'b1', subjectId: 'sam', subjectName: 'Sam',
              center: const LatLng(1, 2), radiusM: 300,
              expiresAt: now.add(const Duration(hours: 2)),
            ),
          ],
          aboutMe: <BubbleAboutMe>[
            BubbleAboutMe(id: 'x', creatorName: 'Ann', expiresAt: now.add(const Duration(minutes: 30))),
          ],
        ),
      );
      await tester.pumpWidget(_wrap(BubblesScreen(service: svc, now: () => now)));
      await tester.pumpAndSettle();
      expect(find.text('Sam'), findsOneWidget);
      expect(find.textContaining('300 m'), findsOneWidget);
      expect(find.text('Ann has a Bubble around you'), findsOneWidget);
      // Only the creator's own Bubble can be cancelled.
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(svc.cancelled, <String>['b1']);
      expect(find.text('Sam'), findsNothing);
      expect(BubbleStore.instance.mine.value, isEmpty);
    });

    testWidgets('empty state', (WidgetTester tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(BubblesScreen(service: FakeBubbleService())));
      await tester.pumpAndSettle();
      expect(find.text('No active Bubbles'), findsOneWidget);
    });
  });
}
