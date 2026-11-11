/// The "Keep tracking alive" checklist: which of the things the user controls and that decide whether Android lets
/// Orbitly keep reporting with the screen off are in place right now.
///
/// Pure (no plugins, no I/O). It is a view over the same [DiagFacts] and the same checks as the Diagnostics screen
/// ([evaluateDiagnostics]), so the two can never disagree; the only check made here is the Samsung one.
library;

import 'diag_model.dart';

/// The ids of [evaluateDiagnostics] that belong on the checklist, in the order the checklist shows them. The
/// likeliest causes of "my phone stopped reporting when the app was closed" come first.
const List<String> kKeepAliveOrder = <String>[
  'sharing',
  'location_service',
  'location_permission',
  'battery',
  'samsung_sleep',
  'standby_bucket',
  'power_save',
  'notifications',
  'background_service',
  'self_restart',
  'last_force_stop',
];

/// The checks of the checklist, in order. Empty for a phone that is not Android: iOS has no such settings.
List<DiagCheck> evaluateKeepAlive(DiagFacts f) {
  if (!f.isAndroid) return const <DiagCheck>[];
  final Map<String, DiagCheck> all = <String, DiagCheck>{
    for (final DiagCheck c in evaluateDiagnostics(f)) c.id: c,
  };
  final DiagCheck? samsung = samsungSleepCheck(f);
  if (samsung != null) all[samsung.id] = samsung;
  return <DiagCheck>[
    for (final String id in kKeepAliveOrder)
      if (all[id] != null) all[id]!,
  ];
}

/// Samsung only. Samsung has its own list ("Never auto sleeping apps") that does not show an app whose battery use
/// is already "Unrestricted", so searching it for Orbitly finds nothing. The app cannot read Samsung's lists; what it
/// can read is Android's own "Unrestricted" flag, which is the setting that counts. Null on other phones.
DiagCheck? samsungSleepCheck(DiagFacts f) {
  if (!f.isAndroid || !isSamsungPhone(f.manufacturer)) return null;
  final bool? ignoring = f.ignoringBatteryOptimizations;
  if (ignoring == null) return null;
  if (ignoring && f.backgroundRestricted != true) {
    return const DiagCheck(
        id: 'samsung_sleep',
        title: 'Samsung sleep settings',
        status: DiagStatus.pass,
        detail: 'Samsung should not put Orbitly to sleep: its battery use is "Unrestricted". If Samsung\'s '
            '"Never auto sleeping apps" search says "No apps" for Orbitly, that is expected. You do not need '
            'Orbitly on that list. Android cannot read Samsung\'s "Sleeping apps" and "Deep sleeping apps" '
            'lists, so open Settings > Battery > Background usage limits once and make sure Orbitly is not on them.');
  }
  return const DiagCheck(
      id: 'samsung_sleep',
      title: 'Samsung sleep settings',
      status: DiagStatus.warn,
      detail: 'Orbitly is not "Unrestricted" yet, so Samsung may put it to sleep. Set Settings > Apps > Orbitly > '
          'Battery > "Unrestricted" (the button below). You do not need Samsung\'s "Never auto sleeping apps" list: '
          'it often shows "No apps" and it is not required.',
      fix: DiagFix(DiagFixKind.batterySettings, 'Set battery to Unrestricted'),
      secondaryFix: DiagFix(DiagFixKind.oemBattery, 'Open Samsung battery screen'));
}

/// How many checks of [checks] need the user (failures and warnings).
({int fail, int warn}) keepAliveCounts(List<DiagCheck> checks) => (
      fail: checks.where((DiagCheck c) => c.status == DiagStatus.fail).length,
      warn: checks.where((DiagCheck c) => c.status == DiagStatus.warn).length,
    );
