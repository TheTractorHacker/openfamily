import 'dart:async';
import 'dart:io';

/// A cross-isolate mutex for `/auth/refresh`.
///
/// A refresh token is single-use and the server treats presenting a spent one as theft. The UI isolate and
/// the background/push isolates each have their own memory, so an in-memory single-flight cannot stop both
/// from presenting the same token. The lease is a file created with `exclusive: true`, which is atomic
/// across isolates AND processes (unlike fcntl locks, which are per process). A lease older than [staleAfter]
/// is considered abandoned (a crashed isolate) and is taken over.
class RefreshLease {
  RefreshLease._(this._file);

  final File? _file;

  /// Where the lease file lives. Defaults to the app's temp/cache dir, which every isolate shares.
  static Directory Function() directory = () => Directory.systemTemp;
  static const String fileName = 'orbitly_refresh.lease';
  static Duration staleAfter = const Duration(seconds: 20);
  static Duration maxWait = const Duration(seconds: 8);
  static Duration poll = const Duration(milliseconds: 60);

  /// Waits for the lease. After [maxWait] it proceeds without one (a stuck holder must never block sign-in
  /// forever); the caller then still re-reads the token store before presenting anything.
  static Future<RefreshLease> acquire() async {
    File f;
    try {
      f = File('${directory().path}${Platform.pathSeparator}$fileName');
    } catch (_) {
      return RefreshLease._(null);
    }
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      try {
        await f.create(exclusive: true);
        await f.writeAsString('${DateTime.now().millisecondsSinceEpoch}');
        return RefreshLease._(f);
      } on FileSystemException {
        // held by someone else
      } catch (_) {
        return RefreshLease._(null);
      }
      try {
        final DateTime m = await f.lastModified();
        if (DateTime.now().difference(m) > staleAfter) {
          await f.delete();
          continue;
        }
      } catch (_) {
        continue; // vanished between the checks: try again at once
      }
      if (sw.elapsed >= maxWait) return RefreshLease._(null);
      await Future<void>.delayed(poll);
    }
  }

  Future<void> release() async {
    try {
      await _file?.delete();
    } catch (_) {}
  }
}
