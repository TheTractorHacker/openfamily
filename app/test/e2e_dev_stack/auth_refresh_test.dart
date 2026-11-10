@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../e2e_real_server/harness.dart';
import 'support.dart';

// Scenario (a): sign-in and refresh-token rotation against the real server and its real Postgres
// (backend/internal/handlers/refresh_store.go): rotation, a lost answer retried within the 3 minute window,
// after the window, a retry of a token whose successor was already used, the retry cap of 8, and what reuse
// does to the whole session family. Time windows are tested by backdating refresh_sessions.used_at (the
// server measures them on the DATABASE clock), so nothing sleeps for minutes.
//
// Each case uses its own account and client address (X-Forwarded-For) so the per-IP limits
// (login 20, refresh 60 per 15 minutes) are never what is being measured.

String jtiOf(String jwt) {
  final List<String> parts = jwt.split('.');
  final String payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
  return (jsonDecode(payload) as Map<String, dynamic>)['jti'] as String;
}

void main() {
  final DevEnv? env = DevEnv.fromEnvironment();
  if (env == null) {
    test('auth and refresh e2e', () {}, skip: skipReason);
    return;
  }
  late DevStack stack;
  late Db db;

  setUpAll(() async {
    db = Db(env.e2e);
    stack = DevStack(env);
  });

  /// A fresh account, signed in through POST /auth/login (token pair in [Phone.token] / [Phone.refreshToken]).
  Future<Phone> account(String name) => stack.newUser(name, runtime: false);

  Future<Resp> refresh(Phone who, String token) => call(env, 'POST', '/auth/refresh', body: <String, dynamic>{'refresh_token': token}, ip: who.ip);

  Future<int> audit(Phone who, String action) => db.count("SELECT count(*) FROM audit_log WHERE user_id = '${who.userId}' AND action = '$action'");

  group('sign-in', () {
    test('wrong password and unknown account are refused with the same answer; the right one returns a token pair that works', () async {
      final Phone p = await stack.newUser('Signin', runtime: false);
      final String ip = nextIp();
      final Resp bad = await call(env, 'POST', '/auth/login', body: <String, dynamic>{'email': p.email, 'password': 'not the password'}, ip: ip);
      final Resp none = await call(env, 'POST', '/auth/login', body: <String, dynamic>{'email': 'nobody-$stamp@dev.orbitly.test', 'password': 'not the password'}, ip: ip);
      expect(bad.status, 401);
      expect(none.status, 401);
      expect(bad.json['error'], none.json['error'], reason: 'the answer must not reveal whether the account exists');

      final Resp ok = await call(env, 'POST', '/auth/login', body: <String, dynamic>{'email': p.email, 'password': userPassword}, ip: ip);
      expect(ok.status, 200, reason: '$ok');
      expect(ok.json['access_token'], isNotEmpty);
      expect(ok.json['refresh_token'], isNotEmpty);
      expect(ok.json['token_type'], 'Bearer');
      expect(ok.json['expires_in'], greaterThan(0));
      expect((await call(env, 'GET', '/me', token: ok.json['access_token'] as String, ip: ip)).status, 200);
      expect((await call(env, 'GET', '/me', token: 'garbage', ip: ip)).status, 401);
      expect((await call(env, 'GET', '/me', ip: ip)).status, 401);
      // A refresh token is not an access token and the other way round.
      expect((await call(env, 'GET', '/me', token: ok.json['refresh_token'] as String, ip: ip)).status, 401);
      expect((await refresh(p, ok.json['access_token'] as String)).status, 401);
      expect((await refresh(p, 'garbage')).status, 401);
    });
  });

  group('refresh rotation', () {
    test('a refresh spends the token and hands out a new pair in the same session family', () async {
      final Phone p = await account('Rotate');
      final String r1 = p.refreshToken!;
      final Resp res = await refresh(p, r1);
      expect(res.status, 200, reason: '$res');
      final String r2 = res.json['refresh_token'] as String;
      expect(r2, isNot(r1));
      expect((await call(env, 'GET', '/me', token: res.json['access_token'] as String, ip: p.ip)).status, 200);
      final List<List<dynamic>> rows = await db.query(
          "SELECT jti, family_id, parent_jti, used_at IS NOT NULL, revoked_at IS NOT NULL FROM refresh_sessions WHERE user_id = '${p.userId}' ORDER BY created_at");
      expect(rows.length, 2);
      expect(rows[0][0], jtiOf(r1));
      expect(rows[0][3], isTrue, reason: 'the old token is spent');
      expect(rows[1][0], jtiOf(r2));
      expect(rows[1][2], jtiOf(r1), reason: 'the new token names its parent');
      expect(rows[1][1], rows[0][1], reason: 'same family');
      expect(rows[1][3], isFalse);
      expect(rows[1][4], isFalse);
      // The new token keeps working (a normal chain).
      final Resp res3 = await refresh(p, r2);
      expect(res3.status, 200);
      expect(await audit(p, 'auth.refresh_reuse'), 0);
    });

    test('a lost answer: the same token again within 3 minutes gets the SAME successor; nothing is revoked', () async {
      final Phone p = await account('Retry');
      final String r1 = p.refreshToken!;
      final Resp first = await refresh(p, r1);
      final String r2 = first.json['refresh_token'] as String;
      // The phone never saw that answer and asks again, several times, as it does every ~15 s.
      for (int i = 0; i < 3; i++) {
        final Resp again = await refresh(p, r1);
        expect(again.status, 200, reason: 'retry ${i + 1}: $again');
        expect(jtiOf(again.json['refresh_token'] as String), jtiOf(r2), reason: 'retry ${i + 1} must be answered with the same successor');
      }
      expect(await audit(p, 'auth.refresh_retry'), 3);
      expect(await audit(p, 'auth.refresh_reuse'), 0);
      expect(await db.count("SELECT count(*) FROM refresh_sessions WHERE user_id = '${p.userId}'"), 2, reason: 'no extra session row per retry');
      expect(await db.count("SELECT count(*) FROM refresh_sessions WHERE user_id = '${p.userId}' AND revoked_at IS NOT NULL"), 0);
      // The successor still works afterwards.
      expect((await refresh(p, r2)).status, 200);
    });

    test('a retry AFTER the 3 minute window is reuse: 401, the whole family is revoked, audited', () async {
      final Phone p = await account('Late');
      final String r1 = p.refreshToken!;
      final String r2 = (await refresh(p, r1)).json['refresh_token'] as String;
      // Make the rotation 4 minutes old on the database clock.
      await db.exec("UPDATE refresh_sessions SET used_at = now() - interval '4 minutes' WHERE jti = '${jtiOf(r1)}' RETURNING 1");
      final Resp late = await refresh(p, r1);
      expect(late.status, 401, reason: '$late');
      expect(await audit(p, 'auth.refresh_reuse'), 1);
      expect(await audit(p, 'auth.refresh_retry'), 0);
      expect(await db.count("SELECT count(*) FROM refresh_sessions WHERE user_id = '${p.userId}' AND revoked_at IS NULL"), 0, reason: 'every token of the family is revoked');
      expect((await refresh(p, r2)).status, 401, reason: 'the valid successor died with the family');
      // Signing in again starts a new family.
      final Resp again = await call(env, 'POST', '/auth/login', body: <String, dynamic>{'email': p.email, 'password': userPassword}, ip: p.ip);
      expect(again.status, 200);
      expect((await refresh(p, again.json['refresh_token'] as String)).status, 200);
    });

    test('presenting a token whose successor was already used is reuse, even inside the window', () async {
      final Phone p = await account('Replay');
      final String r1 = p.refreshToken!;
      final String r2 = (await refresh(p, r1)).json['refresh_token'] as String;
      final String r3 = (await refresh(p, r2)).json['refresh_token'] as String; // the phone DID receive r2
      final Resp replay = await refresh(p, r1);
      expect(replay.status, 401, reason: '$replay');
      expect(await audit(p, 'auth.refresh_reuse'), 1);
      expect((await refresh(p, r3)).status, 401, reason: 'the live head of the family is revoked too');
    });

    test('the retry cap: 8 answers per spent token, the 9th presentation revokes the family', () async {
      final Phone p = await account('Cap');
      final String r1 = p.refreshToken!;
      final String r2 = (await refresh(p, r1)).json['refresh_token'] as String;
      for (int i = 1; i <= 8; i++) {
        final Resp again = await refresh(p, r1);
        expect(again.status, 200, reason: 'answer $i of 8: $again');
        expect(jtiOf(again.json['refresh_token'] as String), jtiOf(r2));
      }
      expect(await audit(p, 'auth.refresh_retry'), 8);
      final Resp ninth = await refresh(p, r1);
      expect(ninth.status, 401, reason: 'past the cap there is no fork either: $ninth');
      expect(await audit(p, 'auth.refresh_reuse'), 1);
      expect((await refresh(p, r2)).status, 401);
      expect(await db.count("SELECT count(*) FROM refresh_sessions WHERE user_id = '${p.userId}' AND revoked_at IS NULL"), 0);
      expect(await db.count("SELECT count(*) FROM refresh_sessions WHERE user_id = '${p.userId}'"), 2, reason: 'no second live successor was ever issued');
    });

    test('an access token stays valid after its refresh family was revoked (only logout bumps the token version)', () async {
      final Phone p = await account('Access');
      final String access = p.token!;
      final String r1 = p.refreshToken!;
      await refresh(p, r1);
      await db.exec("UPDATE refresh_sessions SET used_at = now() - interval '4 minutes' WHERE jti = '${jtiOf(r1)}' RETURNING 1");
      expect((await refresh(p, r1)).status, 401);
      expect((await call(env, 'GET', '/me', token: access, ip: p.ip)).status, 200);
      // Logout, on the other hand, ends every outstanding token.
      expect((await call(env, 'POST', '/auth/logout', token: access, ip: p.ip)).status, lessThan(300));
      expect((await call(env, 'GET', '/me', token: access, ip: p.ip)).status, 401);
    });
  });
}
