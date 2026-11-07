@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/services/chat/chat_wire.dart';
import 'package:openfamily/services/chat/encrypted_chat_service.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';

import 'harness.dart';

// Encrypted chat, real Dart phones against the real Go server and the real
// e2ee-bridge sidecar (docs/design/E2EE_CHAT.md). Skipped unless
// scripts/e2e-lanes.sh set E2E_BASE_URL. Scenarios build on each other.

// Distinctive words so a leak is easy to find in the database and the server log.
const String word1 = 'xyzzy-secret-ONE';
const String word2 = 'plugh-secret-TWO';
const String word3 = 'quux-secret-THREE';

Future<(int, Map<String, dynamic>)> rawStatus(E2eEnv env, String method, String path, {Map<String, dynamic>? body, String? token}) async {
  final http.Request r = http.Request(method, Uri.parse('${env.base}$path'));
  r.headers['Content-Type'] = 'application/json';
  if (token != null) r.headers['Authorization'] = 'Bearer $token';
  if (body != null) r.body = jsonEncode(body);
  final http.Response res = await http.Response.fromStream(await http.Client().send(r));
  return (res.statusCode, res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>);
}

void main() {
  final E2eEnv? env = E2eEnv.fromEnvironment();
  if (env == null) {
    test('real-server chat e2e', () {}, skip: 'set E2E_BASE_URL (scripts/e2e-lanes.sh) to run against a real server');
    return;
  }

  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  late Phone a, b, c;
  late String circle;
  late ServerDevice server;
  late Db db;
  final Map<Phone, EncryptedChatService> chat = <Phone, EncryptedChatService>{};

  // Runs a chat action as [p] and pushes the sealed item out (the app flushes in the background).
  Future<T> act<T>(Phone p, Future<T> Function() f) async {
    final T r = await p.run(f);
    await p.run(() => p.runtime.flush());
    return r;
  }

  Future<List<ChatMessage>> read(Phone p) => p.run(() async {
        await p.runtime.flush();
        await p.runtime.catchUp(circle);
        return (await chat[p]!.messages(circle)).messages;
      });

  setUpAll(() async {
    await bootstrap(env);
    db = Db(env);
    a = Phone('Anna', 'e2e-chat-$stamp-a@example.test', 'correct horse battery');
    b = Phone('Ben', 'e2e-chat-$stamp-b@example.test', 'correct horse battery');
    c = Phone('Cleo', 'e2e-chat-$stamp-c@example.test', 'correct horse battery');
    for (final Phone p in <Phone>[a, b, c]) {
      await p.signUpAndLogin(env);
      p.startRuntime();
      chat[p] = EncryptedChatService(p.runtime, legacy: ApiChatService());
    }
    final Map<String, dynamic> created = await rawJson(env, 'POST', '/circles', body: <String, dynamic>{'name': 'E2E chat'}, token: a.token);
    circle = (created['id'] ?? (created['circle'] as Map<String, dynamic>)['id']) as String;
    // Before the circle is private, Cleo's phone already wrote plaintext history.
    final Map<String, dynamic> inv = await rawJson(env, 'POST', '/circles/$circle/invites', body: <String, dynamic>{'role': 'member', 'max_uses': 10, 'expires_in_hours': 24}, token: a.token);
    final String code = (inv['code'] ?? (inv['invite'] as Map<String, dynamic>)['code']) as String;
    for (final Phone p in <Phone>[b, c]) {
      await rawJson(env, 'POST', '/circles/join', body: <String, dynamic>{'code': code}, token: p.token);
    }
    await rawJson(env, 'POST', '/circles/$circle/chat', body: <String, dynamic>{'body': 'old plaintext history'}, token: c.token);
    for (final Phone p in <Phone>[a, b, c]) {
      await p.run(() => p.service.registerThisDevice());
    }
    await a.run(() => a.service.enableCircle(circle));
    await b.run(() => b.service.syncCircleKeys(circle));
    await c.run(() => c.service.syncCircleKeys(circle));
    for (final Phone p in <Phone>[a, b, c]) {
      await p.syncCircle(circle);
    }
    server = ServerDevice(env, a);
    await server.enroll();
    await server.runOnce(); // pins the server key (as the sidecar does on its first run)
  });

  group('chat in a private circle', () {
    test('Anna sends, Ben and Cleo read it; local notifications carry the text; the server holds ciphertext only', () async {
      await act(a, () => chat[a]!.send(circle, '$word1 \u{1F305} dinner at 7?'));
      for (final Phone p in <Phone>[b, c]) {
        final List<ChatMessage> got = await read(p);
        final ChatMessage m = got.firstWhere((ChatMessage x) => x.body.contains(word1));
        expect(m.senderName, 'Anna');
        expect(m.encrypted, isTrue);
        expect(p.notes.any((String n) => n.contains(word1)), isTrue, reason: '${p.name} shows the text locally');
      }
      final List<ChatMessage> mine = await read(a);
      expect(mine.firstWhere((ChatMessage x) => x.body.contains(word1)).sendState, ChatSendState.sent);
      expect(mine.firstWhere((ChatMessage x) => x.body.contains(word1)).legacy, isFalse);
    });

    test('database: one phone-line chat item, no plaintext anywhere, TTL about 30 days', () async {
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND purpose = 'chat'"), 1);
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND purpose = 'chat' AND key_line <> 'phone'"), 0);
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE position('xyzzy'::bytea IN ciphertext) > 0"), 0);
      expect(await db.count("SELECT count(*) FROM chat_messages WHERE body LIKE '%xyzzy%'"), 0);
      expect(await db.count("SELECT count(*) FROM audit_log WHERE detail LIKE '%xyzzy%'"), 0);
      final int days = await db.count(
          "SELECT round(extract(epoch FROM (expires_at - received_at)) / 86400)::int FROM e2ee_items WHERE circle_id = '$circle' AND purpose = 'chat'");
      expect(days, inInclusiveRange(29, 31));
    });

    test('the old app path is refused with a clear code; old plaintext history stays readable and is marked', () async {
      final (int status, Map<String, dynamic> body) = await rawStatus(env, 'POST', '/circles/$circle/chat', body: <String, dynamic>{'body': 'leak?'}, token: b.token);
      expect(status, 409);
      expect(body['code'], 'chat_encrypted');
      expect(await db.count("SELECT count(*) FROM chat_messages WHERE body = 'leak?'"), 0);
      final List<ChatMessage> got = await read(b);
      final ChatMessage old = got.firstWhere((ChatMessage x) => x.body == 'old plaintext history');
      expect(old.legacy, isTrue);
      expect((await b.run(() => chat[b]!.info(circle))).hasLegacyHistory, isTrue);
    });

    test('unread: the phone counts exactly; the server counts from metadata only', () async {
      expect((await b.run(() => chat[b]!.unread()))[circle], 1);
      final (int s, Map<String, dynamic> body) = await rawStatus(env, 'GET', '/chat/unread', token: b.token);
      expect(s, 200);
      expect((body['circles'] as Map<String, dynamic>)[circle], greaterThanOrEqualTo(1));
      await b.run(() => chat[b]!.markRead(circle));
      expect((await b.run(() => chat[b]!.unread()))[circle], 0);
      final (int s2, Map<String, dynamic> body2) = await rawStatus(env, 'GET', '/chat/unread', token: b.token);
      expect(s2, 200);
      expect((body2['circles'] as Map<String, dynamic>)[circle], 0);
    });

    test('edit and delete: authors act on their own; the admin deletes anyone\'s; a member\'s forged edit or delete changes nothing', () async {
      final ChatMessage bm = await act(b, () => chat[b]!.send(circle, '$word2 from Ben'));
      await read(a);
      await read(c);
      await act(b, () => chat[b]!.edit(circle, bm.id, '$word2 from Ben (edited)'));
      expect((await read(a)).any((ChatMessage x) => x.body == '$word2 from Ben (edited)' && x.editedAt != null), isTrue);
      // Cleo forges a delete of Ben's message and an edit of it.
      final String id = bm.id.split(':').last;
      await c.run(() async {
        await c.runtime.queueSealed(circle, ChannelPurpose.chat, ChatWire.delete(id, b.userId));
        await c.runtime.queueSealed(circle, ChannelPurpose.chat, ChatWire.edit(id, 'forged'));
        await c.runtime.flush();
      });
      final List<ChatMessage> seenByA = await read(a);
      expect(seenByA.any((ChatMessage x) => x.body == '$word2 from Ben (edited)'), isTrue);
      expect(seenByA.any((ChatMessage x) => x.body == 'forged'), isFalse);
      // Anna is admin: her delete is honoured by everybody.
      await act(a, () => chat[a]!.delete(circle, bm.id));
      await a.run(() => a.runtime.flush());
      for (final Phone p in <Phone>[a, b, c]) {
        expect((await read(p)).any((ChatMessage x) => x.body.contains(word2)), isFalse, reason: p.name);
      }
      // Ben deletes his own message.
      final ChatMessage bm2 = await act(b, () => chat[b]!.send(circle, '$word3 mine to delete'));
      expect((await read(c)).any((ChatMessage x) => x.body.contains(word3)), isTrue);
      await act(b, () => chat[b]!.delete(circle, bm2.id));
      expect((await read(c)).any((ChatMessage x) => x.body.contains(word3)), isFalse);
      // A member cannot delete someone else's message from the app either.
      final ChatMessage am = await act(a, () => chat[a]!.send(circle, 'admin keeps this'));
      await expectLater(c.run(() => chat[c]!.delete(circle, am.id)), throwsA(isA<ChatException>()));
    });

    test('photo: encrypted on the phone, opaque at the server, opened by the others', () async {
      final Uint8List jpeg = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0, ...List<int>.generate(3000, (int i) => (i * 13 + 5) % 256)]);
      final ChatMessage m = await act(a, () => chat[a]!.sendPhoto(circle, jpeg));
      final ChatMessage got = (await read(b)).firstWhere((ChatMessage x) => x.hasImage);
      expect(await b.run(() => chat[b]!.photo(circle, got.id)), jpeg);
      expect(m.hasImage, isTrue);
      expect(await db.count("SELECT count(*) FROM e2ee_blobs WHERE circle_id = '$circle' AND position('\\xffd8ffe0'::bytea IN data) > 0"), 0);
      // A person outside the circle cannot fetch the blob.
      final String blob = (await db.query("SELECT id::text FROM e2ee_blobs WHERE circle_id = '$circle' LIMIT 1")).single.single as String;
      final Phone outsider = Phone('Dan', 'e2e-chat-$stamp-d@example.test', 'correct horse battery');
      await outsider.signUpAndLogin(env);
      final (int s, _) = await rawStatus(env, 'GET', '/circles/$circle/e2ee/blobs/$blob', token: outsider.token);
      expect(s, 404);
    });

    test('processing lanes: a member in the server lane still chats on the phone line, and the real sidecar never touches chat', () async {
      await a.run(() => a.lanes.publishPolicy(circle, serverAssist: true));
      for (final Phone p in <Phone>[a, b]) {
        await p.run(() => p.lanes.setLane(circle, E2ee.lineServer, confirmServerFingerprintHex: server.fingerprintHex));
      }
      await a.run(() => a.lanes.maintain(circle));
      await act(b, () => chat[b]!.send(circle, '$word1 sent from the server lane'));
      await read(a);
      final List<List<dynamic>> rows = await db.query(
          "SELECT key_line FROM e2ee_items WHERE circle_id = '$circle' AND purpose = 'chat' ORDER BY id DESC LIMIT 1");
      expect(rows.single.single, 'phone');
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND purpose = 'chat' AND key_line = 'server'"), 0);
      final ProcessResult r = await server.runOnce();
      final String out = '${r.stdout}${r.stderr}';
      if (out.contains('waiting for member consent') && Platform.environment['E2E_REQUIRE_SIDECAR'] != '1') {
        markTestSkipped('sidecar build predates lanes');
      } else {
        expect(r.exitCode, 0, reason: out);
      }
      // Whatever the sidecar did, the server never wrote chat plaintext anywhere.
      expect(await db.count("SELECT count(*) FROM chat_messages WHERE circle_id = '$circle' AND body LIKE '%secret%'"), 0);
      // The server key cannot pull chat even by asking for it.
      final (int s, Map<String, dynamic> body) =
          await rawStatus(env, 'GET', '/circles/$circle/e2ee/items?key_line=all&purpose=chat&as_device=${server.deviceId}', token: a.token);
      expect(s, 200);
      expect((body['items'] as List<dynamic>), isEmpty);
      // And the lane did not stop the others from reading it.
      expect((await read(c)).any((ChatMessage x) => x.body.contains('sent from the server lane')), isTrue);
    });

    test('admin can delete the old plaintext history; a member cannot', () async {
      final (int s, _) = await rawStatus(env, 'DELETE', '/circles/$circle/chat/history', token: b.token);
      expect(s, 403);
      final (int s2, Map<String, dynamic> body) = await rawStatus(env, 'DELETE', '/circles/$circle/chat/history', token: a.token);
      expect(s2, 200);
      expect(body['deleted'], 1);
      expect((await read(b)).any((ChatMessage x) => x.legacy), isFalse);
    });

    test('a removed member cannot read messages sealed after the new key', () async {
      final String? member = c.userId;
      await rawJson(env, 'DELETE', '/circles/$circle/members/$member', token: a.token);
      await a.run(() async {
        await a.service.syncCircleKeys(circle);
        await a.service.bumpEpoch(circle);
      });
      await act(a, () => chat[a]!.send(circle, 'after Cleo left'));
      await b.run(() => b.service.syncCircleKeys(circle)); // Ben's app does this on open / on a bad_epoch answer
      expect((await read(b)).any((ChatMessage x) => x.body == 'after Cleo left'), isTrue);
      final List<ChatMessage> cleo = await c.run(() async {
        try {
          await c.runtime.catchUp(circle);
        } catch (_) {}
        return (await chat[c]!.messages(circle)).messages;
      });
      expect(cleo.any((ChatMessage x) => x.body == 'after Cleo left'), isFalse);
    });
  });
}
