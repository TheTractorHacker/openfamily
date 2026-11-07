import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/chat_message.dart';
import 'package:openfamily/screens/chat_screen.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/theme/app_theme.dart';

ChatMessage _m(int seq, String sender, String body,
        {bool legacy = false, ChatSendState state = ChatSendState.sent, bool enc = true}) =>
    ChatMessage(
      id: sender == 'me' ? 'me:m$seq' : 'u:m$seq',
      seq: seq,
      circleId: 'c1',
      senderId: sender,
      senderName: sender == 'me' ? 'You' : 'Mom',
      body: body,
      createdAt: DateTime(2026, 1, 1, 9, seq % 60),
      encrypted: enc && !legacy,
      legacy: legacy,
      sendState: state,
    );

class _EncChat implements ChatService, ChatProtection {
  _EncChat(this.history, this.infoValue);
  List<ChatMessage> history;
  ChatCircleInfo infoValue;
  final List<String> sent = <String>[];
  final List<String> retried = <String>[];
  int legacyDeleted = 0;

  @override
  Future<String> myUserId() async => 'me';
  @override
  Future<ChatPage> messages(String circleId, {int? before, int? after, int limit = 50}) async => ChatPage(history, null);
  @override
  Future<ChatMessage> send(String circleId, String body, {String? clientId}) async {
    sent.add(body);
    return _m(100 + sent.length, 'me', body, state: ChatSendState.sending);
  }

  @override
  Future<ChatMessage> edit(String circleId, String messageId, String body) async => _m(1, 'me', body);
  @override
  Future<void> delete(String circleId, String messageId) async {}
  @override
  Future<void> markRead(String circleId, {int? seq}) async {}
  @override
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes, {String contentType = 'image/jpeg'}) async => _m(9, 'me', '');
  @override
  Future<Uint8List> photo(String circleId, String messageId) async => throw StateError('none');
  @override
  Future<Map<String, int>> unread() async => <String, int>{};
  @override
  Future<ChatCircleInfo> info(String circleId) async => infoValue;
  @override
  Future<void> retry(String circleId, String messageId) async => retried.add(messageId);
  @override
  Future<int> deleteLegacyHistory(String circleId) async {
    legacyDeleted++;
    return 2;
  }
}

Widget _app(ChatService svc, {bool isAdmin = false}) => MaterialApp(
      theme: buildLightTheme(),
      home: ChatScreen(
        circleId: 'c1',
        circleName: 'Family',
        service: svc,
        incoming: const Stream<ChatMessage>.empty(),
        edits: const Stream<ChatMessage>.empty(),
        deletes: const Stream<(String, String)>.empty(),
        reconnects: const Stream<void>.empty(),
        isAdmin: isAdmin,
      ),
    );

void main() {
  testWidgets('private circle shows the encrypted banner and nothing else odd', (WidgetTester t) async {
    final _EncChat svc = _EncChat(<ChatMessage>[_m(2, 'u', 'hi')], const ChatCircleInfo(encrypted: true));
    await t.pumpWidget(_app(svc));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-encrypted-banner')), findsOneWidget);
    expect(find.text('Encrypted. Only people in this circle can read this.'), findsOneWidget);
    expect(find.byKey(const Key('chat-waiting-key')), findsNothing);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets('a plaintext circle shows no banner', (WidgetTester t) async {
    await t.pumpWidget(_app(_EncChat(<ChatMessage>[_m(2, 'u', 'hi', enc: false)], const ChatCircleInfo())));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-encrypted-banner')), findsNothing);
  });

  testWidgets('waiting for the key and members who need to update are named', (WidgetTester t) async {
    final _EncChat svc = _EncChat(<ChatMessage>[], const ChatCircleInfo(encrypted: true, waitingForKey: true, outdatedMembers: <String>['Dad']));
    await t.pumpWidget(_app(svc));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-waiting-key')), findsOneWidget);
    expect(find.text('Dad needs to update Orbitly to read encrypted chat.'), findsOneWidget);
  });

  testWidgets('sending shows the message as sending and a failed one can be retried by tapping', (WidgetTester t) async {
    final _EncChat svc = _EncChat(
        <ChatMessage>[_m(5, 'me', 'lost one', state: ChatSendState.failed)], const ChatCircleInfo(encrypted: true));
    await t.pumpWidget(_app(svc));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-retry')), findsOneWidget);
    await t.tap(find.byKey(const Key('chat-retry')));
    await t.pumpAndSettle();
    expect(svc.retried, <String>['me:m5']);
    await t.enterText(find.byKey(const Key('chat-input')), 'new one');
    await t.pump();
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pumpAndSettle();
    expect(svc.sent, <String>['new one']);
    expect(find.byKey(const Key('chat-sending')), findsWidgets);
  });

  testWidgets('old plaintext history is marked and an admin can delete it', (WidgetTester t) async {
    final _EncChat svc = _EncChat(<ChatMessage>[
      _m(3, 'u', 'new secret'),
      _m(1, 'u', 'old plain', legacy: true),
    ], const ChatCircleInfo(encrypted: true, hasLegacyHistory: true));
    await t.pumpWidget(_app(svc, isAdmin: true));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-legacy-label')), findsOneWidget);
    expect(find.text('Sent before encryption'), findsOneWidget);
    await t.tap(find.byKey(const Key('chat-legacy-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-legacy-confirm')));
    await t.pumpAndSettle();
    expect(svc.legacyDeleted, 1);
    expect(find.text('old plain'), findsNothing);
    expect(find.text('new secret'), findsOneWidget);
    expect(find.byKey(const Key('chat-legacy-note')), findsNothing);
  });

  testWidgets('a member (not admin) sees the note but no delete button', (WidgetTester t) async {
    final _EncChat svc = _EncChat(<ChatMessage>[_m(1, 'u', 'old plain', legacy: true)], const ChatCircleInfo(encrypted: true, hasLegacyHistory: true));
    await t.pumpWidget(_app(svc));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-legacy-note')), findsOneWidget);
    expect(find.byKey(const Key('chat-legacy-delete')), findsNothing);
  });
}
