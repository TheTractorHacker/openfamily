import 'dart:convert';

import '../models/security_models.dart';
import 'api_client.dart';
import 'security_format.dart';

/// Seam between the security screens and [ApiClient] so widget tests can
/// substitute a fake without HTTP.
abstract class SecurityApi {
  Future<AccountInfo> getAccount();
  Future<TotpSetup> totpSetup(String password);
  Future<List<String>> totpEnable(String code);
  Future<void> totpDisable({required String password, required String code});
  Future<List<SessionInfo>> listSessions();
  Future<void> revokeSession(String id);
  Future<void> logoutAll();
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? totpCode,
  });
  Future<void> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  });
  Future<List<ResettableMember>> listFamilyMembers();
  Future<ResetCodeResult> issueMemberResetCode(String memberId,
      {bool sendSms});
  Future<String> exportMyData();
  Future<void> deleteAccount({required String password, String? totpCode});
}

class ApiSecurityApi implements SecurityApi {
  const ApiSecurityApi();

  @override
  Future<AccountInfo> getAccount() async =>
      AccountInfo.fromJson(await ApiClient.getAccount());

  @override
  Future<TotpSetup> totpSetup(String password) async =>
      TotpSetup.fromJson(await ApiClient.totpSetup(password));

  @override
  Future<List<String>> totpEnable(String code) async {
    final Map<String, dynamic> r = await ApiClient.totpEnable(code);
    final dynamic codes = r['recovery_codes'];
    return codes is List ? codes.map((e) => '$e').toList() : <String>[];
  }

  @override
  Future<void> totpDisable({required String password, required String code}) =>
      ApiClient.totpDisable(password: password, code: code);

  @override
  Future<List<SessionInfo>> listSessions() async {
    final List<dynamic> raw = await ApiClient.listSessions();
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SessionInfo.fromJson)
        .toList();
  }

  @override
  Future<void> revokeSession(String id) => ApiClient.revokeSession(id);

  @override
  Future<void> logoutAll() => ApiClient.logoutAll();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? totpCode,
  }) =>
      ApiClient.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
        totpCode: totpCode,
      );

  @override
  Future<void> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) =>
      ApiClient.resetPasswordWithCode(
        email: email,
        code: code,
        newPassword: newPassword,
      );

  @override
  Future<List<ResettableMember>> listFamilyMembers() async {
    final dynamic raw = await ApiClient.get('/family/members');
    if (raw is! List) return <ResettableMember>[];
    return raw.whereType<Map<String, dynamic>>().map((m) {
      return ResettableMember(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'Member',
        role: m['role'] as String? ?? 'member',
      );
    }).where((m) => m.id.isNotEmpty).toList();
  }

  @override
  Future<ResetCodeResult> issueMemberResetCode(String memberId,
          {bool sendSms = false}) async =>
      ResetCodeResult.fromJson(
          await ApiClient.issueMemberResetCode(memberId, sendSms: sendSms));

  @override
  Future<String> exportMyData() async {
    final String body = await ApiClient.exportMyData();
    if (!ApiClient.isCompleteExport(body)) {
      throw const SecurityException(
        'The export was cut off before it finished. Try again.',
      );
    }
    // Validate it parses so we never hand the user a corrupt file.
    jsonDecode(body);
    return body;
  }

  @override
  Future<void> deleteAccount({required String password, String? totpCode}) =>
      ApiClient.deleteAccount(password: password, totpCode: totpCode);
}
