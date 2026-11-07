import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/circle.dart';
import '../services/app_compat.dart';
import '../services/delivery_status.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_models.dart' show ServerJoinInfo;
import 'add_server_sheet.dart';

// Server by default (docs/design/PRIVACY_PROCESSING.md section 22). Three small cards:
//   * member: "Use the server (recommended)" / "Keep on my phone" on first open of a circle
//     whose admin turned the server on. Nothing is signed until the person taps through the
//     add-server sheet; "Keep on my phone" signs nothing and the server never reads them.
//   * admin: "Let the server do the processing (recommended)" for a private circle that has no
//     server yet, plus the one-tap "switch this circle to normal mode".
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
  }
}

/// What card to show for [circles], most important first. Pure, for tests.
enum ServerPromptKind { none, memberChoice, adminSetup }

({ServerPromptKind kind, Circle? circle}) pickServerPrompt(Iterable<Circle> circles, {bool Function(String id)? answered, bool Function(String id)? snoozed}) {
  final bool Function(String) isAnswered = answered ?? ServerChoiceStore.answered;
  final bool Function(String) isSnoozed = snoozed ?? ServerChoiceStore.snoozed;
  for (final Circle c in circles) {
    if (c.isPrivate && c.serverAssist && !c.myLaneServer && !isAnswered(c.id)) return (kind: ServerPromptKind.memberChoice, circle: c);
  }
  for (final Circle c in circles) {
    if (c.isPrivate && c.isAdmin && !c.serverAssist && !isSnoozed(c.id)) return (kind: ServerPromptKind.adminSetup, circle: c);
  }
  return (kind: ServerPromptKind.none, circle: null);
}

/// The copy-paste message for members whose app is too old to choose.
String updateMessageText(String serverHost) =>
    'Please update the OpenFamily app so you show up on our family map again. '
    'Open the Play Store and update OpenFamily, or, if you installed it from the website, download the new version at '
    '${serverHost.isEmpty ? 'our server' : serverHost}/app.apk and install it.';

class ServerPrompts extends StatelessWidget {
  const ServerPrompts({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: const <Widget>[ServerJoinCard(), _CirclePrompts()]);
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

class _CirclePrompts extends StatelessWidget {
  const _CirclePrompts();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[DeliveryHints.reports, ServerChoiceStore.changed]),
      builder: (BuildContext context, _) {
        final Iterable<Circle> circles = DeliveryHints.circleById.values;
        ServerChoiceStore.load(circles.map((Circle c) => c.id));
        final ({ServerPromptKind kind, Circle? circle}) pick = pickServerPrompt(circles);
        if (pick.kind == ServerPromptKind.none) return const SizedBox.shrink();
        final Circle c = pick.circle!;
        final ColorScheme cs = Theme.of(context).colorScheme;
        final bool member = pick.kind == ServerPromptKind.memberChoice;
        final bool stalled = !member && (DeliveryHints.reports.value[c.id]?.members.any((MemberDelivery m) => m.reason == DeliveryReason.updateNeeded) ?? false);
        return Material(
          color: cs.primaryContainer,
          child: Padding(
            key: Key(member ? 'server-choice-card' : 'server-admin-card'),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(
                member ? 'Use the server for ${c.name}? (recommended)' : 'Let the server do the processing (recommended)',
                style: TextStyle(fontWeight: FontWeight.w700, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 4),
              Text(
                member
                    ? 'Your server keeps your locations so maps, history and driving reports just work. Or keep your location on your phone: it is shared privately, encrypted from phone to phone, with no reports unless you turn on phone reports.'
                    : '${c.name} is private, so the server cannot show maps, history or driving reports yet. One tap lets your server join. Each other member then opens the app and taps "Use the server"; nobody is switched on for them.',
                style: TextStyle(color: cs.onPrimaryContainer),
              ),
              Wrap(spacing: 8, children: <Widget>[
                FilledButton(
                  key: const Key('server-prompt-use'),
                  onPressed: () async {
                    final bool? ok = await showAddServerSheet(context, circle: c);
                    if (ok == true) await ServerChoiceStore.markAnswered(c.id);
                  },
                  child: Text(member ? 'Use the server (recommended)' : 'Let the server do it'),
                ),
                if (member)
                  TextButton(
                    key: const Key('server-prompt-phone'),
                    onPressed: () => ServerChoiceStore.markAnswered(c.id),
                    child: const Text('Keep on my phone'),
                  )
                else
                  TextButton(key: const Key('server-prompt-later'), onPressed: () => ServerChoiceStore.snooze(c.id), child: const Text('Not now')),
                if (stalled)
                  TextButton(
                    key: const Key('server-prompt-normal'),
                    onPressed: () => confirmSwitchToNormal(context, c),
                    child: const Text('Switch this circle to normal mode so everyone shows up again'),
                  ),
              ]),
            ]),
          ),
        );
      },
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
              'Update available${st.latest.isEmpty ? '' : ' (${st.latest})'}. Update OpenFamily in the Play Store, or, if you installed it from your server, download it again at ${serverHost.isEmpty ? 'your server' : serverHost}/app.apk. Your current version keeps working.',
              style: TextStyle(color: cs.onSecondaryContainer),
            ),
          ),
        );
      },
    );
  }
}
