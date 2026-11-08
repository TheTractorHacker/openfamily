import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backoff.dart';

/// What the small status chip shows.
enum SyncState {
  /// Everything this phone has to say reached the server, and it answers.
  upToDate,

  /// The server answers and queued updates are being sent (or a refresh runs).
  syncing,

  /// The server cannot be reached: the app shows what it last knew.
  unreachable,

  /// The server answers, but this phone's login is no longer accepted: the person has to sign in again.
  /// Queued SOS, check-ins and chat stay on the phone until then.
  signedOut,
}

/// One place that knows whether the server is reachable, probes it politely
/// and tells the rest of the app when it came back.
///
/// Rules (docs/design/OFFLINE_RESILIENCE.md):
/// - Every HTTP exchange reports in ([noteResponse], [noteFailure]); no extra
///   traffic while things work.
/// - A failure never flips the chip by itself: it schedules a confirming probe
///   (`GET /healthz`, short timeout, no auth). Only a failed probe says
///   "unreachable". One slow request does not.
/// - While unreachable, probes follow exponential backoff with jitter (3 s up
///   to 5 min). No tight loops, nothing runs while the server is fine.
/// - Connectivity events (Wi-Fi/cellular back) and the manual "Try again" probe
///   at once.
/// - When a probe succeeds, [onRecovered] callbacks run (flush queues, refresh).
class ServerReachability {
  ServerReachability({
    required this.probe,
    Backoff? backoff,
    this.confirmDelay = const Duration(seconds: 2),
    this.connectivityDebounce = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  })  : _backoff = backoff ?? Backoff(),
        _clock = clock ?? DateTime.now;

  /// Asks the server whether it is alive. Must return true only for a 2xx
  /// answer, and must not throw (a throw counts as a failed probe).
  Future<bool> Function() probe;
  final Duration confirmDelay;
  final Duration connectivityDebounce;
  final Backoff _backoff;
  final DateTime Function() _clock;

  /// The process-wide instance. The app wires [probe] at start-up (see
  /// `OfflineSync.start`); until then it never finds a problem.
  static final ServerReachability instance = ServerReachability(probe: () async => true);

  final ValueNotifier<SyncState> state = ValueNotifier<SyncState>(SyncState.upToDate);

  /// Updates waiting on this phone (positions, messages, check-ins ...).
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  /// When the server last answered (any answer under 500).
  DateTime? lastOkAt;

  /// Callbacks that run when the server is back after having been unreachable.
  final List<Future<void> Function()> onRecovered = <Future<void> Function()>[];

  Timer? _timer;
  Timer? _debounce;
  bool _probing = false;
  bool _disposed = false;
  int _probes = 0;

  /// How many probes ran (tests and diagnostics).
  int get probeCount => _probes;
  bool get unreachable => state.value == SyncState.unreachable;

  /// A response arrived. 502/503/504 come from a proxy in front of a dead
  /// server and count as a failure; every other status proves the server is
  /// there (a 4xx is an answer).
  /// The login is gone or refused. The server is reachable, so this must never read as "unreachable".
  void signedOut() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    state.value = SyncState.signedOut;
  }

  /// A fresh sign-in (or any accepted answer) ends the signed-out state.
  void signedIn() {
    if (state.value == SyncState.signedOut) state.value = pending.value > 0 ? SyncState.syncing : SyncState.upToDate;
  }

  void noteResponse(int status) {
    if (status < 400 && state.value == SyncState.signedOut) signedIn();
    if (status == 502 || status == 503 || status == 504) {
      noteFailure();
      return;
    }
    if (_probing) return;
    lastOkAt = _clock();
    _timer?.cancel();
    _timer = null;
    if (unreachable) {
      _backoff.reset();
      _recovered();
    }
  }

  /// A request failed at the transport level (timeout, refused, DNS, TLS).
  void noteFailure() {
    if (_disposed || _probing || _timer != null) return;
    // Confirm before telling the user anything.
    _schedule(unreachable ? _backoff.next() : confirmDelay);
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, () {
      _timer = null;
      unawaited(probeNow());
    });
  }

  /// Probes right now (manual "Try again", connectivity events, timers).
  /// Single flight.
  Future<bool> probeNow() async {
    if (_disposed || _probing) return !unreachable;
    _probing = true;
    _timer?.cancel();
    _timer = null;
    _probes++;
    bool ok;
    try {
      ok = await probe();
    } catch (_) {
      ok = false;
    }
    _probing = false;
    if (_disposed) return ok;
    if (ok) {
      lastOkAt = _clock();
      final bool wasDown = unreachable;
      _backoff.reset();
      if (wasDown) _recovered();
    } else {
      state.value = SyncState.unreachable;
      _schedule(_backoff.next());
    }
    return ok;
  }

  void _recovered() {
    state.value = pending.value > 0 ? SyncState.syncing : SyncState.upToDate;
    for (final Future<void> Function() f in List<Future<void> Function()>.of(onRecovered)) {
      unawaited(f().catchError((Object _) {}));
    }
  }

  /// The OS says the network changed. When it came back and the server was
  /// unreachable, probe soon (debounced against Wi-Fi/cellular flapping).
  void connectivityChanged({required bool connected}) {
    if (_disposed || !connected || !unreachable) return;
    _debounce?.cancel();
    _debounce = Timer(connectivityDebounce, () {
      _debounce = null;
      unawaited(probeNow());
    });
  }

  /// Sets the number of waiting updates and moves between syncing and up to date.
  void setPending(int n) {
    pending.value = n < 0 ? 0 : n;
    if (unreachable) return;
    state.value = pending.value > 0 ? SyncState.syncing : SyncState.upToDate;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _debounce?.cancel();
  }
}
