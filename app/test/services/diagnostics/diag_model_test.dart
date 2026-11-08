import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/diagnostics/diagnostics_probe.dart';
import 'package:openfamily/services/diagnostics/diagnostics_reporter.dart';

DiagFacts healthy({
  String manufacturer = 'Google',
  String? location = 'always',
  bool? ignoring = true,
  bool? restricted = false,
  Duration lastAge = const Duration(minutes: 3),
  int outbox = 0,
  Duration? skew = const Duration(seconds: 1),
  bool privateCircle = false,
  bool? vault = true,
  bool needsUnlock = false,
  bool userAuth = false,
  bool? service = true,
  ServerState server = ServerState.ok,
  bool? online = true,
}) {
  final DateTime now = DateTime.utc(2026, 3, 10, 12);
  return DiagFacts(
    now: now,
    manufacturer: manufacturer,
    model: 'Pixel 8',
    osRelease: '14',
    sdk: 34,
    appVersion: '0.19.0+1',
    locationService: true,
    locationPermission: location,
    preciseLocation: true,
    notificationsGranted: true,
    ignoringBatteryOptimizations: ignoring,
    backgroundRestricted: restricted,
    powerSave: false,
    networkOnline: online,
    server: server,
    serverHost: 'family.example.com',
    lastReportAt: now.subtract(lastAge),
    outboxPending: outbox,
    pushRegistered: true,
    pushTransport: 'direct',
    lastPushOkAt: now.subtract(const Duration(hours: 2)),
    clockSkew: skew,
    backgroundServiceRunning: service,
    hasPrivateCircle: privateCircle,
    vaultReadable: vault,
    vaultNeedsUnlock: needsUnlock,
    vaultUserAuth: userAuth,
    deviceIdSuffix: 'ab12',
  );
}

DiagCheck find(List<DiagCheck> l, String id) => l.firstWhere((DiagCheck c) => c.id == id);

void main() {
  test('a healthy phone passes everything', () {
    final List<DiagCheck> checks = evaluateDiagnostics(healthy());
    expect(overallStatus(checks), DiagStatus.pass);
    expect(checks.where((DiagCheck c) => c.status == DiagStatus.fail), isEmpty);
    expect(checks.where((DiagCheck c) => c.status == DiagStatus.warn), isEmpty);
  });

  test('while-in-use location fails with a fix and says why', () {
    final DiagCheck c = find(evaluateDiagnostics(healthy(location: 'while_in_use')), 'location_permission');
    expect(c.status, DiagStatus.fail);
    expect(c.detail, contains('all the time'));
    expect(c.fix?.kind, DiagFixKind.openAppSettings);
  });

  test('denied location offers a prompt and the settings page', () {
    final DiagCheck c = find(evaluateDiagnostics(healthy(location: 'denied')), 'location_permission');
    expect(c.status, DiagStatus.fail);
    expect(c.fix?.kind, DiagFixKind.requestLocation);
    expect(c.secondaryFix?.kind, DiagFixKind.openAppSettings);
  });

  test('battery optimisation warns; restricted fails; both offer the OEM deep link', () {
    final DiagCheck warn = find(evaluateDiagnostics(healthy(manufacturer: 'Xiaomi', ignoring: false)), 'battery');
    expect(warn.status, DiagStatus.warn);
    expect(warn.detail, contains('Autostart'));
    expect(warn.secondaryFix?.kind, DiagFixKind.oemBattery);
    final DiagCheck bad = find(evaluateDiagnostics(healthy(restricted: true, ignoring: false)), 'battery');
    expect(bad.status, DiagStatus.fail);
    expect(bad.secondaryFix, isNull, reason: 'stock Android has no vendor screen');
  });

  test('exempt phones from aggressive vendors still get the vendor advice as info', () {
    for (final String m in <String>['Samsung', 'Xiaomi', 'OnePlus', 'HUAWEI', 'OPPO']) {
      final DiagCheck c = find(evaluateDiagnostics(healthy(manufacturer: m)), 'battery');
      expect(c.status, DiagStatus.info, reason: m);
      expect(oemGuidance(m), isNotEmpty, reason: m);
      expect(c.secondaryFix?.kind, DiagFixKind.oemAutostart, reason: m);
    }
    expect(find(evaluateDiagnostics(healthy()), 'battery').status, DiagStatus.pass);
  });

  test('upload age thresholds', () {
    expect(find(evaluateDiagnostics(healthy(lastAge: const Duration(minutes: 10))), 'last_upload').status, DiagStatus.pass);
    expect(find(evaluateDiagnostics(healthy(lastAge: const Duration(hours: 2))), 'last_upload').status, DiagStatus.warn);
    expect(find(evaluateDiagnostics(healthy(lastAge: const Duration(hours: 9))), 'last_upload').status, DiagStatus.fail);
  });

  test('queue thresholds and the send-now fix', () {
    expect(find(evaluateDiagnostics(healthy(outbox: 3)), 'outbox').status, DiagStatus.pass);
    expect(find(evaluateDiagnostics(healthy(outbox: 40)), 'outbox').status, DiagStatus.warn);
    final DiagCheck c = find(evaluateDiagnostics(healthy(outbox: 300)), 'outbox');
    expect(c.status, DiagStatus.fail);
    expect(c.fix?.kind, DiagFixKind.sendQueue);
  });

  test('clock skew in either direction', () {
    expect(find(evaluateDiagnostics(healthy(skew: const Duration(seconds: 30))), 'clock').status, DiagStatus.pass);
    expect(find(evaluateDiagnostics(healthy(skew: const Duration(minutes: 4))), 'clock').status, DiagStatus.warn);
    final DiagCheck c = find(evaluateDiagnostics(healthy(skew: const Duration(minutes: -20))), 'clock');
    expect(c.status, DiagStatus.fail);
    expect(c.detail, contains('behind'));
  });

  test('server states', () {
    expect(find(evaluateDiagnostics(healthy(server: ServerState.authFailed)), 'server').fix?.kind, DiagFixKind.signIn);
    final DiagCheck down = find(evaluateDiagnostics(healthy(server: ServerState.unreachable)), 'server');
    expect(down.status, DiagStatus.fail);
    expect(down.fix?.kind, DiagFixKind.openServerSettings);
    // Offline is not the server's fault.
    final List<DiagCheck> off = evaluateDiagnostics(healthy(server: ServerState.unreachable, online: false));
    expect(find(off, 'network').status, DiagStatus.fail);
    expect(find(off, 'server').status, DiagStatus.info);
    // No upload verdict when the server could not be asked.
    expect(off.any((DiagCheck c) => c.id == 'last_upload'), isFalse);
  });

  test('background service not running is a failure with a restart fix', () {
    final DiagCheck c = find(evaluateDiagnostics(healthy(service: false)), 'background_service');
    expect(c.status, DiagStatus.fail);
    expect(c.fix?.kind, DiagFixKind.startTracking);
  });

  test('private circle vault: readable, old-key-needs-unlock, user-auth, unreadable', () {
    expect(find(evaluateDiagnostics(healthy(privateCircle: true)), 'vault').status, DiagStatus.pass);
    final DiagCheck locked = find(evaluateDiagnostics(healthy(privateCircle: true, needsUnlock: true)), 'vault');
    expect(locked.status, DiagStatus.warn);
    expect(locked.detail, contains('unlock'));
    expect(locked.detail, isNot(contains('by design')));
    final DiagCheck ok = find(evaluateDiagnostics(healthy(privateCircle: true)), 'vault');
    expect(ok.detail, contains('Keys available while locked'));
    expect(ok.detail, isNot(contains('by design')));
    expect(find(evaluateDiagnostics(healthy(privateCircle: true, userAuth: true)), 'vault').status, DiagStatus.warn);
    final DiagCheck bad = find(evaluateDiagnostics(healthy(privateCircle: true, vault: false)), 'vault');
    expect(bad.status, DiagStatus.fail);
    expect(bad.fix?.kind, DiagFixKind.openEncryption);
    // No vault line at all for people without a Private circle.
    expect(evaluateDiagnostics(healthy()).any((DiagCheck c) => c.id == 'vault'), isFalse);
  });

  test('unknowns are reported as info, never as a guess', () {
    final DiagFacts f = DiagFacts(now: DateTime.utc(2026, 3, 10));
    final List<DiagCheck> checks = evaluateDiagnostics(f);
    expect(find(checks, 'location_permission').status, DiagStatus.info);
    expect(find(checks, 'battery').status, DiagStatus.info);
  });

  test('the report is redacted: no coordinates, tokens or account details', () {
    final DiagFacts f = healthy(privateCircle: true);
    final String report = buildDiagnosticReport(f, evaluateDiagnostics(f));
    expect(report, contains('Orbitly diagnostic report'));
    expect(report, contains('family.example.com'));
    expect(report, contains('...ab12'));
    expect(report, contains('Overall: PASS'));
    expect(RegExp(r'-?\d{1,3}\.\d{4,}').hasMatch(report), isFalse, reason: 'no decimal coordinates');
    // The closing disclaimer names what is absent, so check the body only.
    final String body = report.split('\nThis report contains').first.toLowerCase();
    for (final String forbidden in <String>['bearer', 'token', 'password', '@', 'ingest', 'refresh', 'latitude', 'longitude']) {
      expect(body.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  test('server view: skew is measured against the middle of the request', () {
    final DateTime sent = DateTime.utc(2026, 3, 10, 12, 0, 0);
    final DateTime received = DateTime.utc(2026, 3, 10, 12, 0, 2);
    final ServerView v = ServerView.parse(<String, dynamic>{
      'server_time': '2026-03-10T11:55:01Z',
      'last_report_at': '2026-03-10T11:50:00Z',
      'last_ws_at': null,
      'devices': <dynamic>[
        <String, dynamic>{'id': 'other', 'push_registered': false},
        <String, dynamic>{'id': 'mine', 'push_registered': true, 'push_transport': 'direct', 'last_seen': '2026-03-10T11:54:00Z'},
      ],
      'circles': <dynamic>[
        <String, dynamic>{'id': 'c1', 'name': 'Family', 'private': false, 'silence_alert_hours': 8},
        <String, dynamic>{'id': 'c2', 'name': 'Us', 'private': true, 'silence_alert_hours': 0},
      ],
    }, deviceId: 'mine', sentAt: sent, receivedAt: received);
    expect(v.clockSkew, const Duration(minutes: 5));
    expect(v.pushRegistered, isTrue);
    expect(v.pushTransport, 'direct');
    expect(v.privateCircles, 1);
    expect(v.silenceCircles.first.hours, 8);
    expect(v.lastReportAt, DateTime.utc(2026, 3, 10, 11, 50));
  });

  test('the self-report to the server carries states and counts only', () {
    final Map<String, dynamic> b = DiagnosticsReporter.body(healthy());
    expect(b['battery_opt'], 'unrestricted');
    expect(b['loc_permission'], 'always');
    expect(b['notif_permission'], 'granted');
    expect(b['outbox_pending'], 0);
    expect(b['os_version'], 'Android 14 (SDK 34)');
    expect(b.keys, isNot(contains('lat')));
    expect(b.keys, isNot(contains('token')));
    final Map<String, dynamic> r = DiagnosticsReporter.body(healthy(restricted: true, ignoring: false));
    expect(r['battery_opt'], 'restricted');
  });

  // Mirrors of the server's enum lists (backend/internal/handlers/diagnostics.go).
  // If the app ever sends a value the server rejects (400), the report never
  // arrives and the Fleet page says "not reported" forever.
  const Set<String> serverBattery = <String>{'unrestricted', 'optimized', 'restricted', 'unknown'};
  const Set<String> serverLoc = <String>{'always', 'while_in_use', 'denied', 'unknown'};
  const Set<String> serverNotif = <String>{'granted', 'denied', 'unknown'};

  test('every report the app can build passes the server validation', () {
    for (final String? loc in <String?>['always', 'while_in_use', 'denied', null]) {
      for (final bool? ignoring in <bool?>[true, false, null]) {
        for (final bool? restricted in <bool?>[true, false, null]) {
          final Map<String, dynamic> b = DiagnosticsReporter.body(healthy(location: loc, ignoring: ignoring, restricted: restricted));
          expect(serverBattery, contains(b['battery_opt']));
          expect(serverLoc, contains(b['loc_permission']));
          expect(serverNotif, contains(b['notif_permission']));
          expect((b['os_version'] as String).length, lessThanOrEqualTo(64));
          expect(((b['app_version'] ?? '') as String).length, lessThanOrEqualTo(64));
          expect(b['outbox_pending'] ?? 0, inInclusiveRange(0, 100000));
          expect(utf8.encode(jsonEncode(b)).length, lessThan(4096));
        }
      }
    }
  });

  test('a report is due on first run, after an update, and after 30 minutes only', () {
    const int min = 60000;
    bool due(int? last, int now, String? lastV, String v) =>
        DiagnosticsAutoReport.due(lastMs: last, nowMs: now, lastVersion: lastV, version: v);
    expect(due(null, 1000, null, '0.23.0'), isTrue);
    expect(due(0, 10 * min, '0.23.0', '0.23.0'), isFalse);
    expect(due(0, 30 * min, '0.23.0', '0.23.0'), isTrue);
    expect(due(0, 1 * min, '0.21.1', '0.23.0'), isTrue, reason: 'version change');
    expect(due(0, 1 * min, null, ''), isFalse, reason: 'unknown version must not force reports');
  });
}
