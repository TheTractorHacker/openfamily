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
// This runs against the compose Postgres of the dev stack (the same image and command as production, plus
// fsync off), not the plain database of scripts/e2e-lanes.sh.

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

  test('the database runs with the explicit limit, well above the API pool', () async {
    final String max = (await db.query('SHOW max_connections')).single.single as String;
    final String reserved = (await db.query('SHOW superuser_reserved_connections')).single.single as String;
    final int limit = int.parse(max);
    expect(limit, env.pgMaxConnections, reason: 'the stack was started with PG_MAX_CONNECTIONS=${env.pgMaxConnections}');
    expect(limit, isNot(25), reason: 'that is the value the timescaledb-ha image tunes itself to');
    final int usable = limit - int.parse(reserved);
    // Room for the pool plus the backup service, migrations and an admin shell.
    expect(usable, greaterThanOrEqualTo(env.dbMaxConns + 10), reason: 'max_connections $limit, reserved $reserved, API pool ${env.dbMaxConns}');
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
    print('burst of $burst: statuses $byStatus, peak server processes seen $peak of ${env.pgMaxConnections} (API pool ${env.dbMaxConns})');
    expect(byStatus.keys.where((int s) => s != 200).toList(), isEmpty, reason: 'every request must succeed: $byStatus');
    for (final Resp r in res) {
      expect(r.body.toLowerCase(), isNot(contains('too many clients')));
    }
    expect(peak, lessThan(env.pgMaxConnections), reason: 'the server never ran out of connection slots');
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
