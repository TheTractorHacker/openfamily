import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/services/security_api.dart';

/// Scriptable in-memory [SecurityApi]. Set `fail` to make the next call throw.
class FakeSecurityApi implements SecurityApi {
  FakeSecurityApi({this.account, this.sessions = const <SessionInfo>[]});

  AccountInfo? account;
  List<SessionInfo> sessions;
  Object? fail;
  final List<String> calls = <String>[];
  Map<String, Object?> lastArgs = <String, Object?>{};

  T _go<T>(String name, T Function() body) {
    calls.add(name);
    final Object? f = fail;
    if (f != null) {
      fail = null;
      throw f;
    }
    return body();
  }

  @override
  Future<AccountInfo> getAccount() async => _go('getAccount', () => account!);

  @override
  Future<TotpSetup> totpSetup(String password) async => _go('totpSetup', () {
        lastArgs = <String, Object?>{'password': password};
        return const TotpSetup(
          secret: 'JBSWY3DPEHPK3PXP',
          otpauthUri: 'otpauth://totp/OpenFamily:a@b.c?secret=JBSWY3DPEHPK3PXP',
        );
      });

  @override
  Future<List<String>> totpEnable(String code) async => _go('totpEnable', () {
        lastArgs = <String, Object?>{'code': code};
        return <String>['AAAAA-BBBBB', 'CCCCC-DDDDD'];
      });

  @override
  Future<void> totpDisable({required String password, required String code}) async =>
      _go('totpDisable', () {
        lastArgs = <String, Object?>{'password': password, 'code': code};
      });

  @override
  Future<List<SessionInfo>> listSessions() async =>
      _go('listSessions', () => sessions);

  @override
  Future<void> revokeSession(String id) async => _go('revokeSession', () {
        lastArgs = <String, Object?>{'id': id};
      });

  @override
  Future<void> logoutAll() async => _go('logoutAll', () {});

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    String? totpCode,
  }) async =>
      _go('changePassword', () {
        lastArgs = <String, Object?>{
          'current': currentPassword,
          'next': newPassword,
          'totp': totpCode,
        };
      });

  @override
  Future<void> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) async =>
      _go('reset', () {
        lastArgs = <String, Object?>{
          'email': email,
          'code': code,
          'next': newPassword,
        };
      });

  @override
  Future<List<ResettableMember>> listFamilyMembers() async =>
      _go('listFamilyMembers', () => const <ResettableMember>[
            ResettableMember(id: 'me', name: 'Me', role: 'admin'),
            ResettableMember(id: 'kid', name: 'Kid', role: 'child'),
          ]);

  @override
  Future<ResetCodeResult> issueMemberResetCode(String memberId,
          {bool sendSms = false}) async =>
      _go('issue', () {
        lastArgs = <String, Object?>{'id': memberId};
        return const ResetCodeResult(
            code: 'ABCDE-FGHJK', expiresAt: null, smsSent: false);
      });

  @override
  Future<String> exportMyData() async =>
      _go('export', () => '{"complete":true}');

  @override
  Future<void> deleteAccount({required String password, String? totpCode}) async =>
      _go('delete', () {
        lastArgs = <String, Object?>{'password': password, 'totp': totpCode};
      });
}
