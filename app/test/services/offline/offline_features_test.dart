// The user-facing services with the server unreachable: chat, roster, places, profile, emergency contacts,
// SOS text fallback. Fake HTTP transport (refuses / 503) and an in-memory vault stand in for the network and the Keystore.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/models/emergency_contact.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/emergency_contact_service.dart';
import 'package:openfamily/services/family_service.dart';
import 'package:openfamily/services/offline/offline_cache.dart';
import 'package:openfamily/services/offline/offline_queue.dart';
import 'package:openfamily/services/offline/sos_sms_fallback.dart';
import 'package:openfamily/services/place_service.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Map<String, String> _json = <String, String>{'content-type': 'application/json'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryVault vault;
  late bool up;
  late List<http.Request> seen;

  http.Client server(Map<String, Object> routes) => MockClient((http.Request r) async {
        seen.add(r);
        if (!up) throw http.ClientException('Connection refused');
        final Object? body = routes['${r.method} ${r.url.path}'];
        if (body == null) return http.Response('{"error":"nope"}', 404, headers: _json);
        return http.Response(jsonEncode(body), r.method == 'POST' ? 201 : 200, headers: _json);
      });

  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'a', 'refresh_token_v2': 'r'});
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    vault = MemoryVault();
    OfflineCache.instance = OfflineCache(vault: vault);
    OfflineQueue.instance = OfflineQueue(storage: MemoryQueueStorage());
    PlaceService.invalidateCache();
    up = true;
    seen = <http.Request>[];
    ChatEvents.selfUserId = 'me';
  });

  Map<String, Object> msg(String id, int seq, String text) => <String, Object>{
        'id': id, 'seq': seq, 'circle_id': 'c1', 'sender_id': 'me', 'sender_name': 'Me', 'body': text,
        'created_at': '2026-11-07T10:00:00Z',
      };

  group('plain chat', () {
    test('opening a chat with the server down shows the last messages, then the ones waiting to be sent', () async {
      final ApiChatService svc = ApiChatService();
      await http.runWithClient(() async {
        final ChatPage live = await svc.messages('c1');
        expect(live.messages.length, 2);
        await Future<void>.delayed(Duration.zero);
        up = false;
        await svc.send('c1', 'written offline', clientId: 'cid-1');
        final ChatPage cached = await svc.messages('c1');
        expect(cached.messages.map((ChatMessage m) => m.body).toList(), <String>['hello', 'world', 'written offline']);
        expect(cached.messages.last.sendState, ChatSendState.sending);
        expect(cached.messages.last.id, 'local:cid-1');
      }, () => server(<String, Object>{
            'GET /circles/c1/chat': <String, Object>{'messages': <Object>[msg('m1', 1, 'hello'), msg('m2', 2, 'world')], 'readers': <Object>[]},
          }));
    });

    test('with no copy and no server the error surfaces (the screen shows its Retry card), no crash', () async {
      up = false;
      await http.runWithClient(() async {
        await expectLater(ApiChatService().messages('c1'), throwsA(isA<ChatException>()));
      }, () => server(<String, Object>{}));
    });

    test('messages written offline go out in order, once, when the server is back, and the bubble is swapped', () async {
      final ApiChatService svc = ApiChatService();
      final List<(String, ChatMessage)> delivered = <(String, ChatMessage)>[];
      OfflineQueue.instance.onDelivered.add(ChatEvents.handleQueueDelivered);
      final StreamSubscription<(String, ChatMessage)> sub = ChatEvents.localDelivered.listen(delivered.add);
      up = false;
      final List<String> posted = <String>[];
      final MockClient c = MockClient((http.Request r) async {
        if (!up) throw http.ClientException('refused');
        posted.add((jsonDecode(r.body) as Map<String, dynamic>)['body'] as String);
        final Map<String, dynamic> b = jsonDecode(r.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(msg('srv-${b['client_id']}', posted.length, b['body'] as String)), 201, headers: _json);
      });
      await http.runWithClient(() async {
        final ChatMessage a = await svc.send('c1', 'one', clientId: 'a');
        final ChatMessage b = await svc.send('c1', 'two', clientId: 'b');
        final ChatMessage d = await svc.send('c1', 'three', clientId: 'c');
        expect(<ChatSendState>[a.sendState, b.sendState, d.sendState], everyElement(ChatSendState.sending));
        expect(await OfflineQueue.instance.size(), 3);
        up = true;
        expect(await OfflineQueue.instance.flush(), 3);
        // The same flush twice (a second trigger) sends nothing again.
        expect(await OfflineQueue.instance.flush(), 0);
      }, () => c);
      await Future<void>.delayed(Duration.zero);
      expect(posted, <String>['one', 'two', 'three']);
      expect(delivered.map(((String, ChatMessage) e) => e.$1).toList(), <String>['a', 'b', 'c']);
      expect(delivered.first.$2.id, 'srv-a');
      await sub.cancel();
    });
  });

  group('roster (people on the map)', () {
    final List<Object> rows = <Object>[
      <String, Object>{'id': 'u1', 'name': 'Mum', 'lat': 52.5, 'lon': 13.4, 'ts': '2026-11-07T08:00:00Z', 'battery_pct': 40},
      <String, Object>{'id': 'u2', 'name': 'Dad', 'lat': 48.1, 'lon': 11.5, 'ts': '2026-11-07T09:30:00Z'},
    ];

    test('server down at start: everyone shows with the position and time they last had, flagged as remembered', () async {
      final FamilyService f = FamilyService();
      await http.runWithClient(() async {
        await f.fetchMembers();
        expect(f.servedFromCache, isFalse);
        await Future<void>.delayed(Duration.zero);
        // "Kill and restart": a new service object, empty memory, only the vault remains.
        final FamilyService restarted = FamilyService();
        up = false;
        final List<Member> m = await restarted.fetchMembers();
        expect(m.map((Member x) => x.name).toList(), <String>['Mum', 'Dad']);
        expect(m.first.position, isNotNull);
        expect(m.first.position!.latitude, 52.5);
        expect(m.first.lastSeen!.toUtc(), DateTime.utc(2026, 11, 7, 8), reason: 'the real age is kept, not "just now"');
        expect(restarted.servedFromCache, isTrue);
        expect(restarted.cachedSince, isNotNull);
      }, () => server(<String, Object>{'GET /family/members': rows, 'GET /family/places': <Object>[]}));
    });

    test('first ever start without network and nothing cached: a plain offline error for the Retry card', () async {
      up = false;
      await http.runWithClient(() async {
        await expectLater(FamilyService().fetchMembers(), throwsA(isA<ApiException>()));
      }, () => server(<String, Object>{}));
    });

    test('a 5xx storm on the roster is treated like being offline', () async {
      await http.runWithClient(() async {
        await FamilyService().fetchMembers();
        await Future<void>.delayed(Duration.zero);
      }, () => server(<String, Object>{'GET /family/members': rows, 'GET /family/places': <Object>[]}));
      await http.runWithClient(() async {
        final FamilyService f = FamilyService();
        for (int i = 0; i < 20; i++) {
          expect((await f.fetchMembers()).length, 2);
        }
      }, () => MockClient((http.Request r) async => http.Response('<html>503</html>', 503)));
    });

    test('the server answering 403 is not hidden by the cache', () async {
      await http.runWithClient(() async {
        await FamilyService().fetchMembers();
        await Future<void>.delayed(Duration.zero);
      }, () => server(<String, Object>{'GET /family/members': rows, 'GET /family/places': <Object>[]}));
      await http.runWithClient(() async {
        await expectLater(FamilyService().fetchMembers(), throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 403)));
      }, () => MockClient((http.Request r) async => r.url.path == '/family/places' ? http.Response('[]', 200, headers: _json) : http.Response('{"error":"no"}', 403)));
    });
  });

  test('places and profile come from the phone when the server is down', () async {
    await http.runWithClient(() async {
      expect((await PlaceService.fetchPlaces(force: true)).single.name, 'Home');
      expect((await ApiClient.getProfile()).id, 'me');
      await Future<void>.delayed(Duration.zero);
      up = false;
      PlaceService.invalidateCache();
      expect((await PlaceService.fetchPlaces(force: true)).single.name, 'Home');
      expect((await ApiClient.getProfile()).id, 'me', reason: 'chat and circles only need it to learn "who am I"');
    }, () => server(<String, Object>{
          'GET /family/places': <Object>[
            <String, Object>{'id': 'p1', 'name': 'Home', 'type': 'home', 'lat': 1.0, 'lon': 2.0, 'radius_meters': 100.0}
          ],
          'GET /api/profile': <String, Object>{'id': 'me', 'name': 'Me', 'email': 'me@example.test'},
        }));
  });

  group('SOS text fallback', () {
    test('contacts are remembered so the SMS fallback works with no server at all', () async {
      await http.runWithClient(() async {
        await EmergencyContactService().list();
        await Future<void>.delayed(Duration.zero);
        up = false;
        final List<EmergencyContact> l = await EmergencyContactService().list();
        expect(l.map((EmergencyContact c) => c.name).toList(), <String>['Mum', 'Neighbour']);
      }, () => server(<String, Object>{
            'GET /me/contacts': <Object>[
              <String, Object>{'id': '1', 'name': 'Mum', 'phone': '+49 170 1234567'},
              <String, Object>{'id': '2', 'name': 'Neighbour', 'phone': '(030) 555-0100'},
            ],
          }));
    });

    final List<EmergencyContact> contacts = <EmergencyContact>[
      const EmergencyContact(id: '1', name: 'Mum', phone: '+49 170 1234567'),
      const EmergencyContact(id: '2', name: 'N', phone: '(030) 555-0100'),
      const EmergencyContact(id: '3', name: 'bad', phone: '--'),
    ];

    test('opens the phone SMS app with every number, the text and the last position (Android separator)', () {
      final Uri u = buildSosSmsUri(contacts, lat: 52.5, lon: 13.4, name: 'Anna', platform: TargetPlatform.android)!;
      expect(u.scheme, 'sms');
      expect(u.path, '+491701234567;0305550100');
      final String body = u.queryParameters['body']!;
      expect(body, contains('Anna needs help'));
      expect(body, contains('mlat=52.50000&mlon=13.40000'));
      expect(u.toString(), isNot(contains('+help')), reason: 'spaces are %20, not +');
    });

    test('iOS separates with a comma; no contacts means no button; no position still works', () {
      expect(buildSosSmsUri(contacts, platform: TargetPlatform.iOS)!.path, '+491701234567,0305550100');
      expect(buildSosSmsUri(const <EmergencyContact>[]), isNull);
      expect(buildSosSmsUri(const <EmergencyContact>[EmergencyContact(id: '3', name: 'x', phone: 'abc')]), isNull);
      expect(buildSosSmsUri(contacts.take(1).toList())!.queryParameters['body'], isNot(contains('openstreetmap')));
    });
  });
}
