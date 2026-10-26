import 'api_client.dart';
import 'server_config.dart';

/// Creates and shares alphanumeric family invite codes.
///
/// A single source of truth for the code format and the share message, used by
/// both the map's "Add a person" flow and the onboarding "Invite family" flow.
/// Codes are created on the server (family admin only) so they are real and
/// validated at registration/join time.
class InviteService {
  InviteService._();

  /// Creates a real invite code on the server and returns it.
  static Future<String> createCode() async {
    final Map<String, dynamic> data = await ApiClient.createInvite();
    return parseInviteCode(data);
  }

  /// Reads the code out of the server's invite JSON.
  static String parseInviteCode(Map<String, dynamic> data) {
    final Object? code = data['code'];
    if (code is String && code.trim().isNotEmpty) return code.trim();
    throw const FormatException('The server did not return an invite code.');
  }

  /// The share-sheet subject line.
  static const String shareSubject = 'Join my OpenFamily family';

  /// The share-sheet body: the code and the operator's server URL.
  ///
  /// There is no `/join/{code}` web route; the recipient installs the Android
  /// app, enters this server, and types the code.
  static String shareMessage(String code) =>
      'Join my OpenFamily family!\n\n'
      '1. Install the OpenFamily Android app\n'
      '2. Enter this server: ${ServerConfig.instance.apiBaseUrl}\n'
      '3. Use invite code $code';
}

/// A user-facing sentence for a failed invite creation. Shows the server's own
/// error text when there is one instead of a generic "check your connection".
String describeInviteError(Object e) {
  if (e is ApiException) {
    if (e.status == 403) {
      return 'Only a family admin can create invite codes (${e.message}).';
    }
    if (e.status == 404) {
      return 'You are not in a family yet, so there is nothing to invite '
          'people to (${e.message}).';
    }
    if (e.status == 429) {
      return 'Too many requests. Wait a moment and try again.';
    }
    if (e.status == 0) {
      return '${e.message} If you tried a moment ago, the code may already '
          'exist on the server: try again.';
    }
    return 'Could not create an invite code: ${e.message}';
  }
  if (e is FormatException) {
    return 'The server sent an unexpected reply. ${e.message}';
  }
  return 'Could not create an invite code: $e';
}
