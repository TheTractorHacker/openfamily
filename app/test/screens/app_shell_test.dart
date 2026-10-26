import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/app_shell.dart';
import 'package:openfamily/theme/app_theme.dart';

class _Counter extends StatefulWidget {
  const _Counter(this.label);
  final String label;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => setState(() => n++),
      child: Text('${widget.label} $n'),
    ),
  );
}

Widget _shell({AppTab initial = AppTab.location}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: AppShell(
      initialTab: initial,
      tabBuilders: <AppTab, WidgetBuilder>{
        AppTab.location: (_) => const _Counter('loc'),
        AppTab.driving: (_) => const _Counter('drv'),
        AppTab.safety: (_) => const _Counter('saf'),
        AppTab.circle: (_) => const _Counter('cir'),
      },
    ),
  );
}

/// The flutter_test default view (800x600) is landscape, which now gets the
/// NavigationRail. These tests exercise the phone bottom bar.
Future<void> _pumpShell(WidgetTester tester, Widget w) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(w);
}

void main() {
  testWidgets('shows four labelled destinations, Location first', (
    tester,
  ) async {
    await _pumpShell(tester, _shell());
    await tester.pump();
    for (final l in ['Location', 'Driving', 'Safety', 'Circle']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.text('loc 0'), findsOneWidget);
    expect(find.text('drv 0'), findsNothing, reason: 'tabs build lazily');
  });

  testWidgets('switching tabs preserves each tab state', (tester) async {
    await _pumpShell(tester, _shell());
    await tester.tap(find.text('loc 0'));
    await tester.pump();
    expect(find.text('loc 1'), findsOneWidget);

    await tester.tap(find.text('Driving'));
    await tester.pump();
    expect(find.text('drv 0'), findsOneWidget);
    await tester.tap(find.text('drv 0'));
    await tester.pump();
    await tester.tap(find.text('drv 1'));
    await tester.pump();

    await tester.tap(find.text('Safety'));
    await tester.pump();
    await tester.tap(find.text('Circle'));
    await tester.pump();
    expect(find.text('cir 0'), findsOneWidget);

    await tester.tap(find.text('Location'));
    await tester.pump();
    expect(find.text('loc 1'), findsOneWidget, reason: 'state kept');
    await tester.tap(find.text('Driving'));
    await tester.pump();
    expect(find.text('drv 2'), findsOneWidget, reason: 'state kept');
  });

  testWidgets('back from another tab returns to Location, then exits', (
    tester,
  ) async {
    await _pumpShell(tester, _shell());
    await tester.tap(find.text('Safety'));
    await tester.pump();
    expect(find.text('saf 0'), findsOneWidget);

    // Android back button.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('loc 0'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      AppTab.location.index,
    );
    // On Location the shell no longer intercepts back.
    expect(
      tester
          .widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope))
          .canPop,
      isTrue,
    );
  });

  testWidgets('requestTab deep-links to a tab', (tester) async {
    await _pumpShell(tester, _shell());
    AppShell.requestTab(AppTab.safety);
    await tester.pump();
    expect(find.text('saf 0'), findsOneWidget);
    expect(AppShell.requestedTab.value, isNull);
  });

  testWidgets('a request made before mount is honoured', (tester) async {
    AppShell.requestTab(AppTab.driving);
    await _pumpShell(tester, _shell());
    await tester.pump();
    expect(find.text('drv 0'), findsOneWidget);
  });

  testWidgets('pushed routes cover the bar and pop back to the same tab', (
    tester,
  ) async {
    await _pumpShell(tester, _shell(initial: AppTab.circle));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('pushed')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('cir 0'), findsOneWidget);
  });
}
