// SOS and Help with the server unreachable: honest "not sent yet", durable, never lost.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/screens/help_alert_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/services/location_reporter.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/offline/offline_cache.dart';
import 'package:openfamily/services/offline/offline_queue.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every request fails like a dead connection (flutter_test would otherwise answer 400 to real HTTP).
Future<void> offline(Future<void> Function() body) =>
    http.runWithClient(body, () => MockClient((http.Request r) async => throw http.ClientException('Connection refused')));

void main() {
  late MemoryQueueStorage storage;

  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'a', 'refresh_token_v2': 'r'});
    // Configured server that nothing answers: the real client fails like a dead connection.
    SharedPreferences.setMockInitialValues(<String, Object>{'sos_intro_seen': true, 'wb_api_base_url': 'https://unreachable.invalid'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    storage = MemoryQueueStorage();
    OfflineQueue.instance = OfflineQueue(storage: storage);
    final MemoryVault v = MemoryVault();
    OfflineCache.instance = OfflineCache(vault: v);
    await OfflineCache.instance.write('emergency-contacts', <Object>[
      <String, Object>{'id': '1', 'name': 'Mum', 'phone': '+49 170 1234567'}
    ]);
  });

  /// Leave no timer behind: the SOS location burst (5 min) and the contacts fetch retry.
Future<void> finish(WidgetTester t) async {
  LocationReporter.stopSosBurst();
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 2));
}

Future<void> pressSos(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: SosScreen(smsConfigured: false)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('sos-send-button')));
    await t.pump();
    await t.tap(find.text('Send SOS'));
    for (int i = 0; i < 20; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('SOS with no connection is saved, says "not sent yet" and offers the phone SMS; it is not shown as sent', (WidgetTester t) async {
  await offline(() async {
    await pressSos(t);
    expect(find.text('SOS sent'), findsNothing);
    expect(find.text('SOS not sent yet'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sos-sms-fallback')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sos-retry-now')), findsOneWidget);
    final List<QueuedItem> q = await t.runAsync(() => OfflineQueue.instance.items(kind: QueueKind.sos)) ?? <QueuedItem>[];
    expect(q.length, 1);
    expect(q.single.path, '/alerts/sos');
    expect(q.single.body!['client_id'], q.single.id, reason: 'the server stores a replay once');
    await finish(t);
  });
  });

  testWidgets('after the app is killed and reopened the waiting SOS is still there', (WidgetTester t) async {
  await offline(() async {
    await pressSos(t);
    await t.pumpWidget(const SizedBox());
    // "Restart": a fresh queue object on the same storage, a fresh screen.
    OfflineQueue.instance = OfflineQueue(storage: storage);
    await t.pumpWidget(const MaterialApp(home: SosScreen(smsConfigured: false)));
    for (int i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('SOS not sent yet'), findsOneWidget);
    await finish(t);
  });
  });

  testWidgets('"I am safe, cancel this SOS" removes an SOS nobody was told about', (WidgetTester t) async {
  await offline(() async {
    await pressSos(t);
    await t.tap(find.byKey(const ValueKey<String>('sos-cancel-queued')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(await t.runAsync(() => OfflineQueue.instance.size()), 0);
    expect(find.text('Cancelled'), findsOneWidget);
    await finish(t);
  });
  });

  testWidgets('Help alert offline is saved once even if pressed again', (WidgetTester t) async {
  await offline(() async {
    await t.pumpWidget(const MaterialApp(home: HelpAlertScreen()));
    for (int i = 0; i < 2; i++) {
      await t.tap(find.widgetWithText(DsPillButton, 'Send Help Alert'));
      for (int k = 0; k < 15; k++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 50));
      }
    }
    expect(find.text('Help alert sent'), findsNothing);
    expect(find.textContaining('Not sent yet'), findsOneWidget);
    expect(await t.runAsync(() => OfflineQueue.instance.size()), 1);
    await finish(t);
  });
  });
}
