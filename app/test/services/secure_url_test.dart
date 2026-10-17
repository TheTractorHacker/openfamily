import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/secure_url.dart';

void main() {
  test('accepts HTTPS URLs with hosts and template paths', () {
    expect(isHttpsUrl('https://family.example.com'), isTrue);
    expect(
      isHttpsUrl('https://tiles.example.com/{z}/{x}/{y}.png'),
      isTrue,
    );
  });

  test('rejects HTTP, relative, and hostless URLs', () {
    expect(isHttpsUrl('http://family.example.com'), isFalse);
    expect(isHttpsUrl('/relative/path'), isFalse);
    expect(isHttpsUrl('https:///missing-host'), isFalse);
  });

  test('normalizes HTTPS server base URLs', () {
    expect(
      normalizeHttpsBaseUrl(' https://family.example.com/ '),
      'https://family.example.com',
    );
    expect(
      normalizeHttpsBaseUrl('https://family.example.com/api/'),
      'https://family.example.com/api',
    );
  });

  test('server base URL rejects cleartext and ambiguous credentials', () {
    expect(normalizeHttpsBaseUrl('http://family.example.com'), isNull);
    expect(
      normalizeHttpsBaseUrl('https://user:secret@family.example.com'),
      isNull,
    );
    expect(
      normalizeHttpsBaseUrl('https://family.example.com?token=secret'),
      isNull,
    );
    expect(
        normalizeHttpsBaseUrl('https://family.example.com/#section'), isNull);
  });
}
