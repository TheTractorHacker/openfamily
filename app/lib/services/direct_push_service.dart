import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'alert_router.dart';
import 'background_credential_store.dart';
import 'live_boost.dart';
import 'location_refresh_service.dart';

// OpenFamily "direct" push: the app keeps ONE authenticated Server-Sent Events
// connection to its own server open and turns what arrives into local
// notifications. No ntfy app, no Google services. See docs/push.md for the
// battery trade-off and what happens when Android kills the process.

/// One parsed SSE frame.
class SseFrame {
  const SseFrame({required this.event, required this.data, this.id});

  final String event;
  final String data;
  final String? id;
}

/// Incremental SSE parser. Feed it decoded text chunks of any size; it returns
/// the frames completed by each chunk. Comment lines (": hb") are ignored but
/// still count as activity for the caller.
class SseParser {
  String _buffer = '';
  String _event = 'message';
  String? _id;
  final List<String> _data = <String>[];

  List<SseFrame> add(String chunk) {
    _buffer += chunk;
    final List<SseFrame> out = <SseFrame>[];
    while (true) {
      final int nl = _buffer.indexOf('\n');
      if (nl < 0) break;
      String line = _buffer.substring(0, nl);
      _buffer = _buffer.substring(nl + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) {
        if (_data.isNotEmpty) {
          out.add(SseFrame(event: _event, data: _data.join('\n'), id: _id));
        }
        _event = 'message';
        _id = null;
        _data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final int colon = line.indexOf(':');
      final String field = colon < 0 ? line : line.substring(0, colon);
      String value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          _event = value;
        case 'data':
          _data.add(value);
        case 'id':
          _id = value;
      }
    }
    return out;
  }
}

enum DirectPushKind { alert, notice, command }

/// A server event: what the user sees (title/body) or a machine command.
class DirectPushEvent {
  const DirectPushEvent({
    required this.id,
    required this.kind,
    this.title = '',
    this.body = '',
    this.alertId = '',
    this.command = '',
  });

  /// Deduplication id; also what is acknowledged to the server.
  final String id;
  final DirectPushKind kind;
  final String title;
  final String body;
  final String alertId;

  /// Raw command JSON for [DirectPushKind.command].
  final String command;

  /// Parses a `push` frame's data; null when it is malformed or unusable.
  static DirectPushEvent? tryParse(String data) {
    try {
      final dynamic j = jsonDecode(data);
      if (j is! Map<String, dynamic>) return null;
      final Object? id = j['id'];
      if (id is! String || id.isEmpty || id.length > 100) return null;
      final DirectPushKind? kind = switch (j['kind']) {
        'alert' => DirectPushKind.alert,
        'notice' => DirectPushKind.notice,
        'command' => DirectPushKind.command,
        _ => null,
      };
      if (kind == null) return null;
      String command = '';
      if (kind == DirectPushKind.command) {
        final Object? c = j['command'];
        command = c is String ? c : jsonEncode(c);
        if (c == null) return null;
      }
      return DirectPushEvent(
        id: id,
        kind: kind,
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        alertId: (j['alert_id'] as String?) ?? '',
        command: command,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Exponential reconnect delay with jitter: 2s, 4s, 8s ... capped. [reset] is
/// called once a connection proved healthy.
class ReconnectBackoff {
  ReconnectBackoff({
    this.base = const Duration(seconds: 2),
    this.max = const Duration(minutes: 5),
    math.Random? random,
  }) : _random = random ?? math.Random();

  final Duration base;
  final Duration max;
  final math.Random _random;
  int _attempt = 0;

  int get attempt => _attempt;

  Duration next() {
    final int shift = math.min(_attempt, 20);
    _attempt++;
    final int ms = math.min(max.inMilliseconds, base.inMilliseconds * (1 << shift));
    // +-20% jitter so a server restart does not make every phone reconnect in
    // the same second.
    final double jitter = 0.8 + _random.nextDouble() * 0.4;
    return Duration(milliseconds: math.min(max.inMilliseconds, (ms * jitter).round()));
  }

  void reset() => _attempt = 0;
}

class DirectPushCredentials {
  const DirectPushCredentials({
    required this.baseUrl,
    required this.deviceId,
    required this.ingestKey,
  });

  final String baseUrl;
  final String deviceId;
  final String ingestKey;

  String get header => '$deviceId.$ingestKey';
}

/// An open stream: HTTP status plus the decoded body.
class DirectPushConnection {
  const DirectPushConnection(this.status, this.body);

  final int status;
  final Stream<String> body;
}

/// Network seam so the service is testable with a fake.
abstract class DirectPushTransport {
  Future<DirectPushConnection> open(DirectPushCredentials creds);
  Future<bool> ack(DirectPushCredentials creds, List<String> ids);
}

class HttpDirectPushTransport implements DirectPushTransport {
  HttpDirectPushTransport({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  http.Client? _client;

  @override
  Future<DirectPushConnection> open(DirectPushCredentials creds) async {
    _client?.close();
    final http.Client client = _client = _clientFactory();
    final http.Request req =
        http.Request('GET', Uri.parse('${creds.baseUrl}/push/stream'))
          ..headers['X-Device-Key'] = creds.header
          ..headers['Accept'] = 'text/event-stream'
          ..headers['Cache-Control'] = 'no-store';
    final http.StreamedResponse res =
        await client.send(req).timeout(const Duration(seconds: 20));
    return DirectPushConnection(
      res.statusCode,
      res.stream.transform(utf8.decoder),
    );
  }

  @override
  Future<bool> ack(DirectPushCredentials creds, List<String> ids) async {
    final http.Response res = await http
        .post(
          Uri.parse('${creds.baseUrl}/push/ack'),
          headers: <String, String>{
            'X-Device-Key': creds.header,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, Object>{
            'device_id': creds.deviceId,
            'ids': ids,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return res.statusCode == 204 || res.statusCode == 200;
  }

  void close() {
    _client?.close();
    _client = null;
  }
}

/// Shows the notification for an event (seam for tests).
abstract class DirectPushNotifier {
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    bool urgent = false,
  });
}

/// Turns server events into local notifications and commands. Returns true
/// when the event was handled and may be acknowledged.
class DirectPushDispatcher {
  DirectPushDispatcher({
    required this.notifier,
    Future<void> Function(String command)? runCommand,
  }) : _runCommand = runCommand ?? _defaultCommand;

  final DirectPushNotifier notifier;
  final Future<void> Function(String command) _runCommand;

  static Future<void> _defaultCommand(String command) async {
    // {"type":"live_boost","ttl_s":60}: a viewer is watching, report at 1 Hz.
    final Duration? boost = LiveBoost.parseCommand(command);
    if (boost != null) {
      await LiveBoost.apply(boost);
      return;
    }
    await LocationRefreshService.handlePush(command);
  }

  /// Notification ids are derived from the event id, so a redelivered event
  /// replaces its notification instead of stacking a duplicate.
  static int notificationId(String eventId) => eventId.hashCode & 0x7fffffff;

  /// Tap payload understood by [routeNotificationTap].
  static String? payloadFor(DirectPushEvent e) =>
      e.alertId.isEmpty ? null : 'alert:${e.alertId}';

  Future<bool> handle(DirectPushEvent e) async {
    try {
      switch (e.kind) {
        case DirectPushKind.command:
          await _runCommand(e.command);
        case DirectPushKind.alert:
        case DirectPushKind.notice:
          final String title = e.title.isEmpty ? 'OpenFamily' : e.title;
          await notifier.show(
            id: notificationId(e.id),
            title: title,
            body: e.body,
            payload: payloadFor(e),
            urgent: e.kind == DirectPushKind.alert,
          );
      }
      return true;
    } catch (_) {
      // Not acked: the server re-sends it on the next connection.
      return false;
    }
  }
}

/// Routes a notification tap: "alert:<id>" opens that alert, anything else
/// falls back to the newest active alert.
Future<void> routeNotificationTap(
  String? payload, {
  required Future<void> Function(String alertId) openAlert,
  required Future<void> Function() checkActive,
}) async {
  if (payload != null && payload.startsWith('alert:')) {
    final String id = payload.substring('alert:'.length);
    if (id.isNotEmpty) return openAlert(id);
  }
  return checkActive();
}

/// Default tap routing into the app's [AlertRouter].
Future<void> onDirectNotificationTap(String? payload) => routeNotificationTap(
      payload,
      openAlert: AlertRouter.instance.openById,
      checkActive: AlertRouter.instance.checkActive,
    );

/// Real notifier on top of flutter_local_notifications. Works from the
/// background isolate too (it initialises its own plugin instance).
class LocalDirectPushNotifier implements DirectPushNotifier {
  LocalDirectPushNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    bool urgent = false,
  }) async {
    if (!_ready) {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_notification'),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse r) =>
            onDirectNotificationTap(r.payload),
      );
      _ready = true;
    }
    await _plugin.show(
      id: id,
      title: title,
      body: body.isEmpty ? null : body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'alerts',
          'Alerts',
          channelDescription: 'Family check-ins, help, and SOS',
          importance: urgent ? Importance.max : Importance.high,
          priority: urgent ? Priority.max : Priority.high,
          category: urgent ? AndroidNotificationCategory.alarm : null,
        ),
      ),
    );
  }
}

typedef CredentialLoader = Future<DirectPushCredentials?> Function();
typedef Sleeper = Future<void> Function(Duration d);

/// The connection manager. One instance per isolate: the main isolate runs one
/// while the app is open, and the background-location isolate runs another so
/// alerts keep arriving after the UI is gone.
class DirectPushService {
  DirectPushService({
    required this.transport,
    required this.loadCredentials,
    required this.dispatcher,
    required this.isEnabled,
    ReconnectBackoff? backoff,
    Stream<bool>? onlineChanges,
    Sleeper? sleeper,
    this.idleTimeout = const Duration(seconds: 150),
    this.revokedPause = const Duration(minutes: 10),
    this.replacedPause = const Duration(minutes: 10),
    this.stableAfter = const Duration(seconds: 30),
  })  : backoff = backoff ?? ReconnectBackoff(),
        _online = onlineChanges,
        _sleeper = sleeper;

  final DirectPushTransport transport;
  final CredentialLoader loadCredentials;
  final DirectPushDispatcher dispatcher;
  final Future<bool> Function() isEnabled;
  final ReconnectBackoff backoff;

  /// No byte (not even a heartbeat) for this long means the connection is dead
  /// (the server heartbeats every ~55s).
  final Duration idleTimeout;
  final Duration revokedPause;
  final Duration replacedPause;

  /// A connection that stayed up this long resets the backoff.
  final Duration stableAfter;

  final Stream<bool>? _online;
  final Sleeper? _sleeper;
  StreamSubscription<bool>? _onlineSub;

  bool _running = false;
  int _generation = 0;
  Completer<void>? _kick;
  final List<String> _seen = <String>[];

  /// Recently handled event ids, so a redelivery after a lost ack is shown once.
  @visibleForTesting
  List<String> get seenIds => List<String>.unmodifiable(_seen);

  bool get running => _running;

  /// Starts the connect loop (idempotent).
  void start() {
    if (_running) return;
    _running = true;
    final int gen = ++_generation;
    _onlineSub = _online?.listen((bool online) {
      if (online) reconnectNow();
    });
    unawaited(_loop(gen));
  }

  /// Stops and closes the connection.
  void stop() {
    _running = false;
    _generation++;
    _onlineSub?.cancel();
    _onlineSub = null;
    _wake();
  }

  /// Network came back or changed: skip any backoff wait and reconnect now.
  void reconnectNow() {
    if (!_running) return;
    backoff.reset();
    _wake();
    _dropConnection?.call();
  }

  void Function()? _dropConnection;

  void _wake() {
    final Completer<void>? k = _kick;
    if (k != null && !k.isCompleted) k.complete();
  }

  Future<void> _sleep(Duration d) {
    if (_sleeper != null) return _sleeper(d);
    final Completer<void> k = _kick = Completer<void>();
    return Future.any(<Future<void>>[Future<void>.delayed(d), k.future]);
  }

  Future<void> _loop(int gen) async {
    while (_running && gen == _generation) {
      Duration wait;
      try {
        wait = await _runOnce(gen);
      } catch (_) {
        wait = backoff.next();
      }
      if (!_running || gen != _generation) return;
      await _sleep(wait);
    }
  }

  /// One connection attempt; returns how long to wait before the next one.
  Future<Duration> _runOnce(int gen) async {
    if (!await isEnabled()) return const Duration(minutes: 1);
    final DirectPushCredentials? creds = await loadCredentials();
    if (creds == null) return const Duration(minutes: 1);

    final DirectPushConnection conn;
    try {
      conn = await transport.open(creds);
    } catch (_) {
      return backoff.next();
    }
    if (conn.status == 401 || conn.status == 403 || conn.status == 404) {
      // Key revoked, device deleted or direct push disabled: retrying fast
      // would only hammer the server. The app re-provisions a key on open.
      await _drain(conn);
      return revokedPause;
    }
    if (conn.status == 429) {
      await _drain(conn);
      return backoff.next() + const Duration(seconds: 30);
    }
    if (conn.status != 200) {
      await _drain(conn);
      return backoff.next();
    }

    final SseParser parser = SseParser();
    final Completer<Duration> done = Completer<Duration>();
    final Stopwatch up = Stopwatch()..start();
    Timer? idle;

    void finish(Duration d) {
      if (!done.isCompleted) done.complete(d);
    }

    void touch() {
      idle?.cancel();
      idle = Timer(idleTimeout, () => finish(backoff.next()));
    }

    Future<void> handleFrame(SseFrame f) async {
      switch (f.event) {
        case 'push':
          final DirectPushEvent? e = DirectPushEvent.tryParse(f.data);
          if (e == null) return;
          if (_seen.contains(e.id)) {
            await transport.ack(creds, <String>[e.id]);
            return;
          }
          if (await dispatcher.handle(e)) {
            _remember(e.id);
            try {
              await transport.ack(creds, <String>[e.id]);
            } catch (_) {
              // Redelivered next time; the seen-list makes that silent.
            }
          }
        case 'bye':
          final String reason = _byeReason(f.data);
          if (reason == 'revoked') {
            finish(revokedPause);
          } else if (reason == 'replaced') {
            finish(replacedPause);
          } else {
            finish(backoff.next());
          }
      }
    }

    touch();
    _dropConnection = () => finish(Duration.zero);
    // Frames are handled strictly in order, off the stream callback.
    Future<void> chain = Future<void>.value();
    final StreamSubscription<String> sub = conn.body.listen(
      (String chunk) {
        touch();
        for (final SseFrame f in parser.add(chunk)) {
          chain = chain.then((_) => handleFrame(f)).catchError((Object _) {});
        }
      },
      onError: (Object _) => finish(backoff.next()),
      onDone: () => finish(backoff.next()),
      cancelOnError: true,
    );

    final Duration next = await done.future;
    idle?.cancel();
    _dropConnection = null;
    await sub.cancel();
    await chain;
    if (up.elapsed >= stableAfter) backoff.reset();
    if (!_running || gen != _generation) return Duration.zero;
    return next;
  }

  void _remember(String id) {
    _seen.add(id);
    if (_seen.length > 200) _seen.removeRange(0, _seen.length - 200);
  }

  static String _byeReason(String data) {
    try {
      final dynamic j = jsonDecode(data);
      if (j is Map<String, dynamic>) return (j['reason'] as String?) ?? '';
    } catch (_) {}
    return '';
  }

  Future<void> _drain(DirectPushConnection c) async {
    try {
      await c.body.drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  // ---- app wiring ----

  /// SharedPreferences key of the user's push on/off switch (owned by
  /// PushService).
  static const String enabledPrefKey = 'push_notifications_enabled';

  static Future<bool> _prefEnabled() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(enabledPrefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<DirectPushCredentials?> _storedCredentials() async {
    final String? base = await BackgroundCredentialStore.readApiBaseUrl();
    final String? id = await BackgroundCredentialStore.readDeviceId();
    final String? key = await BackgroundCredentialStore.readIngestKey();
    if (base == null || base.isEmpty || id == null || id.isEmpty ||
        key == null || key.isEmpty) {
      return null;
    }
    return DirectPushCredentials(
      baseUrl: base.replaceAll(RegExp(r'/+$'), ''),
      deviceId: id,
      ingestKey: key,
    );
  }

  static Stream<bool> _connectivity() {
    try {
      return Connectivity()
          .onConnectivityChanged
          .map((List<ConnectivityResult> r) =>
              r.any((ConnectivityResult c) => c != ConnectivityResult.none));
    } catch (_) {
      return const Stream<bool>.empty();
    }
  }

  static DirectPushService create() => DirectPushService(
        transport: HttpDirectPushTransport(),
        loadCredentials: _storedCredentials,
        dispatcher: DirectPushDispatcher(notifier: LocalDirectPushNotifier()),
        isEnabled: _prefEnabled,
        onlineChanges: _connectivity(),
      );

  /// The instance of the current isolate.
  static DirectPushService? _instance;
  static DirectPushService get instance => _instance ??= create();

  /// Called from the background-location isolate on every fix and heartbeat:
  /// makes sure that isolate's connection is up. Cheap and idempotent; if the
  /// connection died (process restarted, loop ended) this revives it.
  static void ensureRunningInBackground() {
    try {
      instance.start();
    } catch (_) {}
  }

  /// Called by the main isolate while the app is open. When the background
  /// location service is running it owns the connection (two streams for one
  /// device would keep replacing each other), so the UI isolate stays out.
  static Future<void> startForeground({
    required Future<bool> Function() backgroundServiceRunning,
  }) async {
    try {
      if (await backgroundServiceRunning()) return;
    } catch (_) {}
    instance.start();
  }
}

/// Stops the main-isolate connection when the app goes to the background
/// without a location service (nothing keeps the process alive then, and an
/// idle radio is the cheapest radio), and restarts it on resume.
class DirectPushLifecycle with WidgetsBindingObserver {
  DirectPushLifecycle({required this.backgroundServiceRunning});

  final Future<bool> Function() backgroundServiceRunning;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(DirectPushService.startForeground(
        backgroundServiceRunning: backgroundServiceRunning,
      ));
    } else if (state == AppLifecycleState.paused) {
      unawaited(() async {
        try {
          if (await backgroundServiceRunning()) return;
        } catch (_) {}
        DirectPushService.instance.stop();
      }());
    }
  }
}
