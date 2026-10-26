import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/secure_url.dart';
import '../services/server_config.dart';
import '../services/tile_config.dart';
import '../theme/app_theme.dart';
import '../widgets/openfamily_brand.dart';
import '../widgets/ds/ds.dart';
import 'welcome_screen.dart';
import 'privacy_policy_screen.dart';

/// Server URL screen (first launch, or Settings → change server).
///
/// The user enters their OpenFamily server URL, we ping `/healthz`, then
/// persist it for API + WebSocket calls.
class ServerConfigScreen extends StatefulWidget {
  const ServerConfigScreen({super.key, this.allowCancel = false});

  /// When true, show a back control so Settings can return without saving.
  final bool allowCancel;

  @override
  State<ServerConfigScreen> createState() => _ServerConfigScreenState();
}

class _ServerConfigScreenState extends State<ServerConfigScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (ServerConfig.instance.isConfigured) {
      _controller.text = ServerConfig.instance.apiBaseUrl;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Please enter your server URL.');
      return;
    }
    if (normalizeHttpsBaseUrl(url) == null) {
      setState(() => _error = 'Enter a valid HTTPS server URL.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String previous = ServerConfig.instance.apiBaseUrl;
    try {
      await ServerConfig.instance.setUrl(url);
      await ApiClient.healthz();
      await TileConfig.instance.refresh();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    } on ApiException catch (e) {
      await ServerConfig.instance.setUrl(previous);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      await ServerConfig.instance.setUrl(previous);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not reach that server. Check the URL and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DsPage(
      title: 'Server',
      showBack: widget.allowCancel,
      actions: <Widget>[
        DsBusyButton(label: 'Connect', busy: _saving, onPressed: _save),
        DsPillButton(
          label: 'Privacy policy',
          style: DsPillStyle.outlined,
          icon: Icons.privacy_tip_outlined,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const PrivacyPolicyScreen(),
            ),
          ),
        ),
      ],
      children: <Widget>[
        const SizedBox(height: AppSpace.lg),
        const Center(child: OpenFamilyMark(size: 88)),
        const SizedBox(height: AppSpace.xl),
        const DsHeading(
          'Connect to your server',
          subtitle: 'Requires a self-hosted OpenFamily server with HTTPS.\n'
              'Ask your family administrator for its secure address.',
          center: true,
        ),
        TextField(
          controller: _controller,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://openfamily.example.com',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) DsMessage(_error!),
        const SizedBox(height: AppSpace.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.lock_outline, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                'Your HTTPS server URL is stored on this device only. It is '
                'sent nowhere except your own server.',
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
