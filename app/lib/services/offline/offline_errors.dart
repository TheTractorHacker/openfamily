import 'dart:async';

import '../api_client.dart';

/// True when [e] says "the server could not be reached or is struggling", as
/// opposed to "the server answered and said no". Only these failures may
/// trigger cache fallback, queueing and retry; a 4xx is a real answer.
///
/// Never true for [SessionExpiredException]: a dead session needs a sign-in,
/// not a retry.
bool isOfflineError(Object e) {
  if (e is SessionExpiredException) return false;
  if (e is ApiException) {
    final int s = e.status;
    return s == 0 || s == 408 || s == 429 || s >= 500;
  }
  if (e is TimeoutException) return true;
  // Wrapped transport errors (SocketException, HandshakeException, ClientException ...).
  final String n = e.runtimeType.toString();
  return n.contains('Socket') ||
      n.contains('Handshake') ||
      n.contains('ClientException') ||
      n.contains('HttpException') ||
      n.contains('Tls');
}

/// A subset of [isOfflineError] that means the answer was a "try again later"
/// (rate limit) and not a connectivity problem.
bool isRateLimited(Object e) => e is ApiException && e.status == 429;

/// Statuses that mean the server looked at a queued request and refused it for
/// good (replaying it can never work). 401 is excluded: that is a session
/// matter, handled by the API client.
bool isPermanentRejection(Object e) {
  if (e is! ApiException) return false;
  final int s = e.status;
  return s >= 400 && s < 500 && s != 401 && s != 408 && s != 429;
}
