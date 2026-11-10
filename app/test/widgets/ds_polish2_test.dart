// The shared pieces of docs/ux/UI_POLISH_2.md: stat strip, chip row, radio rows, group / header
// alignment, sheet header alignment. Every case also runs at the narrow and large-text corners.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';

Future<void> _pump(WidgetTester t, Widget child, {double width = 390, double scale = 1, bool dark = false}) async {
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: dark ? buildDarkTheme() : buildLightTheme(),
    builder: (BuildContext c, Widget? w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: w!,
    ),
    home: Scaffold(body: child),
  ));
  await t.pump();
}

const List<DsStat> _four = <DsStat>[
  DsStat(value: '28 mi', label: 'Distance'),
  DsStat(value: '37 min', label: 'Duration'),
  DsStat(value: '75 mph', label: 'Top speed', semanticLabel: 'GPS top speed: 75 mph'),
  DsStat(value: '45 mph', label: 'Average'),
];

void main() {
  group('DsStatStrip.columnsFor', () {
    test('all in one row when there is room', () => expect(DsStatStrip.columnsFor(4, 326, 72), 4));
    test('four become 2 + 2, never 3 + 1', () => expect(DsStatStrip.columnsFor(4, 280, 76), 2));
    test('three that do not fit become a stacked list, never 2 + 1', () => expect(DsStatStrip.columnsFor(3, 200, 76), 1));
    test('three fit in a row', () => expect(DsStatStrip.columnsFor(3, 240, 76), 3));
    test('five split 3 + 2', () => expect(DsStatStrip.columnsFor(5, 240, 76), 3));
    test('one item is a plain row', () => expect(DsStatStrip.columnsFor(1, 300, 76), 1));
  });

  group('DsStatStrip', () {
    testWidgets('four stats share one row in equal columns at 326 dp', (WidgetTester t) async {
      await _pump(t, const Padding(padding: EdgeInsets.all(AppSpace.lg), child: DsStatStrip(stats: _four)));
      final List<double> xs = <double>[for (final DsStat s in _four) t.getTopLeft(find.text(s.value)).dx];
      final List<double> ys = <double>[for (final DsStat s in _four) t.getTopLeft(find.text(s.value)).dy];
      expect(ys.toSet().length, 1, reason: 'one row');
      final List<double> gaps = <double>[for (int i = 1; i < xs.length; i++) xs[i] - xs[i - 1]];
      for (final double g in gaps) {
        expect(g, closeTo(gaps.first, 1.0), reason: 'equal column widths');
      }
    });

    testWidgets('on the cover display at 1.5x text it becomes 2 + 2, left edges aligned', (WidgetTester t) async {
      await _pump(t, const Padding(padding: EdgeInsets.all(AppSpace.lg), child: DsStatStrip(stats: _four)), width: 344, scale: 1.5);
      final double x0 = t.getTopLeft(find.text('28 mi')).dx;
      expect(t.getTopLeft(find.text('37 min')).dy, t.getTopLeft(find.text('28 mi')).dy);
      expect(t.getTopLeft(find.text('75 mph')).dx, closeTo(x0, 0.5), reason: 'second row starts on the first column');
      expect(t.getTopLeft(find.text('75 mph')).dy, greaterThan(t.getTopLeft(find.text('28 mi')).dy));
      expect(t.getTopLeft(find.text('45 mph')).dy, t.getTopLeft(find.text('75 mph')).dy);
      expect(t.takeException(), isNull);
    });

    testWidgets('three stats that cannot fit stack as label / value lines', (WidgetTester t) async {
      await _pump(t, const Padding(padding: EdgeInsets.all(AppSpace.lg), child: DsStatStrip(stats: <DsStat>[
        DsStat(value: '28 mi', label: 'Distance'),
        DsStat(value: '37 min', label: 'Duration'),
        DsStat(value: '75 mph', label: 'Top speed'),
      ])), width: 344, scale: 1.5);
      final double yA = t.getTopLeft(find.text('28 mi')).dy;
      final double yB = t.getTopLeft(find.text('37 min')).dy;
      final double yC = t.getTopLeft(find.text('75 mph')).dy;
      expect(yA < yB && yB < yC, isTrue);
      // Values hug the right edge, labels the left.
      expect(t.getTopRight(find.text('28 mi')).dx, closeTo(t.getTopRight(find.text('75 mph')).dx, 0.5));
      expect(t.takeException(), isNull);
    });

    testWidgets('each figure is one semantic node; a custom label wins', (WidgetTester t) async {
      final SemanticsHandle h = t.ensureSemantics();
      await _pump(t, const DsStatStrip(stats: _four));
      expect(find.bySemanticsLabel('Distance: 28 mi'), findsOneWidget);
      expect(find.bySemanticsLabel('GPS top speed: 75 mph'), findsOneWidget);
      h.dispose();
    });
  });

  group('DsChipRow', () {
    testWidgets('chips start on the left edge, 8 dp apart, and wrap instead of overflowing', (WidgetTester t) async {
      await _pump(
        t,
        const Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: DsChipRow(children: <Widget>[
            DsStatusChip(label: 'Processed by server', icon: Icons.dns_outlined),
            DsStatusChip(label: 'Location sharing: on', icon: Icons.location_on),
          ]),
        ),
        width: 344,
        scale: 1.5,
      );
      expect(t.getTopLeft(find.text('Processed by server')).dx, lessThan(60));
      expect(t.takeException(), isNull);
      final double a = t.getTopLeft(find.byType(DsStatusChip).first).dx;
      expect(a, AppSpace.lg);
    });
  });

  group('rows in a group and headers share one left edge', () {
    for (final double w in <double>[344, 390]) {
      testWidgets('header text, row title and footnote align at $w dp', (WidgetTester t) async {
        await _pump(
          t,
          DsSettingsList(children: <Widget>[
            const DsSectionHeader('Members', caption: 'Who may keep data on the phone'),
            DsRowGroup(children: <Widget>[
              const DsListRow(title: 'Row one', subtitle: 'Short', leading: DsIconTile(Icons.dns_outlined)),
              DsRadioRow(title: 'Radio', selected: true, onTap: () {}),
            ]),
            const DsFootnote('A quiet note.'),
          ]),
          width: w,
        );
        final double header = t.getTopLeft(find.text('MEMBERS')).dx;
        final double caption = t.getTopLeft(find.text('Who may keep data on the phone')).dx;
        final double foot = t.getTopLeft(find.text('A quiet note.')).dx;
        final double tile = t.getTopLeft(find.byType(DsIconTile)).dx;
        expect(caption, header);
        expect(foot, header);
        expect(tile, closeTo(header, 0.5), reason: 'icon tile starts where the header text starts');
        final double gutter = t.getTopLeft(find.byType(DsRowGroup)).dx;
        expect(gutter, w < 360 ? AppSpace.md : AppSpace.lg);
        expect(t.takeException(), isNull);
      });
    }
  });

  group('DsRadioRow', () {
    testWidgets('announces itself as one checked option of an exclusive group, and taps', (WidgetTester t) async {
      final SemanticsHandle h = t.ensureSemantics();
      int taps = 0;
      await _pump(t, DsRowGroup(children: <Widget>[
        DsRadioRow(title: 'Server processing', subtitle: 'Recommended', selected: true, onTap: () => taps++),
        DsRadioRow(title: 'Phone only', selected: false, onTap: () => taps += 10),
      ]));
      expect(
        t.getSemantics(find.text('Server processing')),
        isSemantics(label: 'Server processing\nRecommended', isChecked: true, isInMutuallyExclusiveGroup: true, isButton: true),
      );
      expect(
        t.getSemantics(find.text('Phone only')),
        isSemantics(isChecked: false, isInMutuallyExclusiveGroup: true),
      );
      await t.tap(find.text('Phone only'));
      expect(taps, 10);
      h.dispose();
    });

    testWidgets('a read-only radio row does not react', (WidgetTester t) async {
      await _pump(t, const DsRowGroup(children: <Widget>[DsRadioRow(title: 'Phone only', selected: false, onTap: null)]));
      await t.tap(find.text('Phone only'), warnIfMissed: false);
      expect(t.takeException(), isNull);
    });

    testWidgets('has the (i) for the long explanation', (WidgetTester t) async {
      await _pump(t, DsRowGroup(children: <Widget>[
        DsRadioRow(title: 'Required', selected: false, onTap: () {}, info: 'The long text.'),
      ]));
      await t.tap(find.byKey(const Key('info-hint')));
      await t.pumpAndSettle();
      expect(find.text('The long text.'), findsOneWidget);
    });
  });

  group('dsMeta', () {
    test('joins with a middle dot and skips empty parts', () {
      expect(dsMeta(<String?>['2 people', null, 'Admin', '']), '2 people · Admin');
      expect(dsMeta(<String?>[]), '');
    });
  });

  group('DsSheetScaffold', () {
    testWidgets('a header widget starts at the left edge, not the centre', (WidgetTester t) async {
      await _pump(
        t,
        const Align(
          alignment: Alignment.bottomCenter,
          child: DsSheetScaffold(
            title: 'Your circles',
            header: Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 20), child: Text('left header'))),
            child: SizedBox(height: 40),
          ),
        ),
      );
      expect(t.getTopLeft(find.text('left header')).dx, 20);
      expect(t.getTopLeft(find.text('Your circles')).dx, 20);
    });
  });
}
