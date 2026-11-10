// No overflow on narrow and foldable screens: Settings, Notification settings
// and Link another phone at the four window sizes the owner's Galaxy Z Fold 4
// and S26 Ultra produce, at normal and 1.5x text. Any RenderFlex overflow
// fails the test.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/link_device_screen.dart';
import 'package:openfamily/screens/notification_settings_screen.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_e2ee_server.dart';
import '../support/size_matrix.dart';

const String uA = '11111111-1111-4111-8111-111111111111';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('Settings', () {
    layoutMatrix('everything open', (WidgetTester t, Size size, double scale) async {
      await t.pumpWidget(scaled(const SettingsScreen(), scale));
      await t.pump(const Duration(milliseconds: 300));
      // Scroll through the whole page, then open Advanced and scroll again.
      Future<void> sweep() async {
        for (int i = 0; i < 40; i++) {
          await t.drag(find.byType(ListView).first, Offset(0, -size.height * 0.7));
          await t.pump(const Duration(milliseconds: 50));
        }
      }

      await sweep();
      await t.dragUntilVisible(find.byKey(const Key('settings-advanced')), find.byType(ListView).first, const Offset(0, 200));
      await t.tap(find.byKey(const Key('settings-advanced')));
      await t.pumpAndSettle();
      await sweep();
      expect(find.text('Delete account'), findsOneWidget);
    });

    layoutMatrix('search results', (WidgetTester t, Size size, double scale) async {
      await t.pumpWidget(scaled(const SettingsScreen(), scale));
      await t.pump(const Duration(milliseconds: 300));
      for (final String q in <String>['a', 'e', 'server', 'units']) {
        await t.enterText(find.byKey(const Key('settings-search')), q);
        await t.pump();
      }
    });

    testWidgets('wide screens get a centred column of at most 600 dp', (WidgetTester t) async {
      setWindow(t, const Size(1200, 900));
      await t.pumpWidget(scaled(const SettingsScreen(), 1));
      await t.pump(const Duration(milliseconds: 300));
      final Rect r = t.getRect(find.byKey(const Key('settings-search')));
      expect(r.width, lessThanOrEqualTo(600));
      expect((r.center.dx - 600).abs(), lessThan(1), reason: 'centred');
      expect(t.takeException(), isNull);
    });
  });

  group('Notification settings', () {
    layoutMatrix('page', (WidgetTester t, Size size, double scale) async {
      await t.pumpWidget(scaled(const NotificationSettingsScreen(), scale));
      await t.pump(const Duration(milliseconds: 300));
      // Offline in tests: the error state must fit too.
      expect(find.byType(NotificationSettingsScreen), findsOneWidget);
    });
  });

  group('Link another phone', () {
    late FakeE2eeServer server;
    E2eeService phone() => E2eeService(
        api: server.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);

    setUp(() => server = FakeE2eeServer()..names[uA] = 'Alice');

    Future<void> settle(WidgetTester t) async {
      await t.pump();
      for (int i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      await t.pumpAndSettle();
    }

    /// Scrolls [f] into view (the page is a lazy list at large text).
    Future<void> reveal(WidgetTester t, Finder f) async {
      if (f.evaluate().isEmpty) {
        await t.dragUntilVisible(f, find.byType(ListView).first, const Offset(0, -200));
      }
      await t.ensureVisible(f);
      await t.pumpAndSettle();
    }

    layoutMatrix('every step of both phones', (WidgetTester t, Size size, double scale) async {
      final E2eeService old = phone();
      await t.runAsync(() => old.registerThisDevice(label: 'This phone'));
      final E2eeService fresh = phone();

      // New phone: choose, start, waiting (with QR and the folded reset).
      await t.pumpWidget(scaled(LinkDeviceScreen(service: fresh), scale));
      await t.pumpAndSettle();
      await reveal(t, find.text('No other phone?'));
      await t.tap(find.text('No other phone?'));
      await t.pumpAndSettle();
      await reveal(t, find.byKey(const Key('link-choose-new')));
      await t.tap(find.byKey(const Key('link-choose-new')));
      await t.pumpAndSettle();
      await reveal(t, find.byKey(const Key('link-make-code')));
      await t.tap(find.byKey(const Key('link-make-code')));
      await settle(t);
      // Each step now opens at its top (it used to keep the last step's scroll offset), so scroll to the code.
      await reveal(t, find.byKey(const Key('link-request')));
      final String request = (t.widget(find.byKey(const Key('link-request'))) as SelectableText).data!;
      await reveal(t, find.byKey(const Key('link-qr-toggle')));
      await t.tap(find.byKey(const Key('link-qr-toggle')));
      await t.pumpAndSettle();
      await reveal(t, find.byKey(const Key('link-approval-in')));
      await t.enterText(find.byKey(const Key('link-approval-in')), 'x' * 400);
      await t.pumpAndSettle();

      // Phone already in use: paste, compare (with Details), approved.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(scaled(LinkDeviceScreen(service: old, role: LinkRole.existingPhone), scale));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('link-request-in')), request);
      await t.pump();
      await reveal(t, find.byKey(const Key('link-check')));
      await t.tap(find.byKey(const Key('link-check')));
      await settle(t);
      await reveal(t, find.text('Details'));
      await t.tap(find.text('Details'));
      await t.pumpAndSettle();
      await reveal(t, find.byKey(const Key('link-approve')));
      await t.tap(find.byKey(const Key('link-approve')));
      await settle(t);
      expect(find.byKey(const Key('link-approval')), findsOneWidget);
      expect(find.byType(DsPage), findsOneWidget);
    });
  });
}
