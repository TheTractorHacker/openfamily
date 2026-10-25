import 'api_client.dart';

/// What the caller may see/do for one member: whether they are an admin of the
/// family and, only then, the member's phone number (the server omits it for
/// everyone else).
class MemberAdminView {
  const MemberAdminView({required this.isAdmin, this.phone});

  final bool isAdmin;
  final String? phone;
}

/// The saved values returned by the server.
class MemberEditResult {
  const MemberEditResult({required this.name, this.phone});

  final String name;
  final String? phone;
}

/// Client-side phone check mirroring the server (E.164 after stripping
/// spaces, dashes, dots and parentheses). Empty is valid and clears the number.
String? validateMemberPhone(String raw) {
  final String s = raw.replaceAll(RegExp(r'[\s\-().]'), '');
  if (s.isEmpty) return null;
  if (!RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(s)) {
    return 'Use international format, e.g. +15551234567.';
  }
  return null;
}

const int kMemberNameMaxLength = 100;

String? validateMemberName(String raw) {
  final String n = raw.trim();
  if (n.isEmpty) return 'Name is required.';
  if (n.runes.length > kMemberNameMaxLength) {
    return 'Name must be $kMemberNameMaxLength characters or fewer.';
  }
  return null;
}

abstract class MemberEditService {
  Future<MemberAdminView> loadAdminView(String memberId);

  /// Throws [ApiException] with the server's message on failure.
  Future<MemberEditResult> save(
    String memberId, {
    required String name,
    required String phone,
  });
}

class ApiMemberEditService implements MemberEditService {
  const ApiMemberEditService();

  @override
  Future<MemberAdminView> loadAdminView(String memberId) async {
    final dynamic fam = await ApiClient.get('/family');
    final bool admin = fam is Map<String, dynamic> && fam['role'] == 'admin';
    if (!admin) return const MemberAdminView(isAdmin: false);
    final dynamic list = await ApiClient.get('/family/members');
    String? phone;
    if (list is List<dynamic>) {
      for (final dynamic m in list) {
        if (m is Map<String, dynamic> && m['id'] == memberId) {
          final dynamic p = m['phone'];
          if (p is String && p.isNotEmpty) phone = p;
        }
      }
    }
    return MemberAdminView(isAdmin: true, phone: phone);
  }

  @override
  Future<MemberEditResult> save(
    String memberId, {
    required String name,
    required String phone,
  }) async {
    final Map<String, dynamic> r = await ApiClient.updateFamilyMember(
      memberId,
      <String, dynamic>{'name': name.trim(), 'phone': phone.trim()},
    );
    final dynamic p = r['phone'];
    return MemberEditResult(
      name: r['name'] as String? ?? name.trim(),
      phone: p is String && p.isNotEmpty ? p : null,
    );
  }
}
