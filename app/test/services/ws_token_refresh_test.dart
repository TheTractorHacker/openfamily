import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/family_service.dart';

String _jwt(int exp) =>
    'h.${base64Url.encode(utf8.encode(jsonEncode(<String, int>{'exp': exp}))).replaceAll('=', '')}.s';

void main() {
  final DateTime now = DateTime.utc(2026, 1, 1, 12);
  final int nowSec = now.millisecondsSinceEpoch ~/ 1000;

  test('expired or near-expiry access token needs refresh before reconnect', () {
    expect(accessTokenNeedsRefresh(_jwt(nowSec - 5), now), isTrue);
    expect(accessTokenNeedsRefresh(_jwt(nowSec + 10), now), isTrue);
    expect(accessTokenNeedsRefresh('garbage', now), isTrue);
  });

  test('valid token is kept', () {
    expect(accessTokenNeedsRefresh(_jwt(nowSec + 600), now), isFalse);
    expect(accessTokenNeedsRefresh(null, now), isFalse);
  });
}
