import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/widgets/battery_banner.dart';

Widget host(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  test('visible only when the phone says it is not exempt', () {
    expect(batteryBannerVisible(null), isFalse);
    expect(batteryBannerVisible(const BatteryBannerState(exempt: null, manufacturer: '')), isFalse);
    expect(batteryBannerVisible(const BatteryBannerState(exempt: true, manufacturer: '')), isFalse);
    expect(batteryBannerVisible(const BatteryBannerState(exempt: false, manufacturer: '')), isTrue);
  });

  test('Samsung text names the exact setting', () {
    expect(batteryBannerText('samsung'), contains('Unrestricted'));
    expect(batteryBannerText('Google'), isNot(contains('Samsung')));
  });

  testWidgets('shows until exempt, then disappears after the fix', (WidgetTester t) async {
    bool exempt = false;
    int fixes = 0;
    await t.pumpWidget(host(BatteryBanner(
      read: () async => BatteryBannerState(exempt: exempt, manufacturer: 'samsung'),
      onFix: () async {
        fixes++;
        exempt = true;
      },
    )));
    await t.pump();
    expect(find.byKey(const ValueKey<String>('battery-banner')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('battery-banner-fix')));
    await t.pump();
    await t.pump();
    expect(fixes, 1);
    expect(find.byKey(const ValueKey<String>('battery-banner')), findsNothing);
  });

  testWidgets('shows nothing when the state cannot be read', (WidgetTester t) async {
    await t.pumpWidget(host(BatteryBanner(read: () async => null)));
    await t.pump();
    expect(find.byKey(const ValueKey<String>('battery-banner')), findsNothing);
  });
}
