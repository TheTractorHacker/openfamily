@Timeout(Duration(minutes: 5))
library;


import 'package:flutter_test/flutter_test.dart';

import '../e2e_real_server/harness.dart';
import 'support.dart';

// Scenario (e): the database connection limit (commit 0ef9484, "Fix database connection exhaustion"). The
// timescaledb-ha image tunes max_connections down to 25 for a small container; the API pool is 15 and
// backups, migrations and admin tools need connections too, so under load the API was refused with
// "sorry, too many clients already" and requests failed or hung. docker-compose.yml now passes an explicit
// max_connections (PG_MAX_CONNECTIONS, 60) and an explicit pool size (DB_MAX_CONNS, 15).
//
// This runs against the compose Postgres of the dev stack: the image and the `command` come from the repo's own
// docker-compose.yml (the stack override does not replace them; fsync is switched off afterwards with ALTER
// SYSTEM), not the plain database of scripts/e2e-lanes.sh. The expected limit is read from the rendered compose
// command, so the check is not circular.

const int burst = 400;

void main() {
  final DevEnv? env = DevEnv.fromEnvironment();
  if (env == null) {
    test('connection limit e2e', () {}, skip: skipReason);
    return;
  }
  late DevStack stack;
  late Db db;
  late List<Phone> users;
  final LogTail apiLog = LogTail(env, 'api');
  final LogTail pgLog = LogTail(env, 'postgres');

  setUpAll(() async {
    db = Db(env.e2e);
    stack = DevStack(env);
    users = <Phone>[for (int i = 0; i < 8; i++) await stack.newUser('Conn$i', runtime: false)];
  });

  test('the database runs with the limit docker-compose.yml itself sets, well above the API pool', () async {
    // The expected value comes from the repo's compose file as rendered for this stack, NOT from a number the
    // stack scripts also wrote: deleting or reverting `command:` of the postgres service in docker-compose.yml
    // leaves no max_connections here and fails this test (and so would the image's own 25 below).
    final RegExpMatch? m = RegExp(r'max_connections=(\d+)').firstMatch(env.pgComposeCommand);
    expect(m, isNotNull, reason: 'docker-compose.yml must give the postgres service an explicit max_connections; its command is "${env.pgComposeCommand}"');
    final int configured = int.parse(m!.group(1)!);
    final String max = (await db.query('SHOW max_connections')).single.single as String;
    final String reserved = (await db.query('SHOW superuser_reserved_connections')).single.single as String;
    final int limit = int.parse(max);
    expect(limit, configured, reason: 'the running database must use the limit docker-compose.yml sets');
    expect(limit, isNot(25), reason: 'that is the value the timescaledb-ha image tunes itself to');
    final int usable = limit - int.parse(reserved);
    // Room for the pool plus the backup service, migrations and an admin shell.
    expect(usable, greaterThanOrEqualTo(env.dbMaxConns + 10), reason: 'max_connections $limit, reserved $reserved, API pool ${env.dbMaxConns}');
  });

  test('other clients hold connections (backup, migration, admin shells): the API still serves a burst, nothing is "too many clients"', () async {
    // The regression of commit 0ef9484: with the image's limit of 25 (22 usable) the API pool of 15 left room for
    // only a few other connections. Hold MORE than the old limit in total (25 held + a pool of up to 15) with
    // idle-in-session connections of their own, then burst. With the old limit the holders themselves fail
    // ("sorry, too many clients already") or the API's pool does and its requests answer 500/503.
    const int held = 25;
    final int apiMark = apiLog.mark(), pgMark = pgLog.mark();
    final List<Future<List<List<dynamic>>>> holders = <Future<List<List<dynamic>>>>[
      for (int i = 0; i < held; i++) db.query('SELECT count(*) FROM (SELECT pg_sleep(20)) s'),
    ];
    await Future<void>.delayed(const Duration(seconds: 3));
    final int sessions = await db.count("SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(20)%' AND pid <> pg_backend_pid()");
    expect(sessions, greaterThanOrEqualTo(held), reason: 'all $held holders must be connected at once');
    final List<Resp> res = await Future.wait(<Future<Resp>>[
      for (int i = 0; i < 200; i++) call(env, 'GET', i.isEven ? '/circles' : '/app/bootstrap', token: users[i % users.length].token, ip: users[i % users.length].ip),
    ]);
    final Map<int, int> byStatus = <int, int>{};
    for (final Resp r in res) {
      byStatus[r.status] = (byStatus[r.status] ?? 0) + 1;
      expect(r.body.toLowerCase(), isNot(contains('too many clients')));
    }
    expect(byStatus.keys.where((int s) => s != 200).toList(), isEmpty, reason: 'every request must succeed while $held other connections are held: $byStatus');
    await Future.wait(holders); // a holder refused for lack of slots throws here
    requireLogs(apiLog);
    requireLogs(pgLog);
    await Future<void>.delayed(const Duration(seconds: 1));
    for (final MapEntry<String, String> e in <String, String>{'api': apiLog.since(apiMark), 'postgres': pgLog.since(pgMark)}.entries) {
      expect(e.value.toLowerCase(), isNot(contains('too many clients')), reason: '${e.key} log');
    }
  });

  test('$burst concurrent authenticated requests: none fails, none is refused for lack of connections', () async {
    final int apiMark = apiLog.mark(), pgMark = pgLog.mark();
    // Sample how many server processes exist while the burst runs: one server-side loop (a DO block that
    // clears the statistics snapshot each round and records count(*) of pg_stat_activity every 20 ms), so the
    // sampler needs no extra connections of its own after the first.
    await db.exec('DROP TABLE IF EXISTS e2e_conn_peak');
    await db.exec('CREATE UNLOGGED TABLE e2e_conn_peak (n int)');
    final Future<void> sampler = db.exec(
        'DO \$\$ BEGIN FOR i IN 1..300 LOOP PERFORM pg_stat_clear_snapshot(); '
        'INSERT INTO e2e_conn_peak SELECT count(*) FROM pg_stat_activity WHERE datname = current_database(); '
        'PERFORM pg_sleep(0.02); END LOOP; END \$\$');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Endpoints without per-user limiters; each authenticated call costs several database round trips.
    const List<String> paths = <String>['/circles', '/me', '/app/bootstrap'];
    final List<Future<Resp>> calls = <Future<Resp>>[
      for (int i = 0; i < burst; i++)
        call(env, 'GET', paths[i % paths.length], token: users[i % users.length].token, ip: users[i % users.length].ip),
    ];
    final List<Resp> res = await Future.wait(calls);
    await sampler;
    final int peak = (await db.query('SELECT max(n) FROM e2e_conn_peak')).single.single as int;
    await db.exec('DROP TABLE e2e_conn_peak');

    final Map<int, int> byStatus = <int, int>{};
    for (final Resp r in res) {
      byStatus[r.status] = (byStatus[r.status] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('burst of $burst: statuses $byStatus, peak server processes seen $peak (API pool ${env.dbMaxConns})');
    expect(byStatus.keys.where((int s) => s != 200).toList(), isEmpty, reason: 'every request must succeed: $byStatus');
    for (final Resp r in res) {
      expect(r.body.toLowerCase(), isNot(contains('too many clients')));
    }
    expect(peak, greaterThan(1), reason: 'the sampler saw the database');
    expect(peak, lessThanOrEqualTo(env.dbMaxConns + 8), reason: 'the API stays within its pool (plus the sampler, migrations and the probe)');

    // Postgres and the API both log a refusal; neither may have one.
    requireLogs(apiLog);
    requireLogs(pgLog);
    await Future<void>.delayed(const Duration(seconds: 1)); // let the log streams catch up
    for (final MapEntry<String, String> e in <String, String>{'api': apiLog.since(apiMark), 'postgres': pgLog.since(pgMark)}.entries) {
      expect(e.value.toLowerCase(), isNot(contains('too many clients')), reason: '${e.key} log');
      expect(e.value, isNot(contains('53300')), reason: '${e.key} log (SQLSTATE too_many_connections)');
    }
    // And the server still answers afterwards.
    expect((await call(env, 'GET', '/me', token: users.first.token, ip: users.first.ip)).status, 200);
  });

  test('three more back-to-back waves still end with no failure', () async {
    // Three more waves of 150, back to back, on the two heaviest read endpoints.
    final List<Resp> all = <Resp>[];
    for (int wave = 0; wave < 3; wave++) {
      all.addAll(await Future.wait(<Future<Resp>>[
        for (int i = 0; i < 150; i++)
          call(env, 'GET', i.isEven ? '/circles' : '/app/bootstrap', token: users[i % users.length].token, ip: users[i % users.length].ip),
      ]));
    }
    expect(all.where((Resp r) => r.status != 200).map((Resp r) => r.status).toSet(), isEmpty);
  });
}
