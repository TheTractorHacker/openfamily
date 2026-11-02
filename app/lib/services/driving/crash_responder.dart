import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../background_credential_store.dart';
import 'crash_detector.dart';
import 'crash_pending.dart';

/// Sends the crash alert; returns the server's crash id, or null on failure.
abstract class CrashAlertSender {
  Future<String?> send(CrashPending crash);
}

/// What the person sees while the countdown runs (a loud, full-screen
/// notification that opens the app on the "Are you OK?" screen).
abstract class CrashNotifier {
  Future<void> showCountdown();
  Future<void> showSent();
  Future<void> dismiss();
}

/// Background-isolate sender: device ingest key only, like the other
/// background posts (no account tokens).
class IngestKeyCrashSender implements CrashAlertSender {
  const IngestKeyCrashSender();

  @override
  Future<String?> send(CrashPending crash) async {
    final String? base = await BackgroundCredentialStore.readApiBaseUrl();
    final String? device = await BackgroundCredentialStore.readDeviceId();
    final String? key = await BackgroundCredentialStore.readIngestKey();
    if (base == null || base.isEmpty || device == null || key == null) {
      return null;
    }
    final http.Client c = http.Client();
    try {
      final http.Response r = await c
          .post(
            Uri.parse('$base/crash-alerts'),
            headers: <String, String>{
              'X-Device-Key': '$device.$key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(crash.toRequestBody()),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode < 200 || r.statusCode >= 300) return null;
      final Object? j = jsonDecode(r.body);
      return j is Map && j['id'] is String ? j['id'] as String : null;
    } catch (_) {
      return null;
    } finally {
      c.close();
    }
  }
}

/// Local-notification implementation of [CrashNotifier]. Works from the
/// background isolate (initialises its own plugin instance).
///
/// Needs `USE_FULL_SCREEN_INTENT` (declared in the manifest) to pop over the
/// lock screen; without it (Android 14+ lets users revoke it) the same
/// notification still appears as a loud heads-up.
class LocalCrashNotifier implements CrashNotifier {
  LocalCrashNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const int notificationId = 7101;
  static const String payload = 'crash_countdown';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_notification'),
      ),
    );
    _ready = true;
  }

  Future<void> _show(String title, String body, {required bool urgent}) async {
    await _init();
    await _plugin.show(
      id: notificationId,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'crash',
          'Crash detection',
          channelDescription: 'Are you OK? prompt after a probable crash',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: urgent,
          ongoing: urgent,
          autoCancel: !urgent,
          playSound: urgent,
          enableVibration: urgent,
          visibility: NotificationVisibility.public,
        ),
      ),
    );
  }

  @override
  Future<void> showCountdown() => _show(
        'Are you OK?',
        'A possible crash was detected. Your circle is alerted in 30 seconds '
            'unless you open the app and tap "I\'m OK".',
        urgent: true,
      );

  @override
  Future<void> showSent() => _show(
        'Crash alert sent',
        'Your circle was told about a possible crash. Open the app if it was '
            'a false alarm.',
        urgent: false,
      );

  @override
  Future<void> dismiss() async {
    await _init();
    await _plugin.cancel(id: notificationId);
  }
}

/// Runs the countdown and sends the alert (background isolate). Everything
/// is injectable so the flow is unit-testable with a fake clock.
class CrashResponder {
  CrashResponder({
    required this.sender,
    required this.notifier,
    int Function()? clock,
    this.pollEvery = const Duration(seconds: 1),
    this.retryEvery = const Duration(seconds: 10),
    this.maxAttempts = 30,
    this.countdown = CrashPending.countdown,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CrashAlertSender sender;
  final CrashNotifier notifier;
  final int Function() _clock;
  final Duration pollEvery;
  final Duration retryEvery;
  final int maxAttempts;
  final Duration countdown;

  Timer? _timer;
  bool _sending = false;
  int _attempts = 0;
  int _lastAttempt = 0;

  bool get isRunning => _timer != null;

  /// Starts the countdown for [signal]. Ignored while one is already live.
  Future<void> handle(CrashSignal signal) async {
    final int now = _clock();
    final CrashPending? existing = await CrashPendingStore.load();
    if (existing != null && existing.isLive(now)) return;
    final CrashPending pending = CrashPending.start(
      occurredAtMs: now,
      nowMs: now,
      peakG: signal.peakG,
      speedBeforeMps: signal.speedBeforeMps,
      speedAfterMps: signal.speedAfterMps,
      lat: signal.lat,
      lon: signal.lon,
      countdown: countdown,
    );
    await CrashPendingStore.save(pending);
    _attempts = 0;
    _lastAttempt = 0;
    try {
      await notifier.showCountdown();
    } catch (_) {}
    _timer?.cancel();
    _timer = Timer.periodic(pollEvery, (_) => unawaited(poll()));
  }

  /// One step of the countdown; public for tests.
  Future<void> poll() async {
    if (_sending) return;
    final int now = _clock();
    final CrashPending? c = await CrashPendingStore.load();
    if (c == null || c.cancelled) {
      _stop();
      try {
        await notifier.dismiss();
      } catch (_) {}
      return;
    }
    if (c.sentId != null) {
      _stop();
      return;
    }
    if (c.phase(now) != CrashPhase.sending) return;
    if (_attempts >= maxAttempts) {
      _stop();
      return;
    }
    if (_lastAttempt != 0 && now - _lastAttempt < retryEvery.inMilliseconds) {
      return;
    }
    _sending = true;
    _attempts++;
    _lastAttempt = now;
    try {
      final String? id = await sender.send(c);
      if (id != null) {
        await CrashPendingStore.markSent(id);
        _stop();
        try {
          await notifier.showSent();
        } catch (_) {}
      }
    } catch (_) {
      // Retried at the next poll.
    } finally {
      _sending = false;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async => _stop();
}
