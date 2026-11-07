import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'private_channel.dart';

// Where the sensitive stores of the private-circle engine live on iOS: location
// trails and buffers, the sealed upload queue, lane facts (including pref
// history), shared results, sequence numbers, cursors, places. On iOS they are
// FILES in one dedicated directory (Application Support/openfamily-private) that
// Swift creates on every engine start and excludes from backups as a DIRECTORY
// (a flag on a single SharedPreferences plist does not survive the atomic
// rewrites NSUserDefaults does, and was only set at launch). The flag is read
// back and the answer is shown in Diagnostics; if it cannot be confirmed the
// store still works and Diagnostics says "backup exclusion NOT confirmed".
//
// Android keeps SharedPreferences (the app disables backup there).

/// What the app knows about the private store of this isolate.
class PrivateStoreStatus {
  const PrivateStoreStatus({required this.filesInUse, required this.backupExcluded, this.error = ''});

  /// Not on iOS (or no channel): the SharedPreferences store is used.
  static const PrivateStoreStatus prefs = PrivateStoreStatus(filesInUse: false, backupExcluded: null);

  final bool filesInUse;

  /// True: confirmed by reading the directory flag back. False: NOT confirmed. Null: not applicable (not iOS).
  final bool? backupExcluded;
  final String error;
}

/// File-backed [ChannelKv]: one file per key inside [dir]. Writes go to a temp file in the SAME directory and are
/// renamed over the target, so a reader (the other isolate) sees the old or the new content, never half of it.
class FileKv implements ChannelKv, LockableKv {
  FileKv(this.dir);
  final Directory dir;
  static final Random _rng = Random.secure();

  /// File name of a key: base64url of its UTF-8 bytes (keys contain '/').
  static String nameOf(String key) => '${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.kv';
  static String? keyOf(String fileName) {
    if (!fileName.endsWith('.kv')) return null;
    try {
      final String b = fileName.substring(0, fileName.length - 3);
      return utf8.decode(base64Url.decode(base64Url.normalize(b)));
    } catch (_) {
      return null;
    }
  }

  File _file(String key) => File('${dir.path}${Platform.pathSeparator}${nameOf(key)}');

  @override
  Future<String?> get(String key) async {
    try {
      final File f = _file(key);
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getFresh(String key) => get(key);

  @override
  Future<void> set(String key, String value) async {
    final File target = _file(key);
    final File tmp = File('${dir.path}${Platform.pathSeparator}.${nameOf(key)}.${_rng.nextInt(1 << 30)}.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<void> remove(String key) async {
    try {
      final File f = _file(key);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// A cross-isolate lock: a lock file created with O_EXCL (atomic), removed afterwards. A lock older than [staleAfter]
  /// (a crashed or killed writer) is broken. Waiting is bounded; if the lock cannot be taken in time the body runs
  /// anyway, because the versioned queue record still catches most races (no data is lost to a blocked app).
  @override
  Future<T> withLock<T>(String name, Future<T> Function() body, {Duration staleAfter = const Duration(seconds: 10), Duration wait = const Duration(seconds: 5)}) async {
    final File lock = File('${dir.path}${Platform.pathSeparator}.$name.lock');
    final Stopwatch sw = Stopwatch()..start();
    bool held = false;
    while (sw.elapsed < wait) {
      try {
        await lock.create(exclusive: true);
        held = true;
        break;
      } on FileSystemException {
        try {
          if (DateTime.now().difference(lock.lastModifiedSync()) > staleAfter) lock.deleteSync();
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 5 + _rng.nextInt(15)));
      }
    }
    try {
      return await body();
    } finally {
      if (held) {
        try {
          await lock.delete();
        } catch (_) {}
      }
    }
  }

  /// Every key in the store (for tests and the migration check).
  Future<List<String>> keys() async => <String>[
        for (final FileSystemEntity e in dir.listSync())
          if (e is File)
            if (keyOf(e.uri.pathSegments.last) case final String k) k
      ];
}

/// Copies the old SharedPreferences keys (prefix `e2ee_chan_`) into [files], verifies each copy, then deletes the old
/// key. A key already present in [files] is NOT overwritten: another isolate may have migrated and written newer data
/// while this one still sees an old preferences snapshot. Returns how many keys were moved.
Future<int> migratePrefsToFiles(SharedPreferences prefs, FileKv files, {String prefix = 'e2ee_chan_'}) async {
  await prefs.reload();
  int moved = 0;
  for (final String full in prefs.getKeys().where((String k) => k.startsWith(prefix)).toList()) {
    final String key = full.substring(prefix.length);
    final String? value = prefs.getString(full);
    if (value == null) continue;
    if (await files.get(key) == null) await files.set(key, value);
    final String? back = await files.get(key);
    if (back == null) continue; // not stored: keep the old key
    await prefs.remove(full);
    moved++;
  }
  return moved;
}

/// Opens the store of this isolate once: asks Swift for the directory (which also creates it and applies the exclusion
/// on every engine start, including the headless background one), migrates, and remembers the status.
class PrivateStore {
  PrivateStore._();
  static MethodChannel channel = const MethodChannel('app.openfamily/store');
  static Future<FileKv?>? _open;
  static PrivateStoreStatus status = PrivateStoreStatus.prefs;

  /// Test hook: forget what was opened.
  @visibleForTesting
  static void reset() {
    _open = null;
    status = PrivateStoreStatus.prefs;
  }

  /// The file store, or null when this platform keeps using SharedPreferences.
  static Future<FileKv?> files() => _open ??= _openOnce();

  static Future<FileKv?> _openOnce() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final Map<Object?, Object?>? r = await channel.invokeMapMethod<Object?, Object?>('prepare');
      final String path = (r?['path'] as String?) ?? '';
      final bool excluded = r?['excluded'] == true;
      final String err = (r?['error'] as String?) ?? '';
      if (path.isEmpty) {
        status = PrivateStoreStatus(filesInUse: false, backupExcluded: false, error: err.isEmpty ? 'no store directory' : err);
        return null;
      }
      final FileKv kv = FileKv(Directory(path));
      status = PrivateStoreStatus(filesInUse: true, backupExcluded: excluded, error: err);
      try {
        await migratePrefsToFiles(await SharedPreferences.getInstance(), kv);
      } catch (e) {
        status = PrivateStoreStatus(filesInUse: true, backupExcluded: excluded, error: 'migration incomplete');
      }
      return kv;
    } catch (e) {
      status = const PrivateStoreStatus(filesInUse: false, backupExcluded: false, error: 'store channel unavailable');
      return null;
    }
  }
}
