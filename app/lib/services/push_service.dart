import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'device_service.dart';
import 'location_refresh_service.dart';
import 'secure_url.dart';
import 'unifiedpush_bridge.dart';

/// Registers this device for push (UnifiedPush/ntfy on Android, APNs on iOS)
/// and shows a local notification when a message arrives while the app is open.
class PushService {
  PushService._();

  static const String _prefKey = 'push_notifications_enabled';
  static const MethodChannel _apns = MethodChannel(
    'app.openfamily/apns',
  );

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Live preference, defaulting to on until [load] reads disk.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  static bool _initialized = false;
  static int _localId = 0;

  /// Reads the stored preference. Missing keys mean push is on.
  static Future<bool> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool value = prefs.getBool(_prefKey) ?? true;
    enabled.value = value;
    return value;
  }

  /// Persists [value] and registers or clears the device endpoint.
  static Future<void> setEnabled(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
    enabled.value = value;
    if (value) {
      await sync();
    } else {
      await _clearRegistration();
    }
  }

  /// Sets up plugin callbacks. Safe to call more than once.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
    } catch (_) {
      // Tests and unsupported platforms have no native plugin.
    }
    _apns.setMethodCallHandler(_onApnsCall);
    try {
      await initUnifiedPush(
        onNewEndpoint: _onUnifiedPushEndpoint,
        onMessage: _onUnifiedPushMessage,
        onUnregistered: _onUnifiedPushUnregistered,
      );
    } catch (_) {}
  }

  /// Registers tokens with the backend when the user wants push and a
  /// session exists. Skips silently when APNs/ntfy is unavailable.
  static Future<void> sync() async {
    await initialize();
    await load();
    if (!enabled.value) return;
    try {
      await Permission.notification.request();
    } catch (_) {}
    if (defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb) {
      await _registerIos();
    } else if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
      await _registerAndroid();
    }
  }

  /// Shows a local notification while the app is in the foreground. Background
  /// delivery is left to APNs / the UnifiedPush distributor.
  static Future<void> showForeground(String title, String body) async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      await _local.show(
        id: _localId++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'alerts',
            'Alerts',
            channelDescription: 'Family check-ins, help, and SOS',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _registerAndroid() async {
    String? ntfyBaseUrl;
    try {
      final Map<String, dynamic> cfg = await ApiClient.getPushConfig();
      ntfyBaseUrl = cfg['ntfy_base_url'] as String?;
    } catch (_) {}
    try {
      await registerUnifiedPush(
        ntfyBaseUrl: (ntfyBaseUrl != null && isHttpsUrl(ntfyBaseUrl))
            ? ntfyBaseUrl.trim()
            : null,
      );
    } catch (_) {}
  }

  static Future<void> _registerIos() async {
    try {
      final Map<String, dynamic> cfg = await ApiClient.getPushConfig();
      if (cfg['apns_configured'] != true) {
        return;
      }
    } catch (_) {
      return;
    }
    try {
      await _apns.invokeMethod<void>('register');
    } catch (_) {}
  }

  static Future<void> _onApnsCall(MethodCall call) async {
    if (call.method == 'onToken') {
      final Object? args = call.arguments;
      if (args is! String || args.isEmpty) return;
      try {
        final String deviceId = await DeviceService.ensureRegistered();
        await ApiClient.updateDevicePush(deviceId: deviceId, pushToken: args);
      } catch (_) {}
      return;
    }
    if (call.method == 'onCommand') {
      // Native forwarded a silent APNs command (the backend sends
      // location-refresh requests as content-available payloads with the
      // command JSON under "of"). Handle it exactly like the Android
      // UnifiedPush message path. Alert payloads are not forwarded here —
      // iOS shows those banners itself (AppDelegate's willPresent), so the
      // Android foreground-notification fallback must not double-post.
      final Object? args = call.arguments;
      if (args is! String || args.isEmpty) return;
      try {
        await LocationRefreshService.handlePush(args);
      } catch (_) {}
    }
  }

  static Future<void> _onUnifiedPushEndpoint(String endpoint) async {
    try {
      final String deviceId = await DeviceService.ensureRegistered();
      await ApiClient.updateDevicePush(
        deviceId: deviceId,
        unifiedpushEndpoint: endpoint,
      );
    } catch (_) {}
  }

  /// The distributor dropped the registration (reinstalled, switched
  /// distributor, revoked the topic...). The server-side endpoint is now dead:
  /// clear it so location requests and alerts stop targeting an unreachable
  /// device. The next [sync] re-registers a fresh endpoint.
  static Future<void> _onUnifiedPushUnregistered() async {
    try {
      final String deviceId = await DeviceService.ensureRegistered();
      await ApiClient.updateDevicePush(
        deviceId: deviceId,
        unifiedpushEndpoint: '',
      );
    } catch (_) {}
  }

  static Future<void> _onUnifiedPushMessage(String body) async {
    final LocationRefreshResult result =
        await LocationRefreshService.handlePush(body);
    if (result == LocationRefreshResult.notCommand) {
      await showForeground(
        'OpenFamily',
        body.trim().isEmpty ? 'New notification' : body,
      );
    }
  }

  static Future<void> _clearRegistration() async {
    try {
      await unregisterUnifiedPush();
    } catch (_) {}
    try {
      final String deviceId = await DeviceService.ensureRegistered();
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await ApiClient.updateDevicePush(deviceId: deviceId, pushToken: '');
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        await ApiClient.updateDevicePush(
          deviceId: deviceId,
          unifiedpushEndpoint: '',
        );
      }
    } catch (_) {}
  }
}
