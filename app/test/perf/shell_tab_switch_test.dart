// Portable (works before/after): how many tab-body builds does a round of tab
// switching cost once all four tabs have been visited?
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/app_shell.dart';
import 'package:openfamily/theme/app_theme.dart';

void main() {
  testWidgets('switching tabs does not rebuild the visited tab bodies',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final Map<AppTab, int> builds = <AppTab, int>{
      for (final AppTab t in AppTab.values) t: 0,
    };
    WidgetBuilder tab(AppTab t) => (BuildContext _) {
          builds[t] = builds[t]! + 1;
          return Center(child: Text('body ${t.name}'));
        };
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: AppShell(tabBuilders: <AppTab, WidgetBuilder>{
        for (final AppTab t in AppTab.values) t: tab(t),
      }),
    ));
    await tester.pump();
    for (final String l in ['Driving', 'Safety', 'Circle', 'Location']) {
      await tester.tap(find.text(l));
      await tester.pump();
    }
    final int afterVisit = builds.values.fold(0, (a, b) => a + b);

    for (int i = 0; i < 5; i++) {
      for (final String l in ['Driving', 'Safety', 'Circle', 'Location']) {
        await tester.tap(find.text(l));
        await tester.pump();
      }
    }
    final int extra = builds.values.fold(0, (a, b) => a + b) - afterVisit;
    // ignore: avoid_print
    print('PERFMETRIC tab-switch: 20 switches rebuilt tab bodies $extra times');
    expect(extra, 0);
  });
}
