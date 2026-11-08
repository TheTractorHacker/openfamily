import 'dart:async';

import 'package:flutter/material.dart';

import '../services/offline/server_reachability.dart';
import '../utils/member_status.dart' show formatClock;

/// The small, unobtrusive "is the server there" pill on the map.
///
/// - Server unreachable: "Offline · last synced 9:02". The same state is an item
///   of the attention center, with the full sentence and "Try again".
/// - Login ran out: "Signed out" (the attention center offers "Sign in").
/// - Updates being sent: "Syncing…".
/// - Back and everything sent: "Up to date" for a few seconds, then it hides.
/// - Normal operation: nothing at all.
class SyncStatusChip extends StatefulWidget {
  const SyncStatusChip({
    super.key,
    this.reachability,
    this.upToDateFor = const Duration(seconds: 3),
    this.alwaysShow = false,
  });

  /// Defaults to [ServerReachability.instance].
  final ServerReachability? reachability;

  /// How long "Up to date" stays after a recovery.
  final Duration upToDateFor;

  /// Diagnostics shows the state permanently.
  final bool alwaysShow;

  @override
  State<SyncStatusChip> createState() => _SyncStatusChipState();
}

class _SyncStatusChipState extends State<SyncStatusChip> {
  late ServerReachability _r = widget.reachability ?? ServerReachability.instance;
  SyncState _last = SyncState.upToDate;
  bool _showUpToDate = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _last = _r.state.value;
    _r.state.addListener(_onState);
  }

  void _onState() {
    final SyncState now = _r.state.value;
    if (now == SyncState.upToDate && _last != SyncState.upToDate) {
      _showUpToDate = true;
      _hide?.cancel();
      _hide = Timer(widget.upToDateFor, () {
        if (mounted) setState(() => _showUpToDate = false);
      });
    } else if (now != SyncState.upToDate) {
      _showUpToDate = false;
      _hide?.cancel();
    }
    _last = now;
  }

  @override
  void dispose() {
    _r.state.removeListener(_onState);
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_r.state, _r.pending]),
      builder: (BuildContext context, Widget? _) {
        final SyncState s = _r.state.value;
        final int n = _r.pending.value;
        if (s == SyncState.upToDate && !_showUpToDate && !widget.alwaysShow) {
          return const SizedBox.shrink();
        }
        final ColorScheme cs = Theme.of(context).colorScheme;
        final bool signedOut = s == SyncState.signedOut;
        final bool down = s == SyncState.unreachable || signedOut;
        final DateTime? last = _r.lastOkAt;
        final String synced = last == null ? '' : 'last synced ${formatClock(last.toLocal())}';
        // Short on the map; the attention icon holds the full sentence and the "Try again" button.
        final String text = switch (s) {
          SyncState.unreachable => synced.isEmpty ? 'Offline' : 'Offline · $synced',
          SyncState.signedOut => 'Signed out',
          SyncState.syncing => 'Syncing…${n > 0 ? ' $n' : ''}',
          SyncState.upToDate => 'Up to date',
        };
        final String spoken = switch (s) {
          SyncState.unreachable => "Offline: can't reach your server. Showing what this phone last knew${synced.isEmpty ? '' : ', $synced'}."
              '${n > 0 ? ' $n update${n == 1 ? '' : 's'} waiting.' : ''} Details are behind the attention icon.',
          SyncState.signedOut => 'Signed out. Please sign in again. Details are behind the attention icon.',
          SyncState.syncing => 'Syncing${n > 0 ? ' $n update${n == 1 ? '' : 's'}' : ''}',
          SyncState.upToDate => 'Up to date',
        };
        // Information only: map gestures pass through it.
        return IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: Semantics(
              liveRegion: true,
              label: spoken,
              excludeSemantics: true,
              child: Container(
                key: const Key('sync-status-chip'),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: down ? cs.errorContainer : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      signedOut ? Icons.lock_outline : down ? Icons.cloud_off : (s == SyncState.syncing ? Icons.sync : Icons.cloud_done_outlined),
                      size: 14,
                      color: down ? cs.onErrorContainer : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: down ? cs.onErrorContainer : cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
