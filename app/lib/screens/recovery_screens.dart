import 'dart:math';

import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/e2ee_vault.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Shows the 24-word recovery phrase once, with a 3-word confirmation quiz.
/// The phrase is never stored, copied to the clipboard, logged or sent: only the
/// recovery PUBLIC key goes to the server. Screenshots are blocked meanwhile.
class RecoverySetupScreen extends StatefulWidget {
  const RecoverySetupScreen({super.key, this.service, this.screenSecurity = const ScreenSecurity(), this.random});
  final E2eeService? service;
  final ScreenSecurity screenSecurity;
  final Random? random;

  @override
  State<RecoverySetupScreen> createState() => _RecoverySetupScreenState();
}

enum _Step { intro, words, quiz, working, done }

class _RecoverySetupScreenState extends State<RecoverySetupScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  _Step _step = _Step.intro;
  RecoverySetup? _setup;
  List<String> _words = <String>[];
  List<int> _quiz = <int>[];
  final List<TextEditingController> _answers = List<TextEditingController>.generate(3, (_) => TextEditingController());
  final TextEditingController _pass = TextEditingController();
  bool _usePass = false;
  String? _error;

  @override
  void dispose() {
    widget.screenSecurity.setSecure(false);
    for (final TextEditingController c in _answers) {
      c.dispose();
    }
    _pass.dispose();
    _words = <String>[];
    _setup = null;
    super.dispose();
  }

  Future<void> _show() async {
    await widget.screenSecurity.setSecure(true);
    final RecoverySetup s = _svc.newRecoverySetup();
    final Random r = widget.random ?? Random.secure();
    final List<int> idx = (List<int>.generate(24, (int i) => i)..shuffle(r)).take(3).toList()..sort();
    setState(() {
      _setup = s;
      _words = s.mnemonic.split(' ');
      _quiz = idx;
      _step = _Step.words;
    });
  }

  Future<void> _check() async {
    for (int i = 0; i < 3; i++) {
      if (_answers[i].text.trim().toLowerCase() != _words[_quiz[i]]) {
        setState(() => _error = 'One of the words is wrong. Look at your written copy and try again.');
        return;
      }
    }
    setState(() {
      _step = _Step.working;
      _error = null;
    });
    try {
      await _svc.registerRecovery(_setup!.entropy, passphrase: _usePass ? _pass.text : '');
      await widget.screenSecurity.setSecure(false);
      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _words = <String>[];
        _setup = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.quiz;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery phrase')),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(AppSpace.xl), children: _content())),
    );
  }

  List<Widget> _content() {
    switch (_step) {
      case _Step.intro:
        return <Widget>[
          const Text('A way back to your encrypted circles', style: AppType.headline),
          const SizedBox(height: AppSpace.sm),
          const Text(
            'If you lose this phone, the 24 words let a new phone read your private circles again. '
            'The words are made on this phone and are shown once. They are never uploaded, never '
            'stored, and the server only receives a public key derived from them.',
          ),
          const SizedBox(height: AppSpace.md),
          const Text(
            'Anyone who finds the words (and your passphrase, if you set one) can take over your '
            'encrypted identity. Keep them on paper, somewhere private. If you lose every phone AND '
            'the words, your encrypted data cannot be recovered by anyone, including the server operator.',
          ),
          const SizedBox(height: AppSpace.lg),
          SwitchListTile(
            title: const Text('Add an optional passphrase'),
            subtitle: const Text('A second secret you must remember. Slower to unlock on purpose.'),
            value: _usePass,
            onChanged: (bool v) => setState(() => _usePass = v),
          ),
          if (_usePass)
            TextField(
              controller: _pass,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Passphrase', helperText: 'Use letters and digits; you will need it exactly as typed.'),
            ),
          const SizedBox(height: AppSpace.lg),
          DsPillButton(
            label: 'Show my 24 words',
            icon: Icons.visibility,
            onPressed: (_usePass && _pass.text.length < 8 && _pass.text.isNotEmpty) ? null : _show,
          ),
        ];
      case _Step.words:
        return <Widget>[
          const Text('Write these 24 words down, in order', style: AppType.headline),
          const SizedBox(height: AppSpace.sm),
          const Text('Screenshots are blocked on this screen. Do not photograph it or type it into a note app.'),
          const SizedBox(height: AppSpace.md),
          Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: <Widget>[
            for (int i = 0; i < _words.length; i++)
              Container(
                key: Key('word-$i'),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text('${i + 1}. ${_words[i]}', style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
              ),
          ]),
          const SizedBox(height: AppSpace.lg),
          DsPillButton(label: 'I wrote them down', icon: Icons.check, onPressed: () => setState(() => _step = _Step.quiz)),
        ];
      case _Step.quiz:
        return <Widget>[
          const Text('Check your copy', style: AppType.headline),
          const SizedBox(height: AppSpace.sm),
          const Text('Type the words below from your written copy. This proves you can read it back.'),
          for (int i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.md),
              child: TextField(
                key: Key('quiz-$i'),
                controller: _answers[i],
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: 'Word number ${_quiz[i] + 1}'),
              ),
            ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Semantics(liveRegion: true, child: Text(_error!, style: AppType.body.copyWith(color: AppColors.sosRed))),
          ],
          const SizedBox(height: AppSpace.lg),
          DsPillButton(label: 'Confirm and finish', icon: Icons.lock, onPressed: _check),
          TextButton(onPressed: () => setState(() => _step = _Step.words), child: const Text('Show the words again')),
        ];
      case _Step.working:
        return const <Widget>[Center(child: Padding(padding: EdgeInsets.all(AppSpace.xxl), child: CircularProgressIndicator()))];
      case _Step.done:
        return <Widget>[
          const Icon(Icons.check_circle, size: 48, color: Color(0xFF16A34A)),
          const SizedBox(height: AppSpace.md),
          const Text('Recovery phrase set', style: AppType.headline),
          const SizedBox(height: AppSpace.sm),
          const Text('Your private circles\' keys are now also sealed to your recovery key. The words were not saved on this phone.'),
          const SizedBox(height: AppSpace.lg),
          DsPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
        ];
    }
  }
}

/// Restores a new phone from the 24 words (+ optional passphrase).
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key, this.service, this.circles, this.screenSecurity = const ScreenSecurity()});
  final E2eeService? service;
  final CircleService? circles;
  final ScreenSecurity screenSecurity;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;
  CircleService get _circles => widget.circles ?? CircleService.instance;
  final TextEditingController _phrase = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  bool _busy = false;
  String? _error;
  RestoreResult? _done;

  @override
  void initState() {
    super.initState();
    widget.screenSecurity.setSecure(true);
  }

  @override
  void dispose() {
    _phrase.clear();
    _pass.clear();
    _phrase.dispose();
    _pass.dispose();
    widget.screenSecurity.setSecure(false);
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final List<Circle> cs = await _circles.listCircles();
      final RestoreResult r = await _svc.restoreFromPhrase(_phrase.text,
          passphrase: _pass.text, circleIds: cs.map((Circle c) => c.id).toList());
      _phrase.clear();
      _pass.clear();
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is E2eeFormatException ? e.message : (e is E2eeAuthException ? e.message : errorText(e)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final RestoreResult? d = _done;
    return Scaffold(
      appBar: AppBar(title: const Text('Restore from recovery phrase')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(AppSpace.xl), children: <Widget>[
          if (d != null) ...<Widget>[
            const Icon(Icons.check_circle, size: 48, color: Color(0xFF16A34A)),
            const SizedBox(height: AppSpace.md),
            Text('Restored ${d.keysRecovered} circle key${d.keysRecovered == 1 ? '' : 's'}', style: AppType.headline),
            const SizedBox(height: AppSpace.sm),
            const Text(
                'This phone is registered and signed by your recovery key. Because the words were typed on a new phone, ask a circle admin to publish a new circle key (epoch) from the circle\'s encryption screen. The old phone, if lost, should be revoked.'),
            if (d.failedCircles.isNotEmpty) Text('Could not restore ${d.failedCircles.length} circle(s).'),
            const SizedBox(height: AppSpace.lg),
            DsPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
          ] else ...<Widget>[
            const Text('Type your 24 words separated by spaces. The words stay in this screen\'s memory only and are cleared afterwards.'),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const Key('restore-phrase'),
              controller: _phrase,
              minLines: 4,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: const InputDecoration(labelText: 'Recovery phrase'),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _pass,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Passphrase (only if you set one)'),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpace.md),
              Semantics(liveRegion: true, child: Text(_error!, key: const Key('restore-error'), style: AppType.body.copyWith(color: AppColors.sosRed))),
            ],
            const SizedBox(height: AppSpace.lg),
            DsPillButton(label: _busy ? 'Restoring... this can take a few seconds' : 'Restore', icon: Icons.restore, onPressed: _busy ? null : _restore),
          ],
        ]),
      ),
    );
  }
}
