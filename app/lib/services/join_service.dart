import 'api_client.dart';

/// Joins a family by invite code.
///
/// Calls POST /family/join, which validates the code against the server's
/// active invite codes and assigns the caller to the code's family and role.
/// What an invite says about the circle's server processing, before joining.
class InvitePreview {
  const InvitePreview({required this.isPrivate, required this.serverAssist, required this.required, required this.defaultServer, this.legacy = false});
  final bool isPrivate;
  final bool serverAssist;

  /// `member_opt_out = required_server`.
  final bool required;

  /// `default_for_new = server`.
  final bool defaultServer;

  /// The circle is still in the old trusted-server mode (the server holds its key). Absent on an older server = false.
  final bool legacy;

  /// Null for anything that is not a well formed answer (fail towards the generic note).
  static InvitePreview? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final Object? opt = j['member_opt_out'], def = j['default_for_new'];
    if (j['private'] is! bool || j['server_assist'] is! bool) return null;
    if ((opt != 'allowed' && opt != 'required_server') || (def != 'phone' && def != 'server')) return null;
    return InvitePreview(
        isPrivate: j['private'] as bool, serverAssist: j['server_assist'] as bool, required: opt == 'required_server', defaultServer: def == 'server', legacy: j['legacy'] == true);
  }
}

class JoinService {
  JoinService._();

  /// Attempts to join the family for [code]. Returns true on success, false
  /// when the code is unknown/invalid/expired/exhausted.
  /// The circle's processing setup for [code], or null when it cannot be read
  /// (unknown code, offline, old server): the caller then shows the generic note.
  static Future<InvitePreview?> preview(String code) async {
    try {
      return InvitePreview.tryParse(await ApiClient.invitePreview(code));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> join(String code) async {
    try {
      await ApiClient.joinFamily(code);
      return true;
    } on ApiException {
      return false;
    }
  }
}
