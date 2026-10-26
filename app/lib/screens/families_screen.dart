import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/family_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
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
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const DsSkeletonList(rows: 4);
    if (_error != null) {
      return DsErrorState(
        title: 'Could not load your family',
        message: _error!,
        onRetry: _load,
      );
    }
    final FamilyInfo? family = _family;
    if (family == null) return _NoFamily(onChanged: _load);
    final BrandTheme brand = BrandTheme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: AppSpace.xxxl),
        children: <Widget>[
          DsListRow(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: brand.accent,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(Icons.group_outlined, color: brand.onAccent),
            ),
            title: family.name,
            subtitle: _roleLabel(family.role),
            trailing: _isAdmin
                ? IconButton(
                    tooltip: 'Rename family',
                    constraints: const BoxConstraints(
                      minWidth: kMinTarget,
                      minHeight: kMinTarget,
                    ),
                    onPressed: _busy ? null : _rename,
                    icon: const Icon(Icons.edit_outlined),
                  )
                : null,
          ),
          if (_isAdmin)
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.person_add_alt_1),
              title: 'Invite someone',
              subtitle: 'Share a code so they can join',
              chevron: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => InviteScreen(circleName: family.name),
                ),
              ),
            ),
          const DsSectionHeader('Members'),
          if (_members.isEmpty)
            const DsEmptyState(
              icon: Icons.group_outlined,
              title: 'No members to show',
              message: 'Pull down to refresh.',
            ),
          for (final _FamilyMember member in _members)
            DsListRow(
              leading: CircleAvatar(
                backgroundColor: brand.accent.withValues(alpha: 0.25),
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                child: Text(
                  member.name.isEmpty ? '?' : member.name[0].toUpperCase(),
                ),
              ),
              title: member.name,
              subtitle: member.id == family.userId ? 'You' : null,
              trailing: _isAdmin
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: kMinTarget),
                      child: DropdownButton<String>(
                        value: member.role,
                        underline: const SizedBox.shrink(),
                        onChanged: _busy
                            ? null
                            : (String? role) {
                                if (role != null) _setRole(member, role);
                              },
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem(value: 'admin', child: Text('Admin')),
                          DropdownMenuItem(
                            value: 'member',
                            child: Text('Member'),
                          ),
                          DropdownMenuItem(value: 'child', child: Text('Child')),
                        ],
                      ),
                    )
                  : DsStatusChip(label: _roleLabel(member.role)),
            ),
          const Divider(height: AppSpace.xxl),
          DsListRow(
            leading: DsListRow.iconTile(
              context,
              Icons.logout,
              color: _isLastAdmin ? AppColors.statusGrey : AppColors.sosRed,
            ),
            title: 'Leave family',
            destructive: !_isLastAdmin,
            subtitle:
                _isLastAdmin ? 'Promote another admin before you leave.' : null,
            onTap: (_busy || _isLastAdmin) ? null : _leave,
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
          const DsHeading(
            'You are not in a family yet',
            subtitle: 'Create a family to invite people, or join one with a '
                'code.',
            center: true,
          ),
          DsPillButton(
            label: 'Create a family',
            onPressed: 
            () async {
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
          ),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
            label: 'Join with a code',
            style: DsPillStyle.outlined,
            onPressed: () async {
              final bool? joined = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => const JoinCircleScreen(),
                ),
              );
              if (joined == true) onChanged();
            },
          ),
        ],
      ),
    );
  }
}
