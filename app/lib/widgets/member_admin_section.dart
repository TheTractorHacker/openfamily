import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/member_edit_screen.dart';
import '../services/member_edit_service.dart';

/// Shown on a member profile. Renders nothing unless the caller is an admin of
/// the family; admins see the member's phone (tap to copy) and an Edit button.
class MemberAdminSection extends StatefulWidget {
  const MemberAdminSection({
    super.key,
    required this.memberId,
    required this.memberName,
    this.service = const ApiMemberEditService(),
    this.onEdited,
  });

  final String memberId;
  final String memberName;
  final MemberEditService service;

  /// Called after a successful save with the new values.
  final ValueChanged<MemberEditResult>? onEdited;

  @override
  State<MemberAdminSection> createState() => _MemberAdminSectionState();
}

class _MemberAdminSectionState extends State<MemberAdminSection> {
  MemberAdminView? _view;
  late String _name = widget.memberName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final MemberAdminView v = await widget.service.loadAdminView(widget.memberId);
      if (mounted) setState(() => _view = v);
    } catch (_) {
      // Admin extras are optional; the profile works without them.
    }
  }

  Future<void> _edit() async {
    final MemberEditResult? r = await Navigator.of(context).push<MemberEditResult>(
      MaterialPageRoute<MemberEditResult>(
        builder: (_) => MemberEditScreen(
          memberId: widget.memberId,
          initialName: _name,
          initialPhone: _view?.phone,
          service: widget.service,
        ),
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      _name = r.name;
      _view = MemberAdminView(isAdmin: true, phone: r.phone);
    });
    widget.onEdited?.call(r);
  }

  Future<void> _copy(String phone) async {
    await Clipboard.setData(ClipboardData(text: phone));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Phone number copied')));
  }

  @override
  Widget build(BuildContext context) {
    final MemberAdminView? v = _view;
    if (v == null || !v.isAdmin) return const SizedBox.shrink();
    final String? phone = v.phone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 8),
        ListTile(
          minVerticalPadding: 12,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.phone_outlined),
          title: const Text('Phone'),
          subtitle: Text(phone ?? 'Not set'),
          trailing: phone == null ? null : const Icon(Icons.copy, size: 20),
          onTap: phone == null ? null : () => _copy(phone),
          // Tap target is the whole row; ListTile is >= 48dp tall.
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _edit,
          icon: const Icon(Icons.edit_outlined),
          label: Text('Edit $_name'),
        ),
      ],
    );
  }
}
