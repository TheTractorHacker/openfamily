import 'dart:async' show TimeoutException;

import 'api_client.dart';
import 'e2ee/e2ee_crypto.dart' show E2eeAuthException, E2eeFormatException;
import 'e2ee/e2ee_service.dart' show NeedsCrossSignatureException, localKeyProblemOf, LocalKeyException;

/// What kind of failure a message describes. Only [offline], [noAnswer] and
/// [timeout] are about the connection; everything else has another cause and
/// must not tell the person to check their connection.
enum ErrorCause {
  /// This phone has no network at all.
  offline,

  /// The phone is online but the server did not answer (down, restarting,
  /// wrong address, TLS failure).
  noAnswer,

  /// The request was sent but the answer did not come back in time.
  timeout,

  /// The sign-in on this phone ended; signing in again fixes it.
  signIn,

  /// The server answered and refused (no permission, invalid request).
  refused,

  /// The thing asked for no longer exists on the server.
  notFound,

  /// Too many attempts in a short time.
  tooMany,

  /// The server is busy or restarting (a proxy answered 502/503/504).
  serverBusy,

  /// The server failed while handling the request (500 and similar).
  serverError,

  /// This app is too old for the server.
  updateApp,

  /// This phone's encryption key is missing, unreadable or locked.
  keyProblem,

  /// This phone is not set up for encryption yet.
  setupNeeded,

  /// A code or piece of data could not be read or did not pass its check.
  badData,

  /// Something failed on this phone itself (a bug or an unexpected state).
  phone,
}

/// A user-facing explanation of a failure: a short [title] for a full-screen
/// state, a [message] that says what happened and what to do next.
class ErrorCopy {
  const ErrorCopy(this.cause, this.title, this.message);

  final ErrorCause cause;
  final String title;
  final String message;

  /// Whether the failure is about the connection to the server.
  bool get connection => cause == ErrorCause.offline || cause == ErrorCause.noAnswer || cause == ErrorCause.timeout;
}

/// Whether this phone currently has any network, as last reported by the
/// operating system (null when unknown, for example in tests or on desktop).
/// Kept up to date by the offline sync's connectivity listener.
class DeviceNetwork {
  DeviceNetwork._();
  static bool? online;
}

// The two transport messages ApiClient uses for status 0 (see ApiClient._dispatch).
const String _kTimedOut = 'The request timed out';
const String _kUnreachable = 'Could not reach the server';

String _sentence(String s) {
  final String t = s.trim();
  if (t.isEmpty) return t;
  final String first = t[0].toUpperCase() + t.substring(1);
  return RegExp(r'[.!?]$').hasMatch(first) ? first : '$first.';
}

/// The one mapping from a thrown error to what the person reads.
///
/// Rules: "offline" only when the phone has no network; "no answer" only for
/// a real transport failure; "timed out" only for a timeout. A server answer
/// says what the server said; a problem on this phone says so, with the next
/// step, and never blames the connection.
ErrorCopy describeError(Object error) {
  if (error is SignInNeededException) {
    return const ErrorCopy(ErrorCause.signIn, 'Sign in again',
        'This phone is no longer signed in to your server. Sign in again to continue; nothing on the phone is lost.');
  }
  if (error is SessionExpiredException) {
    return const ErrorCopy(ErrorCause.signIn, 'Sign in again',
        'Your sign-in on this phone has ended. Sign in again to continue; nothing on the phone is lost.');
  }
  if (error is ApiException) return _fromApi(error);
  if (error is TimeoutException) return _timeout;
  final String type = error.runtimeType.toString();
  if (type == 'SocketException' || type == 'ClientException' || type == 'HandshakeException') {
    return _unreachable();
  }
  final LocalKeyException? key = localKeyProblemOf(error);
  if (key != null) return ErrorCopy(ErrorCause.keyProblem, 'Encryption key problem', key.message);
  if (error is NeedsCrossSignatureException) {
    return const ErrorCopy(ErrorCause.setupNeeded, 'Set up this phone',
        'Your account already has encryption keys on another phone. Open Encryption keys and link this phone, '
        'or restore with your recovery phrase.');
  }
  if (error is E2eeFormatException) {
    return ErrorCopy(ErrorCause.badData, 'Could not read that', _sentence(error.message));
  }
  if (error is E2eeAuthException) {
    return const ErrorCopy(ErrorCause.badData, 'Security check failed',
        'The data did not pass its security check, so it was not used. If you pasted a code, copy it again from the other phone.');
  }
  if (error is FormatException) {
    return const ErrorCopy(ErrorCause.badData, 'Could not read that',
        'That code or answer is incomplete or has a typo. Copy it again in full and try again.');
  }
  if (error is StateError) {
    return ErrorCopy(ErrorCause.phone, 'Not possible right now', _sentence(error.message));
  }
  return ErrorCopy(ErrorCause.phone, 'Problem on this phone',
      'Something failed on this phone ($type). Try again; if it keeps happening, send a report from Settings > Diagnostics.');
}

const ErrorCopy _timeout = ErrorCopy(ErrorCause.timeout, 'No answer in time',
    'Your server took too long to answer. Check that this phone has a good connection and try again.');

ErrorCopy _unreachable() {
  if (DeviceNetwork.online == false) {
    return const ErrorCopy(ErrorCause.offline, 'No connection',
        'This phone is offline. Connect to Wi-Fi or mobile data and try again.');
  }
  return const ErrorCopy(ErrorCause.noAnswer, "Can't reach your server",
      'Your server did not answer. It may be restarting or down. Try again in a minute; '
      'if it keeps happening, open Settings > Diagnostics.');
}

ErrorCopy _fromApi(ApiException e) {
  // A server's own refusal ("cannot remove the last admin") is shown as it is.
  final String msg = e.message.trim();
  final bool generic = msg.isEmpty || msg.startsWith('Request failed (');
  switch (e.status) {
    case 0:
      if (msg.startsWith(_kTimedOut)) return _timeout;
      if (msg.isEmpty || msg.startsWith(_kUnreachable) || msg.startsWith('Server is not reachable')) return _unreachable();
      // A status-0 failure with its own explanation (an invalid answer from the server).
      return ErrorCopy(ErrorCause.serverError, 'Unexpected answer', _sentence(msg));
    case 401:
      return const ErrorCopy(ErrorCause.signIn, 'Sign in again',
          'Your server no longer accepts this sign-in. Sign in again to continue; nothing on the phone is lost.');
    case 403:
      return ErrorCopy(ErrorCause.refused, 'Not allowed',
          generic ? 'Your server refused this: your account is not allowed to do it. Ask a circle admin.' : msg);
    case 404:
    case 410:
      return ErrorCopy(ErrorCause.notFound, 'No longer there',
          generic ? 'This is no longer on your server. Go back and refresh.' : msg);
    case 426:
      return const ErrorCopy(ErrorCause.updateApp, 'Update Orbitly', 'This app version is too old for your server. Update Orbitly and try again.');
    case 429:
      return const ErrorCopy(ErrorCause.tooMany, 'Too many attempts', 'Too many attempts. Wait a few minutes and try again.');
    case 502:
    case 503:
    case 504:
      return const ErrorCopy(ErrorCause.serverBusy, 'Server busy',
          'Your server is busy or restarting. Try again in a minute.');
  }
  if (e.status >= 500) {
    return ErrorCopy(ErrorCause.serverError, 'Server problem',
        'Your server had a problem handling this (error ${e.status}). Try again shortly; if it keeps happening, tell whoever runs your server.');
  }
  return ErrorCopy(ErrorCause.refused, 'Not accepted',
      generic ? 'Your server did not accept this (error ${e.status}). Check what you entered and try again.' : msg);
}

/// "Could not <action>." followed by the reason and next step, for actions
/// whose own mapping has no specific text for this failure.
String actionFailedMessage(Object error, String action) => 'Could not $action. ${describeError(error).message}';
