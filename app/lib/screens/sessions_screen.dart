import 'package:flutter/material.dart';

import '../models/security_models.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';
import 'welcome_screen.dart';

/// Lists active sign-ins; revoke one or log out everywhere.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    this.api = const ApiSecurityApi(),
    this.onSignedOut,
  });

  final SecurityApi api;

  /// Called after "log out everywhere" succeeds. Defaults to clearing local
  /// credentials and returning to the welcome screen.
  final Future<void> Function(BuildContext context)? onSignedOut;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<SessionInfo>? _sessions;
  String? _loadError;
  bool _offline = false;
  final Set<String> _revoking = <String>{};
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _offline = false;
    });
    try {
      final List<SessionInfo> s = await widget.api.listSessions();
      if (!mounted) return;
      setState(() => _sessions = s);
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

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _revoke(SessionInfo s) async {
    setState(() => _revoking.add(s.id));
    try {
      await widget.api.revokeSession(s.id);
      if (!mounted) return;
      setState(() => _sessions = _sessions?.where((x) => x.id != s.id).toList());
      _snack('Signed out of that device.');
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (mounted) _snack(errorText(e));
    } finally {
      if (mounted) setState(() => _revoking.remove(s.id));
    }
  }

  Future<void> _logoutAll() async {
    final bool ok = await showDsConfirm(
      context,
      title: 'Log out everywhere?',
      message: 'Every device, including this one, will be signed out and '
          'will need to sign in again.',
      confirmLabel: 'Log out everywhere',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await widget.api.logoutAll();
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (mounted) {
        setState(() => _loggingOut = false);
        _snack(errorText(e));
      }
      return;
    }
    if (!mounted) return;
    if (widget.onSignedOut != null) {
      await widget.onSignedOut!(context);
      if (mounted) setState(() => _loggingOut = false);
      return;
    }
    await AuthService.logout(notifyServer: false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<SessionInfo>? sessions = _sessions;
    if (sessions == null) {
      return SecurityPage(
        title: 'Active sessions',
        children: <Widget>[
          LoadStateView(error: _loadError, offline: _offline, onRetry: _load),
        ],
      );
    }
    return SecurityPage(
      title: 'Active sessions',
      heading: 'Where you are signed in',
      subtitle: 'Devices signed in to your account. Signing one out ends its '
          'access within about 15 minutes at most.',
      appBarActions: <Widget>[
        IconButton(
          tooltip: 'Refresh sessions',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
      ],
      actions: <Widget>[
        BusyButton(
          label: 'Log out everywhere',
          icon: Icons.logout,
          onPressed: _logoutAll,
          busy: _loggingOut,
          danger: true,
        ),
      ],
      children: <Widget>[
        if (_loadError != null) ErrorText(_loadError!),
        if (sessions.isEmpty)
          const DsEmptyState(
            icon: Icons.devices_outlined,
            title: 'No active sessions',
          )
        else
          DsRowGroup(
            children: <Widget>[
              for (final SessionInfo s in sessions)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.smartphone),
                  title: describeUserAgent(s.userAgent),
                  subtitle: 'Last used ${relativeTime(s.lastUsedAt)}\n'
                      'Signed in ${relativeTime(s.createdAt)}',
                  trailing: _revoking.contains(s.id)
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip:
                              'Sign out ${describeUserAgent(s.userAgent)}',
                          constraints: const BoxConstraints(
                            minWidth: kMinTarget,
                            minHeight: kMinTarget,
                          ),
                          icon: const Icon(Icons.logout),
                          onPressed: () => _revoke(s),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}
