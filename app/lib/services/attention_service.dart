// The attention center: one list of "something needs you" items, shown behind a
// small icon in the top bar instead of banners that push every screen down
// (docs/user/attention-icon.md).
//
// Every source stays where it is; this file only reads them and turns each into
// a plain item:
//   * AppCompat                 -> update required / circles needing a newer app / update available
//   * ServerReachability        -> offline (last synced) / signed out
//   * DeliveryHints             -> nobody sending in a Private circle, this phone's key not approved yet
//   * ServerPrompts rules       -> "Use the server?", "Use the server again?" after a key reset,
//                                  admin setup, the auto-apply notice, "Your server wants to join"
//   * Diagnostics (evaluateDiagnostics) -> location off / no permission / background stopped / key unreadable
//
// Dismiss and snooze reuse what each source already remembers (AppCompat.dismissed,
// ServerChoiceStore, the auto-apply record); only "Not now" on a silent circle and
// on the server-join question is new, and it lasts for the session.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../models/circle.dart';
import '../utils/member_status.dart' show formatClock;
import '../widgets/server_prompts.dart';
import 'app_compat.dart';
import 'delivery_status.dart';
import 'diagnostics/diag_model.dart';
import 'diagnostics/diagnostics_probe.dart';
import 'e2ee/e2ee_app.dart';
import 'e2ee/e2ee_models.dart' show ServerJoinInfo;
import 'e2ee/private_runtime.dart';
import 'offline/server_reachability.dart';

/// Red, amber or neutral. The icon takes the colour of the worst item.
enum AttentionSeverity { info, warning, critical }

enum AttentionKind {
  updateRequired,
  circleUpdate,
  updateAvailable,
  offline,
  signedOut,
  keyUnreadable,
  keyWaiting,
  phoneProblem,
  nobodySending,
  serverChoice,
  serverChoiceAgain,
  serverAdminSetup,
  serverAutoApplied,
  serverJoin,
}

/// What [AttentionService] found out about one circle after a key reset (see
/// `LanesService.serverChoiceLostToNewKey`).
typedef ServerChoiceLost = ({String oldDeviceId, bool recommended});

/// One card of the sheet: a one-sentence title, a one-sentence reason and one action.
@immutable
class AttentionItem {
  const AttentionItem({
    required this.id,
    required this.kind,
    required this.severity,
    required this.title,
    required this.why,
    required this.action,
    this.secondary,
    this.info,
    this.circle,
    this.data,
  });

  /// Stable per source (and circle), e.g. `nobody:<circleId>`.
  final String id;
  final AttentionKind kind;
  final AttentionSeverity severity;
  final String title;
  final String why;

  /// The primary button label.
  final String action;

  /// Optional second button ("Not now", "Keep on my phone").
  final String? secondary;

  /// Optional longer explanation behind the (i) button.
  final String? info;
  final Circle? circle;

  /// Source detail: the [DiagCheck], the old device id after a reset, the server join code.
  final Object? data;

  String get _sig => '$id|${severity.name}|$title|$why|$action|${secondary ?? ''}';
}

/// The diagnostics checks that mean "this phone is not reporting" and that the
/// attention center shows (the rest stay on the Diagnostics screen). The
/// background-service check is left out: right after start-up the service may
/// simply not be running yet, and the shell probes exactly then.
const Set<String> kAttentionDiagChecks = <String>{'location_service', 'location_permission', 'vault'};

String _phoneProblemTitle(DiagCheck c) => switch (c.id) {
      'location_service' => 'Location is off on this phone',
      'location_permission' when c.fix?.kind == DiagFixKind.requestLocation => "Orbitly can't use your location",
      'location_permission' => 'Location works only while Orbitly is open',
      _ => 'This phone is not sending its location',
    };

class AttentionService extends ChangeNotifier implements ValueListenable<List<AttentionItem>> {
  AttentionService({ServerReachability? reachability}) : reachability = reachability ?? ServerReachability.instance {
    for (final Listenable l in _sources) {
      l.addListener(_onSource);
    }
    _rebuild();
  }

  /// The app's one instance (the top-bar icon and the sheet read it).
  static final AttentionService instance = AttentionService();

  final ServerReachability reachability;

  late final List<Listenable> _sources = <Listenable>[
    AppCompat.state,
    AppCompat.dismissed,
    AppCompat.circlesNeedingUpdate,
    AppCompat.circleNamesNeedingUpdate,
    DeliveryHints.reports,
    ServerChoiceStore.changed,
    reachability.state,
    reachability.pending,
  ];

  // Loaders of the asynchronous sources; tests replace them.
  Future<List<AutoNotice>> Function() autoNoticeLoader = loadAutoNotices;
  Future<ServerJoinInfo> Function() serverJoinLoader = () => E2eeApp.service.api.serverJoin();
  Future<ServerChoiceLost?> Function(Circle c) choiceLostLoader =
      (Circle c) => PrivateRuntime.instance.lanesService.serverChoiceLostToNewKey(c.id);
  Future<List<DiagCheck>> Function() diagnosticsLoader =
      () async => evaluateDiagnostics(await DiagnosticsProbe.collect(light: true));

  List<AttentionItem> _items = const <AttentionItem>[];
  List<AutoNotice> _autoNotices = const <AutoNotice>[];
  ServerJoinInfo _join = ServerJoinInfo.none;
  bool _joinDismissed = false;
  final Map<String, ServerChoiceLost> _choiceLost = <String, ServerChoiceLost>{};
  List<DiagCheck> _diag = const <DiagCheck>[];
  final Set<String> _snoozed = <String>{};
  bool _started = false;
  AppLifecycleListener? _life;
  Timer? _debounce;
  DateTime? _diagAt;

  @override
  List<AttentionItem> get value => _items;

  int get count => _items.length;

  /// Null when nothing needs attention (the icon is hidden then).
  AttentionSeverity? get worst => _items.isEmpty
      ? null
      : _items.map((AttentionItem i) => i.severity).reduce((AttentionSeverity a, AttentionSeverity b) => a.index >= b.index ? a : b);

  /// Wires the asynchronous sources (server join, key reset, auto-apply notice,
  /// diagnostics) and refreshes them on resume and when the server is back.
  /// Called once by the signed-in shell.
  void start() {
    if (_started) return;
    _started = true;
    PrivateRuntime.autoApplied.addListener(_scheduleAsync);
    reachability.onRecovered.add(_onRecovered);
    _life = AppLifecycleListener(onResume: () => unawaited(refresh(diagnostics: true)));
    unawaited(refresh(diagnostics: true));
  }

  Future<void> _onRecovered() => refresh();

  /// Reloads the asynchronous sources. [diagnostics] also re-runs the light
  /// diagnostics probe (at most once a minute).
  Future<void> refresh({bool diagnostics = false}) async {
    try {
      _autoNotices = await autoNoticeLoader();
    } catch (_) {}
    try {
      _join = await serverJoinLoader();
    } catch (_) {}
    await _refreshChoiceLost();
    if (diagnostics && (_diagAt == null || DateTime.now().difference(_diagAt!) > const Duration(minutes: 1))) {
      _diagAt = DateTime.now();
      try {
        _diag = await diagnosticsLoader();
      } catch (_) {}
    }
    _rebuild();
  }

  Future<void> _refreshChoiceLost() async {
    for (final Circle c in DeliveryHints.circleById.values.toList()) {
      if (!(c.isPrivate && c.serverAssist && !c.myLaneServer)) {
        _choiceLost.remove(c.id);
        continue;
      }
      try {
        final ServerChoiceLost? lost = await choiceLostLoader(c);
        if (lost == null) {
          _choiceLost.remove(c.id);
        } else {
          await ServerChoiceStore.loadReoffer(c.id, lost.oldDeviceId);
          _choiceLost[c.id] = lost;
        }
      } catch (_) {
        // offline: keep what we knew
      }
    }
  }

  void _onSource() {
    if (DeliveryHints.circleById.isNotEmpty) unawaited(ServerChoiceStore.load(DeliveryHints.circleById.keys));
    _rebuild();
    _scheduleAsync();
  }

  void _scheduleAsync() {
    if (!_started) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => unawaited(refresh()));
  }

  // ------------------------------------------------------------- session dismissals

  /// "Not now" on an item that has no remembered dismissal of its own.
  void snooze(AttentionItem item) {
    if (item.kind == AttentionKind.serverJoin) {
      _joinDismissed = true;
    } else {
      _snoozed.add(item.id);
    }
    _rebuild();
  }

  /// The server join was approved: drop the item at once.
  void serverJoinDone() {
    _join = ServerJoinInfo.none;
    _rebuild();
  }

  /// An auto-apply notice was answered: drop it at once (the next refresh confirms).
  void autoNoticeDone(String circleId) {
    _autoNotices = _autoNotices.where((AutoNotice n) => n.circleId != circleId).toList();
    _rebuild();
  }

  // ------------------------------------------------------------- test hooks

  @visibleForTesting
  void debugSet({List<AutoNotice>? autoNotices, ServerJoinInfo? join, Map<String, ServerChoiceLost>? choiceLost, List<DiagCheck>? diagnostics}) {
    if (autoNotices != null) _autoNotices = autoNotices;
    if (join != null) _join = join;
    if (choiceLost != null) {
      _choiceLost
        ..clear()
        ..addAll(choiceLost);
    }
    if (diagnostics != null) _diag = diagnostics;
    _rebuild();
  }

  @visibleForTesting
  void debugReset() {
    _autoNotices = const <AutoNotice>[];
    _join = ServerJoinInfo.none;
    _joinDismissed = false;
    _choiceLost.clear();
    _diag = const <DiagCheck>[];
    _snoozed.clear();
    _diagAt = null;
    _rebuild();
  }

  @override
  void dispose() {
    for (final Listenable l in _sources) {
      l.removeListener(_onSource);
    }
    if (_started) {
      PrivateRuntime.autoApplied.removeListener(_scheduleAsync);
      reachability.onRecovered.remove(_onRecovered);
      _life?.dispose();
    }
    _debounce?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- aggregation

  void _rebuild() {
    final List<AttentionItem> next = compute();
    if (listEquals(next.map((AttentionItem i) => i._sig).toList(), _items.map((AttentionItem i) => i._sig).toList())) {
      _items = next; // same cards; keep fresh data without a rebuild
      return;
    }
    _items = next;
    notifyListeners();
  }

  /// The current items, worst first. Pure apart from reading the sources.
  @visibleForTesting
  List<AttentionItem> compute() {
    final List<AttentionItem> out = <AttentionItem>[];
    _compat(out);
    _connection(out);
    _diagnostics(out);
    final Set<String> waitingKey = _delivery(out);
    _server(out, waitingKey);
    // Stable sort: severity first, then the order above.
    final List<MapEntry<int, AttentionItem>> idx = out.asMap().entries.toList()
      ..sort((MapEntry<int, AttentionItem> a, MapEntry<int, AttentionItem> b) {
        final int s = b.value.severity.index - a.value.severity.index;
        return s != 0 ? s : a.key - b.key;
      });
    return List<AttentionItem>.unmodifiable(idx.map((MapEntry<int, AttentionItem> e) => e.value));
  }

  void _compat(List<AttentionItem> out) {
    final CompatState st = AppCompat.state.value;
    final int n = AppCompat.circlesNeedingUpdate.value;
    if (st.status == CompatStatus.required) {
      out.add(const AttentionItem(
        id: 'update-required',
        kind: AttentionKind.updateRequired,
        severity: AttentionSeverity.critical,
        title: 'Please update Orbitly.',
        why: 'Your server no longer supports this version, so locations may be missing or out of date.',
        action: 'How to update',
      ));
    } else if (n > 0) {
      final List<String> names = AppCompat.circleNamesNeedingUpdate.value;
      final String which = names.isEmpty ? '' : ': ${names.join(', ')}';
      out.add(AttentionItem(
        id: 'update-circles',
        kind: AttentionKind.circleUpdate,
        severity: AttentionSeverity.warning,
        title: n == 1 ? 'A circle needs a newer Orbitly$which.' : '$n circles need a newer Orbitly$which.',
        why: 'This version cannot open ${n == 1 ? 'it' : 'them'}. Update the app to see ${n == 1 ? 'it' : 'them'} again.',
        action: 'How to update',
      ));
    } else if (st.status == CompatStatus.recommended && !AppCompat.dismissed.value) {
      out.add(AttentionItem(
        id: 'update-available',
        kind: AttentionKind.updateAvailable,
        severity: AttentionSeverity.warning,
        title: 'A newer Orbitly is available${st.latest.isEmpty ? '' : ' (${st.latest})'}.',
        why: 'Your version keeps working; the update brings fixes.',
        action: 'How to update',
        secondary: 'Not now',
      ));
    }
  }

  void _connection(List<AttentionItem> out) {
    final DateTime? last = reachability.lastOkAt;
    switch (reachability.state.value) {
      case SyncState.unreachable:
        final int n = reachability.pending.value;
        out.add(AttentionItem(
          id: 'offline',
          kind: AttentionKind.offline,
          severity: AttentionSeverity.critical,
          title: "Can't reach your server.",
          why: 'You see what this phone last knew${last == null ? '' : ' (last synced ${formatClock(last.toLocal())})'}. '
              '${n > 0 ? '$n update${n == 1 ? '' : 's'} will be sent' : 'Everything syncs'} when it is back.',
          action: 'Try again',
        ));
      case SyncState.signedOut:
        out.add(const AttentionItem(
          id: 'signed-out',
          kind: AttentionKind.signedOut,
          severity: AttentionSeverity.critical,
          title: 'Please sign in again.',
          why: "This phone's login ran out. The server is fine and nothing on the phone is lost.",
          action: 'Sign in',
        ));
      case SyncState.syncing:
      case SyncState.upToDate:
        break;
    }
  }

  void _diagnostics(List<AttentionItem> out) {
    for (final DiagCheck c in _diag) {
      if (c.status != DiagStatus.fail || !kAttentionDiagChecks.contains(c.id)) continue;
      if (c.id == 'vault') {
        out.add(AttentionItem(
          id: 'diag:vault',
          kind: AttentionKind.keyUnreadable,
          severity: AttentionSeverity.critical,
          title: "This phone's encryption key can't be read.",
          why: 'Private circles cannot send or show locations until it is repaired.',
          info: c.detail,
          action: 'Open Encryption keys',
          data: c,
        ));
      } else {
        out.add(AttentionItem(
          id: 'diag:${c.id}',
          kind: AttentionKind.phoneProblem,
          severity: AttentionSeverity.critical,
          title: '${_phoneProblemTitle(c)}.',
          why: 'Your circle stops seeing where you are until this is fixed.',
          info: c.detail,
          action: 'Fix it',
          data: c,
        ));
      }
    }
  }

  /// Adds delivery items; returns the circles where this phone's key is not usable yet.
  Set<String> _delivery(List<AttentionItem> out) {
    final Set<String> waiting = <String>{};
    for (final MapEntry<String, CircleDelivery> e in DeliveryHints.reports.value.entries) {
      final Circle? c = DeliveryHints.circleById[e.key];
      if (c == null || !c.isPrivate) continue;
      MemberDelivery? me;
      for (final MemberDelivery m in e.value.members) {
        if (m.you) me = m;
      }
      if (me != null && (me.reason == DeliveryReason.notApproved || me.reason == DeliveryReason.noKeyWrap)) {
        waiting.add(c.id);
        out.add(AttentionItem(
          id: 'key-waiting:${c.id}',
          kind: AttentionKind.keyWaiting,
          severity: AttentionSeverity.warning,
          title: me.reason == DeliveryReason.notApproved
              ? 'This phone is waiting for approval in ${c.name}.'
              : "This phone hasn't received the key for ${c.name} yet.",
          why: me.reason == DeliveryReason.notApproved
              ? 'An admin has to approve its new key before it can send or see locations there.'
              : 'An admin\'s phone sends it the next time it opens Orbitly.',
          action: 'Open Encryption keys',
          circle: c,
        ));
      }
      if (e.value.nobodySending && !_snoozed.contains('nobody:${c.id}')) {
        String? reason;
        for (final MemberDelivery m in e.value.members) {
          reason ??= describeMemberDelivery(m);
        }
        out.add(AttentionItem(
          id: 'nobody:${c.id}',
          kind: AttentionKind.nobodySending,
          severity: AttentionSeverity.warning,
          title: 'Nobody has sent an update in ${c.name}.',
          why: reason == null ? 'It is a private circle; the Delivery page shows what is known.' : '$reason.',
          action: 'Fix it',
          secondary: 'Not now',
          circle: c,
        ));
      }
    }
    return waiting;
  }

  void _server(List<AttentionItem> out, Set<String> waitingKey) {
    if (_join.waiting && _join.canApprove && !_joinDismissed) {
      out.add(AttentionItem(
        id: 'server-join',
        kind: AttentionKind.serverJoin,
        severity: AttentionSeverity.warning,
        title: 'Your server wants to join.',
        why: 'Approve only if the admin page of your server shows this code: ${_join.short}',
        info: 'You find the code on the admin page of your server under Settings > Server setup.',
        action: 'It matches, approve',
        secondary: 'Not now',
        data: _join.short,
      ));
    }
    for (final Circle c in DeliveryHints.circleById.values) {
      if (waitingKey.contains(c.id)) continue; // approve the key first; the server choice needs it
      final ServerChoiceLost? lost = _choiceLost[c.id];
      if (c.isPrivate && c.serverAssist && !c.myLaneServer && lost != null) {
        if (ServerChoiceStore.reofferAnswered(c.id, lost.oldDeviceId)) continue;
        out.add(AttentionItem(
          id: 'server-again:${c.id}',
          kind: AttentionKind.serverChoiceAgain,
          severity: AttentionSeverity.warning,
          title: 'Use the server again for ${c.name}?',
          why: 'This phone got a new key, so your earlier choice needs one more tap.',
          info: 'You had chosen to let your server process your locations. That choice was signed by the key this '
              'phone had before it was set up again, so it no longer counts and the server stopped reading your '
              'locations.${lost.recommended ? ' Your circle admin recommends the server for everyone.' : ''} '
              '"Keep on my phone" keeps your locations end-to-end encrypted instead.',
          action: 'Use the server again',
          secondary: 'Keep on my phone',
          circle: c,
          data: lost.oldDeviceId,
        ));
        continue;
      }
      switch (serverPromptFor(c)) {
        case ServerPromptKind.memberChoice:
          out.add(AttentionItem(
            id: 'server-choice:${c.id}',
            kind: AttentionKind.serverChoice,
            severity: AttentionSeverity.warning,
            title: 'Use the server for ${c.name}?',
            why: 'Your server then keeps your locations, so maps, history and driving reports just work.',
            info: 'Or keep your location on your phone: it is shared privately, encrypted from phone to phone, with no '
                'reports unless you turn on phone reports. You can change this later in the circle settings.',
            action: 'Use the server',
            secondary: 'Keep on my phone',
            circle: c,
          ));
        case ServerPromptKind.adminSetup:
          out.add(AttentionItem(
            id: 'server-setup:${c.id}',
            kind: AttentionKind.serverAdminSetup,
            severity: AttentionSeverity.info,
            title: 'Let the server help in ${c.name}?',
            why: 'It is private, so the server cannot show maps, history or driving reports yet.',
            info: 'One tap lets your server join. Each other member then opens the app and taps "Use the server"; '
                'nobody is switched on for them.',
            action: 'Let the server do it',
            secondary: 'Not now',
            circle: c,
            data: serverSetupStalled(c),
          ));
        case ServerPromptKind.none:
          break;
      }
    }
    for (final AutoNotice n in _autoNotices) {
      out.add(AttentionItem(
        id: 'auto:${n.circleId}',
        kind: AttentionKind.serverAutoApplied,
        severity: AttentionSeverity.info,
        title: '${n.circleName} uses the server.',
        why: 'Your circle set this up so maps, history and driving reports work.',
        info: autoApplyNoticeText,
        action: 'OK',
        secondary: 'Keep on my phone',
        circle: DeliveryHints.circleById[n.circleId],
        data: n.circleId,
      ));
    }
  }
}
