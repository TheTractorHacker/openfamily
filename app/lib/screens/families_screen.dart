import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/family_service.dart';
import '../theme/app_theme.dart';
import 'invite_screen.dart';
import 'join_circle_screen.dart';
import 'app_shell.dart';

class _FamilyMember {
  const _FamilyMember({
    required this.id,
    required this.name,
    required this.role,
  });

  final String id;
  final String name;
  final String role;
}

/// Settings destination for the caller's family: rename, invite, roles, leave.
class FamiliesScreen extends StatefulWidget {
  const FamiliesScreen({super.key});

  @override
  State<FamiliesScreen> createState() => _FamiliesScreenState();
}

class _FamiliesScreenState extends State<FamiliesScreen> {
  final FamilyService _familyService = FamilyService();
  FamilyInfo? _family;
  List<_FamilyMember> _members = <_FamilyMember>[];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  bool get _isAdmin => _family?.role == 'admin';

  int get _adminCount =>
      _members.where((_FamilyMember m) => m.role == 'admin').length;

  bool get _isLastAdmin => _isAdmin && _adminCount <= 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final FamilyInfo family = await _familyService.fetchFamily();
      final dynamic raw = await ApiClient.get('/family/members');
      final List<_FamilyMember> members = <_FamilyMember>[];
      if (raw is List) {
        for (final dynamic row in raw) {
          if (row is! Map<String, dynamic>) continue;
          members.add(
            _FamilyMember(
              id: row['id'] as String? ?? '',
              name: row['name'] as String? ?? 'Member',
              role: row['role'] as String? ?? 'member',
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _family = family;
        _members = members;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _family = null;
        _members = <_FamilyMember>[];
        _error = e.status == 404 ? null : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your family.';
      });
    }
  }

  Future<void> _rename() async {
    final FamilyInfo? family = _family;
    if (family == null || !_isAdmin) return;
    // Capture the draft in a local so we don't dispose a TextEditingController
    // while the dialog's exit transition and IME are still running.
    String draft = family.name;
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Rename family'),
        content: TextFormField(
          initialValue: family.name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onChanged: (String value) => draft = value,
          decoration: const InputDecoration(
            labelText: 'Family name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(draft.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (name == null || name.isEmpty || name == family.name) return;
    setState(() => _busy = true);
    try {
      await ApiClient.renameFamily(name);
      if (!mounted) return;
      setState(() {
        _family = FamilyInfo(name: name, role: family.role, userId: family.userId);
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not rename the family.');
    }
  }

  Future<void> _setRole(_FamilyMember member, String role) async {
    if (role == member.role || !_isAdmin) return;
    setState(() => _busy = true);
    try {
      await ApiClient.updateMemberRole(member.id, role);
      if (!mounted) return;
      setState(() {
        _members = _members
            .map(
              (_FamilyMember m) => m.id == member.id
                  ? _FamilyMember(id: m.id, name: m.name, role: role)
                  : m,
            )
            .toList();
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not change that role.');
    }
  }

  Future<void> _leave() async {
    if (_isLastAdmin) {
      _snack('Promote another admin before you leave.');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Leave this family?'),
        content: const Text(
          'You will stop sharing location with this family. You can join '
          'another family with an invite code, or create a new one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ApiClient.leaveFamily();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const AppShell()),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not leave the family.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return 'Admin';
      case 'child':
        return 'Child';
      default:
        return 'Member';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Family')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _family == null
                  ? _NoFamily(onChanged: _load)
                  : ListView(
                      children: [
                        ListTile(
                          leading: const Icon(
                            Icons.group_outlined,
                            color: AppColors.purple,
                          ),
                          title: Text(_family!.name),
                          subtitle: Text(_roleLabel(_family!.role)),
                          trailing: _isAdmin
                              ? IconButton(
                                  tooltip: 'Rename',
                                  onPressed: _busy ? null : _rename,
                                  icon: const Icon(Icons.edit_outlined),
                                )
                              : null,
                        ),
                        if (_isAdmin)
                          ListTile(
                            leading: const Icon(
                              Icons.person_add_alt_1,
                              color: AppColors.purple,
                            ),
                            title: const Text('Invite someone'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => InviteScreen(
                                  circleName: _family!.name,
                                ),
                              ),
                            ),
                          ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                          child: Text(
                            'MEMBERS',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                        for (final _FamilyMember member in _members)
                          ListTile(
                            title: Text(member.name),
                            subtitle: member.id == _family!.userId
                                ? const Text('You')
                                : null,
                            trailing: _isAdmin
                                ? DropdownButton<String>(
                                    value: member.role,
                                    underline: const SizedBox.shrink(),
                                    onChanged: _busy
                                        ? null
                                        : (String? role) {
                                            if (role != null) {
                                              _setRole(member, role);
                                            }
                                          },
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'admin',
                                        child: Text('Admin'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'member',
                                        child: Text('Member'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'child',
                                        child: Text('Child'),
                                      ),
                                    ],
                                  )
                                : Text(_roleLabel(member.role)),
                          ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(
                            Icons.logout,
                            color: AppColors.sosRed,
                          ),
                          title: Text(
                            'Leave family',
                            style: TextStyle(
                              color: _isLastAdmin
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                  : AppColors.sosRed,
                            ),
                          ),
                          subtitle: _isLastAdmin
                              ? const Text(
                                  'Promote another admin before you leave.',
                                )
                              : null,
                          enabled: !_busy && !_isLastAdmin,
                          onTap: _leave,
                        ),
                      ],
                    ),
    );
  }
}

class _NoFamily extends StatelessWidget {
  const _NoFamily({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.group_outlined, size: 64, color: AppColors.purple),
          const SizedBox(height: 16),
          const Text(
            'You are not in a family yet',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Create a family to invite people, or join one with a code.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              String draft = '';
              final String? name = await showDialog<String>(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('Create a family'),
                    content: TextFormField(
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (String value) => draft = value,
                      decoration: const InputDecoration(
                        labelText: 'Family name (optional)',
                        hintText: 'My Family',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(draft.trim()),
                        child: const Text('Create'),
                      ),
                    ],
                  );
                },
              );
              if (name == null) return;
              try {
                await ApiClient.createFamily(
                  name.isEmpty ? 'My Family' : name,
                );
                onChanged();
              } on ApiException catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.message)),
                  );
                }
              }
            },
            child: const Text('Create a family'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () async {
              final bool? joined = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => const JoinCircleScreen(),
                ),
              );
              if (joined == true) onChanged();
            },
            child: const Text('Join with a code'),
          ),
        ],
      ),
    );
  }
}
