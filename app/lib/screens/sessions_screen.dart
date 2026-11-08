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
  bool _signingOutOthers = false;
  String? _currentId;

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
      final List<Object?> r = await Future.wait<Object?>(<Future<Object?>>[
        widget.api.listSessions(),
        widget.api.currentSessionId().then<Object?>((String? v) => v).catchError((Object _) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _sessions = r[0] as List<SessionInfo>;
        _currentId = r[1] as String?;
      });
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

  Future<void> _signOutOthers() async {
    final List<SessionInfo> others = (_sessions ?? <SessionInfo>[]).where((SessionInfo x) => x.id != _currentId).toList();
    if (_currentId == null || others.isEmpty) return;
    final bool ok = await showDsConfirm(
      context,
      title: 'Sign out other sessions?',
      message: 'This device stays signed in. ${others.length} other ${others.length == 1 ? 'session is' : 'sessions are'} signed out.',
      confirmLabel: 'Sign out others',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _signingOutOthers = true);
    try {
      for (final SessionInfo o in others) {
        await widget.api.revokeSession(o.id);
      }
      _snack('Signed out ${others.length} other ${others.length == 1 ? 'session' : 'sessions'}.');
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (mounted) _snack(errorText(e));
    } finally {
      if (mounted) setState(() => _signingOutOthers = false);
    }
    if (mounted) await _load();
  }

  static bool _isRecent(SessionInfo s, DateTime now) {
    final DateTime? t = s.lastUsedAt ?? s.createdAt;
    return t == null || now.difference(t).inDays < 7;
  }

  static bool _isBrowser(String ua) {
    final String u = ua.toLowerCase();
    return !u.contains('dart') && !u.contains('android') && !u.contains('iphone') && !u.contains('ios') &&
        (u.contains('windows') || u.contains('mac') || u.contains('linux') || u.contains('chrome') || u.contains('firefox') || u.contains('safari'));
  }

  Widget _row(SessionInfo s) {
    final bool me = s.id == _currentId;
    return DsListRow(
      key: Key('session-${s.id}'),
      leading: DsListRow.iconTile(context, _isBrowser(s.userAgent) ? Icons.desktop_windows_outlined : Icons.smartphone),
      title: describeUserAgent(s.userAgent),
      subtitle: 'Last used ${relativeTime(s.lastUsedAt)}',
      info: 'Signed in ${relativeTime(s.createdAt)}. Signing a device out ends its access within about 15 minutes at most.',
      infoTitle: describeUserAgent(s.userAgent),
      trailing: me
          ? const DsStatusChip(label: 'This device', icon: Icons.check_circle_outline, color: AppColors.accentInk)
          : _revoking.contains(s.id)
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  tooltip: 'Sign out ${describeUserAgent(s.userAgent)}',
                  constraints: const BoxConstraints(minWidth: kMinTarget, minHeight: kMinTarget),
                  icon: const Icon(Icons.logout),
                  onPressed: () => _revoke(s),
                ),
    );
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
    final DateTime now = DateTime.now();
    final List<SessionInfo> recent = sessions.where((SessionInfo x) => x.id == _currentId || _isRecent(x, now)).toList();
    final List<SessionInfo> older = sessions.where((SessionInfo x) => !recent.contains(x)).toList();
    return SecurityPage(
      title: 'Active sessions',
      heading: 'Where you are signed in',
      subtitle: 'Devices signed in to your account.',
      appBarActions: <Widget>[
        IconButton(
          tooltip: 'Refresh sessions',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
      ],
      actions: <Widget>[
        if (_currentId != null && sessions.any((SessionInfo x) => x.id != _currentId))
          BusyButton(
            label: 'Sign out other sessions',
            icon: Icons.devices_other_outlined,
            onPressed: _signOutOthers,
            busy: _signingOutOthers,
          ),
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
        else ...<Widget>[
          DsRowGroup(children: <Widget>[for (final SessionInfo s in recent) _row(s)]),
          if (older.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            DsRowGroup(children: <Widget>[
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const Key('older-sessions'),
                  title: Text('Older sessions (${older.length})', style: AppType.body),
                  subtitle: const Text('Not used for over a week', style: AppType.secondary),
                  children: <Widget>[for (final SessionInfo s in older) _row(s)],
                ),
              ),
            ]),
          ],
        ],
      ],
    );
  }
}
