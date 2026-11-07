import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/app_compat.dart';
import 'package:openfamily/widgets/update_banner.dart';

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Column(children: <Widget>[UpdateBanner()]))));

void main() {
  setUp(AppCompat.debugReset);

  testWidgets('hidden when the app is current', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('update-banner-text')), findsNothing);
    AppCompat.state.value = const CompatState(status: CompatStatus.ok);
    await tester.pump();
    expect(find.byKey(const Key('update-banner-text')), findsNothing);
  });

  testWidgets('required: clear, undismissable update message',
      (WidgetTester tester) async {
    await _pump(tester);
    AppCompat.state.value = const CompatState(status: CompatStatus.required);
    await tester.pump();
    expect(find.textContaining('Update required'), findsOneWidget);
    expect(find.byKey(const Key('update-banner-dismiss')), findsNothing);
  });

  testWidgets('recommended: dismissible', (WidgetTester tester) async {
    await _pump(tester);
    AppCompat.state.value = const CompatState(
        status: CompatStatus.recommended, latest: '0.21.0');
    await tester.pump();
    expect(find.textContaining('Update available'), findsOneWidget);
    expect(find.textContaining('0.21.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update-banner-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('update-banner-text')), findsNothing);
  });

  testWidgets('a circle that needs a newer app says so',
      (WidgetTester tester) async {
    await _pump(tester);
    AppCompat.circlesNeedingUpdate.value = 1;
    await tester.pump();
    expect(find.textContaining('This circle needs a newer version'),
        findsOneWidget);
    AppCompat.circlesNeedingUpdate.value = 2;
    await tester.pump();
    expect(find.textContaining('2 circles need a newer version'),
        findsOneWidget);
  });

  testWidgets('required wins over recommended', (WidgetTester tester) async {
    await _pump(tester);
    AppCompat.dismissed.value = true;
    AppCompat.state.value = const CompatState(status: CompatStatus.required);
    await tester.pump();
    expect(find.textContaining('Update required'), findsOneWidget);
  });
}
