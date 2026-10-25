import 'package:flutter/material.dart';

import '../models/security_models.dart';
import '../services/security_api.dart';
import '../services/security_format.dart';
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
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text('Issue a reset code for ${m.name}?'),
        content: const Text(
          'Any earlier unused code for this person stops working. Anyone with '
          'the code can set a new password, so share it privately.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Issue code'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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
    return Scaffold(
      appBar: AppBar(title: const Text('Issue reset code')),
      body: SafeArea(
        child: members == null
            ? LoadStateView(
                error: _loadError,
                offline: _offline,
                onRetry: _load,
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(
                    'If someone in your family forgot their password, issue '
                    'a one-time code and give it to them. They enter it under '
                    '"Have a reset code?" on the log-in screen.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (_result != null) ..._resultCard(),
                  if (_error != null) ErrorText(_error!),
                  if (members.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('No other members yet.')),
                    ),
                  for (final ResettableMember m in members)
                    ListTile(
                      minVerticalPadding: 12,
                      leading: const Icon(Icons.person_outline),
                      title: Text(m.name),
                      subtitle: Text(m.role),
                      trailing: _issuingFor == m.id
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed:
                                  _issuingFor == null ? () => _issue(m) : null,
                              child: const Text('Issue code'),
                            ),
                    ),
                ],
              ),
      ),
    );
  }

  List<Widget> _resultCard() {
    final ResetCodeResult r = _result!;
    final String until = r.expiresAt == null
        ? 'in about 30 minutes'
        : 'at ${TimeOfDay.fromDateTime(r.expiresAt!).format(context)}';
    return <Widget>[
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Code for $_resultName',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              CopyableValue(value: r.code, label: 'Reset code'),
              const SizedBox(height: 8),
              Text('Works once, expires $until.'),
              if (r.smsNote != null) Text(r.smsNote!),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }
}
