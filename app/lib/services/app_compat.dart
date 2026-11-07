// App/server compatibility (docs: docs/api-compat.md).
//
// The app announces its version with every request (X-App-Version); the server
// answers with X-OpenFamily-Compat: ok | recommended | required. This file
// holds the version helpers and the observable state the update banner shows,
// so an app that fell behind the server says so instead of silently showing
// "No location yet" or "Offline".

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// How the server classified this app.
enum CompatStatus { unknown, ok, recommended, required }

/// Parses "0.20.1", "v0.20.1", "0.20.1+45" or "0.21.0-rc1" into [major, minor,
/// patch]; null when it is not at least "major.minor".
List<int>? parseVersion(String? raw) {
  if (raw == null) return null;
  String s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final int cut = s.indexOf(RegExp(r'[+-]'));
  if (cut >= 0) s = s.substring(0, cut);
  final List<String> parts = s.split('.');
  if (parts.length < 2 || parts.length > 3) return null;
  final List<int> out = <int>[0, 0, 0];
  for (int i = 0; i < parts.length; i++) {
    final int? n = int.tryParse(parts[i]);
    if (n == null || n < 0) return null;
    out[i] = n;
  }
  return out;
}

/// -1, 0 or 1; null when either side does not parse.
int? compareVersions(String? a, String? b) {
  final List<int>? x = parseVersion(a);
  final List<int>? y = parseVersion(b);
  if (x == null || y == null) return null;
  for (int i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}

/// What the banner renders.
@immutable
class CompatState {
  const CompatState({
    this.status = CompatStatus.unknown,
    this.minSupported = '',
    this.latest = '',
    this.message = '',
  });

  final CompatStatus status;
  final String minSupported;
  final String latest;

  /// Server-provided text (only on a 426 body); the banner has its own wording.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is CompatState &&
      other.status == status &&
      other.minSupported == minSupported &&
      other.latest == latest &&
      other.message == message;

  @override
  int get hashCode => Object.hash(status, minSupported, latest, message);
}

class AppCompat {
  AppCompat._();

  /// Build-time override: `--dart-define=OPENFAMILY_APP_VERSION=0.21.0`.
  static const String _defined = String.fromEnvironment('OPENFAMILY_APP_VERSION');

  static String _version = _defined;

  /// The running app's version ("" until [init] ran and no dart-define is set;
  /// the header is then simply not sent).
  static String get version => _version;

  /// Sets the version directly (tests).
  @visibleForTesting
  static void debugSetVersion(String v) => _version = v;

  /// Reads the real version from the installed package. Best effort.
  static Future<void> init() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (parseVersion(info.version) != null) _version = info.version;
    } catch (_) {
      // Keep whatever the dart-define gave us.
    }
  }

  /// The server's verdict on this app; updated from response headers.
  static final ValueNotifier<CompatState> state =
      ValueNotifier<CompatState>(const CompatState());

  /// True once the user dismissed the "recommended" banner this session.
  static final ValueNotifier<bool> dismissed = ValueNotifier<bool>(false);

  /// Circles the server says this app cannot open (see [noteCircles]).
  static final ValueNotifier<int> circlesNeedingUpdate = ValueNotifier<int>(0);

  /// Reads the compat headers of any API response (lower-cased names).
  static void observeHeaders(Map<String, String> headers) {
    final String? raw = headers['x-openfamily-compat'];
    if (raw == null) return;
    final CompatStatus st = switch (raw) {
      'ok' => CompatStatus.ok,
      'recommended' => CompatStatus.recommended,
      'required' => CompatStatus.required,
      _ => CompatStatus.unknown,
    };
    _set(CompatState(
      status: st,
      minSupported: headers['x-openfamily-min-app-version'] ?? '',
      latest: headers['x-openfamily-latest-app-version'] ?? '',
    ));
  }

  /// A 426 answer means the server refuses this app version outright.
  static void observeUpgradeRequired([String message = '']) {
    _set(CompatState(
      status: CompatStatus.required,
      minSupported: state.value.minSupported,
      latest: state.value.latest,
      message: message,
    ));
  }

  /// True when [minAppVersion] (a circle's `min_app_version`) is newer than
  /// this app. Unknown or unparsable values are treated as compatible.
  static bool requiresNewer(String? minAppVersion) =>
      compareVersions(_version, minAppVersion) == -1;

  /// Records how many of the user's circles need a newer app.
  static void noteCircles(Iterable<bool> needsNewer) {
    final int n = needsNewer.where((bool b) => b).length;
    if (circlesNeedingUpdate.value != n) circlesNeedingUpdate.value = n;
  }

  static void _set(CompatState next) {
    if (state.value != next) state.value = next;
  }

  @visibleForTesting
  static void debugReset() {
    _version = _defined;
    state.value = const CompatState();
    dismissed.value = false;
    circlesNeedingUpdate.value = 0;
  }
}
