import 'dart:async';

import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../screens/delivery_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/encryption_keys_screen.dart';
import '../services/api_client.dart';
import '../services/app_compat.dart';
import '../services/attention_service.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/private_runtime.dart' show PrivateRuntime;
import '../services/offline/offline_sync.dart';
import '../services/offline/server_reachability.dart';
import '../services/server_config.dart';
import '../theme/app_theme.dart';
import 'add_server_sheet.dart';
import 'ds/map_round_button.dart';
import 'ds/sheet_scaffold.dart';
import 'server_prompts.dart';

/// Icon colour per severity; both pass 3:1 on the light sheet and on white.
Color attentionColor(BuildContext context, AttentionSeverity s) => switch (s) {
      AttentionSeverity.critical => const Color(0xFFC62828),
      AttentionSeverity.warning => const Color(0xFFB45309),
      AttentionSeverity.info => BrandTheme.of(context).accentInk,
    };

IconData attentionIcon(AttentionSeverity s) => switch (s) {
      AttentionSeverity.critical => Icons.error_outline,
      AttentionSeverity.warning => Icons.warning_amber_rounded,
      AttentionSeverity.info => Icons.info_outline,
    };

String attentionLabel(int n) => n == 1 ? '1 thing needs your attention' : '$n things need your attention';

/// The small status control of the top bar: a warning icon with a count, coloured
/// by the worst item, hidden when nothing needs attention. Tapping it opens the
/// "Needs your attention" sheet. [onMap] draws it as one of the round map buttons.
class AttentionButton extends StatelessWidget {
  const AttentionButton({super.key, this.onMap = false, this.service, this.actions});

  final bool onMap;

  /// Defaults to [AttentionService.instance].
  final AttentionService? service;
  final AttentionActions? actions;

  @override
  Widget build(BuildContext context) {
    final AttentionService svc = service ?? AttentionService.instance;
    return ValueListenableBuilder<List<AttentionItem>>(
      valueListenable: svc,
      builder: (BuildContext context, List<AttentionItem> items, _) {
        final AttentionSeverity? worst = svc.worst;
        if (items.isEmpty || worst == null) return const SizedBox.shrink();
        final Color color = attentionColor(context, worst);
        final String label = attentionLabel(items.length);
        void open() => showAttentionSheet(context, service: svc, actions: actions ?? const AttentionActions());
        final Widget count = Text(items.length > 9 ? '9+' : '${items.length}');
        if (onMap) {
          return Padding(
            padding: const EdgeInsets.only(right: AppSpace.sm),
            child: Badge(
              key: const Key('attention-button'),
              label: count,
              backgroundColor: color,
              offset: const Offset(-2, 2),
              child: DsMapButton(icon: attentionIcon(worst), tooltip: label, iconColor: color, onPressed: open),
            ),
          );
        }
        return Semantics(
          button: true,
          label: label,
          onTap: open,
          excludeSemantics: true,
          child: IconButton(
            key: const Key('attention-button'),
            tooltip: label,
            onPressed: open,
            icon: Badge(label: count, backgroundColor: color, child: Icon(attentionIcon(worst), color: color)),
          ),
        );
      },
    );
  }
}

/// Opens the "Needs your attention" sheet.
Future<void> showAttentionSheet(BuildContext context, {AttentionService? service, AttentionActions actions = const AttentionActions()}) {
  final AttentionService svc = service ?? AttentionService.instance;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheet) => AttentionSheet(service: svc, actions: actions, host: context),
  );
}

/// The sheet: one card per item, worst first.
class AttentionSheet extends StatelessWidget {
  const AttentionSheet({super.key, required this.service, required this.actions, required this.host});
  final AttentionService service;
  final AttentionActions actions;

  /// The context that opened the sheet (screens are pushed from there after the sheet closes).
  final BuildContext host;

  @override
  Widget build(BuildContext context) {
    return DsSheetScaffold(
      title: 'Needs your attention',
      child: ValueListenableBuilder<List<AttentionItem>>(
        valueListenable: service,
        builder: (BuildContext context, List<AttentionItem> items, _) {
          if (items.isEmpty) {
            return const Padding(
              key: Key('attention-empty'),
              padding: EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.xxl),
              child: Text('All good. Nothing needs your attention right now.', style: AppType.body),
            );
          }
          return ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.xl + MediaQuery.paddingOf(context).bottom),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpace.sm),
            itemBuilder: (BuildContext context, int i) =>
                AttentionCard(key: ValueKey<String>('attention-${items[i].id}'), item: items[i], service: service, actions: actions, host: host),
          );
        },
      ),
    );
  }
}

class AttentionCard extends StatefulWidget {
  const AttentionCard({super.key, required this.item, required this.service, required this.actions, required this.host});
  final AttentionItem item;
  final AttentionService service;
  final AttentionActions actions;
  final BuildContext host;

  @override
  State<AttentionCard> createState() => _AttentionCardState();
}

class _AttentionCardState extends State<AttentionCard> {
  bool _busy = false;
  bool _info = false;
  String? _error;

  Future<void> _run(Future<void> Function(AttentionContext) f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f(AttentionContext(sheet: context, host: widget.host, service: widget.service));
    } on AttentionFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'That did not work. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AttentionItem it = widget.item;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color color = attentionColor(context, it.severity);
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.sm, AppSpace.sm),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(attentionIcon(it.severity), color: color, semanticLabel: it.severity == AttentionSeverity.critical ? 'Problem' : 'Attention'),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(it.title, style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
              ),
            ),
            if (it.info != null)
              IconButton(
                key: Key('attention-info-${it.id}'),
                tooltip: _info ? 'Hide details' : 'More about this',
                icon: Icon(_info ? Icons.expand_less : Icons.info_outline),
                onPressed: () => setState(() => _info = !_info),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: AppSpace.xs, right: AppSpace.sm),
            child: Text(it.why, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
          ),
          if (_info && it.info != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: AppSpace.sm, right: AppSpace.sm),
              child: Text(it.info!, key: Key('attention-info-text-${it.id}'), style: AppType.secondary),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: AppSpace.sm),
              child: Text(_error!, style: AppType.secondary.copyWith(color: cs.error)),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: AppSpace.sm),
            child: Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.xs, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
              FilledButton(
                key: Key('attention-primary-${it.id}'),
                onPressed: _busy ? null : () => _run((AttentionContext c) => widget.actions.primary(c, it)),
                child: Text(it.action),
              ),
              if (it.secondary != null)
                TextButton(
                  key: Key('attention-secondary-${it.id}'),
                  onPressed: _busy ? null : () => _run((AttentionContext c) => widget.actions.secondary(c, it)),
                  child: Text(it.secondary!),
                ),
              if (it.kind == AttentionKind.serverAdminSetup && it.data == true && it.circle != null)
                TextButton(
                  key: Key('attention-normal-${it.id}'),
                  onPressed: _busy ? null : () => _run((AttentionContext c) => widget.actions.switchToNormal(c, it.circle!)),
                  child: const Text('Switch to normal mode'),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Where an action runs: the open sheet, and the screen that opened it.
class AttentionContext {
  const AttentionContext({required this.sheet, required this.host, required this.service});
  final BuildContext sheet;
  final BuildContext host;
  final AttentionService service;

  /// Closes the sheet and pushes [page] from the screen underneath.
  Future<void> open(Widget page) async {
    final NavigatorState nav = Navigator.of(host);
    if (sheet.mounted) Navigator.of(sheet).pop();
    await nav.push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

/// A failure the card shows in plain words.
class AttentionFailure implements Exception {
  const AttentionFailure(this.message);
  final String message;
}

/// What the buttons do. [primary] / [secondary] are the dispatch (tested as is);
/// the effectful steps below are separate methods so tests can replace them.
class AttentionActions {
  const AttentionActions();

  Future<void> primary(AttentionContext c, AttentionItem it) async {
    switch (it.kind) {
      case AttentionKind.updateRequired:
      case AttentionKind.circleUpdate:
      case AttentionKind.updateAvailable:
        await showUpdateHelp(c);
      case AttentionKind.offline:
        await tryAgain();
      case AttentionKind.signedOut:
        if (c.sheet.mounted) Navigator.of(c.sheet).pop();
        signIn();
      case AttentionKind.keyUnreadable:
      case AttentionKind.keyWaiting:
        await openEncryptionKeys(c);
      case AttentionKind.phoneProblem:
        await openDiagnostics(c);
      case AttentionKind.nobodySending:
        await openDelivery(c, it.circle!);
      case AttentionKind.serverChoice:
        if (await useServer(c, it.circle!)) await ServerChoiceStore.markAnswered(it.circle!.id);
      case AttentionKind.serverChoiceAgain:
        if (await useServer(c, it.circle!)) {
          await ServerChoiceStore.markAnswered(it.circle!.id);
          await ServerChoiceStore.markReofferAnswered(it.circle!.id, it.data! as String);
        }
      case AttentionKind.serverAdminSetup:
        if (await useServer(c, it.circle!)) await ServerChoiceStore.markAnswered(it.circle!.id);
      case AttentionKind.serverAutoApplied:
        await dismissAutoNotice(it.data! as String);
        c.service.autoNoticeDone(it.data! as String);
      case AttentionKind.serverJoin:
        try {
          await approveServerJoin();
        } catch (_) {
          throw const AttentionFailure('Could not approve the server. Check the connection and try again.');
        }
        c.service.serverJoinDone();
    }
  }

  Future<void> secondary(AttentionContext c, AttentionItem it) async {
    switch (it.kind) {
      case AttentionKind.updateAvailable:
        AppCompat.dismissed.value = true;
      case AttentionKind.serverChoice:
        await ServerChoiceStore.markAnswered(it.circle!.id);
      case AttentionKind.serverChoiceAgain:
        await ServerChoiceStore.markAnswered(it.circle!.id);
        await ServerChoiceStore.markReofferAnswered(it.circle!.id, it.data! as String);
      case AttentionKind.serverAdminSetup:
        ServerChoiceStore.snooze(it.circle!.id);
      case AttentionKind.serverAutoApplied:
        try {
          await keepOnPhone(it.data! as String);
        } catch (_) {
          throw const AttentionFailure('Could not switch to your phone. Check the connection and try again.');
        }
        c.service.autoNoticeDone(it.data! as String);
      case AttentionKind.nobodySending:
      case AttentionKind.serverJoin:
        c.service.snooze(it);
      default:
        break;
    }
  }

  // ---- effectful steps (tests override these) ----

  Future<void> showUpdateHelp(AttentionContext c) {
    final String host = ServerConfig.instance.apiBaseUrl;
    return showDialog<void>(
      context: c.sheet,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Update Orbitly'),
        content: Text(
          'Open the Play Store and update Orbitly. If you installed it from your server, download it again at '
          '${host.isEmpty ? 'your server' : host}/app.apk and install it. Your places, circles and keys stay.',
        ),
        actions: <Widget>[TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
      ),
    );
  }

  Future<void> tryAgain() async {
    await ServerReachability.instance.probeNow();
    unawaited(OfflineSync.flushAll());
  }

  void signIn() => ApiClient.onSessionExpired?.call();

  Future<void> openEncryptionKeys(AttentionContext c) => c.open(const EncryptionKeysScreen());

  Future<void> openDiagnostics(AttentionContext c) => c.open(const DiagnosticsScreen());

  Future<void> openDelivery(AttentionContext c, Circle circle) => c.open(DeliveryScreen(circle: circle));

  /// The existing add-server sheet (checks the server key, signs with this phone's key). True when done.
  Future<bool> useServer(AttentionContext c, Circle circle) async => await showAddServerSheet(c.sheet, circle: circle) == true;

  Future<void> switchToNormal(AttentionContext c, Circle circle) => confirmSwitchToNormal(c.sheet, circle);

  Future<void> dismissAutoNotice(String circleId) => PrivateRuntime.instance.lanesService.store.dismissAutoNotice(circleId);

  Future<void> keepOnPhone(String circleId) => keepAutoAppliedOnPhone(circleId);

  Future<void> approveServerJoin() => E2eeApp.service.approveServerJoin();
}
