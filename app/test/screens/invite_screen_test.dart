import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/invite_screen.dart';
import 'package:openfamily/screens/join_circle_screen.dart';
import 'package:openfamily/services/invite_link.dart';
import 'package:openfamily/services/pending_invite.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/invite_service.dart';
import 'package:openfamily/theme/app_theme.dart';

import 'dart:convert';

// Real bodies captured from the API (POST /family/invites, POST
// /circles/{id}/invites) on a throwaway stack built from this repo.
const String _familyInviteBody =
    '{"id":"ff261466-f217-4ba3-b6ac-912499bcc453","code":"4AL52AWU",'
    '"family_id":"bb0a8263-127d-4c0a-b364-8b3d85f99d4b",'
    '"created_by":"b2504f8b-0efb-4b0a-9f50-84c630b0be19","role":"member",'
    '"max_uses":1,"uses":0,"expires_at":"2026-11-02T15:05:01.151071Z",'
    '"created_at":"2026-10-26T15:05:01.151301Z"}';
const String _circleInviteBody =
    '{"id":"5bb84471-8f51-43b6-a4f9-655a6fbee49b","code":"5WZWJJLD",'
    '"circle_id":"bb0a8263-127d-4c0a-b364-8b3d85f99d4b","role":"member",'
    '"max_uses":5,"uses":0,"expires_at":"2026-11-02T15:05:42.034347Z",'
    '"created_at":"2026-10-26T15:05:42.035156Z"}';

Widget _app(Widget child) =>
    MaterialApp(theme: buildLightTheme(), home: child);

void main() {
  _qrTests();
  test('parses the real family invite JSON', () {
    final Map<String, dynamic> j =
        jsonDecode(_familyInviteBody) as Map<String, dynamic>;
    expect(InviteService.parseInviteCode(j), '4AL52AWU');
  });

  test('parses the real circle invite JSON', () {
    final CircleInvite inv = CircleInvite.fromJson(
        jsonDecode(_circleInviteBody) as Map<String, dynamic>);
    expect(inv.code, '5WZWJJLD');
    expect(inv.maxUses, 5);
    expect(inv.expiresAt, isNotNull);
  });

  test('a reply without a code is a clear error, not a cast crash', () {
    expect(() => InviteService.parseInviteCode(<String, dynamic>{'id': 'x'}),
        throwsFormatException);
  });

  testWidgets('shows the code and Copy first; share is optional',
      (WidgetTester t) async {
    int shares = 0;
    await t.pumpWidget(_app(InviteScreen(
      createCode: () async => '4AL52AWU',
      shareCode: (String m, String s) async => shares++,
    )));
    await t.tap(find.text('Create invite code'));
    await t.pumpAndSettle();
    expect(find.text('4AL52AWU'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(shares, 0, reason: 'creating must not open the share sheet');
    await t.tap(find.text('Share code'));
    await t.pumpAndSettle();
    expect(shares, 1);
  });

  testWidgets('a throwing share sheet still leaves the code on screen',
      (WidgetTester t) async {
    await t.pumpWidget(_app(InviteScreen(
      createCode: () async => 'ABCD2345',
      shareCode: (String m, String s) async =>
          throw PlatformException0('One UI share failure'),
    )));
    await t.tap(find.text('Create invite code'));
    await t.pumpAndSettle();
    await t.tap(find.text('Share code'));
    await t.pumpAndSettle();
    expect(find.text('ABCD2345'), findsOneWidget);
    expect(find.textContaining('Could not open the share sheet'),
        findsOneWidget);
  });

  testWidgets('shows the server error text on failure and can retry',
      (WidgetTester t) async {
    int n = 0;
    await t.pumpWidget(_app(InviteScreen(
      createCode: () async {
        n++;
        if (n == 1) throw const ApiException(403, 'admin only');
        return 'ZZZZ2222';
      },
    )));
    await t.tap(find.text('Create invite code'));
    await t.pumpAndSettle();
    expect(find.textContaining('admin only'), findsOneWidget);
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('ZZZZ2222'), findsOneWidget);
  });

  testWidgets('a timeout says the code may already exist',
      (WidgetTester t) async {
    await t.pumpWidget(_app(InviteScreen(
      createCode: () async => throw const ApiException(
          0, 'The request timed out. Please try again.'),
    )));
    await t.tap(find.text('Create invite code'));
    await t.pumpAndSettle();
    expect(find.textContaining('may already exist'), findsOneWidget);
  });

  testWidgets('double tap creates only one code', (WidgetTester t) async {
    final Completer<String> c = Completer<String>();
    int calls = 0;
    await t.pumpWidget(_app(InviteScreen(
      createCode: () {
        calls++;
        return c.future;
      },
    )));
    await t.tap(find.text('Create invite code'));
    await t.pump();
    expect(find.text('Please wait'), findsOneWidget);
    await t.tap(find.text('Please wait'), warnIfMissed: false);
    await t.pump();
    c.complete('ONLY2222');
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('ONLY2222'), findsOneWidget);
  });
}

void _qrTests() {
  testWidgets('shows a QR code of the join link and shares the link',
      (WidgetTester t) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ServerConfig.instance.debugReset();
    await ServerConfig.instance.setUrl('https://family.example.com');
    String? shared;
    await t.pumpWidget(_app(InviteScreen(
      createCode: () async => 'ABCD2345',
      shareCode: (String m, String s) async => shared = m,
    )));
    await t.tap(find.text('Create invite code'));
    await t.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byKey(const Key('invite-qr-slot')), findsOneWidget);
    await t.tap(find.text('Share code'));
    await t.pumpAndSettle();
    expect(shared, contains('https://family.example.com/join/ABCD2345'));
  });

  testWidgets('join screen pre-fills the code from a pending invite',
      (WidgetTester t) async {
    PendingInvite.current.value = const InviteLink(
        server: 'https://family.example.com', code: 'ABCD2345');
    addTearDown(PendingInvite.clear);
    await t.pumpWidget(_app(const JoinCircleScreen()));
    expect(find.text('ABCD2345'), findsOneWidget);
  });
}

class PlatformException0 implements Exception {
  PlatformException0(this.m);
  final String m;
}
