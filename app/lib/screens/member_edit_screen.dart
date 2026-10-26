import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/member_edit_service.dart';
import '../services/security_format.dart';
import 'security_widgets.dart';

/// Family admins edit a member's name and phone. Pops with the saved
/// [MemberEditResult] so the caller can refresh.
class MemberEditScreen extends StatefulWidget {
  const MemberEditScreen({
    super.key,
    required this.memberId,
    required this.initialName,
    this.initialPhone,
    this.service = const ApiMemberEditService(),
  });

  final String memberId;
  final String initialName;
  final String? initialPhone;
  final MemberEditService service;

  @override
  State<MemberEditScreen> createState() => _MemberEditScreenState();
}

class _MemberEditScreenState extends State<MemberEditScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _phone =
      TextEditingController(text: widget.initialPhone ?? '');
  String? _nameError;
  String? _phoneError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String? ne = validateMemberName(_name.text);
    final String? pe = validateMemberPhone(_phone.text);
    setState(() {
      _nameError = ne;
      _phoneError = pe;
      _error = null;
    });
    if (ne != null || pe != null) return;
    setState(() => _saving = true);
    try {
      final MemberEditResult r = await widget.service
          .save(widget.memberId, name: _name.text, phone: _phone.text);
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ApiException && e.status != 0 && e.status < 500 &&
                e.status != 429
            ? e.message
            : securityErrorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit member')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Change how this person appears to your family. Their email, '
              'password and role are not changed here.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phone,
              enabled: !_saving,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Phone',
                hintText: '+15551234567',
                helperText: 'International format. Leave empty to remove.',
                helperMaxLines: 2,
                errorText: _phoneError,
              ),
            ),
            if (_error != null) ErrorText(_error!),
            const SizedBox(height: 20),
            BusyButton(label: 'Save', busy: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
