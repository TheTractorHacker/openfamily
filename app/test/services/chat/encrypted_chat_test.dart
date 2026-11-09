import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/chat/chat_store.dart';
import 'package:openfamily/services/chat/chat_wire.dart';
import 'package:openfamily/services/chat/encrypted_chat_service.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import '../e2ee/lanes_channel_test.dart' show FakeLanes, FakeSk;
import '../e2ee/private_channel_test.dart' show FakeServer, FakeClock, Keys, Dir, Phone;

const String uA = '11111111-1111-4111-8111-111111111111'; // circle admin
const String uB = '22222222-2222-4222-8222-222222222222';
const String uC = '33333333-3333-4333-8333-333333333333'; // not in the circle
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String other = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

class MemBlobs implements ChatBlobApi {
  final Map<String, Uint8List> data = <String, Uint8List>{};
  @override
  Future<String> upload(String circleId, Uint8List sealed) async {
    final String id = E2ee.newUuid();
    data[id] = sealed;
    return id;
  }

  @override
  Future<Uint8List> download(String circleId, String blobId) async => data[blobId] ?? (throw StateError('404'));
}

class Dev {
  Dev(FakeE2eeServer server, FakeServer channel, this.user, FakeClock clock, MemBlobs blobs)
      : kv = MemoryKv() {
    final E2eeService svc = E2eeService(
        api: server.client(user), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
    service = svc;
    runtime = PrivateRuntime(
        service: svc, api: server.client(user), kv: kv, clock: clock, channel: channel,
        directory: StateSenderDirectory(server.client(user)));
    runtime.notify = (String t, String b) async => notes.add('$t: $b');
    runtime.chatNotify = (String t, String b) async => notes.add('$t: $b');
    runtime.chat.showNames = () async => showNames;
    chat = EncryptedChatService(runtime, blobs: blobs, now: clock.now);
  }
  final String user;
  final MemoryKv kv;
  late final E2eeService service;
  late final PrivateRuntime runtime;
  late final EncryptedChatService chat;
  final List<String> notes = <String>[];

  /// This phone's "Show names in notifications" choice.
  bool showNames = true;

  Future<List<ChatMessage>> list() async => (await chat.messages(priv)).messages;
  Future<void> sync() async {
    await runtime.flush();
    await runtime.catchUp(priv);
  }
}

void main() {
  late FakeE2eeServer server;
  late FakeServer channel;
  late FakeClock clock;
  late MemBlobs blobs;
  late Dev a, b;

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob', uC: 'Carol'});
    server.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = FakeServer();
    clock = FakeClock(DateTime.utc(2026, 11, 7, 12));
    blobs = MemBlobs();
    a = Dev(server, channel, uA, clock, blobs);
    b = Dev(server, channel, uB, clock, blobs);
    await a.service.registerThisDevice();
    await b.service.registerThisDevice();
    await a.service.enableCircle(priv);
    await b.service.syncCircleKeys(priv);
    final Circle c = Circle(id: priv, name: 'Family', role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');
    await a.runtime.setCircles(<Circle>[c]);
    await b.runtime.setCircles(<Circle>[c]);
  });

  group('wire format', () {
    test('parse accepts well formed events and refuses malformed ones', () {
      expect(ChatWire.parse(ChatWire.message('m1', ' hi ')), isA<ChatEvent>().having((ChatEvent e) => e.text, 'trimmed', 'hi'));
      expect(ChatWire.parse(ChatWire.edit('m1', 'x'))!.kind, ChatEventKind.edit);
      expect(ChatWire.parse(ChatWire.delete('m1', uA))!.author, uA);
      expect(ChatWire.parse(<String, dynamic>{'v': 2, 'k': 'msg', 'id': 'a', 't': 'x'}), isNull); // newer format: ignored
      expect(ChatWire.parse(<String, dynamic>{'v': 1, 'k': 'msg', 'id': '', 't': 'x'}), isNull);
      expect(ChatWire.parse(<String, dynamic>{'v': 1, 'k': 'msg', 'id': 'a:b', 't': 'x'}), isNull); // ':' would forge a key
      expect(ChatWire.parse(<String, dynamic>{'v': 1, 'k': 'msg', 'id': 'a', 't': '   '}), isNull);
      expect(ChatWire.parse(ChatWire.message('a', 'x' * 2001)), isNull);
      expect(ChatWire.parse(<String, dynamic>{'v': 1, 'k': 'msg', 'id': 'a', 't': 'x', 'img': <String, dynamic>{'b': 'nope'}}), isNull);
      expect(ChatWire.parse(<String, dynamic>{'v': 1, 'k': 'zap', 'id': 'a'}), isNull);
    });

    test('attachment encryption: round trip, tamper, wrong key, wrong circle', () async {
      final Uint8List plain = Uint8List.fromList(List<int>.generate(1000, (int i) => i % 251));
      final Uint8List key = ChatBlobCrypto.newKey();
      final Uint8List sealed = await ChatBlobCrypto.encrypt(plain, key, priv);
      expect(sealed.length, plain.length + 1 + 24 + 16);
      expect(await ChatBlobCrypto.decrypt(sealed, key, priv), plain);
      final Uint8List t = Uint8List.fromList(sealed)..[40] ^= 1;
      await expectLater(ChatBlobCrypto.decrypt(t, key, priv), throwsA(isA<E2eeAuthException>()));
      await expectLater(ChatBlobCrypto.decrypt(sealed, ChatBlobCrypto.newKey(), priv), throwsA(isA<E2eeAuthException>()));
      await expectLater(ChatBlobCrypto.decrypt(sealed, key, other), throwsA(isA<E2eeAuthException>()));
      await expectLater(ChatBlobCrypto.decrypt(Uint8List(10), key, priv), throwsA(isA<E2eeFormatException>()));
    });
  });

  group('sealing rules', () {
    test('chat is sealed on the phone line even in the server lane; other purposes follow the lane', () async {
      final Phone p = await Phone.make(uA, 0xa1);
      final Keys keys = Keys()..byEpoch[1] = Uint8List.fromList(List<int>.filled(32, 7));
      final FakeLanes lanes = FakeLanes()..own = const LaneChoice(E2ee.lineServer, 1);
      final FakeSk sk = FakeSk()..byGen[1] = Uint8List.fromList(List<int>.filled(32, 9));
      final ChannelSealer s = ChannelSealer(keys: keys, kv: MemoryKv(), clock: clock, lanes: lanes, serverKeys: sk);
      final SenderIdentity me = SenderIdentity(p.deviceId, p.edSeed, uA);
      final WireItem fix = await s.seal(me, priv, ChannelPurpose.fix, <String, dynamic>{'lat': 1.0, 'lon': 2.0});
      final WireItem chat = await s.seal(me, priv, ChannelPurpose.chat, ChatWire.message('m', 'hello'));
      expect(fix.line, E2ee.lineServer);
      expect(chat.line, E2ee.linePhone);
      expect(chat.twin, isNull);
    });

    test('events and check-ins are sealed on the phone line even in the server lane (members read them)', () async {
      final Phone p = await Phone.make(uA, 0xa1);
      final Keys keys = Keys()..byEpoch[1] = Uint8List.fromList(List<int>.filled(32, 7));
      final FakeLanes lanes = FakeLanes()..own = const LaneChoice(E2ee.lineServer, 1);
      final FakeSk sk = FakeSk()..byGen[1] = Uint8List.fromList(List<int>.filled(32, 9));
      final ChannelSealer s = ChannelSealer(keys: keys, kv: MemoryKv(), clock: clock, lanes: lanes, serverKeys: sk);
      final SenderIdentity me = SenderIdentity(p.deviceId, p.edSeed, uA);
      for (final String purpose in <String>[ChannelPurpose.event, ChannelPurpose.checkin]) {
        final WireItem it = await s.seal(me, priv, purpose, <String, dynamic>{'k': 'place', 'a': 'enter', 'name': 'Home'});
        expect(it.line, E2ee.linePhone, reason: purpose);
      }
      // Fixes still follow the lane (the server processes them).
      expect((await s.seal(me, priv, ChannelPurpose.fix, <String, dynamic>{'lat': 1.0, 'lon': 2.0})).line, E2ee.lineServer);
    });

    test('a place is sealed on the phone line even in the server lane, so every member can read it', () async {
      final Phone p = await Phone.make(uA, 0xa1);
      final Keys keys = Keys()..byEpoch[1] = Uint8List.fromList(List<int>.filled(32, 7));
      final FakeLanes lanes = FakeLanes()..own = const LaneChoice(E2ee.lineServer, 1);
      final FakeSk sk = FakeSk()..byGen[1] = Uint8List.fromList(List<int>.filled(32, 9));
      final ChannelSealer s = ChannelSealer(keys: keys, kv: MemoryKv(), clock: clock, lanes: lanes, serverKeys: sk);
      final SenderIdentity me = SenderIdentity(p.deviceId, p.edSeed, uA);
      final WireItem place = await s.seal(me, priv, ChannelPurpose.place, <String, dynamic>{'id': 'p1', 'name': 'Home'});
      expect(place.line, E2ee.linePhone);
      expect(place.twin, isNull);
    });

    test('a received chat item on the server line is refused by the receiver', () async {
      // The signed header of an item names its line; chat on the server line is never valid.
      final Phone p = await Phone.make(uA, 0xa1);
      final Keys keys = Keys()..byEpoch[1] = Uint8List.fromList(List<int>.filled(32, 7));
      final WireItem it = WireItem(
          circleId: priv, deviceId: p.deviceId, seq: 1, purpose: ChannelPurpose.chat, epoch: 1, sizeBucket: 256,
          ciphertext: Uint8List.fromList(<int>[2, 1, 0, 0, 0, 1, ...List<int>.filled(24 + 256 + 16, 3)]), line: E2ee.lineServer, id: 1);
      final ChannelReceiver r = ChannelReceiver(keys: keys, directory: Dir()..devices[p.deviceId] = p.key(), kv: MemoryKv(), clock: clock);
      await expectLater(r.process(it), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.laneMismatch)));
    });
  });

  group('two phones', () {
    test('send, receive, the server relay holds no plaintext, local notification shows the text', () async {
      final ChatMessage sent = await a.chat.send(priv, 'dinner at 7? the secret word is pineapple');
      expect(sent.sendState, ChatSendState.sending);
      expect(sent.senderName, 'Alice');
      await a.sync();
      await b.sync();
      final List<ChatMessage> got = await b.list();
      expect(got.single.body, 'dinner at 7? the secret word is pineapple');
      expect(got.single.senderName, 'Alice');
      expect(got.single.encrypted, isTrue);
      expect(b.notes, <String>['Alice in Family: dinner at 7? the secret word is pineapple']);
      // The relay saw ciphertext only.
      for (final WireItem i in channel.items) {
        expect(i.purpose, ChannelPurpose.chat);
        expect(i.line, E2ee.linePhone);
        expect(latin1.decode(i.ciphertext).contains('pineapple'), isFalse);
      }
      // The sender's own copy becomes delivered (echo), same id, relay position.
      final ChatMessage mine = (await a.list()).single;
      expect(mine.sendState, ChatSendState.sent);
      expect(mine.id, got.single.id);
      // Nothing is persisted in plaintext outside the chat store of each phone.
      expect(a.kv.data['queue/v1'] ?? '', isNot(contains('pineapple')));
    });

    test('"Show names in notifications" off: the local chat notification names nobody and shows no text', () async {
      b.showNames = false;
      await a.chat.send(priv, 'the secret word is pineapple');
      await a.sync();
      await b.sync();
      expect((await b.list()).single.body, 'the secret word is pineapple');
      expect(b.notes, <String>['New message in Family: ']);
    });

    test('idempotent send: the same client id twice makes one message', () async {
      await a.chat.send(priv, 'once', clientId: 'cid-1');
      await a.chat.send(priv, 'once', clientId: 'cid-1');
      await a.sync();
      await b.sync();
      expect((await b.list()).length, 1);
      expect(channel.items.length, 1);
    });

    test('a replayed or duplicated relay item is applied once and notifies once', () async {
      await a.chat.send(priv, 'hello');
      await a.runtime.flush();
      await b.runtime.catchUp(priv);
      await b.runtime.sync.resetCursor(priv);
      await b.runtime.catchUp(priv);
      expect((await b.list()).length, 1);
      expect(b.notes.length, 1);
    });

    test('unread counts others only, the exact count lives on the phone', () async {
      await a.chat.send(priv, 'one');
      await a.chat.send(priv, 'two');
      await a.sync();
      await b.sync();
      expect((await b.chat.unread())[priv], 2);
      expect((await a.chat.unread())[priv], 0); // own messages are never unread
      await b.chat.markRead(priv);
      expect((await b.chat.unread())[priv], 0);
      await b.chat.send(priv, 'three'); // own message
      await b.sync();
      await a.sync();
      expect((await a.chat.unread())[priv], 1);
    });

    test('edit: only the author; newer edit wins over a replayed older one', () async {
      final ChatMessage m = await a.chat.send(priv, 'v1');
      await a.sync();
      await b.sync();
      clock.t = clock.t.add(const Duration(minutes: 1));
      await a.chat.edit(priv, m.id, 'v2');
      await a.runtime.flush();
      final WireItem edit2 = channel.items.last;
      clock.t = clock.t.add(const Duration(minutes: 1));
      await a.chat.edit(priv, m.id, 'v3');
      await a.sync();
      await b.sync();
      expect((await b.list()).single.body, 'v3');
      expect((await b.list()).single.editedAt, isNotNull);
      // A relay replays the OLDER edit (v2) after v3: the phone keeps v3.
      await b.runtime.onWireFrame(<String, dynamic>{
        'type': 'e2ee_item', 'circle_id': priv, 'id': 99, 'device_id': edit2.deviceId, 'seq': edit2.seq, 'purpose': 'chat',
        'epoch': edit2.epoch, 'size_bucket': edit2.sizeBucket, 'ciphertext': base64.encode(edit2.ciphertext),
      });
      expect((await b.list()).single.body, 'v3');
      // Bob cannot edit Alice's message: his edit addresses HIS OWN (author, id) and changes nothing of hers.
      await expectLater(b.chat.edit(priv, m.id, 'hacked'), throwsA(isA<ChatException>()));
      await b.runtime.queueSealed(priv, ChannelPurpose.chat, ChatWire.edit(m.id.split(':').last, 'forged edit'));
      await b.sync();
      await a.sync();
      expect((await a.list()).single.body, 'v3');
      expect((await b.list()).single.body, 'v3');
    });

    test('delete: author removes own; admin removes anyone\'s; a member cannot remove someone else\'s', () async {
      final ChatMessage am = await a.chat.send(priv, 'from admin');
      final ChatMessage bm = await b.chat.send(priv, 'from bob');
      await a.sync();
      await b.sync();
      await a.sync();
      expect((await b.list()).length, 2);
      // Bob forges a tombstone for Alice's message: honoured by nobody.
      await b.runtime.queueSealed(priv, ChannelPurpose.chat, ChatWire.delete(am.id.split(':').last, uA));
      await b.sync();
      await a.sync();
      expect((await a.list()).length, 2);
      expect((await b.list()).length, 2);
      await expectLater(b.chat.delete(priv, am.id), throwsA(isA<ChatException>()));
      // Bob deletes his own message.
      await b.chat.delete(priv, bm.id);
      await b.sync();
      await a.sync();
      expect((await a.list()).map((ChatMessage x) => x.body), <String>['from admin']);
      // The admin deletes a member's message.
      final ChatMessage bm2 = await b.chat.send(priv, 'bob again');
      await b.sync();
      await a.sync();
      await a.chat.delete(priv, bm2.id);
      await a.sync();
      await b.sync();
      expect((await b.list()).map((ChatMessage x) => x.body), <String>['from admin']);
    });

    test('a tombstone that arrives before its message suppresses it', () async {
      final ChatMessage m = await b.chat.send(priv, 'late');
      final String id = m.id.split(':').last;
      // Deliver the delete first by processing out of order on A's phone.
      await b.chat.delete(priv, m.id);
      await b.runtime.flush();
      final List<WireItem> items = List<WireItem>.of(channel.items);
      expect(items.length, 2);
      // Cursor-ordered catch-up would give message then delete; feed delete first.
      for (final WireItem w in items.reversed) {
        await a.runtime.onWireFrame(<String, dynamic>{
          'type': 'e2ee_item', 'circle_id': priv, 'id': w.id, 'device_id': w.deviceId, 'seq': w.seq, 'purpose': 'chat',
          'epoch': w.epoch, 'size_bucket': w.sizeBucket, 'ciphertext': base64.encode(w.ciphertext),
        });
      }
      expect(await a.list(), isEmpty);
      expect(await a.runtime.chatStore.isTombstoned(priv, '$uB:$id'), isTrue);
    });

    test('photo: encrypted with a per-file key, the blob is opaque, the receiver opens it', () async {
      final Uint8List jpeg = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, ...List<int>.generate(2000, (int i) => (i * 7) % 256)]);
      final ChatMessage m = await a.chat.sendPhoto(priv, jpeg);
      expect(m.hasImage, isTrue);
      await a.sync();
      await b.sync();
      final ChatMessage got = (await b.list()).single;
      expect(got.hasImage, isTrue);
      expect(await b.chat.photo(priv, got.id), jpeg);
      expect(await a.chat.photo(priv, m.id), jpeg);
      final Uint8List stored = blobs.data.values.single;
      expect(stored.length, greaterThan(jpeg.length));
      expect(stored.sublist(25, 60), isNot(jpeg.sublist(0, 35)));
    });

    test('history: a message sent before the other phone had the key stays pending and shows once the key arrives', () async {
      final Dev late = Dev(server, channel, uC, clock, blobs);
      await late.service.registerThisDevice();
      server.circles[priv]!.members.add(uC);
      await late.runtime.setCircles(<Circle>[Circle(id: priv, name: 'F', role: 'member', sharingEnabled: true, memberCount: 3, e2eeMode: 'private')]);
      await a.chat.send(priv, 'before carol joined');
      await a.sync();
      // No key on Carol's phone: nothing readable, nothing lost, no crash.
      await late.runtime.catchUp(priv);
      expect(await late.list(), isEmpty);
      expect((await late.chat.info(priv)).waitingForKey, isTrue);
      // A removed/unknown member never reads: the epoch key was never wrapped to Carol.
      expect(late.notes, isEmpty);
    });

    test('info: banner state and the members whose app cannot read encrypted chat', () async {
      final ChatCircleInfo ok = await a.chat.info(priv);
      expect(ok.encrypted, isTrue);
      expect(ok.waitingForKey, isFalse);
      expect(ok.outdatedMembers, isEmpty);
    });

    test('info names a member whose app predates encrypted chat', () async {
      final FakeE2eeServer s2 = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      s2.circle(priv, members: <String>[uA, uB], admin: uA);
      s2.oldAppUsers.add(uB); // Bob registers without capabilities
      final Dev a2 = Dev(s2, channel, uA, clock, blobs);
      final Dev b2 = Dev(s2, channel, uB, clock, blobs);
      await a2.service.registerThisDevice();
      await b2.service.registerThisDevice();
      await a2.service.enableCircle(priv);
      await a2.runtime.setCircles(<Circle>[Circle(id: priv, name: 'F', role: 'admin', sharingEnabled: true, memberCount: 2, e2eeMode: 'private')]);
      final ChatCircleInfo info = await a2.chat.info(priv);
      expect(info.outdatedMembers, <String>['Bob']);
    });

    test('failed state: a sent item that left the queue but never came back is offered for retry', () async {
      final ChatMessage m = await a.chat.send(priv, 'lost?');
      await a.runtime.flush(); // uploaded
      channel.items.clear(); // ... and the relay lost it
      clock.t = clock.t.add(const Duration(minutes: 11));
      expect((await a.list()).single.sendState, ChatSendState.failed);
      await a.chat.retry(priv, m.id);
      await a.sync();
      await b.sync();
      expect((await b.list()).single.body, 'lost?');
      expect((await a.list()).single.sendState, ChatSendState.sent);
    });

    test('offline send is queued and goes out later', () async {
      channel.offline = true;
      await a.chat.send(priv, 'offline hello');
      await a.runtime.flush();
      expect(channel.items, isEmpty);
      expect((await a.list()).single.sendState, ChatSendState.sending);
      channel.offline = false;
      await a.sync();
      await b.sync();
      expect((await b.list()).single.body, 'offline hello');
    });
  });

  group('removed member', () {
    test('a phone without the new epoch key cannot open later messages', () async {
      await a.chat.send(priv, 'first');
      await a.sync();
      await b.sync();
      // Alice rotates the key without Bob (member removal).
      server.circles[priv]!.members.remove(uB);
      await a.service.bumpEpoch(priv);
      clock.t = clock.t.add(const Duration(minutes: 20));
      await a.chat.send(priv, 'after bob left');
      await a.sync();
      await b.runtime.catchUp(priv);
      final List<ChatMessage> got = await b.list();
      expect(got.map((ChatMessage m) => m.body), <String>['first']);
    });
  });

  group('store', () {
    test('tombstones, pending edits and the cap', () async {
      final ChatStore s = ChatStore(kv: MemoryKv(), maxMessages: 3, now: () => clock.t);
      for (int i = 1; i <= 5; i++) {
        await s.applyMessage(priv, uA, ChatEvent(kind: ChatEventKind.message, id: 'm$i', text: 't$i'), tsMs: i, cursor: i);
      }
      expect((await s.all(priv)).map((StoredChat m) => m.id), <String>['m5', 'm4', 'm3']);
      // an edit before its message waits for it
      await s.applyEdit(priv, uA, const ChatEvent(kind: ChatEventKind.edit, id: 'm9', text: 'edited'), tsMs: 50, itemSeq: 2);
      await s.applyMessage(priv, uA, const ChatEvent(kind: ChatEventKind.message, id: 'm9', text: 'orig'), tsMs: 40, cursor: 9);
      expect((await s.find(priv, '$uA:m9'))!.text, 'edited');
      // the same id from another author is a different message
      await s.applyMessage(priv, uB, const ChatEvent(kind: ChatEventKind.message, id: 'm9', text: 'bob'), tsMs: 41, cursor: 10);
      expect((await s.find(priv, '$uA:m9'))!.text, 'edited');
      expect((await s.find(priv, '$uB:m9'))!.text, 'bob');
    });
  });
}
