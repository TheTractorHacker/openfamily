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

import 'tracking_health.dart';

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

/// How this phone delivers to ONE Private circle. Counts, times and short codes only: no circle id or name, no
/// position, no content.
class PrivateCircleDelivery {
  const PrivateCircleDelivery({
    required this.laneKind,
    this.serverGen = 0,
    this.prefGen = 0,
    this.serverKeyMissing = false,
    this.queued = 0,
    this.parked = 0,
    this.lastSealedAt,
    this.circleKeyMissing = false,
    this.awaitingApproval = false,
    this.serverCopyRefused = false,
  });

  /// This phone holds no key of the circle yet (it waits for another member's phone to share it).
  final bool circleKeyMissing;

  /// This phone's key is not approved in the circle yet (an admin approves it once).
  final bool awaitingApproval;

  /// The server refused this phone's server copy (its signed choice names an old server key); the phone switched to
  /// the family copy and signs its choice again by itself.
  final bool serverCopyRefused;

  /// 'phone' | 'server' | 'pending' (the family admin requires server processing and this phone has not signed its
  /// own choice for the current server key yet: the relay refuses its positions until it has) | 'failed' (the processing
  /// records did not verify: the phone lane is used).
  final String laneKind;

  /// The circle's current server-key generation (server lane only).
  final int serverGen;

  /// The generation this member's own signed pref names (0: unknown). Older than [serverGen] is accepted by the phone
  /// and the server alike; shown so a reader does not have to wonder.
  final int prefGen;

  /// Server lane, but this phone does not hold the server key of [serverGen]: items go on the phone line instead.
  final bool serverKeyMissing;

  /// Sealed items waiting for upload.
  final int queued;

  /// Positions waiting to be sealed (no key yet, keys unreadable): not part of "Updates waiting".
  final int parked;
  final DateTime? lastSealedAt;

  bool get stalePref => laneKind == 'server' && prefGen > 0 && prefGen < serverGen;

  String get laneLabel {
    switch (laneKind) {
      case 'server':
        return 'server gen $serverGen${stalePref ? ' (pref names gen $prefGen)' : ''}${serverKeyMissing ? ' (no server key here: phone line used)' : ''}';
      case 'pending':
        return 'server processing required (phone signs by itself; positions refused until it has)';
      case 'failed':
        return 'phone (verification failed)';
      default:
        return 'phone';
    }
  }
}

/// This phone's Private-circle pipeline (see `PrivateRuntime.deliveryFacts`).
class PrivateDeliveryFacts {
  const PrivateDeliveryFacts({
    required this.uplink,
    this.circles = const <PrivateCircleDelivery>[],
    this.lastFixAt,
    this.lastUploadOkAt,
    this.lastErrorCode = '',
    this.lastErrorAt,
  });

  /// 'sealed only' | 'both' | 'plaintext only'.
  final String uplink;
  final List<PrivateCircleDelivery> circles;

  /// The newest GPS fix the pipeline was handed (before sealing), either isolate.
  final DateTime? lastFixAt;

  /// The last time the relay answered an upload of sealed items.
  final DateTime? lastUploadOkAt;

  /// The last seal or upload problem, as a short code (`seal_timeout`, `http_401`, `rejected_bad_epoch` ...).
  final String lastErrorCode;
  final DateTime? lastErrorAt;
}

/// GPS fixes this recent count as "the phone is getting positions".
const Duration kRecentFix = Duration(minutes: 15);

/// Nothing sealed for this long while fixes arrive: the Private pipeline is stuck.
const Duration kNoSealWarn = Duration(minutes: 30);

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
    this.storeBackupExcluded,
    this.storeBackupError = '',
    this.vaultReadable,
    this.vaultDetail = '',
    this.vaultNeedsUnlock = false,
    this.vaultUserAuth = false,
    this.deviceIdSuffix = '',
    this.privateDelivery,
    this.tracking,
  });

  /// Process exits, standby bucket, hourly counters and the tracking journal (null: not collected, e.g. the light probe).
  final TrackingHealthFacts? tracking;

  /// The Private-circle pipeline of this phone (null: no Private circle or not collected).
  final PrivateDeliveryFacts? privateDelivery;

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

  /// iOS: whether the private store directory is confirmed excluded from backups (read back). Null: not applicable.
  final bool? storeBackupExcluded;
  final String storeBackupError;

  /// Whether the E2EE secrets could be decrypted just now with the Keystore.
  final bool? vaultReadable;
  final String vaultDetail;

  /// True when the Keystore key can only be used while the phone is unlocked (an old pre-0.24.2 key that has not been
  /// re-wrapped yet, or the strict mode): fixes taken while locked are parked until the next unlock.
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

/// Whether [manufacturer] is Samsung (its own battery lists are described in [oemGuidance]).
bool isSamsungPhone(String manufacturer) => _oemName(manufacturer) == 'Samsung';

/// OEM-specific advice, shown under the battery check. Empty for stock Android.
String oemGuidance(String manufacturer) {
  switch (_oemName(manufacturer)) {
    case 'Xiaomi':
      return 'On Xiaomi / Redmi / POCO phones: open Security > Permissions > Autostart and switch Orbitly on, '
          'then Settings > Apps > Orbitly > Battery saver and choose "No restrictions". '
          'Also lock Orbitly in the recent-apps list (long-press its card, tap the lock).';
    case 'Samsung':
      return 'On Samsung phones: open Settings > Apps > Orbitly > Battery and choose "Unrestricted". That is the '
          'setting that counts. Samsung\'s "Never auto sleeping apps" list often says "No apps" when you search it '
          'for an app that is already Unrestricted, so do not hunt for Orbitly there. Then open Settings > Battery > '
          'Background usage limits and make sure Orbitly is not under "Sleeping apps" or "Deep sleeping apps"; if it '
          'is, remove it. Android cannot read those two lists, so this one needs a look from you.';
    case 'OnePlus':
      return 'On OnePlus phones: open Settings > Battery > Battery optimization > Orbitly > "Don\'t optimize", '
          'then Settings > Apps > Orbitly > Battery > "Allow background activity". '
          'Also allow Auto-launch for Orbitly and lock it in the recent-apps list.';
    case 'Huawei':
      return 'On Huawei / Honor phones: open Settings > Apps > App launch, switch Orbitly to "Manage manually" '
          'and turn on Auto-launch, Secondary launch and Run in background.';
    case 'Oppo':
      return 'On Oppo / Realme phones: open Settings > Battery > Orbitly and allow background activity, '
          'allow Auto-launch for Orbitly and lock it in the recent-apps list.';
  }
  return '';
}

/// What Android's own records say about whether it lets Orbitly keep running: the power group it put the app in,
/// whether the app tried to restart tracking by itself and was refused, and the last time Android stopped it the way
/// "Force stop" does. Shared by the Diagnostics list and the "Keep tracking alive" checklist, so both always agree.
/// Empty when the phone is not Android or nothing was collected (the light probe).
List<DiagCheck> _staySilentChecks(DiagFacts f) {
  final TrackingHealthFacts? t = f.tracking;
  if (!f.isAndroid || t == null) return const <DiagCheck>[];
  final List<DiagCheck> out = <DiagCheck>[];

  final int? bucket = t.standbyBucket;
  if (bucket != null) {
    final String name = standbyBucketName(bucket);
    if (bucket >= 45) {
      out.add(DiagCheck(
          id: 'standby_bucket',
          title: 'Android\'s power group',
          status: DiagStatus.fail,
          detail: 'Android has put Orbitly in the "${name.toLowerCase()}" power group, which allows almost no work '
              'while the app is closed. Set Orbitly\'s battery use to "Unrestricted".',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings')));
    } else if (bucket >= 40) {
      out.add(DiagCheck(
          id: 'standby_bucket',
          title: 'Android\'s power group',
          status: DiagStatus.warn,
          detail: 'Android has put Orbitly in the "${name.toLowerCase()}" power group because it was not opened for a '
              'while. It spaces out the app\'s timed wake-ups. Opening the app moves it up; "Unrestricted" battery '
              'use keeps it from being moved down again.',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings')));
    } else {
      out.add(DiagCheck(
          id: 'standby_bucket',
          title: 'Android\'s power group',
          status: DiagStatus.pass,
          detail: 'Android has Orbitly in the "${name.toLowerCase()}" power group, which does not hold it back.'));
    }
  }

  // The newest answer of Orbitly's own "bring tracking back" attempts, written by the Android service.
  JournalLine? attempt;
  for (final JournalLine l in t.journal) {
    if (l.source != 'native') continue;
    if (l.event == 'service_restarted_by_watchdog' ||
        l.event == 'watchdog_refused' ||
        l.event == 'start_foreground_refused') {
      if (attempt == null || (l.last ?? l.at).isAfter(attempt.last ?? attempt.at)) attempt = l;
    }
  }
  if (attempt != null) {
    final DateTime when = attempt.last ?? attempt.at;
    final String ago = humanAgo(f.now.difference(when));
    if (attempt.event == 'service_restarted_by_watchdog') {
      out.add(DiagCheck(
          id: 'self_restart',
          title: 'Orbitly restarting itself',
          status: DiagStatus.info,
          detail: 'Orbitly found its tracking service stopped and asked Android to start it again ($ago). '
              'That is Orbitly\'s own safety net working.'));
    } else {
      final String why = attempt.detail.contains('no_background_location')
          ? 'Location is not allowed "all the time". Choose "Allow all the time" in the app permissions.'
          : attempt.detail.contains('no_location_permission')
              ? 'Location permission is off.'
              : 'Android only lets an app start tracking from the background when the user has set its battery use to '
                  '"Unrestricted". Set that and the next try can work.';
      out.add(DiagCheck(
          id: 'self_restart',
          title: 'Orbitly restarting itself',
          status: f.sharingEnabled ? DiagStatus.warn : DiagStatus.info,
          detail: 'Orbitly found its tracking service stopped and tried to start it again ($ago), but Android '
              'refused. $why',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings'),
          secondaryFix: const DiagFix(DiagFixKind.openAppSettings, 'Open app permissions')));
    }
  }

  // Android's record of the last time it ended the app the way "Force stop" does. A stopped app receives nothing
  // until it is opened, so no restart can happen after this.
  final List<ProcessExit>? exits = t.exits;
  if (exits != null && f.sharingEnabled) {
    ProcessExit? stopped;
    int stops = 0;
    for (final ProcessExit e in exits) {
      if ((e.reason == 10 || e.reason == 11) && f.now.difference(e.at) < const Duration(hours: 72)) {
        stops++;
        if (stopped == null || e.at.isAfter(stopped.at)) stopped = e;
      }
    }
    if (stopped != null) {
      // Reopening the app ends this problem for now, and the user cannot clear the record, so a single stop that
      // is followed by a running service is only information. It is a warning while the service is down or when it
      // keeps happening.
      final bool recovered = f.backgroundServiceRunning == true && stops < 2;
      out.add(DiagCheck(
          id: 'last_force_stop',
          title: 'Android stopped Orbitly',
          status: recovered ? DiagStatus.info : DiagStatus.warn,
          detail: 'Android recorded that Orbitly was ended the way "Force stop" does it ${humanAgo(f.now.difference(stopped.at))} '
              '(${exitReasonName(stopped.reason)}${stops > 1 ? ', $stops times in 3 days' : ''}). That can be you '
              'swiping it away on some phones, a switch of phone user, or the phone\'s own clean-up (Samsung '
              '"Sleeping apps" and Device care do this). A stopped app cannot restart itself: it stays silent until '
              '${recovered ? 'it is opened, which it now has been and tracking is running' : 'you open it'}. '
              'Set battery use to "Unrestricted" so it is not stopped again.',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings')));
    }
  }
  return out;
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
          detail: 'You turned location sharing off in Orbitly, so nothing is being sent. '
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
          detail: 'Allowed "all the time", so Orbitly can report with the screen off.'));
    case 'while_in_use':
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.fail,
          detail: 'Location is only allowed "while using the app". Orbitly stops reporting as soon as '
              'you lock the phone or switch apps, which is the most common reason a phone goes quiet. '
              'Choose "Allow all the time".',
          fix: DiagFix(DiagFixKind.openAppSettings, 'Open app permissions')));
    case 'denied':
      out.add(const DiagCheck(
          id: 'location_permission',
          title: 'Location permission',
          status: DiagStatus.fail,
          detail: 'Location permission is denied, so Orbitly cannot see where this phone is.',
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
          detail: 'Battery optimisation is on for Orbitly. Android may pause it while the phone is idle, '
              'so updates arrive late or not at all. Set it to "Don\'t optimise".${oem.isEmpty ? '' : ' $oem'}',
          fix: const DiagFix(DiagFixKind.batterySettings, 'Open battery settings'),
          secondaryFix: _oemFix(f.manufacturer, DiagFixKind.oemBattery, 'Open ${_oemName(f.manufacturer)} battery screen')));
    } else if (f.ignoringBatteryOptimizations == true) {
      out.add(DiagCheck(
          id: 'battery',
          title: 'Battery and background limits',
          status: oem.isEmpty ? DiagStatus.pass : DiagStatus.info,
          detail: oem.isEmpty
              ? 'Orbitly is exempt from battery optimisation.'
              : 'Orbitly is exempt from Android\'s battery optimisation. $oem Android cannot tell whether '
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

  out.addAll(_staySilentChecks(f));

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
          title: 'Your Orbitly server',
          status: DiagStatus.pass,
          detail: 'Reached ${f.serverHost.isEmpty ? 'the server' : f.serverHost} and you are signed in.'));
    case ServerState.authFailed:
      out.add(const DiagCheck(
          id: 'server',
          title: 'Your Orbitly server',
          status: DiagStatus.fail,
          detail: 'The server answered but no longer accepts this sign-in, so nothing can be uploaded. '
              'Sign in again.',
          fix: DiagFix(DiagFixKind.signIn, 'Sign in again')));
    case ServerState.unreachable:
      out.add(DiagCheck(
          id: 'server',
          title: 'Your Orbitly server',
          status: f.networkOnline == false ? DiagStatus.info : DiagStatus.fail,
          detail: f.networkOnline == false
              ? 'Could not check the server because the phone is offline.'
              : 'The phone is online but could not reach ${f.serverHost.isEmpty ? 'the server' : f.serverHost}. '
                  'The server may be down, or the address in Settings may be wrong.',
          fix: const DiagFix(DiagFixKind.openServerSettings, 'Check server address')));
    case ServerState.unknown:
      out.add(const DiagCheck(
          id: 'server',
          title: 'Your Orbitly server',
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
        title: 'Updates waiting',
        status: q >= kOutboxFail
            ? DiagStatus.fail
            : q >= kOutboxWarn
                ? DiagStatus.warn
                : DiagStatus.pass,
        detail: q == 0
            ? 'Nothing is waiting: everything has been sent.'
            : q >= kOutboxWarn
                ? '$q updates are stuck on the phone. They are sent as soon as the connection to the server works.'
                : '$q update${q == 1 ? '' : 's'} waiting (positions, messages, check-ins). They are sent in order when the server can be reached.',
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
  // Since 0.24.2 the wrapping key works while the phone is locked (after the first unlock since it started), so
  // background reporting seals and sends normally. Only an old key that was not re-wrapped yet, or a key bound to
  // biometrics/PIN every time (userAuthRequired), stops the background service: both are reported as warnings.
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
          status: f.vaultNeedsUnlock ? DiagStatus.warn : DiagStatus.pass,
          detail: f.vaultNeedsUnlock
              ? 'The keys on this phone still only work while it is unlocked, so positions taken with the screen off '
                  'wait until you unlock it. Open the app once and unlock the phone: the keys are moved to the new '
                  'setting automatically.'
              : 'Keys available while locked: the encryption keys opened just now and work with the screen off, so '
                  'your Private circle keeps updating from a locked phone (after you have unlocked it once since it started).'));
    }
  }

  // 13b. Private circles: is the phone actually sealing and uploading?
  final DiagCheck? pd = privateDeliveryCheck(f);
  if (pd != null) out.add(pd);

  // 14. iOS: is the store of the private circles kept out of backups?
  if (f.storeBackupExcluded != null) {
    out.add(f.storeBackupExcluded == true
        ? const DiagCheck(
            id: 'backup-exclusion',
            title: 'Private data and backups',
            status: DiagStatus.pass,
            detail: 'The folder that holds your Private circle trail, queue and settings on this phone is excluded from backups.')
        : DiagCheck(
            id: 'backup-exclusion',
            title: 'Private data and backups',
            status: DiagStatus.warn,
            detail: 'Backup exclusion NOT confirmed${f.storeBackupError.isEmpty ? '' : ' (${f.storeBackupError})'}. '
                'Private circle data still works, but this phone could not verify that its trail, queue and settings stay out of '
                'iCloud and computer backups. Turn off backups for this app in the phone settings to be safe.'));
  }

  return out;
}

/// Plain words for a short upload or encryption problem code (`http_401`, `rejected_lane_not_server`, `seal_...`),
/// saying what happened and what the app does about it. No codes, no jargon: the code itself stays in the copied
/// report's technical section.
String plainDeliveryProblem(String code) {
  final String c = code.trim();
  if (c.isEmpty) return '';
  if (c == 'offline') return 'the phone had no connection; it sends them as soon as it is back online';
  if (c == 'no_credentials' || c == 'http_401') return 'the phone was renewing its sign-in; it retries by itself';
  if (c == 'http_408' || c == 'http_429') return 'the server asked the phone to slow down; it retries by itself';
  if (c == 'server_error' || RegExp(r'^http_5\d\d$').hasMatch(c)) return 'the server had a problem; the phone retries by itself';
  if (c == 'http_403') {
    return 'the server no longer accepts the encryption key these updates were made with (the key was replaced); '
        'new positions use the current key';
  }
  if (c == 'rejected_lane_not_server' || c == 'rejected_server_line_off' || c == 'rejected_device_lacks_lanes2') {
    return 'the server would not take the copy meant for server processing, so the phone sends the family copy instead '
        'and renews its server processing choice by itself';
  }
  if (c == 'required_server' || c == 'rejected_required_server') {
    return 'the family admin requires server processing and this phone has not signed its server choice (or its choice is for an older server key), so the server refuses these positions (they wait on the phone); '
        'it can also mean an admin phone has to sign the circle policy again. Check-ins, events and chat still go through. The phone signs its choice by itself; update the app if it does not';
  }
  if (c == 'rejected_bad_epoch' || c == 'rejected_legacy_epoch_closed') {
    return 'the family\'s encryption key changed; the phone fetches the new one and sends again';
  }
  if (c.startsWith('flush_unreadable') || c.startsWith('flush_missing') || c.startsWith('flush_invalidated')) {
    final String reason = c.contains(':') ? c.substring(c.indexOf(':') + 1) : '';
    if (c.startsWith('flush_invalidated')) {
      return 'this phone\'s key storage was reset, so its encryption key is lost for good; open Encryption keys and '
          'restore it with your recovery phrase or link it from your other phone';
    }
    if (c.startsWith('flush_missing')) {
      return 'this phone has no encryption key; open Encryption keys to set it up or restore it';
    }
    if (reason == 'empty-user-id') {
      return 'the part of the app that sends positions in the background has lost the note of which account this '
          'phone\'s key belongs to; opening the app repairs it once the server confirms this phone\'s key, and the key '
          'is not changed; if it stays, send this report';
    }
    if (reason == 'device-id-format' || reason == 'device-id-missing') {
      return 'the note of this phone\'s id next to its encryption key is damaged or missing (reason code: $reason); the key '
          'was not changed or deleted; opening the app repairs the note once the server confirms this phone\'s key '
          '(Encryption keys has a Repair button); if it stays, send this report';
    }
    if (reason == 'seed-length' || reason == 'owner-format') {
      return 'the encryption key stored on this phone is not usable as it is (reason code: $reason); the key was not '
          'changed or deleted; if this stays after opening the app, open Encryption keys and send this report';
    }
    if (reason.isEmpty) {
      return 'this phone could not use its own encryption key (the cause was not recorded); open Encryption keys';
    }
    // The read failures (seed-read-*, owner-read-*, device-id-read-*, vault-*): the secure storage did not answer.
    return 'this phone\'s secure storage did not hand over the encryption key for a moment (reason code: $reason); '
        'the key is not changed and the phone tries again';
  }
  if (c.startsWith('seal_')) {
    return 'this phone could not open its own encryption key for a moment; it tries again with the next position';
  }
  if (c.startsWith('rejected_')) return 'the server refused some updates';
  if (c.startsWith('http_')) return 'the server refused the upload';
  return 'there was a problem sending';
}

/// The "Private circle delivery" check: null when there is nothing to say (no Private circle, not collected).
/// Warnings are in plain family words (what is wrong and what the app does about it); the technical summary (counts,
/// codes) is only in the PASS detail and the copied report's own section.
DiagCheck? privateDeliveryCheck(DiagFacts f) {
  final PrivateDeliveryFacts? p = f.privateDelivery;
  if (p == null || p.circles.isEmpty) return null;
  final DateTime? fix = p.lastFixAt;
  final bool gettingFixes = fix != null && f.now.difference(fix) <= kRecentFix;
  final List<String> problems = <String>[];
  int n = 0;
  for (final PrivateCircleDelivery c in p.circles) {
    n++;
    final String name = p.circles.length == 1 ? 'your Private circle' : 'Private circle $n';
    if (c.laneKind == 'pending') {
      problems.add('The family admin requires server processing in $name. This phone signs that choice by itself; until it has, '
          'the server refuses your positions there (check-ins and alerts still go through). Update the app if this stays.');
    }
    final DateTime? s = c.lastSealedAt;
    final bool stuck = gettingFixes && (s == null || f.now.difference(s) > kNoSealWarn);
    if (c.awaitingApproval) {
      problems.add('This phone is waiting to be approved in $name. An admin of the circle approves it once in Encryption keys; '
          'until then your positions are kept on this phone and sent right after.');
    } else if (c.circleKeyMissing || (stuck && c.parked > 0 && !p.lastErrorCode.startsWith('seal_'))) {
      problems.add('This phone is waiting for the family\'s encryption key for $name. It is asked for automatically; another '
          'family member\'s phone or the admin\'s phone has to be online once. Your positions are kept and sent after that.');
    } else if (stuck) {
      final String why = plainDeliveryProblem(p.lastErrorCode);
      problems.add('This phone has fresh positions but has not encrypted one for $name '
          '${s == null ? 'yet' : 'recently (the last one ${humanAgo(f.now.difference(s))})'}, so the others see an old position'
          '${why.isEmpty ? '.' : '. Most likely $why.'}');
    }
    if (c.laneKind == 'failed') {
      problems.add('The server processing settings of $name could not be confirmed, so this phone sends your position '
          'to the family only until they can. Nothing is lost.');
    } else if (c.serverCopyRefused) {
      problems.add('The server stopped taking the copy of your position meant for server processing in $name (its key changed). '
          'This phone sends the family copy instead and renews your choice by itself.');
    }
  }
  final int waiting = p.circles.fold(0, (int a, PrivateCircleDelivery c) => a + c.queued + c.parked);
  final DateTime? ok = p.lastUploadOkAt;
  if (waiting > 0 && (ok == null || f.now.difference(ok) > kStaleUpload)) {
    final String why = plainDeliveryProblem(p.lastErrorCode);
    problems.add('$waiting encrypted update${waiting == 1 ? ' is' : 's are'} waiting and the server has not accepted an '
        'upload ${ok == null ? 'yet' : 'recently (the last one ${humanAgo(f.now.difference(ok))})'}'
        '${why.isEmpty ? '.' : ': $why.'}');
  }
  if (problems.isEmpty) {
    return DiagCheck(
        id: 'private_delivery',
        title: 'Private circle delivery',
        status: DiagStatus.pass,
        detail: 'Positions are encrypted and sent. ${privateDeliverySummary(f)}');
  }
  return DiagCheck(
      id: 'private_delivery',
      title: 'Private circle delivery',
      status: DiagStatus.warn,
      detail: problems.join(' '),
      fix: const DiagFix(DiagFixKind.sendQueue, 'Send now'));
}

String _ageS(DateTime now, DateTime? t) => t == null ? 'never' : '${now.difference(t).inSeconds}';

/// One-line, redacted summary of the Private pipeline (counts, ages in seconds, short codes).
String privateDeliverySummary(DiagFacts f) {
  final PrivateDeliveryFacts? p = f.privateDelivery;
  if (p == null) return '';
  final StringBuffer b = StringBuffer('Uplink: ${p.uplink}.');
  int n = 0;
  for (final PrivateCircleDelivery c in p.circles) {
    n++;
    b.write(' Circle $n: lane ${c.laneLabel}, ${c.queued} queued, ${c.parked} parked, '
        'last sealed ${c.lastSealedAt == null ? 'never' : '${_ageS(f.now, c.lastSealedAt)} s ago'}.');
  }
  b.write(' Last GPS fix: ${p.lastFixAt == null ? 'never' : '${_ageS(f.now, p.lastFixAt)} s ago'}.');
  b.write(' Last accepted upload: ${p.lastUploadOkAt == null ? 'never' : '${_ageS(f.now, p.lastUploadOkAt)} s ago'}.');
  b.write(' Last error: ${p.lastErrorCode.isEmpty ? 'none' : '${p.lastErrorCode} (${_ageS(f.now, p.lastErrorAt)} s ago)'}.');
  return b.toString();
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
String buildDiagnosticReport(DiagFacts f, List<DiagCheck> checks, {String storageEvents = ''}) {
  final StringBuffer b = StringBuffer()
    ..writeln('Orbitly diagnostic report')
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
  final PrivateDeliveryFacts? p = f.privateDelivery;
  if (p != null && p.circles.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Private circle delivery')
      ..writeln('uplink=${p.uplink}');
    int n = 0;
    for (final PrivateCircleDelivery c in p.circles) {
      n++;
      b.writeln('circle$n lane="${c.laneLabel}" queued=${c.queued} parked=${c.parked} sealed_s=${_ageS(f.now, c.lastSealedAt)}');
    }
    b
      ..writeln('gps_fix_s=${_ageS(f.now, p.lastFixAt)} upload_ok_s=${_ageS(f.now, p.lastUploadOkAt)}')
      ..writeln('last_error=${p.lastErrorCode.isEmpty ? 'none' : p.lastErrorCode} error_s=${p.lastErrorCode.isEmpty ? '-' : _ageS(f.now, p.lastErrorAt)}');
  }
  if (storageEvents.isNotEmpty) {
    b
      ..writeln()
      ..write(storageEvents);
  }
  // Last: the tracking journal ends the report, so the newest events are what a reader sees first from the bottom.
  final TrackingHealthFacts? t = f.tracking;
  if (t != null) {
    b
      ..writeln()
      ..write(renderTrackingHealth(t, f.now));
  }
  b
    ..writeln()
    ..writeln('This report contains no locations, no tokens and no account details.');
  return b.toString();
}
