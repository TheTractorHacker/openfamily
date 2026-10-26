import 'package:flutter/material.dart';

import '../models/emergency_contact.dart';
import '../services/api_client.dart';
import '../services/contact_picker.dart';
import '../services/emergency_contact_service.dart';
import '../services/server_features.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'alerts_history_screen.dart';

/// The Safety screen. Manages emergency contacts (who receive SOS alerts).
///
/// Contacts are picked from the phone's address book and stored on the
/// server so they survive leaving this screen.
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({
    super.key,
    this.contactService,
    this.contactPicker,
    this.smsConfigured,
  });

  final EmergencyContactService? contactService;
  final ContactPicker? contactPicker;

  /// When null, uses [ServerFeatures.smsConfigured].
  final bool? smsConfigured;

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  late final EmergencyContactService _service;
  late final ContactPicker _picker;

  List<EmergencyContact>? _contacts;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service = widget.contactService ?? EmergencyContactService();
    _picker = widget.contactPicker ?? NativeContactPicker();
    if (_smsConfigured) {
      _load();
    }
  }

  bool get _smsConfigured =>
      widget.smsConfigured ?? ServerFeatures.instance.smsConfigured;

  Future<void> _load() async {
    setState(() {
      _contacts = null;
      _error = null;
    });
    try {
      final List<EmergencyContact> contacts = await _service.list();
      if (!mounted) return;
      setState(() => _contacts = contacts);
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _errorMessage(e,
          fallback: 'Couldn\'t load emergency contacts. Please try again.'));
    }
  }

  String _errorMessage(Object e, {required String fallback}) {
    if (e is ApiException) return e.message;
    return fallback;
  }

  Future<void> _addFromPhone() async {
    if (_saving) return;
    try {
      final PickedPhoneContact? picked = await _picker.pickPhoneContact();
      if (picked == null || !mounted) return;

      final String? phone = await _phoneForPickedContact(picked);
      if (phone == null || !mounted) return;

      await _saveContact(name: picked.name, phone: phone);
    } on ContactHasNoPhoneException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That contact has no phone number.'),
        ),
      );
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _errorMessage(e, fallback: 'Couldn\'t open your contacts.'),
          ),
        ),
      );
    }
  }

  /// Picks which number to save when the address-book entry has several.
  Future<String?> _phoneForPickedContact(PickedPhoneContact picked) async {
    final String? selected = picked.selectedPhone;
    if (selected != null && selected.isNotEmpty) return selected;
    if (picked.phones.length == 1) return picked.phones.first;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return SafeArea(
          child: DsSheetScaffold(
            title: 'Which number for ${picked.name}?',
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final String phone in picked.phones)
                    DsListRow(
                      leading: DsListRow.iconTile(context, Icons.phone_outlined),
                      title: phone,
                      onTap: () => Navigator.of(context).pop(phone),
                    ),
                  const SizedBox(height: AppSpace.sm),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addManually() async {
    if (_saving) return;
    final _DraftContact? draft = await showDialog<_DraftContact>(
      context: context,
      builder: (BuildContext context) => const _ManualContactDialog(),
    );
    if (draft == null || !mounted) return;
    await _saveContact(name: draft.name, phone: draft.phone);
  }

  Future<void> _saveContact({
    required String name,
    required String phone,
  }) async {
    setState(() => _saving = true);
    try {
      final EmergencyContact created = await _service.add(
        name: name,
        phone: phone,
      );
      if (!mounted) return;
      setState(() {
        _contacts = <EmergencyContact>[...?_contacts, created];
      });
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _errorMessage(
              e,
              fallback: 'Couldn\'t save that contact. Please try again.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      } else {
        _saving = false;
      }
    }
  }

  Future<void> _removeContact(EmergencyContact contact) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text(
          'Stop sending SOS alerts to ${contact.name}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.delete(contact.id);
      if (!mounted) return;
      setState(() {
        _contacts = _contacts!
            .where((EmergencyContact c) => c.id != contact.id)
            .toList();
      });
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _errorMessage(
              e,
              fallback: 'Couldn\'t remove that contact. Please try again.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Alert history',
            constraints: const BoxConstraints(
              minWidth: kMinTarget,
              minHeight: kMinTarget,
            ),
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AlertsHistoryScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_smsConfigured) {
      return const DsEmptyState(
        icon: Icons.sms_failed_outlined,
        title: 'Text alerts are not set up',
        message: 'Emergency contacts get SOS by text message. This server '
            'has not set up SMS yet, so those contacts would not be notified.',
      );
    }
    if (_error != null) {
      return DsErrorState(
        icon: Icons.cloud_off,
        title: 'Could not load contacts',
        message: _error!,
        onRetry: _load,
      );
    }
    final List<EmergencyContact>? contacts = _contacts;
    if (contacts == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.xl),
        child: DsSkeletonList(rows: 3),
      );
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool canAdd = !_saving && contacts.length < 10;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.xl,
            AppSpace.sm,
            AppSpace.xl,
            AppSpace.sm,
          ),
          child: Text(
            'Emergency contacts receive your SOS alerts with your location. '
            'They do not need the app or to be in your family.',
            style: AppType.secondary.copyWith(
              fontSize: 14,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
        const DsSectionHeader('Emergency contacts'),
        if (contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl,
              AppSpace.sm,
              AppSpace.xl,
              AppSpace.lg,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'No emergency contacts yet. Choose someone from your phone.',
                    style: AppType.body.copyWith(
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final EmergencyContact c in contacts)
          _ContactTile(contact: c, onRemove: () => _removeContact(c)),
        if (contacts.length >= 10)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.xl,
              vertical: AppSpace.sm,
            ),
            child: Text(
              'You have added the most contacts allowed (10).',
              style: AppType.secondary.copyWith(
                fontSize: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        Opacity(
          opacity: canAdd ? 1 : 0.5,
          child: DsListRow(
            leading: DsListRow.iconTile(context, Icons.contacts_outlined),
            title: 'Choose from contacts',
            chevron: true,
            onTap: canAdd ? _addFromPhone : null,
          ),
        ),
        Opacity(
          opacity: canAdd ? 1 : 0.5,
          child: DsListRow(
            leading: DsListRow.iconTile(
              context,
              Icons.keyboard_outlined,
              color: cs.onSurfaceVariant,
            ),
            title: 'Type a name and number',
            chevron: true,
            onTap: canAdd ? _addManually : null,
          ),
        ),
      ],
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.onRemove});

  final EmergencyContact contact;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final String subtitle = contact.relation.isEmpty
        ? contact.phone
        : '${contact.phone} · ${contact.relation}';
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.person),
      title: contact.name,
      subtitle: subtitle,
      trailing: Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          tooltip: 'Remove',
          constraints: const BoxConstraints(
            minWidth: kMinTarget,
            minHeight: kMinTarget,
          ),
          icon: Icon(
            Icons.delete_outline,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

class _DraftContact {
  const _DraftContact({required this.name, required this.phone});

  final String name;
  final String phone;
}

class _ManualContactDialog extends StatefulWidget {
  const _ManualContactDialog();

  @override
  State<_ManualContactDialog> createState() => _ManualContactDialogState();
}

class _ManualContactDialogState extends State<_ManualContactDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  String? _nameError;
  String? _phoneError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    final String phone = _phone.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Enter a name' : null;
      _phoneError = EmergencyContact.looksLikePhone(phone)
          ? null
          : 'Enter a valid phone number';
    });
    if (name.isEmpty || !EmergencyContact.looksLikePhone(phone)) return;
    Navigator.of(context).pop(_DraftContact(name: name, phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add emergency contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Phone',
              errorText: _phoneError,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
