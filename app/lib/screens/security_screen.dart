import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/security_models.dart';
import '../services/api_client.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/key_backup.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'change_password_screen.dart';
import 'delete_account_screen.dart';
import 'encryption_keys_screen.dart';
import 'issue_reset_code_screen.dart';
import 'security_widgets.dart';
import 'sessions_screen.dart';
import 'two_factor_screen.dart';

/// Hub for account security: two-factor, sessions, password, data export and
/// account deletion. Reached from Settings.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({
    super.key,
    this.api = const ApiSecurityApi(),
    this.shareExport,
    this.keyBackup,
    this.backUpNow,
  });

  final SecurityApi api;

  /// "Keep this phone's key safe through reinstalls". Defaults to the app's (null where the platform has none,
  /// then the row is not shown).
  final KeyBackup? keyBackup;

  /// Saves the live key's copy after the switch is turned on. Defaults to the app's E2EE service.
  final Future<void> Function()? backUpNow;

  /// Hands the exported JSON text to the OS. Overridable for tests.
  final Future<void> Function(String json)? shareExport;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  AccountInfo? _account;
  String? _loadError;
  bool _offline = false;
  bool _exporting = false;
  KeyBackup? _keyBackup;
  bool? _keyBackupOn;

  @override
  void initState() {
    super.initState();
    _keyBackup = widget.keyBackup ?? E2eeApp.keyBackup;
    _load();
    _loadKeyBackup();
  }

  Future<void> _loadKeyBackup() async {
    final KeyBackup? kb = _keyBackup;
    if (kb == null) return;
    final bool on = await kb.enabled();
    if (mounted) setState(() => _keyBackupOn = on);
  }

  Future<void> _setKeyBackup(bool on) async {
    final KeyBackup? kb = _keyBackup;
    if (kb == null) return;
    setState(() => _keyBackupOn = on);
    bool ok = true;
    try {
      ok = await kb.setEnabled(on);
      if (on) await (widget.backUpNow ?? E2eeApp.service.backUpIdentityNow)();
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The copy could not be removed right now. The app tries again at the next start.')));
    }
  }

  static String get _keyBackupText => defaultTargetPlatform == TargetPlatform.iOS
      ? 'Kept in this iPhone\'s keychain, which stays when the app is deleted, so you do not have to set up '
          'encryption again after reinstalling. It can also come back when you restore an encrypted iPhone backup. '
          'It never goes to iCloud Keychain. Turn off to keep the key only on this phone.'
      : 'Stored encrypted in your Google account so you do not have to set up encryption again after reinstalling. '
          'Needs Google backup on and a screen lock; without a screen lock it stays on this phone only. '
          'Turn off to keep the key only on this phone.';

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _offline = false;
    });
    try {
      final AccountInfo a = await widget.api.getAccount();
      if (!mounted) return;
      setState(() => _account = a);
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = errorText(e);
        _offline = isOfflineError(e);
      });
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(builder: (_) => screen),
    );
    if (mounted) _load();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final String json = await widget.api.exportMyData();
      if (widget.shareExport != null) {
        await widget.shareExport!(json);
      } else {
        await Share.shareXFiles(
          <XFile>[
            XFile.fromData(
              utf8.encode(json),
              mimeType: 'application/json',
              name: 'orbitly-export.json',
            ),
          ],
          fileNameOverrides: <String>['orbitly-export.json'],
          subject: 'Orbitly data export',
        );
      }
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is ApiException && e.status == 429
                  ? 'You can export twice an hour. Try again later.'
                  : errorText(e),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AccountInfo? a = _account;
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: SafeArea(
        child: a == null
            ? LoadStateView(error: _loadError, offline: _offline, onRetry: _load)
            : ListView(
                children: <Widget>[
                  _tile(
                    icon: Icons.shield_outlined,
                    title: 'Two-factor authentication',
                    subtitle: a.totpEnabled
                        ? 'On. Codes are required to sign in.'
                        : 'Off. Add a second step when signing in.',
                    onTap: () => _push(TwoFactorScreen(
                      enabled: a.totpEnabled,
                      api: widget.api,
                    )),
                  ),
                  _tile(
                    icon: Icons.devices_outlined,
                    title: 'Active sessions',
                    subtitle: 'See where you are signed in, or log out '
                        'everywhere.',
                    onTap: () => _push(SessionsScreen(api: widget.api)),
                  ),
                  _tile(
                    icon: Icons.password,
                    title: 'Change password',
                    subtitle: 'Signs out your other devices.',
                    onTap: () => _push(ChangePasswordScreen(
                      totpEnabled: a.totpEnabled,
                      api: widget.api,
                    )),
                  ),
                  if (a.isFamilyAdmin)
                    _tile(
                      icon: Icons.key_outlined,
                      title: 'Issue a reset code',
                      subtitle: 'Help a family member who forgot their '
                          'password.',
                      onTap: () => _push(IssueResetCodeScreen(
                        selfId: a.id,
                        api: widget.api,
                      )),
                    ),
                  _tile(
                    icon: Icons.key,
                    title: 'Encryption keys',
                    subtitle: 'Your device key, the server\'s record of it, '
                        'safety numbers and the recovery phrase.',
                    onTap: () => _push(const EncryptionKeysScreen()),
                  ),
                  if (_keyBackup != null && _keyBackupOn != null)
                    DsToggleRow(
                      key: const Key('key-backup-switch'),
                      icon: Icons.restore,
                      title: 'Keep this phone\'s key safe through reinstalls',
                      subtitle: _keyBackupText,
                      value: _keyBackupOn!,
                      onChanged: _setKeyBackup,
                    ),
                  const Divider(height: AppSpace.xxl),
                  _tile(
                    icon: Icons.download_outlined,
                    title: 'Download my data',
                    subtitle: 'A JSON file with your profile, devices, '
                        'places and location history.',
                    busy: _exporting,
                    onTap: _export,
                  ),
                  const Divider(height: AppSpace.xxl),
                  _tile(
                    icon: Icons.delete_forever,
                    title: 'Delete account',
                    subtitle: 'Permanently erase your account and data.',
                    danger: true,
                    onTap: () => _push(DeleteAccountScreen(
                      totpEnabled: a.totpEnabled,
                      api: widget.api,
                    )),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
    bool busy = false,
  }) {
    return DsListRow(
      leading: busy
          ? const SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : DsListRow.iconTile(
              context,
              icon,
              color: danger ? AppColors.sosRed : null,
            ),
      title: title,
      subtitle: busy ? 'Preparing your file...' : subtitle,
      destructive: danger,
      chevron: !busy,
      onTap: busy ? null : onTap,
    );
  }
}
