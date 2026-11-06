/// The "Why isn't my phone reporting?" checks.
///
/// Everything in this file is pure (no plugins, no I/O) so the plain-language
/// verdicts can be unit tested. The facts are collected by `DiagnosticsProbe`
/// and rendered by `DiagnosticsScreen`.
///
/// Privacy: facts and reports never contain coordinates, tokens, passwords,
/// the recovery phrase or key material. The report that "Copy diagnostic
/// report" produces is built from these same redacted facts only.
library;

enum DiagStatus { pass, warn, fail, info }

/// What the one-tap fix button does. The screen maps each kind to an action.
enum DiagFixKind {
  openAppSettings,
  requestLocation,
  requestNotifications,
  batterySettings,
  oemAutostart,
  oemBattery,
  openServerSettings,
  signIn,
  sendQueue,
  openPushSettings,
  openEncryption,
  runSelfTest,
  startTracking,
}

class DiagFix {
  const DiagFix(this.kind, this.label);
  final DiagFixKind kind;
  final String label;
}

class DiagCheck {
  const DiagCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    this.fix,
    this.secondaryFix,
  });

  final String id;
  final String title;
  final DiagStatus status;

  /// Plain-language explanation of what was found and why it matters.
  final String detail;
  final DiagFix? fix;
  final DiagFix? secondaryFix;
}

/// Server reachability as the app experienced it.
enum ServerState { ok, unreachable, authFailed, unknown }

/// Raw facts about this phone. Null means "could not be determined", which the
/// checks report honestly instead of guessing.
class DiagFacts {
  const DiagFacts({
    required this.now,
    this.isAndroid = true,
    this.manufacturer = '',
    this.model = '',
    this.osRelease = '',
    this.sdk,
    this.appVersion = '',
    this.locationService,
    this.locationPermission,
    this.preciseLocation,
    this.notificationsGranted,
    this.ignoringBatteryOptimizations,
    this.backgroundRestricted,
    this.powerSave,
    this.networkOnline,
    this.server = ServerState.unknown,
    this.serverHost = '',
    this.lastReportAt,
    this.lastSeenAt,
    this.lastWsAt,
    this.outboxPending,
    this.pushRegistered,
    this.pushTransport = '',
    this.lastPushOkAt,
    this.lastPushFailAt,
    this.clockSkew,
    this.backgroundServiceRunning,
    this.sharingEnabled = true,
    this.hasPrivateCircle = false,
    this.vaultReadable,
    this.vaultDetail = '',
    this.vaultNeedsUnlock = false,
    this.vaultUserAuth = false,
    this.deviceIdSuffix = '',
  });

  final DateTime now;
  final bool isAndroid;
  final String manufacturer;
  final String model;
  final String osRelease;
  final int? sdk;
  final String appVersion;

  /// Whether the phone's location switch is on.
  final bool? locationService;

  /// 'always' | 'while_in_use' | 'denied' | 'unknown'.
  final String? locationPermission;
  final bool? preciseLocation;
  final bool? notificationsGranted;
  final bool? ignoringBatteryOptimizations;
  final bool? backgroundRestricted;
  final bool? powerSave;
  final bool? networkOnline;
  final ServerState server;
  final String serverHost;

  /// When the server last heard from this account (any upload or heartbeat).
  final DateTime? lastReportAt;
  final DateTime? lastSeenAt;
  final DateTime? lastWsAt;
  final int? outboxPending;
  final bool? pushRegistered;
  final String pushTransport;
  final DateTime? lastPushOkAt;
  final DateTime? lastPushFailAt;

  /// Device clock minus server clock (positive = the phone runs fast).
  final Duration? clockSkew;
  final bool? backgroundServiceRunning;
  final bool sharingEnabled;
  final bool hasPrivateCircle;

  /// Whether the E2EE secrets could be decrypted just now with the Keystore.
  final bool? vaultReadable;
  final String vaultDetail;

  /// True when the Keystore key can only be used while the phone is unlocked
  /// (always the case on Android 9+): fixes taken while locked are parked.
  final bool vaultNeedsUnlock;

  /// True when the key demands biometrics / PIN on every use, which the
  /// background service can never satisfy.
  final bool vaultUserAuth;

  /// Last 4 characters of the device id, for matching with the admin page.
  final String deviceIdSuffix;
}

/// How long since the last upload before we call it stale.
const Duration kStaleUpload = Duration(minutes: 30);
const Duration kVeryStaleUpload = Duration(hours: 6);
const Duration kClockWarn = Duration(minutes: 2);
const Duration kClockFail = Duration(minutes: 10);
const int kOutboxWarn = 20;
const int kOutboxFail = 200;

String humanAgo(Duration d) {
  if (d.isNegative) return 'just now';
  if (d.inSeconds < 90) return 'just now';
  if (d.inMinutes < 90) return '${d.inMinutes} minutes ago';
  if (d.inHours < 48) return '${d.inHours} hours ago';
  return '${d.inDays} days ago';
}

String _oemName(String manufacturer) {
  final String m = manufacturer.toLowerCase();
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) return 'Xiaomi';
  if (m.contains('samsung')) return 'Samsung';
  if (m.contains('oneplus')) return 'OnePlus';
  if (m.contains('huawei') || m.contains('honor')) return 'Huawei';
  if (m.contains('oppo') || m.contains('realme')) return 'Oppo';
  return '';
}

/// OEM-specific advice, shown under the battery check. Empty for stock Android.
String oemGuidance(String manufacturer) {
  switch (_oemName(manufacturer)) {
    case 'Xiaomi':
      return 'On Xiaomi / Redmi / POCO phones: open Security > Permissions > Autostart and switch OpenFamily on, '
          'then Settings > Apps > OpenFamily > Battery saver and choose "No restrictions". '
          'Also lock OpenFamily in the recent-apps list (long-press its card, tap the lock).';
    case 'Samsung':
      return 'On Samsung phones: open Settings > Battery > Background usage limits, remove OpenFamily from '
          '"Sleeping apps" and "Deep sleeping apps", and add it to "Never sleeping apps". '
          'Then set Settings > Apps > OpenFamily > Battery to "Unrestricted".';
    case 'OnePlus':
      return 'On OnePlus phones: open Settings > Battery > Battery optimization > OpenFamily > "Don\'t optimize", '
          'then Settings > Apps > OpenFamily > Battery > "Allow background activity". '
          'Also allow Auto-launch for OpenFamily and lock it in the recent-apps list.';
    case 'Huawei':
      return 'On Huawei / Honor phones: open Settings > Apps > App launch, switch OpenFamily to "Manage manually" '
          'and turn on Auto-launch, Secondary launch and Run in background.';
    case 'Oppo':
      return 'On Oppo / Realme phones: open Settings > Battery > OpenFamily and allow background activity, '
          'allow Auto-launch for OpenFamily and lock it in the recent-apps list.';
  }
  return '';
}

/// Evaluates every check, in the order the screen lists them. The order puts
/// the likeliest causes of "my phone is not reporting" first.
List<DiagCheck> evaluateDiagnostics(DiagFacts f) {
  final List<DiagCheck> out = <DiagCheck>[];

  // 1. Is sharing switched on at all?
  out.add(f.sharingEnabled
      ? const DiagCheck(
          id: 'sharing',
          title: 'Location sharing',
          status: DiagStatus.pass,
          detail: 'Sharing is on for this phone.')
      : const DiagCheck(
          id: 'sharing',
          title: 'Location sharing',
          status: DiagStatus.fail,
          detail: 'You turned location sharing off in OpenFamily, so nothing is being sent. '
              'Turn it back on in Settings to share again.',
          fix: DiagFix(DiagFixKind.startTracking, 'Turn sharing on')));

  // 2. Phone location switch.
  switch (f.locationService) {
    case true:
      out.add(const DiagCheck(
          id: 'location_service',
          title: 'Phone location switch',
          status: DiagStatus.pass,
          detail: 'Location is switched on for the whole phone.'));
    case false:
      out.add(const DiagCheck(
          id: 'location_service',
          title: 'Phone location switch',
          status: DiagStatus.fail,
          detail: 'Location is switched off for the whole phone (the quick-settings tile). '
              'Nothing can report until you switch it on.',
          fix: DiagFix(DiagFixKind.openAppSettings, 'Open settings')));
    default:
      out.add(const DiagCheck(
          id: 'location_service',
          title: 'Phone location switch',
          status: DiagStatus.info,
          detail: 'Could not read the phone\'s location switch.'));
  }

  // 3. Permission level.
  switch (f.locationPermission) {
    case 'always':
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.pass,
          detail: 'Allowed "all the time", so OpenFamily can report with the screen off.'));
    case 'while_in_use':
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.fail,
          detail: 'Location is only allowed "while using the app". OpenFamily stops reporting as soon as '
              'you lock the phone or switch apps, which is the most common reason a phone goes quiet. '
              'Choose "Allow all the time".',
          fix: DiagFix(DiagFixKind.openAppSettings, 'Open app permissions')));
    case 'denied':
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.fail,
          detail: 'Location permission is denied, so OpenFamily cannot see where this phone is.',
          fix: DiagFix(DiagFixKind.requestLocation, 'Allow location'),
          secondaryFix: DiagFix(DiagFixKind.openAppSettings, 'Open app permissions')));
    default:
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.info,
          detail: 'Could not read the location permission.'));
  }

  // 4. Precise location.
  if (f.preciseLocation == false) {
    out.add(const DiagCheck(
        id: 'precise',
        title: 'Precise location',
        status: DiagStatus.warn,
        detail: 'Only approximate location is allowed, so positions can be off by a few hundred metres '
            'and arrivals at places may be missed. Turn "Use precise location" on.',
        fix: DiagFix(DiagFixKind.openAppSettings, 'Open app permissions')));
  } else if (f.preciseLocation == true) {
    out.add(const DiagCheck(
        id: 'precise',
        title: 'Precise location',
        status: DiagStatus.pass,
        detail: 'Precise location is allowed.'));
  }

  // 5. Battery (Android only).
  if (f.isAndroid) {
    final String oem = oemGuidance(f.manufacturer);
    final bool restricted = f.backgroundRestricted == true;
    if (restricted) {
      out.add(DiagCheck(
          id: 'battery',
          title: 'Battery and background limits',
          status: DiagStatus.fail,
          detail: 'Android has this app on "Restricted" battery use, which blocks all background work, so it '
              'cannot report with the screen off. Set it to "Unrestricted".${oem.isEmpty ? '' : ' $oem'}',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings'),
          secondaryFix: _oemFix(f.manufacturer, DiagFixKind.oemBattery, 'Open ${_oemName(f.manufacturer)} battery screen')));
    } else if (f.ignoringBatteryOptimizations == false) {
      out.add(DiagCheck(
          id: 'battery',
          title: 'Battery and background limits',
          status: DiagStatus.warn,
          detail: 'Battery optimisation is on for OpenFamily. Android may pause it while the phone is idle, '
              'so updates arrive late or not at all. Set it to "Don\'t optimise".${oem.isEmpty ? '' : ' $oem'}',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings'),
          secondaryFix: _oemFix(f.manufacturer, DiagFixKind.oemBattery, 'Open ${_oemName(f.manufacturer)} battery screen')));
    } else if (f.ignoringBatteryOptimizations == true) {
      out.add(DiagCheck(
          id: 'battery',
          title: 'Battery and background limits',
          status: oem.isEmpty ? DiagStatus.pass : DiagStatus.info,
          detail: oem.isEmpty
              ? 'OpenFamily is exempt from battery optimisation.'
              : 'OpenFamily is exempt from Android\'s battery optimisation. $oem Android cannot tell whether '
                  'your phone maker\'s own extra setting is on, so check it once.',
          secondaryFix: _oemFix(f.manufacturer, DiagFixKind.oemAutostart, 'Open ${_oemName(f.manufacturer)} autostart screen')));
    } else {
      out.add(const DiagCheck(
          id: 'battery',
          title: 'Battery and background limits',
          status: DiagStatus.info,
          detail: 'Could not read the battery optimisation state.',
          fix: DiagFix(DiagFixKind.batterySettings, 'Open battery settings')));
    }
    if (f.powerSave == true) {
      out.add(const DiagCheck(
          id: 'power_save',
          title: 'Battery saver mode',
          status: DiagStatus.warn,
          detail: 'Battery saver is on right now. It limits background activity and location, so updates '
              'will be less frequent until you turn it off.',
          fix: DiagFix(DiagFixKind.batterySettings, 'Open battery settings')));
    }
  }

  // 6. Notifications.
  if (f.notificationsGranted == true) {
    out.add(const DiagCheck(
        id: 'notifications',
        title: 'Notifications',
        status: DiagStatus.pass,
        detail: 'Notifications are allowed, so alerts can reach this phone.'));
  } else if (f.notificationsGranted == false) {
    out.add(const DiagCheck(
        id: 'notifications',
        title: 'Notifications',
        status: DiagStatus.warn,
        detail: 'Notifications are blocked. You will not see arrival alerts, SOS or check-ins, and Android may '
            'hide the "sharing your location" notice that keeps tracking alive.',
        fix: DiagFix(DiagFixKind.requestNotifications, 'Allow notifications'),
        secondaryFix: DiagFix(DiagFixKind.openAppSettings, 'Open app settings')));
  }

  // 7. Network, server, sign-in.
  if (f.networkOnline == false) {
    out.add(const DiagCheck(
        id: 'network',
        title: 'Internet connection',
        status: DiagStatus.fail,
        detail: 'The phone has no internet right now (airplane mode, no signal or Wi-Fi without internet). '
            'Positions are kept on the phone and sent when it reconnects.'));
  } else if (f.networkOnline == true) {
    out.add(const DiagCheck(
        id: 'network',
        title: 'Internet connection',
        status: DiagStatus.pass,
        detail: 'The phone is online.'));
  }
  switch (f.server) {
    case ServerState.ok:
      out.add(DiagCheck(
          id: 'server',
          title: 'Your OpenFamily server',
          status: DiagStatus.pass,
          detail: 'Reached ${f.serverHost.isEmpty ? 'the server' : f.serverHost} and you are signed in.'));
    case ServerState.authFailed:
      out.add(const DiagCheck(
          id: 'server',
          title: 'Your OpenFamily server',
          status: DiagStatus.fail,
          detail: 'The server answered but no longer accepts this sign-in, so nothing can be uploaded. '
              'Sign in again.',
          fix: DiagFix(DiagFixKind.signIn, 'Sign in again')));
    case ServerState.unreachable:
      out.add(DiagCheck(
          id: 'server',
          title: 'Your OpenFamily server',
          status: f.networkOnline == false ? DiagStatus.info : DiagStatus.fail,
          detail: f.networkOnline == false
              ? 'Could not check the server because the phone is offline.'
              : 'The phone is online but could not reach ${f.serverHost.isEmpty ? 'the server' : f.serverHost}. '
                  'The server may be down, or the address in Settings may be wrong.',
          fix: const DiagFix(DiagFixKind.openServerSettings, 'Check server address')));
    case ServerState.unknown:
      out.add(const DiagCheck(
          id: 'server',
          title: 'Your OpenFamily server',
          status: DiagStatus.info,
          detail: 'The server was not checked.'));
  }

  // 8. Last successful upload (the server's view).
  final DateTime? last = f.lastReportAt ?? f.lastSeenAt;
  if (f.server == ServerState.ok) {
    if (last == null) {
      out.add(const DiagCheck(
          id: 'last_upload',
          title: 'Last upload the server received',
          status: DiagStatus.fail,
          detail: 'The server has never received anything from this account. Check the permission and battery '
              'items above, then walk around for a minute with the app open.',
          fix: DiagFix(DiagFixKind.runSelfTest, 'Run the self-test')));
    } else {
      final Duration age = f.now.difference(last);
      out.add(DiagCheck(
          id: 'last_upload',
          title: 'Last upload the server received',
          status: age > kVeryStaleUpload
              ? DiagStatus.fail
              : age > kStaleUpload
                  ? DiagStatus.warn
                  : DiagStatus.pass,
          detail: age > kStaleUpload
              ? 'The server last heard from this phone ${humanAgo(age)}. If the phone has been moving or in use '
                  'since then, something above is stopping background reporting.'
              : 'The server heard from this phone ${humanAgo(age)}.',
          fix: age > kStaleUpload ? const DiagFix(DiagFixKind.runSelfTest, 'Run the self-test') : null));
    }
  }

  // 9. Queue.
  final int? q = f.outboxPending;
  if (q != null) {
    out.add(DiagCheck(
        id: 'outbox',
        title: 'Waiting to upload',
        status: q >= kOutboxFail
            ? DiagStatus.fail
            : q >= kOutboxWarn
                ? DiagStatus.warn
                : DiagStatus.pass,
        detail: q == 0
            ? 'Nothing is waiting: every position has been sent.'
            : q >= kOutboxWarn
                ? '$q positions are stuck on the phone. They are sent as soon as the connection to the server works.'
                : '$q position${q == 1 ? ' is' : 's are'} waiting to be sent.',
        fix: q > 0 && f.server == ServerState.ok ? const DiagFix(DiagFixKind.sendQueue, 'Send now') : null));
  }

  // 10. Push.
  if (f.pushRegistered == false) {
    out.add(const DiagCheck(
        id: 'push',
        title: 'Push channel',
        status: DiagStatus.warn,
        detail: 'This phone is not registered to receive alerts. Alerts about family members will not arrive '
            'while the app is closed.',
        fix: DiagFix(DiagFixKind.openPushSettings, 'Open notification settings')));
  } else if (f.pushRegistered == true) {
    final DateTime? fail = f.lastPushFailAt;
    final DateTime? ok = f.lastPushOkAt;
    final bool failing = fail != null && (ok == null || fail.isAfter(ok));
    out.add(DiagCheck(
        id: 'push',
        title: 'Push channel',
        status: failing ? DiagStatus.warn : DiagStatus.pass,
        detail: failing
            ? 'The server could not deliver the last alert it tried to send here (${humanAgo(f.now.difference(fail))}). '
                'Open the app once and check notification settings.'
            : ok != null
                ? 'Registered${f.pushTransport.isEmpty ? '' : ' (${f.pushTransport})'}. The last alert was delivered '
                    '${humanAgo(f.now.difference(ok))}.'
                : 'Registered${f.pushTransport.isEmpty ? '' : ' (${f.pushTransport})'}. No alert has been sent to this phone yet; '
                    'the self-test can send one.',
        fix: failing ? const DiagFix(DiagFixKind.openPushSettings, 'Open notification settings') : null,
        secondaryFix: const DiagFix(DiagFixKind.runSelfTest, 'Send a test alert')));
  }

  // 11. Clock.
  final Duration? skew = f.clockSkew;
  if (skew != null) {
    final Duration abs = skew.abs();
    final String dir = skew.isNegative ? 'behind' : 'ahead of';
    out.add(DiagCheck(
        id: 'clock',
        title: 'Phone clock',
        status: abs >= kClockFail
            ? DiagStatus.fail
            : abs >= kClockWarn
                ? DiagStatus.warn
                : DiagStatus.pass,
        detail: abs >= kClockWarn
            ? 'The phone clock is ${abs.inMinutes} minutes $dir the server. A wrong clock makes the server reject '
                'positions as too old or from the future, and sign-in can fail. Turn on automatic date and time.'
            : 'The phone clock agrees with the server.',
        fix: abs >= kClockWarn ? const DiagFix(DiagFixKind.openAppSettings, 'Open settings') : null));
  }

  // 12. Background service.
  if (f.isAndroid && f.sharingEnabled && f.backgroundServiceRunning != null) {
    out.add(f.backgroundServiceRunning!
        ? const DiagCheck(
            id: 'background_service',
            title: 'Background tracking service',
            status: DiagStatus.pass,
            detail: 'The background service that reports with the screen off is running.')
        : const DiagCheck(
            id: 'background_service',
            title: 'Background tracking service',
            status: DiagStatus.fail,
            detail: 'The background service is not running, so nothing reports while the app is closed. '
                'It is restarted when you open the app; if it keeps stopping, the battery items above are the cause.',
            fix: DiagFix(DiagFixKind.startTracking, 'Restart tracking')));
  }

  // 13. Private circles: can the background reporter use its keys?
  //
  // By design the Keystore key can only be used while the phone is unlocked
  // (setUnlockedDeviceRequired), so fixes taken while it is locked are parked on
  // the phone and sealed on the next unlock (PrivateRuntime). That is reported
  // as information, not as a fault. A key bound to biometrics/PIN every time
  // (userAuthRequired) is a real problem: the background service can never use it.
  if (f.hasPrivateCircle) {
    if (f.vaultReadable != true) {
      out.add(DiagCheck(
          id: 'vault',
          title: 'Private circle keys',
          status: DiagStatus.fail,
          detail: 'The encryption keys on this phone could not be opened${f.vaultDetail.isEmpty ? '' : ' (${f.vaultDetail})'}. '
              'Positions for your Private circle cannot be encrypted, so none are sent. '
              'Open encryption settings to restore the keys.',
          fix: const DiagFix(DiagFixKind.openEncryption, 'Open encryption settings')));
    } else if (f.vaultUserAuth) {
      out.add(const DiagCheck(
          id: 'vault',
          title: 'Private circle keys',
          status: DiagStatus.warn,
          detail: 'The keys are set to ask for your screen lock or fingerprint each time. The background '
              'service cannot do that, so your Private circle only updates while you are using the app. '
              'Turn that protection off in encryption settings if you want updates with the screen off.',
          fix: DiagFix(DiagFixKind.openEncryption, 'Open encryption settings')));
    } else {
      out.add(DiagCheck(
          id: 'vault',
          title: 'Private circle keys',
          status: f.vaultNeedsUnlock ? DiagStatus.info : DiagStatus.pass,
          detail: f.vaultNeedsUnlock
              ? 'The encryption keys opened just now. They can only be used while the phone is unlocked, so '
                  'positions taken while it is locked are held on the phone and encrypted and sent when you next '
                  'unlock it. Your circle may see updates late; this is by design.'
              : 'The encryption keys on this phone opened just now, so background reporting can encrypt positions.'));
    }
  }

  return out;
}

DiagFix? _oemFix(String manufacturer, DiagFixKind kind, String label) =>
    _oemName(manufacturer).isEmpty ? null : DiagFix(kind, label);

/// Worst status across checks (info counts as pass).
DiagStatus overallStatus(List<DiagCheck> checks) {
  if (checks.any((DiagCheck c) => c.status == DiagStatus.fail)) return DiagStatus.fail;
  if (checks.any((DiagCheck c) => c.status == DiagStatus.warn)) return DiagStatus.warn;
  return DiagStatus.pass;
}

String statusWord(DiagStatus s) {
  switch (s) {
    case DiagStatus.pass:
      return 'PASS';
    case DiagStatus.warn:
      return 'WARN';
    case DiagStatus.fail:
      return 'FAIL';
    case DiagStatus.info:
      return 'INFO';
  }
}

/// The text behind "Copy diagnostic report". Redacted by construction: it is
/// built only from [DiagFacts] fields, which never hold coordinates, tokens,
/// emails, passwords or key material. Free-text details are the plain-language
/// verdicts above, which contain only counts, ages and the server host name.
String buildDiagnosticReport(DiagFacts f, List<DiagCheck> checks) {
  final StringBuffer b = StringBuffer()
    ..writeln('OpenFamily diagnostic report')
    ..writeln('Time (UTC): ${f.now.toUtc().toIso8601String()}')
    ..writeln('App version: ${f.appVersion.isEmpty ? 'unknown' : f.appVersion}')
    ..writeln('Phone: ${f.manufacturer} ${f.model}'.trimRight())
    ..writeln('Android: ${f.osRelease}${f.sdk == null ? '' : ' (SDK ${f.sdk})'}')
    ..writeln('Server: ${f.serverHost.isEmpty ? 'unknown' : f.serverHost}')
    ..writeln('Device: ...${f.deviceIdSuffix.isEmpty ? '?' : f.deviceIdSuffix}')
    ..writeln('Overall: ${statusWord(overallStatus(checks))}')
    ..writeln();
  for (final DiagCheck c in checks) {
    b.writeln('[${statusWord(c.status)}] ${c.title}: ${c.detail}');
  }
  b
    ..writeln()
    ..writeln('This report contains no locations, no tokens and no account details.');
  return b.toString();
}
