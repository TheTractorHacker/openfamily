import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/security_widgets.dart';
import 'package:openfamily/services/alert_service.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/bubble_service.dart';
import 'package:openfamily/services/chat_service.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/trips_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/error_copy.dart';
import 'package:openfamily/services/security_format.dart';

void main() {
  tearDown(() => DeviceNetwork.online = null);

  bool saysOffline(String m) => RegExp('offline|check your connection|good connection', caseSensitive: false).hasMatch(m);

  group('describeError: offline only for the connection', () {
    test('a transport failure with the phone offline says offline', () {
      DeviceNetwork.online = false;
      final ErrorCopy c = describeError(const ApiException(0, 'Could not reach the server. Check your connection.'));
      expect(c.cause, ErrorCause.offline);
      expect(c.message, contains('This phone is offline'));
      expect(c.connection, isTrue);
    });

    test('a transport failure with the phone online blames the server, not the phone', () {
      DeviceNetwork.online = true;
      final ErrorCopy c = describeError(const ApiException(0, 'Could not reach the server. Check your connection.'));
      expect(c.cause, ErrorCause.noAnswer);
      expect(c.message, isNot(contains('offline')));
      expect(c.message, contains('did not answer'));
    });

    test('a timeout says it timed out', () {
      expect(describeError(const ApiException(0, 'The request timed out. Please try again.')).cause, ErrorCause.timeout);
      expect(describeError(TimeoutException('x')).cause, ErrorCause.timeout);
    });

    final Map<String, Object> notConnection = <String, Object>{
      'sign-in ended (401)': const ApiException(401, 'unauthorized'),
      'sign in needed': const SignInNeededException(),
      'session expired': const SessionExpiredException(),
      'refused (403)': const ApiException(403, 'not an admin of this circle'),
      'server busy (503)': const ApiException(503, 'Request failed (503).'),
      'server error (500)': const ApiException(500, 'Request failed (500).'),
      'too many (429)': const ApiException(429, 'too many requests'),
      'key missing': const LocalKeyException(LocalKeyProblem.missing),
      'key locked': const LocalKeyException(LocalKeyProblem.locked),
      'not set up': const NeedsCrossSignatureException(),
      'bad code': const FormatException('bad base64'),
      'bad e2ee data': const E2eeFormatException('this request is for another account'),
      'state': StateError('The server is not asking to join right now.'),
      'bug on the phone': ArgumentError('x'),
      'invalid answer (status 0, own text)': const ApiException(0, 'The avatar returned by the server is invalid.'),
    };
    for (final MapEntry<String, Object> e in notConnection.entries) {
      test('${e.key}: no "offline", no "Something went wrong. Please try again."', () {
        DeviceNetwork.online = true;
        final ErrorCopy c = describeError(e.value);
        expect(c.connection, isFalse, reason: c.message);
        expect(saysOffline(c.message), isFalse, reason: c.message);
        expect(c.message, isNot('Something went wrong. Please try again.'));
        expect(c.title, isNot('Something went wrong'));
      });
    }

    test('specific causes name the next step', () {
      expect(describeError(const ApiException(401, 'x')).message, contains('Sign in again'));
      expect(describeError(const ApiException(503, 'x')).message, contains('restarting'));
      expect(describeError(const ApiException(500, 'Request failed (500).')).message, contains('error 500'));
      expect(describeError(const ApiException(403, 'not an admin of this circle')).message, 'not an admin of this circle');
      expect(describeError(const LocalKeyException(LocalKeyProblem.missing)).message, contains('Encryption keys'));
      expect(describeError(ArgumentError('x')).message, contains('Diagnostics'));
    });
  });

  test('the shared screen helper uses the mapping', () {
    expect(securityErrorMessage(const ApiException(503, 'x')), contains('busy'));
    expect(securityErrorMessage(const SecurityException('Wrong code.')), 'Wrong code.');
  });

  test('action helpers no longer blame the connection for a problem on the phone', () {
    expect(bubbleErrorMessage(const LocalKeyException(LocalKeyProblem.locked), action: 'start the Bubble'),
        allOf(startsWith('Could not start the Bubble.'), isNot(contains('connection'))));
    expect(alertErrorMessage(StateError('no circle')), isNot(contains('reach the server')));
    DeviceNetwork.online = true;
    expect(alertErrorMessage(const ApiException(0, 'Could not reach the server. Check your connection.')),
        allOf(startsWith('Could not send the alert.'), contains('did not answer')));
  });

  testWidgets('a full-screen error shows the title of its cause', (WidgetTester t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: LoadStateView.forError(const ApiException(503, 'x'), onRetry: () {}))));
    expect(find.text('Server busy'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  group('every service that words its own errors goes through describeError', () {
    const ApiException transport = ApiException(0, 'Could not reach the server.');

    test('chat, circles and trips: online means the server did not answer, offline means offline', () {
      DeviceNetwork.online = true;
      for (final String m in <String>[
        describeChatError(transport).message,
        describeChatError(TimeoutException('x')).message,
        describeCircleError(transport).message,
        mapTripsError(transport).message,
        mapTripsError(TimeoutException('x')).message,
      ]) {
        expect(m, isNot(contains('offline')), reason: m);
        expect(saysOffline(m) && !m.contains('good connection'), isFalse, reason: m);
      }
      expect(describeChatError(transport).message, contains('did not answer'));
      expect(mapTripsError(TimeoutException('x')).message, contains('too long'));
      DeviceNetwork.online = false;
      expect(describeChatError(transport).message, contains('This phone is offline'));
      final CircleException c = describeCircleError(transport);
      expect(c.message, contains('This phone is offline'));
      expect(c.title, 'No connection');
      expect(mapTripsError(transport).message, contains('This phone is offline'));
    });

    test('a non-transport failure in chat or circles never mentions the connection', () {
      DeviceNetwork.online = true;
      expect(describeChatError(StateError('no key')).message, isNot(contains('connection')));
      expect(describeCircleError(StateError('x')).message, isNot(contains('reach the server')));
    });

    test('no screen or service text tells people to check their connection', () {
      final List<String> hits = <String>[];
      for (final FileSystemEntity f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        // Join string literals split over lines, so a split sentence is found too.
        final String text = f.readAsLinesSync().where((String l) => !l.trimLeft().startsWith('//')).join('\n').replaceAll(RegExp(r"'\s*\n\s*'"), '');
        if (RegExp('check your\\s+connection', caseSensitive: false).hasMatch(text)) hits.add(f.path);
      }
      expect(hits, isEmpty);
    });
  });
}
