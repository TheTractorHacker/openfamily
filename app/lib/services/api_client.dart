import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

import '../models/user_profile.dart';
import 'perf/perf_monitor.dart';
import 'server_config.dart';
import 'session_gate.dart';
import 'token_storage.dart';

/// Thrown when the backend returns a non-2xx response.
///
/// [status] is the HTTP status code and [message] is the backend's
/// `{"error": "..."}` body (or a generic fallback when the body is not JSON).
class ApiException implements Exception {
  const ApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'ApiException($status): $message';
}

/// Outcome of a mid-session token refresh.
enum _RefreshResult { ok, rejected, transient }

/// Thrown when the session has expired and cannot be recovered by a token
/// refresh (e.g. the refresh token is missing or expired).
///
/// The app root has already redirected to the login screen via
/// [ApiClient.onSessionExpired] before this is thrown. Callers that run after
/// authentication (e.g. post-auth device registration) should catch this and
/// abort their own navigation rather than proceeding onto a protected screen
/// with cleared tokens.
class SessionExpiredException implements Exception {
  const SessionExpiredException([
    this.message = 'Your session has expired. Please log in again.',
  ]);

  final String message;

  @override
  String toString() => 'SessionExpiredException: $message';
}

/// Top-level so it can run on a worker isolate.
dynamic _decodeJsonBytes(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

/// A thin HTTP client for the OpenFamily backend.
///
/// Every authenticated request injects `Authorization: Bearer <access_token>`
/// from [TokenStorage]. On a 401 it attempts a single token refresh and retries
/// the original request once; if that fails it clears tokens and throws
/// [SessionExpiredException].
class ApiClient {
  ApiClient._();

  static const Duration _timeout = Duration(seconds: 15);

  /// Maximum number of bytes accepted by the profile-avatar endpoint.
  ///
  /// Keep this client-side guard aligned with the server limit so an oversized
  /// selection fails before it consumes a network request.
  static const int maxProfileAvatarBytes = 5 * 1024 * 1024;

  /// Invoked when a session expires and cannot be recovered by refresh.
  ///
  /// The app root registers a handler here to redirect the user to the login
  /// screen. Tokens (and the device id) are already cleared before this fires.
  static void Function()? onSessionExpired;

  /// Whether the session-expired redirect has already fired for the current
  /// (now-dead) session. Guards against concurrent 401s each firing
  /// [onSessionExpired]. Reset by [markSessionActive] when a new session is
  /// established.
  static bool _sessionExpiredFired = false;

  /// Single-flight guard for token refresh: concurrent 401s share one refresh
  /// call instead of each issuing their own.
  static Future<_RefreshResult>? _refreshInFlight;

  // ---------------------------------------------------------------------------
  // Typed helpers
  // ---------------------------------------------------------------------------

  /// POST /auth/register → the created user object.
  ///
  /// [inviteCode], when provided, is validated by the server and assigns the
  /// new user to the code's family and role. On a managed server (one with a
  /// configured platform admin) it is required.
  static Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String name,
    String? inviteCode,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'email': email,
      'password': password,
      'name': name,
    };
    if (inviteCode != null && inviteCode.isNotEmpty) {
      body['invite_code'] = inviteCode;
    }
    final dynamic data = await _send(
      'POST',
      _uri('/auth/register'),
      body: body,
      auth: false,
    );
    return data as Map<String, dynamic>;
  }

  /// POST /family/invites → the created invite code (family admin only).
  static Future<Map<String, dynamic>> createInvite() async {
    final dynamic data = await _send(
      'POST',
      _uri('/family/invites'),
      body: <String, dynamic>{},
    );
    return data as Map<String, dynamic>;
  }

  /// POST /family/join → join a family by invite code.
  static Future<Map<String, dynamic>> joinFamily(String code) async {
    final dynamic data = await _send(
      'POST',
      _uri('/family/join'),
      body: <String, dynamic>{'code': code},
    );
    return data as Map<String, dynamic>;
  }

  /// POST /families → create a family (caller becomes admin).
  static Future<Map<String, dynamic>> createFamily(String name) async {
    final dynamic data = await _send(
      'POST',
      _uri('/families'),
      body: <String, dynamic>{'name': name},
    );
    return data as Map<String, dynamic>;
  }

  /// PATCH /family → rename the caller's family (admin only).
  static Future<void> renameFamily(String name) async {
    await _send(
      'PATCH',
      _uri('/family'),
      body: <String, dynamic>{'name': name},
    );
  }

  /// POST /family/leave → leave the current family.
  static Future<void> leaveFamily() async {
    await _send('POST', _uri('/family/leave'));
  }

  /// PATCH /family/members/{id}/role → change a member's role (admin only).
  static Future<void> updateMemberRole(String memberId, String role) async {
    await _send(
      'PATCH',
      _uri('/family/members/${Uri.encodeComponent(memberId)}/role'),
      body: <String, dynamic>{'role': role},
    );
  }

  /// POST /auth/login → the token pair.
  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? totpCode,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'email': email,
      'password': password,
    };
    if (totpCode != null && totpCode.isNotEmpty) {
      body['totp_code'] = totpCode;
    }
    final dynamic data = await _send(
      'POST',
      _uri('/auth/login'),
      body: body,
      auth: false,
    );
    return data as Map<String, dynamic>;
  }

  /// POST /auth/refresh → a fresh token pair.
  static Future<Map<String, dynamic>> refresh(String refreshToken) async {
    final dynamic data = await _send(
      'POST',
      _uri('/auth/refresh'),
      body: <String, dynamic>{'refresh_token': refreshToken},
      auth: false,
    );
    return data as Map<String, dynamic>;
  }

  /// POST /devices → the registered device object.
  static Future<Map<String, dynamic>> registerDevice({
    required String platform,
    required String name,
    String? pushToken,
    String? unifiedpushEndpoint,
    String? appVersion,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'platform': platform,
      'name': name,
    };
    if (pushToken != null) body['push_token'] = pushToken;
    if (unifiedpushEndpoint != null) {
      body['unifiedpush_endpoint'] = unifiedpushEndpoint;
    }
    if (appVersion != null) body['app_version'] = appVersion;
    final dynamic data = await _send('POST', _uri('/devices'), body: body);
    return data as Map<String, dynamic>;
  }

  /// How long a successful `GET /config` answer is reused. The document is
  /// operator-level (tile URLs, push transports) and changes only when the
  /// server is reconfigured, yet startup used to fetch it three times (session
  /// gate, push sync, map screen).
  static const Duration configTtl = Duration(minutes: 5);

  static Map<String, dynamic>? _configCache;
  static String? _configCacheBase;
  static DateTime? _configCachedAt;
  static Future<Map<String, dynamic>>? _configInFlight;

  /// Clock for the config cache; tests override it.
  static DateTime Function() configClock = DateTime.now;

  /// Drops the cached `/config` (server URL changed, explicit refresh).
  static void invalidateConfig() {
    _configCache = null;
    _configCachedAt = null;
  }

  /// GET /config → public ntfy/APNs/tile settings for the generic APK.
  ///
  /// Cached for [configTtl] per server URL and single-flighted, so concurrent
  /// callers share one request. [force] bypasses the cache. A failed request
  /// is never cached.
  static Future<Map<String, dynamic>> getPushConfig({bool force = false}) {
    final String base = ServerConfig.instance.apiBaseUrl;
    final Map<String, dynamic>? cached = _configCache;
    final DateTime? at = _configCachedAt;
    if (!force &&
        cached != null &&
        at != null &&
        _configCacheBase == base &&
        configClock().difference(at) < configTtl) {
      return Future<Map<String, dynamic>>.value(
          Map<String, dynamic>.of(cached));
    }
    final Future<Map<String, dynamic>>? inFlight = _configInFlight;
    if (inFlight != null && _configCacheBase == base && !force) {
      return inFlight.then(
          (Map<String, dynamic> m) => Map<String, dynamic>.of(m));
    }
    _configCacheBase = base;
    final Future<Map<String, dynamic>> f = () async {
      final dynamic data = await _send('GET', _uri('/config'), auth: false);
      final Map<String, dynamic> map = data as Map<String, dynamic>;
      _configCache = map;
      _configCachedAt = configClock();
      return map;
    }();
    _configInFlight = f;
    f.whenComplete(() {
      if (identical(_configInFlight, f)) _configInFlight = null;
    }).ignore();
    return f.then((Map<String, dynamic> m) => Map<String, dynamic>.of(m));
  }

  /// GET /healthz → throws when the server is unreachable or not OK.
  static Future<void> healthz() async {
    final http.Response response = await _rawSend(
      'GET',
      _uri('/healthz'),
      auth: false,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, 'Server is not reachable.');
    }
  }

  /// POST /auth/logout → invalidates server-side sessions when supported.
  /// Older servers without the route return 404; that is treated as success.
  static Future<void> logout() async {
    try {
      await _send('POST', _uri('/auth/logout'));
    } on ApiException catch (e) {
      if (e.status == 404) return;
      rethrow;
    }
  }

  /// POST /auth/password/change. Requires the current password (and a TOTP or
  /// recovery code when two-factor is on). The server revokes every other
  /// session and returns a fresh token pair, which is stored so this device
  /// stays signed in.
  static Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? totpCode,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'current_password': currentPassword,
      'new_password': newPassword,
    };
    if (totpCode != null && totpCode.trim().isNotEmpty) {
      body['totp_code'] = totpCode.trim();
    }
    final dynamic data =
        await _send('POST', _uri('/auth/password/change'), body: body);
    if (data is Map<String, dynamic> &&
        data['access_token'] is String &&
        data['refresh_token'] is String) {
      await TokenStorage.saveTokens(
        access: data['access_token'] as String,
        refresh: data['refresh_token'] as String,
      );
    }
  }

  /// DELETE /me with step-up `{password, totp_code?}`. 409 means last admin
  /// of a family that still has other members.
  static Future<void> deleteAccount({
    required String password,
    String? totpCode,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{'password': password};
    if (totpCode != null && totpCode.trim().isNotEmpty) {
      body['totp_code'] = totpCode.trim();
    }
    await _send('DELETE', _uri('/me'), body: body);
  }

  /// POST /devices/{id}/ingest-key → a fresh ingest key for the background
  /// reporter. The previous key is invalidated; the new one is returned once.
  static Future<String> rotateDeviceIngestKey(String deviceId) async {
    final String id = deviceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    final dynamic data = await _send(
      'POST',
      _uri('/devices/${Uri.encodeComponent(id)}/ingest-key'),
      body: <String, dynamic>{},
    );
    return (data as Map<String, dynamic>)['ingest_key'] as String;
  }

  /// PATCH /devices/{id} with push credentials. Empty strings clear them.
  static Future<void> updateDevicePush({
    required String deviceId,
    String? pushToken,
    String? unifiedpushEndpoint,
    String? pushTransport,
  }) async {
    final String id = deviceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    final Map<String, dynamic> body = <String, dynamic>{};
    if (pushToken != null) body['push_token'] = pushToken;
    if (unifiedpushEndpoint != null) {
      body['unifiedpush_endpoint'] = unifiedpushEndpoint;
    }
    if (pushTransport != null) body['push_transport'] = pushTransport;
    await _send(
      'PATCH',
      _uri('/devices/${Uri.encodeComponent(id)}'),
      body: body,
    );
  }

  /// GET /api/profile → the authenticated user's private profile information.
  ///
  /// Avatar image data is deliberately fetched separately via
  /// [getProfileAvatar], rather than as a URL embedded in profile or member
  /// data. This keeps the image behind the authenticated API request.
  static Future<UserProfile> getProfile() async {
    final dynamic data = await _send('GET', _uri('/api/profile'));
    return UserProfile.fromJson(data as Map<String, dynamic>);
  }

  /// GET /api/profile/avatar → private avatar image bytes, or null when none is
  /// set (the endpoint uses 404 for that case).
  ///
  /// This uses the same Bearer-token injection and one-time 401 refresh/retry
  /// path as JSON API calls. The image never needs to be exposed as a public
  /// URL.
  static Future<Uint8List?> getProfileAvatar() async {
    final http.Response response = await _sendResponse(
      'GET',
      _uri('/api/profile/avatar'),
      accept: 'image/jpeg, image/png, application/json',
    );
    if (response.statusCode == 404) return null;
    return _avatarBytesFromResponse(response, label: 'profile photo');
  }

  /// GET /family/members/{id}/avatar → private avatar image bytes, or null
  /// when the member has no photo (404).
  ///
  /// The response is deliberately fetched with the same Bearer-token flow as
  /// every other protected API call. Callers receive image bytes for
  /// [Image.memory], never a public avatar URL.
  static Future<Uint8List?> getFamilyMemberAvatar(String memberId) async {
    final String normalizedId = memberId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(memberId, 'memberId', 'must not be empty');
    }

    final http.Response response = await _sendResponse(
      'GET',
      _uri('/family/members/${Uri.encodeComponent(normalizedId)}/avatar'),
      accept: 'image/jpeg, image/png, application/json',
    );
    if (response.statusCode == 404) return null;
    return _avatarBytesFromResponse(response, label: 'family member photo');
  }

  /// PUT /api/profile/avatar with raw JPEG or PNG bytes.
  ///
  /// The endpoint returns 204 No Content on success. Validation is repeated
  /// here (in addition to the UI) so any future caller cannot accidentally
  /// upload an unsupported or oversized payload.
  static Future<void> uploadProfileAvatar({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final String normalizedType =
        contentType.toLowerCase().split(';').first.trim();
    if (bytes.isEmpty) {
      throw const ApiException(0, 'Choose a JPEG or PNG image to upload.');
    }
    if (bytes.length > maxProfileAvatarBytes) {
      throw const ApiException(0, 'Profile photos must be 5 MB or smaller.');
    }
    if (!_matchesAvatarContentType(bytes, normalizedType)) {
      throw const ApiException(0, 'Profile photos must be JPEG or PNG images.');
    }

    final http.Response response = await _sendResponse(
      'PUT',
      _uri('/api/profile/avatar'),
      bytes: bytes,
      contentType: normalizedType,
    );
    _ensureSuccess(response);
  }

  /// DELETE /api/profile/avatar. A missing response body (204) is successful.
  static Future<void> deleteProfileAvatar() async {
    final http.Response response = await _sendResponse(
      'DELETE',
      _uri('/api/profile/avatar'),
    );
    _ensureSuccess(response);
  }

  // ---------------------------------------------------------------------------
  // Generic verbs (for later pieces)
  // ---------------------------------------------------------------------------

  static Future<dynamic> get(String path, {Map<String, String>? query}) {
    return _send('GET', _uri(path, query: query));
  }

  static Future<dynamic> post(String path, {Object? body}) {
    return _send('POST', _uri(path), body: body);
  }

  static Future<dynamic> put(String path, {Object? body}) {
    return _send('PUT', _uri(path), body: body);
  }

  static Future<dynamic> patch(String path, {Object? body}) {
    return _send('PATCH', _uri(path), body: body);
  }

  static Future<dynamic> delete(String path, {Object? body}) {
    return _send('DELETE', _uri(path), body: body);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static Uri _uri(String path, {Map<String, String>? query}) {
    final Uri uri = Uri.parse('${ServerConfig.instance.apiBaseUrl}$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  /// Sends a request, transparently refreshing the access token and retrying
  /// once when the server responds 401.
  static Future<dynamic> _send(
    String method,
    Uri uri, {
    Object? body,
    bool auth = true,
  }) async {
    final http.Response response = await _sendResponse(
      method,
      uri,
      body: body,
      // Preserve the JSON headers used by the original generic API helpers,
      // including for bodyless GET requests.
      contentType: 'application/json',
      auth: auth,
    );
    return _decodeMaybeOffThread(response);
  }

  /// Sends a request whose response is not necessarily JSON, transparently
  /// refreshing the access token and retrying once on 401.
  ///
  /// Profile-avatar operations use this to upload raw bytes and download image
  /// data while retaining exactly the authentication behavior of [_send].
  static Future<http.Response> _sendResponse(
    String method,
    Uri uri, {
    Object? body,
    Uint8List? bytes,
    String? contentType,
    String? accept,
    bool auth = true,
  }) async {
    final http.Response response = await _rawSend(
      method,
      uri,
      body: body,
      bytes: bytes,
      contentType: contentType,
      accept: accept,
      auth: auth,
    );

    if (response.statusCode == 401 && auth) {
      final _RefreshResult refreshResult = await _tryRefresh();
      if (refreshResult == _RefreshResult.transient) {
        // The server was unreachable, restarting (5xx from the proxy) or
        // rate limiting. That says nothing about the session, so keep the
        // tokens and let the caller retry later.
        throw const ApiException(
          0,
          'Could not reach the server. Check your connection.',
        );
      }
      if (refreshResult == _RefreshResult.ok) {
        final http.Response retry = await _rawSend(
          method,
          uri,
          body: body,
          bytes: bytes,
          contentType: contentType,
          accept: accept,
          auth: auth,
        );
        if (retry.statusCode == 401) {
          // The refresh just succeeded, so the session is alive: a 401 right
          // after it is a server hiccup (or a request that is refused for
          // another reason), never proof the login is gone. Keep the tokens;
          // a genuinely dead session is rejected by the refresh itself.
          throw const ApiException(
            0,
            'Could not reach the server. Check your connection.',
          );
        }
        return retry;
      }
      _notifySessionExpired();
      throw const SessionExpiredException();
    }

    return response;
  }

  /// Performs the actual HTTP request with auth headers injected.
  static Future<http.Response> _rawSend(
    String method,
    Uri uri, {
    Object? body,
    Uint8List? bytes,
    String? contentType,
    String? accept,
    bool auth = true,
  }) async {
    if (ServerConfig.instance.apiBaseUrl.isEmpty) {
      throw const ApiException(
        0,
        'Server URL not configured. Enter your OpenFamily server address '
        'in the app settings.',
      );
    }

    final Map<String, String> headers = <String, String>{
      'Accept': accept ?? 'application/json',
    };
    if (contentType != null) {
      headers['Content-Type'] = contentType;
    } else if (body != null) {
      headers['Content-Type'] = 'application/json';
    }
    if (auth) {
      final String? token = await TokenStorage.readAccessToken();
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    final Object? encoded = bytes ?? (body == null ? null : jsonEncode(body));

    // Lightweight instrumentation: method + normalised path + duration only.
    final Stopwatch sw = Stopwatch()..start();
    int status = 0;
    try {
      final http.Response r = await _dispatch(method, uri, headers, encoded);
      status = r.statusCode;
      return r;
    } finally {
      PerfMonitor.instance.recordHttp(method, uri.path, sw.elapsedMilliseconds, status);
    }
  }

  static Future<http.Response> _dispatch(
    String method,
    Uri uri,
    Map<String, String> headers,
    Object? encoded,
  ) async {
    try {
      switch (method) {
        case 'GET':
          return await http.get(uri, headers: headers).timeout(_timeout);
        case 'POST':
          return await http
              .post(uri, headers: headers, body: encoded)
              .timeout(_timeout);
        case 'PATCH':
          return await http
              .patch(uri, headers: headers, body: encoded)
              .timeout(_timeout);
        case 'PUT':
          return await http
              .put(uri, headers: headers, body: encoded)
              .timeout(_timeout);
        case 'DELETE':
          return await http
              .delete(uri, headers: headers, body: encoded)
              .timeout(_timeout);
        default:
          throw ArgumentError.value(
              method, 'method', 'Unsupported HTTP method');
      }
    } on TimeoutException {
      throw const ApiException(0, 'The request timed out. Please try again.');
    } on http.ClientException {
      throw const ApiException(
        0,
        'Could not reach the server. Check your connection.',
      );
    }
  }

  /// Attempts a single token refresh, single-flighted so concurrent 401s share
  /// one refresh call. Returns true and persists the new pair on success;
  /// otherwise clears tokens (and the device id) and returns false.
  static Future<_RefreshResult> _tryRefresh() {
    final Future<_RefreshResult>? inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    final Future<_RefreshResult> future = _performRefresh();
    _refreshInFlight = future;
    future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    });
    return future;
  }

  static Future<_RefreshResult> _performRefresh() async {
    try {
      final String? refreshToken = await TokenStorage.readRefreshToken();
      if (refreshToken == null) {
        await _recoverOrClear();
        return _RefreshResult.rejected;
      }
      final http.Response response = await _rawSend(
        'POST',
        _uri('/auth/refresh'),
        body: <String, dynamic>{'refresh_token': refreshToken},
        auth: false,
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            jsonDecode(response.body) as Map<String, dynamic>;
        await TokenStorage.saveTokens(
          access: data['access_token'] as String,
          refresh: data['refresh_token'] as String,
        );
        return _RefreshResult.ok;
      }
      // Only a definitive rejection ends the session. A deploy restarts the
      // server (502/503 from the proxy), and 429/5xx are equally temporary.
      if (response.statusCode == 400 ||
          response.statusCode == 401 ||
          response.statusCode == 403) {
        await _recoverOrClear();
        return _RefreshResult.rejected;
      }
      return _RefreshResult.transient;
    } catch (_) {
      // Offline, timeout or a storage hiccup: nothing says the session died.
      return _RefreshResult.transient;
    }
  }

  /// Handles a failed foreground refresh: the background isolate no longer
  /// holds or rotates account tokens (MOB-002), so a definitive failure tears
  /// the session down.
  static Future<bool> _recoverOrClear() async {
    await TokenStorage.clear();
    return false;
  }

  /// Notifies the app root that the session expired so it can redirect to
  /// login. Tokens are cleared by the caller before this fires.
  ///
  /// Fires at most once per session: concurrent 401s all funnel through here,
  /// but only the first triggers the redirect.
  static void _notifySessionExpired() {
    if (_sessionExpiredFired) return;
    _sessionExpiredFired = true;
    onSessionExpired?.call();
  }

  /// Marks a fresh session as active, re-arming the session-expired redirect
  /// so a later expiry fires [onSessionExpired] again.
  static void markSessionActive() {
    _sessionExpiredFired = false;
  }

  /// The startup session check used by the app's session gate.
  ///
  /// Unlike the retired `hasValidSession` (which wiped the session whenever
  /// the 15-minute access JWT had expired — forcing a password login at
  /// nearly every open), this refreshes through the 30-day refresh token when
  /// needed and only reports [SessionGateResult.expired] on a definitive
  /// server rejection; transport failures report
  /// [SessionGateResult.unreachable] so an offline open never logs the user
  /// out. The caller (the gate in main.dart) decides whether to clear.
  static Future<SessionGateResult> checkSession() {
    final SessionGate gate = SessionGate(
      loadTokens: () async => (
        access: await TokenStorage.readAccessToken(),
        refresh: await TokenStorage.readRefreshToken(),
      ),
      postRefresh: _refreshForGate,
      saveTokens: ({required String access, required String refresh}) =>
          TokenStorage.saveTokens(access: access, refresh: refresh),
    );
    return gate.evaluate();
  }

  /// The gate's refresh call: distinguishes a definitive rejection (401/403)
  /// from every other failure so the session is destroyed only on purpose.
  static Future<SessionGateRefreshOutcome> _refreshForGate(
    String refreshToken,
  ) async {
    try {
      final http.Response response = await _rawSend(
        'POST',
        _uri('/auth/refresh'),
        body: <String, dynamic>{'refresh_token': refreshToken},
        auth: false,
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            jsonDecode(response.body) as Map<String, dynamic>;
        return SessionGateRefreshOutcome.ok(
          access: data['access_token'] as String,
          refresh: data['refresh_token'] as String,
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const SessionGateRefreshOutcome.rejected();
      }
      return const SessionGateRefreshOutcome.unreachable();
    } catch (_) {
      // Offline, timeout, malformed body, storage hiccup — none of these say
      // anything about whether the session is still valid.
      return const SessionGateRefreshOutcome.unreachable();
    }
  }

  /// Responses at least this large are UTF-8 + JSON decoded on a worker
  /// isolate. On a phone, decoding ~1 MB of JSON blocks the UI isolate for
  /// several frames (trip reports, history trails, long trip lists); below the
  /// threshold the isolate round trip costs more than the decode.
  static const int isolateDecodeThreshold = 128 * 1024;

  /// Same result as [_decode], without blocking the UI isolate for big bodies.
  static Future<dynamic> _decodeMaybeOffThread(http.Response response) async {
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        response.bodyBytes.length >= isolateDecodeThreshold) {
      final Uint8List bytes = response.bodyBytes;
      // compute() runs inline on web, where isolates do not exist.
      return compute<Uint8List, dynamic>(_decodeJsonBytes, bytes);
    }
    return _decode(response);
  }

  /// Decodes a response body, throwing [ApiException] on non-2xx statuses.
  static dynamic _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final String body = response.body;
      if (body.isEmpty) return null;
      return jsonDecode(body);
    }

    _throwForError(response);
  }

  /// Throws an [ApiException] using the backend's error JSON when available.
  static Never _throwForError(http.Response response) {
    final String body = response.body;
    String message = 'Request failed (${response.statusCode}).';
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        message = decoded['error'] as String;
      }
    } catch (_) {
      // Non-JSON error body; keep the generic message.
    }
    throw ApiException(response.statusCode, message);
  }

  /// Ensures a raw-response API call succeeded, including 204 No Content.
  static void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    _throwForError(response);
  }

  /// Validates and returns image bytes from a successful avatar response.
  static Uint8List _avatarBytesFromResponse(
    http.Response response, {
    required String label,
  }) {
    _ensureSuccess(response);

    final String contentType =
        (response.headers['content-type'] ?? '').split(';').first.trim();
    if (contentType != 'image/jpeg' && contentType != 'image/png') {
      throw ApiException(
          0, 'The server returned an unsupported $label format.');
    }
    if (response.bodyBytes.isEmpty ||
        response.bodyBytes.length > maxProfileAvatarBytes ||
        !_matchesAvatarContentType(response.bodyBytes, contentType)) {
      throw ApiException(0, 'The $label returned by the server is invalid.');
    }
    return response.bodyBytes;
  }

  /// Verifies that raw image bytes match the content type we are about to put
  /// on the wire. Server-side decoding remains authoritative, but this avoids
  /// trusting a filename or picker-provided MIME label alone.
  static bool _matchesAvatarContentType(Uint8List bytes, String contentType) {
    if (contentType == 'image/jpeg') {
      return bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff;
    }
    if (contentType == 'image/png') {
      return bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a;
    }
    return false;
  }

  // --- account security ---

  /// GET /me → profile including `totp_enabled`.
  static Future<Map<String, dynamic>> getAccount() async {
    final dynamic data = await _send('GET', _uri('/me'));
    return data as Map<String, dynamic>;
  }

  /// POST /auth/totp/setup → `{secret, otpauth_uri}`.
  static Future<Map<String, dynamic>> totpSetup(String password) async {
    final dynamic data = await _send(
      'POST',
      _uri('/auth/totp/setup'),
      body: <String, dynamic>{'password': password},
    );
    return data as Map<String, dynamic>;
  }

  /// POST /auth/totp/enable → `{enabled, recovery_codes}` (shown once).
  static Future<Map<String, dynamic>> totpEnable(String code) async {
    final dynamic data = await _send(
      'POST',
      _uri('/auth/totp/enable'),
      body: <String, dynamic>{'code': code},
    );
    return data as Map<String, dynamic>;
  }

  /// POST /auth/totp/disable with the password and a TOTP/recovery code.
  static Future<void> totpDisable({
    required String password,
    required String code,
  }) async {
    await _send(
      'POST',
      _uri('/auth/totp/disable'),
      body: <String, dynamic>{'password': password, 'code': code},
    );
  }

  /// GET /auth/sessions → list of session objects.
  static Future<List<dynamic>> listSessions() async {
    final dynamic data = await _send('GET', _uri('/auth/sessions'));
    return data as List<dynamic>;
  }

  /// DELETE /auth/sessions/{id}.
  static Future<void> revokeSession(String id) async {
    await _send('DELETE', _uri('/auth/sessions/${Uri.encodeComponent(id)}'));
  }

  /// POST /auth/logout-all.
  static Future<void> logoutAll() async {
    await _send('POST', _uri('/auth/logout-all'));
  }

  /// POST /auth/password/reset (no auth) with an admin-issued code.
  static Future<void> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _send(
      'POST',
      _uri('/auth/password/reset'),
      body: <String, dynamic>{
        'email': email,
        'code': code,
        'new_password': newPassword,
      },
      auth: false,
    );
  }

  /// POST /family/members/{id}/reset-code (family admin) →
  /// `{code, expires_at, sms_sent, sms_note?}`.
  static Future<Map<String, dynamic>> issueMemberResetCode(
    String memberId, {
    bool sendSms = false,
  }) async {
    final dynamic data = await _send(
      'POST',
      _uri('/family/members/${Uri.encodeComponent(memberId)}/reset-code'),
      body: <String, dynamic>{'send_sms': sendSms},
    );
    return data as Map<String, dynamic>;
  }

  /// GET /me/export → the raw JSON document text. The server ends a complete
  /// export with `"complete":true`; callers must check [isCompleteExport].
  static Future<String> exportMyData() async {
    final http.Response response =
        await _sendResponse('GET', _uri('/me/export'));
    _ensureSuccess(response);
    return response.body;
  }

  /// Whether an export document ends with the server's completion marker.
  static bool isCompleteExport(String json) {
    final String tail = json.length > 64 ? json.substring(json.length - 64) : json;
    return RegExp(r'"complete"\s*:\s*true').hasMatch(tail);
  }

  // --- circles ---
  // Helpers for the multi-circle API (see docs/design/CIRCLES.md).

  /// Generic PUT (used by PUT /circles/{id}/sharing).
  static Future<dynamic> putJson(String path, {Object? body}) {
    return _send('PUT', _uri(path), body: body);
  }

  // --- trips ---

  static Future<dynamic> getTrips({
    required String userId,
    required DateTime from,
    required DateTime to,
    int limit = 200,
  }) {
    return get(
      '/trips',
      query: <String, String>{
        'user_id': userId,
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'limit': '$limit',
      },
    );
  }

  static Future<dynamic> getTrip(String id, {int maxPoints = 400}) {
    return get(
      '/trips/${Uri.encodeComponent(id)}',
      query: <String, String>{'max_points': '$maxPoints'},
    );
  }

  static Future<dynamic> getTripsSummary({
    required String userId,
    required String period,
    DateTime? date,
    double? speedThresholdMps,
  }) {
    final Map<String, String> q = <String, String>{
      'user_id': userId,
      'period': period,
    };
    if (date != null) {
      String two(int n) => n.toString().padLeft(2, '0');
      q['date'] = '${date.year}-${two(date.month)}-${two(date.day)}';
    }
    if (speedThresholdMps != null) {
      q['speed_threshold_mps'] = speedThresholdMps.toStringAsFixed(2);
    }
    return get('/trips/summary', query: q);
  }

  static Future<dynamic> computeTrips({
    required DateTime from,
    required DateTime to,
  }) {
    final String f = Uri.encodeQueryComponent(from.toUtc().toIso8601String());
    final String t = Uri.encodeQueryComponent(to.toUtc().toIso8601String());
    return post('/trips/compute?from=$f&to=$t');
  }

  // --- alerts ---

  /// `GET /alerts`: the family's alert history, newest first.
  static Future<Map<String, dynamic>> listAlerts({
    int limit = 20,
    String? before,
  }) async {
    final dynamic r = await get('/alerts', query: <String, String>{
      'limit': '$limit',
      if (before != null && before.isNotEmpty) 'before': before,
    });
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  /// `GET /alerts/{id}`: one alert with per-recipient delivery rows.
  static Future<Map<String, dynamic>> getAlert(String id) async {
    final dynamic r = await get('/alerts/${Uri.encodeComponent(id)}');
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  /// `POST /alerts/{id}/ack`: idempotent acknowledgement by a recipient.
  static Future<Map<String, dynamic>> ackAlert(String id) async {
    final dynamic r = await post('/alerts/${Uri.encodeComponent(id)}/ack');
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  /// `POST /alerts/{id}/share/revoke`: turns the public location link off.
  static Future<void> revokeAlertShare(String id) async {
    await post('/alerts/${Uri.encodeComponent(id)}/share/revoke');
  }

  // --- member edit ---

  /// `PATCH /family/members/{id}`: a family admin edits a member's name
  /// and/or phone. Only the keys present in [body] are changed.
  static Future<Map<String, dynamic>> updateFamilyMember(
    String id,
    Map<String, dynamic> body,
  ) async {
    final dynamic r =
        await patch('/family/members/${Uri.encodeComponent(id)}', body: body);
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  // --- trip report ---

  /// `GET /trips/report`: the family driving report for one week or month.
  static Future<dynamic> getTripReport({
    required String period,
    required String start,
    required int utcOffsetMinutes,
    String? circleId,
  }) {
    return get(
      '/trips/report',
      query: <String, String>{
        'period': period,
        'start': start,
        'utc_offset_minutes': '$utcOffsetMinutes',
        if (circleId != null && circleId.isNotEmpty) 'circle_id': circleId,
      },
    );
  }

  /// `GET /trips/{id}/events`.
  static Future<dynamic> getTripEvents(String id) {
    return get('/trips/${Uri.encodeComponent(id)}/events');
  }

  // --- driving sensor ---

  /// Request body of `POST /trips/sensor-events`. Only detected events and the
  /// opt-in flag are ever sent, never raw sensor data. At most 100 events per
  /// request.
  static Map<String, dynamic> sensorEventsBody(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  }) {
    return <String, dynamic>{
      'events': events,
      'sensor_enabled': sensorEnabled,
      // Separate opt-in; the server shows phone use as "off" until it is true.
      'phone_use_enabled': phoneUseEnabled,
    };
  }

  /// `POST /trips/sensor-events` with the account session (foreground use,
  /// e.g. the opt-in switch). Returns `{accepted, duplicate, rejected}`.
  static Future<Map<String, dynamic>> postSensorEvents(
    List<Map<String, dynamic>> events, {
    required bool sensorEnabled,
    required bool phoneUseEnabled,
  }) async {
    final dynamic r = await post(
      '/trips/sensor-events',
      body: sensorEventsBody(events,
          sensorEnabled: sensorEnabled, phoneUseEnabled: phoneUseEnabled),
    );
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  /// `POST /trips/sensor-events` authenticated with the **device ingest key**
  /// (`X-Device-Key`), for the background isolate. Never uses account tokens
  /// and never refreshes a session. Throws [ApiException] on non-2xx.
  static Future<Map<String, dynamic>> postSensorEventsWithIngestKey({
    required String apiBaseUrl,
    required String deviceId,
    required String ingestKey,
    required List<Map<String, dynamic>> events,
    required bool sensorEnabled,
    required bool phoneUseEnabled,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final http.Client c = client ?? http.Client();
    try {
      final http.Response r = await c
          .post(
            Uri.parse('$apiBaseUrl/trips/sensor-events'),
            headers: <String, String>{
              'X-Device-Key': '$deviceId.$ingestKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(sensorEventsBody(events,
                sensorEnabled: sensorEnabled,
                phoneUseEnabled: phoneUseEnabled)),
          )
          .timeout(timeout);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw ApiException(r.statusCode, 'sensor events rejected');
      }
      final dynamic data = r.body.isEmpty ? null : jsonDecode(r.body);
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } finally {
      if (client == null) c.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Live tracking (viewer side)
  // ---------------------------------------------------------------------------

  /// `POST /locations/watch`: tells the backend this viewer is looking at
  /// [userId]'s live pin, so it can ask that member's phone to boost to 1 Hz.
  /// Throws like any other call; see [watchMemberQuiet] for the no-throw form.
  static Future<dynamic> watchMember(String userId, {String? circleId}) {
    return post('/locations/watch', body: <String, dynamic>{
      'user_id': userId,
      if (circleId != null && circleId.isNotEmpty) 'circle_id': circleId,
    });
  }

  /// [watchMember] that never throws (a failed watch just means no boost).
  /// Returns true when the request was accepted.
  static Future<bool> watchMemberQuiet(String userId, {String? circleId}) async {
    try {
      await watchMember(userId, circleId: circleId);
      return true;
    } catch (_) {
      return false;
    }
  }
}
