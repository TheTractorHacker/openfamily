// The "Keep tracking alive" checklist: pure verdicts over the same facts Diagnostics uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/diagnostics/keep_alive.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';

final DateTime now = DateTime.utc(2026, 11, 11, 12);

DiagFacts facts({
  String manufacturer = 'Google',
  String? location = 'always',
  bool? ignoring = true,
  bool? restricted = false,
  bool? notifications = true,
  bool sharing = true,
  bool? service = true,
  bool android = true,
  TrackingHealthFacts? tracking = const TrackingHealthFacts(standbyBucket: 10),
}) =>
    DiagFacts(
      now: now,
      isAndroid: android,
      manufacturer: manufacturer,
      locationService: true,
      locationPermission: location,
      notificationsGranted: notifications,
      ignoringBatteryOptimizations: ignoring,
      backgroundRestricted: restricted,
      powerSave: false,
      sharingEnabled: sharing,
      backgroundServiceRunning: service,
      tracking: tracking,
    );

DiagCheck? row(List<DiagCheck> l, String id) {
  for (final DiagCheck c in l) {
    if (c.id == id) return c;
  }
  return null;
}

JournalLine native(String event, {String detail = '', DateTime? at}) =>
    JournalLine(at: at ?? now.subtract(const Duration(minutes: 20)), source: 'native', event: event, detail: detail);

ProcessExit exitOf(int reason, Duration ago) => ProcessExit(
    at: now.subtract(ago), reason: reason, importance: 125, status: 0, processName: 'app.orbitly');

void main() {
  test('a healthy Pixel: every row passes and there is no Samsung row', () {
    final List<DiagCheck> rows = evaluateKeepAlive(facts());
    expect(rows.map((DiagCheck c) => c.id), containsAll(<String>['sharing', 'location_permission', 'battery', 'standby_bucket', 'notifications']));
    expect(row(rows, 'samsung_sleep'), isNull);
    for (final DiagCheck c in rows) {
      expect(c.status, DiagStatus.pass, reason: c.id);
    }
  });

  test('the rows come in the checklist order', () {
    final List<String> ids = evaluateKeepAlive(facts(manufacturer: 'samsung')).map((DiagCheck c) => c.id).toList();
    final List<String> expected = kKeepAliveOrder.where(ids.contains).toList();
    expect(ids, expected);
  });

  group('Samsung', () {
    test('Unrestricted: a green line that says the Never auto sleeping list is not needed', () {
      final DiagCheck c = row(evaluateKeepAlive(facts(manufacturer: 'samsung')), 'samsung_sleep')!;
      expect(c.status, DiagStatus.info);
      expect(c.detail, contains('should keep Samsung from'));
      expect(c.detail, contains('could not confirm'));
      expect(c.detail, isNot(contains('that is expected')));
      expect(c.detail, contains('Sleeping apps'));
      expect(c.fix, isNull);
    });

    test('not Unrestricted: a warning with the one-tap battery fix, and the Samsung screen as the second choice', () {
      final DiagCheck c = row(evaluateKeepAlive(facts(manufacturer: 'samsung', ignoring: false)), 'samsung_sleep')!;
      expect(c.status, DiagStatus.warn);
      expect(c.fix?.kind, DiagFixKind.batterySettings);
      expect(c.secondaryFix?.kind, DiagFixKind.oemBattery);
      expect(c.detail, contains('cannot add itself'));
    });

    test('Restricted is never reported green', () {
      final DiagCheck c = row(evaluateKeepAlive(facts(manufacturer: 'samsung', restricted: true)), 'samsung_sleep')!;
      expect(c.status, DiagStatus.warn);
    });

    test('an unreadable battery state shows no Samsung verdict at all (no guess)', () {
      expect(row(evaluateKeepAlive(facts(manufacturer: 'samsung', ignoring: null)), 'samsung_sleep'), isNull);
    });

    test('the Samsung advice never tells the user to find Orbitly in the Never auto sleeping list', () {
      final String g = oemGuidance('samsung');
      expect(g, contains('Unrestricted'));
      expect(g, contains('do not hunt for Orbitly there'));
      expect(isSamsungPhone('Samsung'), isTrue);
      expect(isSamsungPhone('Google'), isFalse);
    });
  });

  group('rows that need the user', () {
    test('location only "while using": a problem with a fix; battery optimised: a warning', () {
      final List<DiagCheck> rows = evaluateKeepAlive(facts(location: 'while_in_use', ignoring: false));
      expect(row(rows, 'location_permission')!.status, DiagStatus.fail);
      expect(row(rows, 'location_permission')!.fix, isNotNull);
      expect(row(rows, 'battery')!.status, DiagStatus.warn);
      expect(row(rows, 'battery')!.fix?.kind, DiagFixKind.batterySettings);
    });

    test('background restricted is a problem', () {
      expect(row(evaluateKeepAlive(facts(restricted: true)), 'battery')!.status, DiagStatus.fail);
    });

    test('notifications off: a warning with the permission request', () {
      final DiagCheck c = row(evaluateKeepAlive(facts(notifications: false)), 'notifications')!;
      expect(c.status, DiagStatus.warn);
      expect(c.fix?.kind, DiagFixKind.requestNotifications);
    });

    test('sharing off is a problem with the start button', () {
      final DiagCheck c = row(evaluateKeepAlive(facts(sharing: false)), 'sharing')!;
      expect(c.status, DiagStatus.fail);
      expect(c.fix?.kind, DiagFixKind.startTracking);
    });

    test('the power group: restricted fails, rare warns, active passes, unknown shows no row', () {
      DiagCheck? bucket(int? b) => row(evaluateKeepAlive(facts(tracking: TrackingHealthFacts(standbyBucket: b))), 'standby_bucket');
      expect(bucket(45)!.status, DiagStatus.fail);
      expect(bucket(45)!.detail, contains('restricted'));
      expect(bucket(50)!.status, DiagStatus.fail);
      expect(bucket(40)!.status, DiagStatus.warn);
      expect(bucket(30)!.status, DiagStatus.pass);
      expect(bucket(10)!.status, DiagStatus.pass);
      expect(bucket(null), isNull);
    });
  });

  group('what Android and the service recorded', () {
    test('a refused self-restart without "all the time" says so and offers the permission page', () {
      final List<DiagCheck> rows = evaluateKeepAlive(facts(
          tracking: TrackingHealthFacts(standbyBucket: 10, journal: <JournalLine>[
        native('watchdog_refused', detail: 'source=heartbeat reason=no_background_location'),
      ])));
      final DiagCheck c = row(rows, 'self_restart')!;
      expect(c.status, DiagStatus.warn);
      expect(c.detail, contains('Allow all the time'));
      expect(c.secondaryFix?.kind, DiagFixKind.openAppSettings);
    });

    test('a refusal by Android itself points at Unrestricted battery use', () {
      final DiagCheck c = row(
          evaluateKeepAlive(facts(
              tracking: TrackingHealthFacts(journal: <JournalLine>[
            native('watchdog_refused', detail: 'source=heartbeat type=ForegroundServiceStartNotAllowedException'),
          ]))),
          'self_restart')!;
      expect(c.detail, contains('Unrestricted'));
    });

    test('the newest attempt wins: a later success replaces an earlier refusal', () {
      final DiagCheck c = row(
          evaluateKeepAlive(facts(
              tracking: TrackingHealthFacts(journal: <JournalLine>[
            native('watchdog_refused', detail: 'source=heartbeat type=SecurityException', at: now.subtract(const Duration(hours: 3))),
            native('service_restarted_by_watchdog', detail: 'source=activity_transition', at: now.subtract(const Duration(minutes: 5))),
          ]))),
          'self_restart')!;
      expect(c.status, DiagStatus.info);
      expect(c.detail, contains('safety net'));
    });

    test('lines written by the app, not the service, never count as a restart attempt', () {
      final List<DiagCheck> rows = evaluateKeepAlive(facts(
          tracking: TrackingHealthFacts(journal: <JournalLine>[
        JournalLine(at: now, source: 'app', event: 'watchdog_refused'),
      ])));
      expect(row(rows, 'self_restart'), isNull);
    });

    test('Android\'s "force stop" record of the last 3 days is a warning; an old or other exit is not', () {
      DiagCheck? stopped(List<ProcessExit> e) =>
          row(evaluateKeepAlive(facts(tracking: TrackingHealthFacts(exits: e))), 'last_force_stop');
      final DiagCheck c = stopped(<ProcessExit>[exitOf(10, const Duration(hours: 2))])!;
      // The service is running now (the default fact), so a single stop is information, not a nag.
      expect(c.status, DiagStatus.info);
      expect(stopped(<ProcessExit>[exitOf(10, const Duration(hours: 2)), exitOf(10, const Duration(hours: 9))])!.status,
          DiagStatus.warn);
      expect(
          row(evaluateKeepAlive(facts(service: false, tracking: TrackingHealthFacts(exits: <ProcessExit>[exitOf(10, const Duration(hours: 2))]))),
                  'last_force_stop')!
              .status,
          DiagStatus.warn);
      expect(c.detail, contains('USER_REQUESTED'));
      expect(c.detail, contains('cannot restart itself'));
      expect(stopped(<ProcessExit>[exitOf(11, const Duration(hours: 5))]), isNotNull);
      expect(stopped(<ProcessExit>[exitOf(10, const Duration(days: 4))]), isNull);
      expect(stopped(<ProcessExit>[exitOf(3, const Duration(hours: 1)), exitOf(14, const Duration(hours: 1))]), isNull);
      expect(stopped(<ProcessExit>[]), isNull);
    });

    test('no force-stop warning while sharing is off', () {
      expect(
          row(evaluateKeepAlive(facts(sharing: false, tracking: TrackingHealthFacts(exits: <ProcessExit>[exitOf(10, const Duration(hours: 1))]))),
              'last_force_stop'),
          isNull);
    });
  });

  group('headline verdict', () {
    test('everything read and right on a Pixel is ok', () {
      expect(keepAliveVerdict(evaluateKeepAlive(facts()), facts()), KeepAliveVerdict.ok);
    });

    test('a Samsung phone is never plain ok: the Sleeping apps lists are the user\'s check', () {
      expect(keepAliveVerdict(evaluateKeepAlive(facts(manufacturer: 'samsung')), facts(manufacturer: 'samsung')), KeepAliveVerdict.yourCheck);
    });

    test('another phone maker with its own setting (battery row is a check-once note) is not plain ok either', () {
      expect(keepAliveVerdict(evaluateKeepAlive(facts(manufacturer: 'Xiaomi')), facts(manufacturer: 'Xiaomi')), KeepAliveVerdict.yourCheck);
    });

    test('unreadable required settings are not green (probe failure defaults, unreadable battery or location)', () {
      expect(keepAliveVerdict(evaluateKeepAlive(DiagFacts(now: now, manufacturer: 'samsung')), DiagFacts(now: now, manufacturer: 'samsung')), KeepAliveVerdict.unread);
      expect(keepAliveVerdict(evaluateKeepAlive(facts(manufacturer: 'samsung', ignoring: null)), facts(manufacturer: 'samsung', ignoring: null)), KeepAliveVerdict.unread);
      expect(keepAliveVerdict(evaluateKeepAlive(facts(ignoring: null)), facts(ignoring: null)), KeepAliveVerdict.unread);
      expect(keepAliveVerdict(evaluateKeepAlive(facts(location: null)), facts(location: null)), KeepAliveVerdict.unread);
    });

    test('a failing or warning row wins over unread', () {
      expect(keepAliveVerdict(evaluateKeepAlive(facts(location: 'denied')), facts(location: 'denied')), KeepAliveVerdict.fail);
      expect(keepAliveVerdict(evaluateKeepAlive(facts(ignoring: false)), facts(ignoring: false)), KeepAliveVerdict.warn);
    });
  });

  test('the checklist and Diagnostics agree: same battery and standby verdicts from the same facts', () {
    final DiagFacts f = facts(manufacturer: 'samsung', ignoring: false, tracking: const TrackingHealthFacts(standbyBucket: 45));
    final List<DiagCheck> diag = evaluateDiagnostics(f);
    final List<DiagCheck> alive = evaluateKeepAlive(f);
    for (final String id in <String>['battery', 'standby_bucket', 'location_permission', 'notifications']) {
      final DiagCheck a = row(diag, id)!;
      final DiagCheck b = row(alive, id)!;
      expect(b.status, a.status, reason: id);
      expect(b.detail, a.detail, reason: id);
    }
  });

  test('iPhone: no rows (there are no such settings)', () {
    expect(evaluateKeepAlive(facts(android: false)), isEmpty);
  });

  test('the light probe (no tracking facts) still gives the permission and battery rows', () {
    final List<DiagCheck> rows = evaluateKeepAlive(facts(tracking: null));
    expect(row(rows, 'battery'), isNotNull);
    expect(row(rows, 'standby_bucket'), isNull);
    expect(row(rows, 'self_restart'), isNull);
  });

  test('counts', () {
    final ({int fail, int warn}) n = keepAliveCounts(evaluateKeepAlive(facts(location: 'while_in_use', ignoring: false)));
    expect(n.fail, 1);
    expect(n.warn, greaterThanOrEqualTo(1));
  });
}
