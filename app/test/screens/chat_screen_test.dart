import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Object? sendError;

  @override
  Future<String> myUserId() async => 'me';

  @override
  Future<ChatPage> messages(String circleId, {int? before, int limit = 50}) async {
    return ChatPage(history, null);
  }

  @override
  Future<ChatMessage> send(String circleId, String body) async {
    if (sendError != null) throw sendError!;
    sent.add(body);
    return _msg(100 + sent.length, 'me', body);
  }

  @override
  Future<void> markRead(String circleId, {int? seq}) async => reads++;

  @override
  Future<Map<String, int>> unread() async => <String, int>{'c1': 0};
}

Widget _app(ChatService svc, Stream<ChatMessage> live) => MaterialApp(
      theme: buildLightTheme(),
      home: ChatScreen(
        circleId: 'c1',
        circleName: 'Family',
        service: svc,
        incoming: live,
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
}

class _ThrowingChat extends _FakeChat {
  _ThrowingChat() : super(<ChatMessage>[]);
  bool fail = true;

  @override
  Future<ChatPage> messages(String circleId, {int? before, int limit = 50}) async {
    if (fail) throw const ChatException('Can\'t reach the server.');
    return ChatPage(<ChatMessage>[_msg(1, 'mom', 'Hello')], null);
  }
}
