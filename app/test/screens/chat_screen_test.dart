import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/screens/chat_screen.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/theme/app_theme.dart';

ChatMessage _msg(int seq, String sender, String body, {String circle = 'c1'}) =>
    ChatMessage(
      id: 'id$seq',
      seq: seq,
      circleId: circle,
      senderId: sender,
      senderName: sender == 'me' ? 'Me' : 'Mom',
      body: body,
      createdAt: DateTime(2026, 1, 1, 9, seq % 60),
    );

class _FakeChat implements ChatService {
  _FakeChat(this.history);

  final List<ChatMessage> history;
  final List<String> sent = <String>[];
  int reads = 0;
  List<ChatReader> readers = const <ChatReader>[];
  Object? sendError;

  @override
  Future<String> myUserId() async => 'me';

  @override
  Future<ChatPage> messages(String circleId,
      {int? before, int? after, int limit = 50}) async {
    final List<ChatMessage> out = after == null
        ? history
        : history.where((ChatMessage m) => m.seq > after).toList();
    return ChatPage(out, null, readers);
  }

  final List<String?> clientIds = <String?>[];
  final List<String> edited = <String>[];
  final List<String> deleted = <String>[];

  @override
  Future<ChatMessage> edit(String circleId, String messageId, String body) async {
    edited.add('$messageId=$body');
    return ChatMessage(
      id: messageId, seq: 1, circleId: circleId, senderId: 'me',
      senderName: 'Me', body: body, createdAt: DateTime(2026, 1, 1, 9, 1),
      editedAt: DateTime(2026, 1, 1, 9, 5),
    );
  }

  @override
  Future<void> delete(String circleId, String messageId) async =>
      deleted.add(messageId);

  @override
  Future<ChatMessage> send(String circleId, String body,
      {String? clientId}) async {
    if (sendError != null) throw sendError!;
    sent.add(body);
    clientIds.add(clientId);
    return _msg(100 + sent.length, 'me', body);
  }

  @override
  Future<void> markRead(String circleId, {int? seq}) async => reads++;

  @override
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes,
      {String contentType = 'image/jpeg'}) async {
    photosSent++;
    return _msg(200, 'me', '');
  }

  @override
  Future<Uint8List> photo(String circleId, String messageId) async =>
      throw StateError('no photo');

  int photosSent = 0;

  @override
  Future<Map<String, int>> unread() async => <String, int>{'c1': 0};
}

Widget _app(ChatService svc, Stream<ChatMessage> live,
        {Stream<ChatMessage>? edits,
        Stream<(String, String)>? deletes,
        Stream<void>? reconnects,
        bool isAdmin = false,
        Stream<(String, ChatReader)>? reads,
        Future<Uint8List?> Function(ImageSource)? picker}) => MaterialApp(
      theme: buildLightTheme(),
      home: ChatScreen(
        circleId: 'c1',
        circleName: 'Family',
        service: svc,
        incoming: live,
        reads: reads,
        picker: picker,
        edits: edits ?? const Stream<ChatMessage>.empty(),
        deletes: deletes ?? const Stream<(String, String)>.empty(),
        reconnects: reconnects ?? const Stream<void>.empty(),
        isAdmin: isAdmin,
      ),
    );

void main() {
  testWidgets('shows history, marks read, and sends a message',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(
        <ChatMessage>[_msg(2, 'mom', 'Dinner at 6?'), _msg(1, 'me', 'Hi')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();

    expect(find.text('Dinner at 6?'), findsOneWidget);
    expect(find.text('Hi'), findsOneWidget);
    expect(find.text('Mom'), findsOneWidget);
    expect(svc.reads, 1);

    // Send is disabled until there is text.
    expect(t.widget<IconButton>(find.byKey(const Key('chat-send'))).onPressed,
        isNull);
    await t.enterText(find.byKey(const Key('chat-input')), '  On my way ');
    await t.pump();
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();

    expect(svc.sent, <String>['On my way']);
    expect(find.text('On my way'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('chat-input'))).controller!.text,
        isEmpty);
  });

  testWidgets('live message appears once, other circles are ignored',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[_msg(1, 'mom', 'Hello')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();

    live.add(_msg(2, 'mom', 'Live one'));
    live.add(_msg(2, 'mom', 'Live one')); // duplicate delivery
    live.add(_msg(3, 'mom', 'Wrong circle', circle: 'c2'));
    await t.pumpAndSettle();

    expect(find.text('Live one'), findsOneWidget);
    expect(find.text('Wrong circle'), findsNothing);
    expect(svc.reads, 2); // history + the live message from someone else
  });

  testWidgets('a failed send keeps the draft and shows the error',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[_msg(1, 'mom', 'Hello')])
      ..sendError = const ChatException('You are sending messages too fast.',
          status: 429);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('chat-input')), 'spam');
    await t.pump();
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('chat-send-error')), findsOneWidget);
    expect(find.text('You are sending messages too fast.'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('chat-input'))).controller!.text,
        'spam');
  });

  testWidgets('over-long text cannot be sent', (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();
    expect(find.text('No messages yet'), findsOneWidget);

    await t.enterText(
        find.byKey(const Key('chat-input')), 'x' * (kMaxChatLength + 1));
    await t.pump();
    expect(t.widget<IconButton>(find.byKey(const Key('chat-send'))).onPressed,
        isNull);
  });

  testWidgets('load failure offers retry', (WidgetTester t) async {
    final _ThrowingChat svc = _ThrowingChat();
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    svc.fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
  });

  group('ChatEvents', () {
    setUp(() {
      ChatEvents.unreadTotal.value = 0;
      ChatEvents.viewingCircleId = null;
      ChatEvents.selfUserId = 'me';
    });

    Map<String, dynamic> frame(String sender, String circle) =>
        <String, dynamic>{
          'type': 'chat',
          'circle_id': circle,
          'message': <String, dynamic>{
            'id': 'm-$sender-$circle',
            'seq': 5,
            'circle_id': circle,
            'sender_id': sender,
            'sender_name': 'X',
            'body': 'hi',
            'created_at': '2026-01-01T09:00:00Z',
          },
        };

    test('counts messages from others, not own or the open chat', () {
      ChatEvents.handleFrame(frame('mom', 'c1'));
      expect(ChatEvents.unreadTotal.value, 1);
      ChatEvents.handleFrame(frame('me', 'c1'));
      expect(ChatEvents.unreadTotal.value, 1);
      ChatEvents.viewingCircleId = 'c1';
      ChatEvents.handleFrame(frame('dad', 'c1'));
      expect(ChatEvents.unreadTotal.value, 1);
      ChatEvents.handleFrame(frame('dad', 'c2'));
      expect(ChatEvents.unreadTotal.value, 2);
    });

    test('malformed frames are ignored', () {
      expect(ChatEvents.handleFrame(<String, dynamic>{'type': 'chat'}), false);
      expect(ChatEvents.unreadTotal.value, 0);
    });
  });

  test('ChatMessage parses the API shape', () {
    final ChatMessage m = ChatMessage.fromJson(<String, dynamic>{
      'id': 'a',
      'seq': 7,
      'circle_id': 'c',
      'sender_id': 's',
      'sender_name': 'Sam',
      'body': 'yo',
      'created_at': '2026-03-04T05:06:07Z',
    });
    expect(m.seq, 7);
    expect(m.senderName, 'Sam');
    expect(m.createdAt.toUtc().hour, 5);
  });

  testWidgets('Seen by shows under my last message, live updates, capped',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(
        <ChatMessage>[_msg(2, 'me', 'Later'), _msg(1, 'mom', 'Earlier')]);
    svc.readers = const <ChatReader>[
      ChatReader(userId: 'sam', name: 'Sam', lastSeq: 2),
      ChatReader(userId: 'old', name: 'Old', lastSeq: 1),
    ];
    final StreamController<(String, ChatReader)> reads =
        StreamController.broadcast();
    addTearDown(reads.close);
    await t.pumpWidget(_app(svc, const Stream<ChatMessage>.empty(), reads: reads.stream));
    await t.pumpAndSettle();
    expect(find.text('Seen by Sam'), findsOneWidget);

    reads.add(('c1', const ChatReader(userId: 'ava', name: 'Ava', lastSeq: 2)));
    await t.pumpAndSettle();
    expect(find.text('Seen by Ava, Sam'), findsOneWidget);
    for (final String n in <String>['Bo', 'Cy', 'Di']) {
      reads.add(('c1', ChatReader(userId: n, name: n, lastSeq: 2)));
    }
    await t.pumpAndSettle();
    expect(find.text('Seen by Ava, Bo, Cy +2'), findsOneWidget);
  });

  testWidgets('date separator and photo send', (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[
      _msg(2, 'mom', 'b'),
      _msg(1, 'mom', 'a'),
    ]);
    final Uint8List jpg = Uint8List.fromList(<int>[1, 2, 3]);
    await t.pumpWidget(_app(svc, const Stream<ChatMessage>.empty(),
        picker: (ImageSource s) async => jpg));
    await t.pumpAndSettle();
    expect(find.text(chatDayLabel(DateTime(2026, 1, 1, 9))), findsOneWidget); // one header for the day
    expect(chatDayLabel(DateTime.now()), 'Today');

    await t.tap(find.byKey(const Key('chat-attach')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-attach-gallery')));
    await t.pumpAndSettle();
    expect(svc.photosSent, 1);
  });

  testWidgets('long-press edits my own message', (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[_msg(1, 'me', 'Helo')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();
    await t.longPress(find.text('Helo'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-action-edit')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-editing')), findsOneWidget);
    await t.enterText(find.byKey(const Key('chat-input')), 'Hello');
    await t.pump();
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();
    expect(svc.edited, <String>['id1=Hello']);
    expect(svc.sent, isEmpty);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
    expect(find.byKey(const Key('chat-editing')), findsNothing);
  });

  testWidgets('delete asks first; others cannot be deleted unless admin',
      (WidgetTester t) async {
    final _FakeChat svc =
        _FakeChat(<ChatMessage>[_msg(2, 'mom', 'Hers'), _msg(1, 'me', 'Mine')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();
    await t.longPress(find.text('Hers'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-action-delete')), findsNothing);

    await t.longPress(find.text('Mine'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-action-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-delete-confirm')));
    await t.pumpAndSettle();
    expect(svc.deleted, <String>['id1']);
    expect(find.text('Mine'), findsNothing);
  });

  testWidgets('admin can delete someone else\'s message', (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[_msg(1, 'mom', 'Rude')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream, isAdmin: true));
    await t.pumpAndSettle();
    await t.longPress(find.text('Rude'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-action-edit')), findsNothing);
    await t.tap(find.byKey(const Key('chat-action-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-delete-confirm')));
    await t.pumpAndSettle();
    expect(svc.deleted, <String>['id1']);
  });

  testWidgets('live delete and edit frames update the list; reconnect catches up',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[_msg(2, 'mom', 'Old'), _msg(1, 'mom', 'Gone')]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    final StreamController<ChatMessage> edits = StreamController.broadcast();
    final StreamController<(String, String)> dels = StreamController.broadcast();
    final StreamController<void> recon = StreamController.broadcast();
    addTearDown(live.close);
    addTearDown(edits.close);
    addTearDown(dels.close);
    addTearDown(recon.close);
    await t.pumpWidget(_app(svc, live.stream,
        edits: edits.stream, deletes: dels.stream, reconnects: recon.stream));
    await t.pumpAndSettle();
    dels.add(('c1', 'id1'));
    dels.add(('other', 'id2'));
    edits.add(_msg(2, 'mom', 'New'));
    await t.pumpAndSettle();
    expect(find.text('Gone'), findsNothing);
    expect(find.text('Old'), findsNothing);
    expect(find.text('New'), findsOneWidget);

    svc.history.insert(0, _msg(3, 'mom', 'Missed while offline'));
    recon.add(null);
    await t.pumpAndSettle();
    expect(find.text('Missed while offline'), findsOneWidget);
  });

  testWidgets('a retry after a failed send reuses the client id',
      (WidgetTester t) async {
    final _FakeChat svc = _FakeChat(<ChatMessage>[]);
    final StreamController<ChatMessage> live = StreamController.broadcast();
    addTearDown(live.close);
    await t.pumpWidget(_app(svc, live.stream));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('chat-input')), 'Ping');
    await t.pump();
    svc.sendError = const ChatException('offline');
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-send-error')), findsOneWidget);
    expect(find.text('Ping'), findsOneWidget); // draft kept
    svc.sendError = null;
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();
    expect(svc.clientIds.length, 1);
    expect(svc.clientIds.first, isNotNull);
  });
}


class _ThrowingChat extends _FakeChat {
  _ThrowingChat() : super(<ChatMessage>[]);
  bool fail = true;

  @override
  Future<ChatPage> messages(String circleId,
      {int? before, int? after, int limit = 50}) async {
    if (fail) throw const ChatException('Can\'t reach the server.');
    return ChatPage(<ChatMessage>[_msg(1, 'mom', 'Hello')], null);
  }
}
