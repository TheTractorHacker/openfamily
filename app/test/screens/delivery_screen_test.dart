import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/delivery_screen.dart';
import 'package:openfamily/services/delivery_status.dart';

import '../services/e2ee/private_channel_test.dart' show FakeServer, FakeClock;
import '../services/e2ee/private_runtime_test.dart' show Device, circleOf, priv, uA, uB;
import '../support/fake_e2ee_server.dart';

void main() {
  testWidgets('the screen names the reason per member and Fix this circle gets the missing key', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final FakeE2eeServer server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      server.circle(priv, members: <String>[uA, uB], admin: uA);
      final FakeServer channel = FakeServer();
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 7, 12));
      final Device a = Device(server, channel, uA, clock);
      final Device b = Device(server, channel, uB, clock);
      await a.service.registerThisDevice();
      await b.service.registerThisDevice();
      await a.service.enableCircle(priv);
      await b.runtime.setCircles([circleOf(priv, isPrivate: true)]);

      final CircleDelivery report = CircleDelivery.fromJson(<String, dynamic>{
        'circle_id': priv, 'summary': 'nobody_sending',
        'members': <dynamic>[
          <String, dynamic>{'user_id': uB, 'name': 'Bob Foley', 'you': true, 'reason': 'never_sent'},
          <String, dynamic>{'user_id': uA, 'name': 'Alice Foley', 'reason': 'no_key_wrap', 'app_version': '0.21.1'},
        ],
      });
      await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(circle: circleOf(priv, isPrivate: true), runtime: b.runtime, loader: (String _) async => report),
      ));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(find.byKey(const Key('delivery-nobody')), findsOneWidget);
      expect(find.text("Alice's phone has not received the circle key yet"), findsOneWidget);
      expect(find.textContaining('does not have the circle key yet'), findsOneWidget); // this phone's own problem

      expect(await b.service.heldEpochs(priv), isEmpty);
      await tester.tap(find.byKey(const Key('delivery-fix')));
      for (int i = 0; i < 400 && find.textContaining('Fetched the circle key for this phone.').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await b.service.heldEpochs(priv), <int>[1]);
      expect(find.textContaining('Fetched the circle key for this phone.'), findsOneWidget);
    });
  });
}
