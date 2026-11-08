import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/circle.dart';
import '../services/app_compat.dart';
import '../services/delivery_status.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart' show ServerJoinInfo;
import '../services/e2ee/lanes_store.dart' show AutoApplyRecord;
import '../services/e2ee/private_runtime.dart' show PrivateRuntime;

// Server by default (docs/design/PRIVACY_PROCESSING.md section 22). The questions themselves are
// items of the attention center (services/attention_service.dart); this file keeps their rules and
// what they remember:
//   * member: "Use the server" / "Keep on my phone" on first open of a circle whose admin turned
//     the server on. Nothing is signed until the person taps through the add-server sheet; "Keep on
//     my phone" signs nothing and the server never reads them.
//   * member after "Set this phone up again": the earlier server choice was signed by the old key,
//     so it no longer counts; one tap re-offers it ([ServerChoiceStore.reofferAnswered]).
//   * admin: "Let the server do the processing" for a private circle that has no server yet, plus
//     the one-tap "switch this circle to normal mode".
//   * update: a soft "Update available" card with the Play/APK hint.

/// Remembers, per circle on this phone, that the person already answered the first-open question.
class ServerChoiceStore {
  ServerChoiceStore._();
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);
  static final Set<String> _answered = <String>{};
  static final Set<String> _snoozed = <String>{};

  static String _key(String circleId) => 'server_choice_answered_$circleId';

  static Future<void> load(Iterable<String> circleIds) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    bool any = false;
    for (final String id in circleIds) {
      if (p.getBool(_key(id)) == true && _answered.add(id)) any = true;
    }
    if (any) changed.value++;
  }

  static bool answered(String circleId) => _answered.contains(circleId);
  static bool snoozed(String circleId) => _snoozed.contains(circleId);

  static String _reofferKey(String circleId, String oldDeviceId) => 'server_choice_reoffer_${circleId}_$oldDeviceId';
  static final Set<String> _reoffered = <String>{};

  /// Reads whether the re-offer after the reset that revoked [oldDeviceId] was already answered.
  static Future<void> loadReoffer(String circleId, String oldDeviceId) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (p.getBool(_reofferKey(circleId, oldDeviceId)) == true && _reoffered.add(_reofferKey(circleId, oldDeviceId))) changed.value++;
  }

  static bool reofferAnswered(String circleId, String oldDeviceId) => _reoffered.contains(_reofferKey(circleId, oldDeviceId));

  /// "Keep on my phone" (or a finished "Use the server again") after a key reset. A later reset asks again.
  static Future<void> markReofferAnswered(String circleId, String oldDeviceId) async {
    _reoffered.add(_reofferKey(circleId, oldDeviceId));
    changed.value++;
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_reofferKey(circleId, oldDeviceId), true);
  }

  static Future<void> markAnswered(String circleId) async {
    _answered.add(circleId);
    changed.value++;
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_key(circleId), true);
  }

  static void snooze(String circleId) {
    _snoozed.add(circleId);
    changed.value++;
  }

  static void debugReset() {
    _answered.clear();
    _snoozed.clear();
    _reoffered.clear();
  }
}

/// What card to show for [circles], most important first. Pure, for tests.
enum ServerPromptKind { none, memberChoice, adminSetup }

({ServerPromptKind kind, Circle? circle}) pickServerPrompt(Iterable<Circle> circles, {bool Function(String id)? answered, bool Function(String id)? snoozed}) {
  for (final ServerPromptKind want in <ServerPromptKind>[ServerPromptKind.memberChoice, ServerPromptKind.adminSetup]) {
    for (final Circle c in circles) {
      if (serverPromptFor(c, answered: answered, snoozed: snoozed) == want) return (kind: want, circle: c);
    }
  }
  return (kind: ServerPromptKind.none, circle: null);
}

/// The question (if any) for one circle; the attention center asks it per circle.
ServerPromptKind serverPromptFor(Circle c, {bool Function(String id)? answered, bool Function(String id)? snoozed}) {
  final bool Function(String) isAnswered = answered ?? ServerChoiceStore.answered;
  final bool Function(String) isSnoozed = snoozed ?? ServerChoiceStore.snoozed;
  if (c.isPrivate && c.serverAssist && !c.myLaneServer && !isAnswered(c.id)) return ServerPromptKind.memberChoice;
  if (c.isPrivate && c.isAdmin && !c.serverAssist && !isSnoozed(c.id)) return ServerPromptKind.adminSetup;
  return ServerPromptKind.none;
}

/// The admin's circle is stuck because some members' app is too old for Private mode.
bool serverSetupStalled(Circle c) =>
    DeliveryHints.reports.value[c.id]?.members.any((MemberDelivery m) => m.reason == DeliveryReason.updateNeeded) ?? false;

/// The copy-paste message for members whose app is too old to choose.
String updateMessageText(String serverHost) =>
    'Please update the Orbitly app so you show up on our family map again. '
    'Open the Play Store and update Orbitly, or, if you installed it from the website, download the new version at '
    '${serverHost.isEmpty ? 'our server' : serverHost}/app.apk and install it.';

/// The copy-paste reminder for members who are not on the server yet (same words as the admin API's `remind_text`).
const String remindMessageText = 'Please open the Orbitly app once. Your circle uses the family server so maps, history and driving reports work. '
    'You will see a short notice and can tap "Keep on my phone" if you prefer that. If the app is old, update it first.';

/// A circle where this phone signed the server lane on its own (admin setting "members are on the server by default").
class AutoNotice {
  const AutoNotice(this.circleId, this.circleName);
  final String circleId;
  final String circleName;
}

/// The circles where this phone signed the server lane on its own and the person has not answered the notice yet.
Future<List<AutoNotice>> loadAutoNotices() async {
  final PrivateRuntime rt = PrivateRuntime.instance;
  final List<AutoNotice> out = <AutoNotice>[];
  for (final Circle c in DeliveryHints.circleById.values) {
    if (!c.isPrivate) continue;
    final AutoApplyRecord? r = await rt.lanesService.store.autoRecord(c.id);
    if (r != null && r.applied && !r.dismissed && c.myLaneServer) out.add(AutoNotice(c.id, c.name));
  }
  return out;
}

/// "Keep on my phone" on the auto-apply notice: signs the phone lane, asks the server to delete the copies, remembers it.
Future<void> keepAutoAppliedOnPhone(String circleId) async {
  await PrivateRuntime.instance.lanesService.keepOnPhone(circleId);
  await ServerChoiceStore.markAnswered(circleId);
}

/// The words of the notice. One place so tests and docs quote the same text.
const String autoApplyNoticeText = 'Your circle uses the server so maps, history and driving reports work. Tap to keep your data on your phone.';

/// First-time, non-blocking notice after the member's own phone turned on server processing by the admin's default.
/// "Keep on my phone" signs the phone lane at once and asks the server to delete the copies. It stays until dismissed.
class AutoApplyNotice extends StatefulWidget {
  const AutoApplyNotice({super.key, this.loader, this.keep, this.dismiss});

  /// Test hooks (the real app reads the phone's own records).
  final Future<List<AutoNotice>> Function()? loader;
  final Future<void> Function(String circleId)? keep;
  final Future<void> Function(String circleId)? dismiss;

  @override
  State<AutoApplyNotice> createState() => _AutoApplyNoticeState();
}

class _AutoApplyNoticeState extends State<AutoApplyNotice> {
  List<AutoNotice> _items = const <AutoNotice>[];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    PrivateRuntime.autoApplied.addListener(_load);
    ServerChoiceStore.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    PrivateRuntime.autoApplied.removeListener(_load);
    ServerChoiceStore.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final List<AutoNotice> l = await (widget.loader ?? loadAutoNotices)();
      if (mounted) setState(() => _items = l);
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() f, String failure) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (_) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final AutoNotice n = _items.first;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.secondaryContainer,
      child: Padding(
        key: const Key('auto-apply-notice'),
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(_items.length > 1 ? '${n.circleName} (and ${_items.length - 1} more) use the server' : '${n.circleName} uses the server',
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSecondaryContainer)),
          const SizedBox(height: 4),
          Text(autoApplyNoticeText, style: TextStyle(color: cs.onSecondaryContainer)),
          if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
          Wrap(spacing: 8, children: <Widget>[
            FilledButton(
              key: const Key('auto-apply-keep'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await (widget.keep ?? keepAutoAppliedOnPhone)(n.circleId);
                      }, 'Could not switch to your phone. Check the connection and try again.'),
              child: const Text('Keep on my phone'),
            ),
            TextButton(
              key: const Key('auto-apply-ok'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await (widget.dismiss ?? (String id) => PrivateRuntime.instance.lanesService.store.dismissAutoNotice(id))(n.circleId);
                      }, 'Could not save that.'),
              child: const Text('OK'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// "Your server wants to join - does the code match?" for a server administrator. Needs no circle:
/// the built-in server device asks to be approved once, by one tap on an admin phone.
class ServerJoinCard extends StatefulWidget {
  const ServerJoinCard({super.key, this.loader, this.approver});

  /// Test hooks (the real app talks to the server).
  final Future<ServerJoinInfo> Function()? loader;
  final Future<void> Function()? approver;

  @override
  State<ServerJoinCard> createState() => _ServerJoinCardState();
}

class _ServerJoinCardState extends State<ServerJoinCard> {
  ServerJoinInfo _join = ServerJoinInfo.none;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ServerJoinInfo j = await (widget.loader ?? () => E2eeApp.service.api.serverJoin())();
      if (mounted) setState(() => _join = j);
    } catch (_) {}
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.approver ?? () => E2eeApp.service.approveServerJoin())();
      if (mounted) setState(() => _join = ServerJoinInfo.none);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not approve the server. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_join.waiting || !_join.canApprove) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      child: Padding(
        key: const Key('server-join-card'),
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Your server wants to join', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onTertiaryContainer)),
          const SizedBox(height: 4),
          Text('Does this code match the one on the admin page of your server (Settings > Server setup)?', style: TextStyle(color: cs.onTertiaryContainer)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_join.short, key: const Key('server-join-code'), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: cs.onTertiaryContainer)),
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
          Wrap(spacing: 8, children: <Widget>[
            FilledButton(key: const Key('server-join-approve'), onPressed: _busy ? null : _approve, child: const Text('Yes, it matches - approve')),
            TextButton(key: const Key('server-join-later'), onPressed: () => setState(() => _join = ServerJoinInfo.none), child: const Text('Not now')),
          ]),
        ]),
      ),
    );
  }
}

/// Circle admin: one confirmation, then the circle leaves Private mode.
Future<bool> confirmSwitchToNormal(BuildContext context, Circle c) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('Switch to normal mode?'),
      content: Text(
          'From now on the server keeps the locations of everyone in ${c.name} (readable), so maps, history and driving reports just work and everyone shows up again, even people on an old app.\n\n'
          'The encrypted copies and key copies the server holds for this circle are deleted. Places and history that exist only on phones stay on those phones. Everyone in the circle is told. You can make the circle private again later.'),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(key: const Key('switch-normal-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Switch to normal mode')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await E2eeApp.service.disableCircle(c.id);
    DeliveryHints.circleById.remove(c.id);
    ServerChoiceStore.changed.value++;
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not switch to normal mode. Check the connection and try again.')));
    }
    return false;
  }
}

/// Soft "Update available" card (Settings): non-blocking, with the Play / APK hint.
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, this.serverHost = ''});
  final String serverHost;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CompatState>(
      valueListenable: AppCompat.state,
      builder: (BuildContext context, CompatState st, _) {
        if (st.status != CompatStatus.recommended) return const SizedBox.shrink();
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Card(
          key: const Key('update-card'),
          color: cs.secondaryContainer,
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Update available${st.latest.isEmpty ? '' : ' (${st.latest})'}. Update Orbitly in the Play Store, or, if you installed it from your server, download it again at ${serverHost.isEmpty ? 'your server' : serverHost}/app.apk. Your current version keeps working.',
              style: TextStyle(color: cs.onSecondaryContainer),
            ),
          ),
        );
      },
    );
  }
}
