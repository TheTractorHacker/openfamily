import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/secure_url.dart';
import '../services/server_config.dart';
import '../services/tile_config.dart';
import '../theme/app_theme.dart';
import '../widgets/openfamily_brand.dart';
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
    return Scaffold(
      appBar: widget.allowCancel ? AppBar(title: const Text('Server')) : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(child: OpenFamilyMark(size: 88)),
              const SizedBox(height: 20),
              Text(
                'OpenFamily',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Requires a self-hosted OpenFamily server with HTTPS.\n'
                'Ask your family administrator for its secure address.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: AppColors.textMuted),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://openfamily.example.com',
                  prefixIcon: const Icon(Icons.dns_outlined),
                  errorText: _error,
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect', style: TextStyle(fontSize: 16)),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const PrivacyPolicyScreen()),
                ),
                child: const Text('Privacy policy'),
              ),
              const Text(
                'Your HTTPS server URL is stored on this device only.\n'
                'It is sent nowhere except your own server.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
