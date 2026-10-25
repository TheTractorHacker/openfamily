import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';

Widget _host(Widget child, {ThemeData? theme, double textScale = 1}) {
  return MaterialApp(
    theme: theme ?? buildLightTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets(
    'pill button taps, is at least 48dp tall, and is a semantic button',
    (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(DsPillButton(label: 'Check in', onPressed: () => taps++)),
      );
      await tester.tap(find.text('Check in'));
      expect(taps, 1);
      expect(
        tester.getSize(find.byType(DsPillButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.bySemanticsLabel('Check in'), findsOneWidget);
    },
  );

  testWidgets('disabled pill button ignores taps', (tester) async {
    await tester.pumpWidget(
      _host(const DsPillButton(label: 'Go', onPressed: null)),
    );
    await tester.tap(find.text('Go'), warnIfMissed: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map button exposes its tooltip as the accessible label', (
    tester,
  ) async {
    int taps = 0;
    await tester.pumpWidget(
      _host(
        DsMapButton(
          icon: Icons.layers,
          tooltip: 'Layers',
          onPressed: () => taps++,
        ),
      ),
    );
    expect(tester.getSize(find.byType(DsMapButton)).width, 48);
    await tester.tap(find.byType(DsMapButton));
    expect(taps, 1);
    expect(find.bySemanticsLabel('Layers'), findsOneWidget);
  });

  testWidgets('toggle row toggles when the row is tapped', (tester) async {
    bool value = false;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          DsToggleRow(
            title: 'Location sharing',
            subtitle: 'When off, nothing is shared',
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Location sharing'));
    await tester.pump();
    expect(value, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('segmented tabs report the tapped index', (tester) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        DsSegmentedTabs(
          labels: const ['People', 'Places'],
          selected: 0,
          onChanged: (i) => picked = i,
        ),
      ),
    );
    await tester.tap(find.text('Places'));
    expect(picked, 1);
  });

  testWidgets('list row, chip and sheet survive 2x text in dark theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const DsSheetScaffold(
          title: 'Your circles',
          child: Column(
            children: [
              DsListRow(
                title: 'A rather long circle name that must wrap not clip',
                subtitle: 'Admin and more words to wrap onto lines',
                trailing: DsStatusChip(
                  label: 'Battery 18%',
                  icon: Icons.battery_alert,
                ),
                chevron: true,
              ),
            ],
          ),
        ),
        theme: buildDarkTheme(),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Your circles'), findsOneWidget);
  });

  testWidgets('empty and error states show their action', (tester) async {
    int retries = 0;
    await tester.pumpWidget(
      _host(DsErrorState(message: 'Offline', onRetry: () => retries++)),
    );
    await tester.tap(find.text('Try again'));
    expect(retries, 1);

    int added = 0;
    await tester.pumpWidget(
      _host(
        DsEmptyState(
          title: 'No places',
          actionLabel: 'Add',
          onAction: () => added++,
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    expect(added, 1);
  });

  testWidgets('reduced motion: AppMotion collapses durations', (tester) async {
    late Duration d;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (c) {
              d = AppMotion.of(c);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(d, Duration.zero);
  });
}
