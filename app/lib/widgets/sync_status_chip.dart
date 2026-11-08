import 'dart:async';

import 'package:flutter/material.dart';

import '../services/offline/offline_sync.dart';
import '../services/offline/server_reachability.dart';

/// The small, unobtrusive "is the server there" chip.
///
/// - Server unreachable: "Server unreachable. Showing last known. Will sync when
///   it is back." with a "Try again" button (and how many updates wait).
/// - Updates being sent: "Syncing…".
/// - Back and everything sent: "Up to date" for a few seconds, then it hides.
/// - Normal operation: nothing at all.
class SyncStatusChip extends StatefulWidget {
  const SyncStatusChip({
    super.key,
    this.reachability,
    this.upToDateFor = const Duration(seconds: 3),
    this.alwaysShow = false,
    this.flush,
  });

  /// Defaults to [ServerReachability.instance].
  final ServerReachability? reachability;

  /// How long "Up to date" stays after a recovery.
  final Duration upToDateFor;

  /// Diagnostics shows the state permanently.
  final bool alwaysShow;

  /// What "Try again" sends besides the probe. Defaults to [OfflineSync.flushAll].
  final Future<void> Function()? flush;

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
        final String waiting = n > 0 ? ' $n update${n == 1 ? '' : 's'} waiting.' : '';
        final String text = switch (s) {
          SyncState.unreachable => 'Server unreachable. Showing last known. Will sync when it is back.$waiting',
          SyncState.signedOut => 'Please sign in again. The server is fine; this phone\'s login ran out.${n > 0 ? ' $n update${n == 1 ? '' : 's'} will be sent after you sign in.' : ''}',
          SyncState.syncing => 'Syncing…${n > 0 ? ' $n update${n == 1 ? '' : 's'}' : ''}',
          SyncState.upToDate => 'Up to date',
        };
        return Align(
          alignment: Alignment.topCenter,
          child: Semantics(
            liveRegion: true,
            child: Container(
              key: const Key('sync-status-chip'),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: down ? cs.errorContainer : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    signedOut ? Icons.lock_outline : down ? Icons.cloud_off : (s == SyncState.syncing ? Icons.sync : Icons.cloud_done_outlined),
                    size: 16,
                    color: down ? cs.onErrorContainer : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 12, color: down ? cs.onErrorContainer : cs.onSurfaceVariant),
                    ),
                  ),
                  if (s == SyncState.unreachable) ...<Widget>[
                    const SizedBox(width: 8),
                    InkWell(
                      key: const Key('sync-try-again'),
                      onTap: () {
                        unawaited(_r.probeNow());
                        unawaited((widget.flush ?? OfflineSync.flushAll)());
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                        child: Text(
                          'Try again',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onErrorContainer),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
