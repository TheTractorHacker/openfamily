import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Links a second phone to the same account. The existing phone signs the new
/// phone's key ("cross-signing") so everyone else can see the chain. The two
/// codes are exchanged by copy/paste; the server never relays them.
class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key, this.service});
  final E2eeService? service;

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  String? _request;
  LinkRequestInfo? _info;
  String? _approval;
  String? _message;
  bool _busy = false;
  final TextEditingController _requestIn = TextEditingController();
  final TextEditingController _approvalIn = TextEditingController();

  @override
  void dispose() {
    _requestIn.dispose();
    _approvalIn.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _message = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link another phone')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(AppSpace.xl), children: <Widget>[
          const Text('On the NEW phone', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          const Text('1. Create a request and copy it to your other phone (message it to yourself).'),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
            label: 'Create link request',
            icon: Icons.add_link,
            style: DsPillStyle.tonal,
            onPressed: _busy ? null : () => _guard(() async {
                  final String r = await _svc.createLinkRequest();
                  setState(() => _request = r);
                }),
          ),
          if (_request != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            SelectableText(_request!, key: const Key('link-request'), style: AppType.secondary.copyWith(fontFamily: 'monospace')),
            TextButton.icon(onPressed: () => _copy(_request!), icon: const Icon(Icons.copy), label: const Text('Copy request')),
          ],
          const SizedBox(height: AppSpace.sm),
          const Text('2. Paste the approval code from your other phone:'),
          TextField(controller: _approvalIn, autocorrect: false, decoration: const InputDecoration(labelText: 'Approval code')),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
            label: 'Register this phone',
            icon: Icons.phone_android,
            onPressed: _busy
                ? null
                : () => _guard(() async {
                      await _svc.registerThisDevice(approval: _svc.parseApproval(_approvalIn.text), label: 'Linked phone');
                      if (!mounted) return;
                      // ignore: use_build_context_synchronously
                      Navigator.of(context).pop();
                    }),
          ),
          const Divider(height: AppSpace.xxxl),
          const Text('On the phone you ALREADY use', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          const Text('Paste the request from the new phone. Compare the short code with the one on the new phone\'s Encryption keys screen before approving.'),
          TextField(controller: _requestIn, autocorrect: false, decoration: const InputDecoration(labelText: 'Request from the new phone')),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
            label: 'Check request',
            style: DsPillStyle.tonal,
            onPressed: _busy
                ? null
                : () => _guard(() async {
                      final LinkRequestInfo i = await _svc.inspectLinkRequest(_requestIn.text);
                      setState(() {
                        _info = i;
                        _approval = null;
                      });
                    }),
          ),
          if (_info != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Text('New phone key: ${_info!.short}', key: const Key('link-short'), style: AppType.body.copyWith(fontWeight: FontWeight.w800)),
            Text(_info!.digits, style: AppType.secondary.copyWith(fontFamily: 'monospace')),
            const SizedBox(height: AppSpace.sm),
            DsPillButton(
              label: 'It matches: approve this phone',
              icon: Icons.verified_user,
              onPressed: _busy ? null : () => _guard(() async {
                    final String a = await _svc.approveLinkRequest(_info!);
                    setState(() => _approval = a);
                  }),
            ),
          ],
          if (_approval != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            const Text('Copy this approval code to the new phone:'),
            SelectableText(_approval!, key: const Key('link-approval'), style: AppType.secondary.copyWith(fontFamily: 'monospace')),
            TextButton.icon(onPressed: () => _copy(_approval!), icon: const Icon(Icons.copy), label: const Text('Copy approval')),
          ],
          if (_message != null) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            Semantics(liveRegion: true, child: Text(_message!, style: AppType.body.copyWith(color: AppColors.sosRed))),
          ],
          const Divider(height: AppSpace.xxxl),
          const Text('No other phone and no recovery phrase?', style: AppType.headline),
          const SizedBox(height: AppSpace.xs),
          const Text(
            'You can reset your keys. Everyone you share a private circle with will see that your '
            'identity changed and a circle admin must approve the new key before it can read anything.',
          ),
          const SizedBox(height: AppSpace.sm),
          DsPillButton(
            label: 'Reset my keys',
            style: DsPillStyle.danger,
            icon: Icons.restart_alt,
            onPressed: _busy
                ? null
                : () async {
                    final bool ok = await showDsConfirm(context,
                        title: 'Reset your encryption keys?',
                        message: 'Your old keys are revoked. Encrypted data you could not read yet stays unreadable to you. Members must approve your new key.',
                        confirmLabel: 'Reset keys',
                        destructive: true);
                    if (!ok) return;
                    await _guard(() async {
                      await _svc.registerThisDevice(reset: true, label: 'Reset');
                      if (!mounted) return;
                      // ignore: use_build_context_synchronously
                      Navigator.of(context).pop();
                    });
                  },
          ),
        ]),
      ),
    );
  }
}
