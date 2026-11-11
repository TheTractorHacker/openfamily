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

/// Samsung only. Samsung has its own list ("Never auto sleeping apps") and on the reporter's phone searching it for
/// Orbitly shows "No apps". Why is NOT confirmed: web reports say Samsung can leave out an app whose battery use is
/// already "Unrestricted", but nobody has checked that on that phone. The app cannot read Samsung's lists; what it
/// can read is Android's own "Unrestricted" flag. Null on other phones.
///
/// Even when that flag is set this row is only "info": the Samsung "Sleeping apps" and "Deep sleeping apps" lists
/// cannot be read, so the app must not call the phone good. The user checks those once.
DiagCheck? samsungSleepCheck(DiagFacts f) {
  if (!f.isAndroid || !isSamsungPhone(f.manufacturer)) return null;
  final bool? ignoring = f.ignoringBatteryOptimizations;
  if (ignoring == null) return null;
  if (ignoring && f.backgroundRestricted != true) {
    return const DiagCheck(
        id: 'samsung_sleep',
        title: 'Samsung sleep settings',
        status: DiagStatus.info,
        detail: 'Android reports Orbitly as "Unrestricted", which is the setting that should keep Samsung from '
            'putting it to sleep. Check once yourself: open Settings > Battery > Background usage limits and make '
            'sure Orbitly is NOT under "Sleeping apps" or "Deep sleeping apps" (Orbitly cannot read those lists). '
            'If Samsung\'s "Never auto sleeping apps" search says "No apps" for Orbitly, we think that is because '
            'Samsung leaves out apps that are already Unrestricted, but we could not confirm that on your phone.');
  }
  return const DiagCheck(
      id: 'samsung_sleep',
      title: 'Samsung sleep settings',
      status: DiagStatus.warn,
      detail: 'Orbitly is not "Unrestricted" yet, so Samsung may put it to sleep. Set Settings > Apps > Orbitly > '
          'Battery > "Unrestricted" (the button below). Samsung\'s "Never auto sleeping apps" search may say '
          '"No apps" for Orbitly; Orbitly cannot add itself there, and the "Unrestricted" setting is the one it can '
          'ask for.',
      fix: DiagFix(DiagFixKind.batterySettings, 'Set battery to Unrestricted'),
      secondaryFix: DiagFix(DiagFixKind.oemBattery, 'Open Samsung battery screen'));
}

/// The checks whose answer the headline cannot do without. When one is missing or only "info" (could not be read),
/// the headline must not say everything is right.
const List<String> kKeepAliveRequired = <String>['location_service', 'location_permission', 'battery'];

/// What the headline of the checklist says.
enum KeepAliveVerdict {
  /// At least one check failed.
  fail,

  /// At least one check needs a look.
  warn,

  /// A required setting could not be read: no verdict.
  unread,

  /// Everything readable is right, but something only the user can check is left (the Samsung lists).
  yourCheck,

  /// Everything readable is right and nothing is left to check by hand.
  ok,
}

/// [f] tells an unreadable battery state (no verdict) from the "check your phone maker's own setting once" note that
/// the battery row also carries as "info" on Samsung, Xiaomi and similar phones.
KeepAliveVerdict keepAliveVerdict(List<DiagCheck> checks, DiagFacts f) {
  final ({int fail, int warn}) n = keepAliveCounts(checks);
  if (n.fail > 0) return KeepAliveVerdict.fail;
  if (n.warn > 0) return KeepAliveVerdict.warn;
  final Map<String, DiagCheck> byId = <String, DiagCheck>{for (final DiagCheck c in checks) c.id: c};
  bool oemCheckLeft = false;
  for (final String id in kKeepAliveRequired) {
    final DiagCheck? c = byId[id];
    if (c == null) return KeepAliveVerdict.unread;
    if (c.status != DiagStatus.info) continue;
    if (id == 'battery' && f.ignoringBatteryOptimizations == true) {
      oemCheckLeft = true; // exempt, but the phone maker's own setting cannot be read
    } else {
      return KeepAliveVerdict.unread;
    }
  }
  if (oemCheckLeft || byId['samsung_sleep'] != null) return KeepAliveVerdict.yourCheck;
  return KeepAliveVerdict.ok;
}

/// How many checks of [checks] need the user (failures and warnings).
({int fail, int warn}) keepAliveCounts(List<DiagCheck> checks) => (
      fail: checks.where((DiagCheck c) => c.status == DiagStatus.fail).length,
      warn: checks.where((DiagCheck c) => c.status == DiagStatus.warn).length,
    );
