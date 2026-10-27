import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openfamily/services/invite_link.dart';
import 'package:openfamily/services/pending_invite.dart';
import 'package:openfamily/services/server_config.dart';

void main() {
  group('InviteLink.parse', () {
    test('https join link', () {
      final InviteLink? l =
          InviteLink.parse('https://fam.example.com/join/ab23cdef');
      expect(l?.server, 'https://fam.example.com');
      expect(l?.code, 'AB23CDEF');
    });

    test('keeps a path prefix and port', () {
      final InviteLink? l =
          InviteLink.parse('https://h.example:8443/of/join/AB23CDEF');
      expect(l?.server, 'https://h.example:8443/of');
    });

    test('custom scheme from the landing page', () {
      final InviteLink? l = InviteLink.parse(
          'openfamily://join?code=AB23CDEF&server=https%3A%2F%2Ffam.example.com');
      expect(l?.server, 'https://fam.example.com');
      expect(l?.code, 'AB23CDEF');
    });

    test('rejects http, bad codes, credentials and other shapes', () {
      for (final String bad in <String>[
        'http://fam.example.com/join/AB23CDEF',
        'https://fam.example.com/join/short',
        'https://fam.example.com/other/AB23CDEF',
        'https://user:pw@fam.example.com/join/AB23CDEF',
        'openfamily://join?code=AB23CDEF&server=http%3A%2F%2Fx.example',
        'openfamily://join?code=AB23CDEF',
        'not a url',
        '',
      ]) {
        expect(InviteLink.parse(bad), isNull, reason: bad);
      }
    });

    test('build round-trips through parse', () {
      final String link = InviteLink.build('https://fam.example.com/', 'ab23cdef')!;
      expect(link, 'https://fam.example.com/join/AB23CDEF');
      expect(InviteLink.parse(link)?.code, 'AB23CDEF');
      expect(InviteLink.build('http://x.example', 'AB23CDEF'), isNull);
    });
  });

  group('PendingInvite.accept', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ServerConfig.instance.debugReset();
      PendingInvite.clear();
    });

    test('sets the server when the app is not configured', () async {
      const InviteLink l =
          InviteLink(server: 'https://fam.example.com', code: 'AB23CDEF');
      expect(await PendingInvite.accept(l), isTrue);
      expect(ServerConfig.instance.apiBaseUrl, 'https://fam.example.com');
      expect(PendingInvite.code, 'AB23CDEF');
    });

    test('does not switch an already configured different server', () async {
      await ServerConfig.instance.setUrl('https://mine.example.com');
      const InviteLink l =
          InviteLink(server: 'https://other.example.com', code: 'AB23CDEF');
      expect(await PendingInvite.accept(l), isFalse);
      expect(ServerConfig.instance.apiBaseUrl, 'https://mine.example.com');
      expect(PendingInvite.code, isNull);
    });

    test('accepts a link for the configured server', () async {
      await ServerConfig.instance.setUrl('https://mine.example.com');
      const InviteLink l =
          InviteLink(server: 'https://mine.example.com', code: 'AB23CDEF');
      expect(await PendingInvite.accept(l), isTrue);
      expect(PendingInvite.code, 'AB23CDEF');
    });
  });
}
