import 'package:flutter/material.dart';

import '../models/security_models.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Family admins issue a one-time password reset code for a member.
class IssueResetCodeScreen extends StatefulWidget {
  const IssueResetCodeScreen({
    super.key,
    required this.selfId,
    this.api = const ApiSecurityApi(),
  });

  final String selfId;
  final SecurityApi api;

  @override
  State<IssueResetCodeScreen> createState() => _IssueResetCodeScreenState();
}

class _IssueResetCodeScreenState extends State<IssueResetCodeScreen> {
  List<ResettableMember>? _members;
  String? _loadError;
  bool _offline = false;
  String? _issuingFor;
  ResetCodeResult? _result;
  String? _resultName;
  String? _error;

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
      final List<ResettableMember> all = await widget.api.listFamilyMembers();
      if (!mounted) return;
      setState(() => _members = all.where((m) => m.id != widget.selfId).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = errorText(e);
        _offline = isOfflineError(e);
      });
    }
  }

  Future<void> _issue(ResettableMember m) async {
    final bool ok = await showDsConfirm(
      context,
      title: 'Issue a reset code for ${m.name}?',
      message: 'Any earlier unused code for this person stops working. Anyone '
          'with the code can set a new password, so share it privately.',
      confirmLabel: 'Issue code',
    );
    if (!ok || !mounted) return;
    setState(() {
      _issuingFor = m.id;
      _error = null;
    });
    try {
      final ResetCodeResult r = await widget.api.issueMemberResetCode(m.id);
      if (!mounted) return;
      setState(() {
        _result = r;
        _resultName = m.name;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _issuingFor = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<ResettableMember>? members = _members;
    if (members == null) {
      return SecurityPage(
        title: 'Issue reset code',
        children: <Widget>[
          LoadStateView(error: _loadError, offline: _offline, onRetry: _load),
        ],
      );
    }
    return SecurityPage(
      title: 'Issue reset code',
      heading: 'Help someone get back in',
      subtitle: 'If someone in your family forgot their password, issue a '
          'one-time code and give it to them. They enter it under "Have a '
          'reset code?" on the log-in screen.',
      children: <Widget>[
        if (_result != null) ..._resultCard(),
        if (_error != null) ErrorText(_error!),
        if (members.isEmpty)
          const DsEmptyState(
            icon: Icons.group_outlined,
            title: 'No other members yet',
            message: 'Invite someone to your family and they will show up '
                'here.',
          )
        else
          DsRowGroup(
            children: <Widget>[
              for (final ResettableMember m in members)
                DsListRow(
                  leading: DsListRow.iconTile(context, Icons.person_outline),
                  title: m.name,
                  subtitle: m.role,
                  trailing: _issuingFor == m.id
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed:
                              _issuingFor == null ? () => _issue(m) : null,
                          child: const Text('Issue code'),
                        ),
                ),
            ],
          ),
      ],
    );
  }

  List<Widget> _resultCard() {
    final ResetCodeResult r = _result!;
    final String until = r.expiresAt == null
        ? 'in about 30 minutes'
        : 'at ${TimeOfDay.fromDateTime(r.expiresAt!).format(context)}';
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Code for $_resultName', style: AppType.headline),
            const SizedBox(height: AppSpace.sm),
            CopyableValue(value: r.code, label: 'Reset code'),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Works once, expires $until.',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            if (r.smsNote != null)
              Text(
                r.smsNote!,
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.lg),
    ];
  }
}
