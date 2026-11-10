import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_crypto.dart' show E2eeFormatException;
import '../services/e2ee/e2ee_service.dart';
import '../services/error_copy.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Which of the two phones this screen runs on.
enum LinkRole {
  /// The phone being added: it makes a code and waits for the answer.
  newPhone,

  /// The phone already in use: it checks the code and approves.
  existingPhone,
}

/// Where the screen is in the flow. One primary action per step.
@visibleForTesting
enum LinkStep {
  /// Which phone is this?
  choose,

  /// New phone: explains the steps, primary "Make a code".
  newStart,

  /// New phone: shows its code, waits for the answer code.
  newWaiting,

  /// New phone: linked.
  newDone,

  /// Existing phone: paste the new phone's code.
  existingPaste,

  /// Existing phone: compare the check code, then approve.
  existingCompare,

  /// Existing phone: approved, send the answer back.
  existingApproved,
}

/// Links a second phone to the same account. The existing phone signs the new
/// phone's key ("cross-signing") so everyone else can see the chain. The two
/// codes are exchanged by copy/paste or the share sheet; the server never
/// relays them.
///
/// The screen walks one phone through its half of the flow: first "Which phone
/// is this?" (unless [role] says it), then one step at a time, each with a
/// single primary button at the bottom. Technical details (the long check
/// number) stay behind "Details".
class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key, this.service, this.role, this.share});
  final E2eeService? service;

  /// Skips the "Which phone is this?" question (for example when this phone
  /// just learned that the account already has keys elsewhere).
  final LinkRole? role;

  /// Opens the share sheet with a code. Defaults to `Share.share`; tests inject it.
  final Future<void> Function(String text)? share;

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  E2eeService get _svc => widget.service ?? E2eeApp.service;

  late LinkStep _step = switch (widget.role) {
    null => LinkStep.choose,
    LinkRole.newPhone => LinkStep.newStart,
    LinkRole.existingPhone => LinkStep.existingPaste,
  };
  String? _request;

  /// The new phone's own check code (the same one the existing phone shows).
  String? _ownShort;
  LinkRequestInfo? _info;
  String? _approval;
  String? _message;
  bool _busy = false;
  final TextEditingController _requestIn = TextEditingController();
  final TextEditingController _approvalIn = TextEditingController();

  @override
  void initState() {
    super.initState();
    _requestIn.addListener(_onInput);
    _approvalIn.addListener(_onInput);
  }

  @override
  void dispose() {
    _requestIn.dispose();
    _approvalIn.dispose();
    super.dispose();
  }

  void _onInput() {
    if (mounted) setState(() {});
  }

  void _go(LinkStep step) => setState(() {
        _step = step;
        _message = null;
      });

  /// Codes travel through chat apps that wrap long lines; a code never contains spaces.
  static String _clean(String code) => code.replaceAll(RegExp(r'\s+'), '');

  /// Runs [f] with the button in its busy state; a failure becomes one calm sentence.
  Future<void> _guard(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _message = _explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a failure means here, in plain words.
  static String _explain(Object e) {
    // A pasted code that is cut off or mistyped fails while decoding. Only that
    // failure is named here; anything else is a problem on this phone and says so.
    if (e is FormatException) {
      return 'That code is not complete. Copy the whole code again from the other phone and paste it here.';
    }
    if (e is E2eeFormatException && e.message.contains('another account')) {
      return 'That code belongs to a different account. Both phones must be signed in to the same account.';
    }
    return describeError(e).message;
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied. Now paste it on your other phone.')));
    }
  }

  Future<void> _share(String text) async {
    try {
      await (widget.share ?? (String t) => Share.share(t))(text);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open sharing. Use Copy instead.')));
      }
    }
  }

  Future<void> _paste(TextEditingController into) async {
    try {
      final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
      final String t = (d?.text ?? '').trim();
      if (t.isNotEmpty) into.text = t;
    } catch (_) {}
  }

  // ---------------------------------------------------------------- actions

  Future<void> _makeCode() => _guard(() async {
        final String r = await _svc.createLinkRequest();
        String? short;
        try {
          short = (await _svc.inspectLinkRequest(r)).short;
        } catch (_) {
          // The check code is a convenience: the existing phone still shows it.
        }
        if (!mounted) return;
        setState(() {
          _request = r;
          _ownShort = short;
          _step = LinkStep.newWaiting;
        });
      });

  Future<void> _finishLinking() => _guard(() async {
        await _svc.registerThisDevice(approval: _svc.parseApproval(_clean(_approvalIn.text)), label: 'Linked phone');
        if (!mounted) return;
        setState(() => _step = LinkStep.newDone);
      });

  Future<void> _checkRequest() => _guard(() async {
        final LinkRequestInfo i = await _svc.inspectLinkRequest(_clean(_requestIn.text));
        if (!mounted) return;
        setState(() {
          _info = i;
          _approval = null;
          _step = LinkStep.existingCompare;
        });
      });

  Future<void> _approve() => _guard(() async {
        final String a = await _svc.approveLinkRequest(_info!);
        if (!mounted) return;
        setState(() {
          _approval = a;
          _step = LinkStep.existingApproved;
        });
      });

  void _noMatch() {
    setState(() {
      _info = null;
      _requestIn.clear();
      _step = LinkStep.existingPaste;
      _message = 'Nothing was approved. On the new phone, make a new code and try again. '
          'If the codes still differ, do not approve: the code did not come from your phone.';
    });
  }

  Future<void> _reset() async {
    bool serverKey = false;
    try {
      serverKey = await _svc.accountHoldsServerKey();
    } catch (_) {
      serverKey = false; // offline: the reset itself will say so
    }
    if (!mounted) return;
    final bool ok = await showDsConfirm(context,
        title: 'Reset your encryption keys?',
        message: resetConfirmMessage(serverKey: serverKey),
        confirmLabel: 'Reset keys',
        destructive: true);
    if (!ok) return;
    await _guard(() async {
      final KeyResetResult r = await _svc.resetThisDevice();
      if (!mounted) return;
      final String? note = resetDoneMessage(r);
      // ignore: use_build_context_synchronously
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
      if (note != null) messenger.showSnackBar(SnackBar(content: Text(note)));
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final (List<Widget> body, List<Widget> actions) = switch (_step) {
      LinkStep.choose => _choose(),
      LinkStep.newStart => _newStart(),
      LinkStep.newWaiting => _newWaiting(),
      LinkStep.newDone => _done(
          'This phone is linked',
          'Your private circles open here in a moment. You can now use both phones.',
        ),
      LinkStep.existingPaste => _existingPaste(),
      LinkStep.existingCompare => _existingCompare(),
      LinkStep.existingApproved => _existingApproved(),
    };
    return PopScope(
      // Back inside the flow goes one step back, not out of the screen. On the
      // two steps that show a code, leaving asks first: the code is lost.
      canPop: _previous == null && !_holdsCode,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || _busy) return;
        final LinkStep? prev = _previous;
        if (prev != null) {
          _go(prev);
        } else if (_holdsCode) {
          _confirmLeave();
        }
      },
      child: DsPage(
        // A new step starts at the top, not where the last step's list was scrolled to.
        key: ValueKey<LinkStep>(_step),
        title: 'Link another phone',
        // The page gutter of the settings lists (16 dp, 12 narrow): one left edge with them.
        gutter: DsListRow.compactFor(context) ? AppSpace.md : AppSpace.lg,
        actions: actions,
        children: <Widget>[
          ...body,
          if (_message != null) DsMessage(_message!, key: const Key('link-message')),
        ],
      ),
    );
  }

  /// The new phone waiting for its answer, or the old phone about to hand
  /// the answer over: leaving loses a code the other phone is waiting for.
  bool get _holdsCode => _step == LinkStep.newWaiting || _step == LinkStep.existingApproved;

  Future<void> _confirmLeave() async {
    final bool leave = await showDsConfirm(
      context,
      title: 'Leave linking?',
      message: _step == LinkStep.newWaiting
          ? 'The code on this screen stops being useful. To link this phone you would make a new one.'
          : 'The answer on this screen is gone. Without it the new phone cannot finish; you would approve it again.',
      confirmLabel: 'Leave',
      cancelLabel: 'Stay',
    );
    if (leave && mounted) Navigator.of(context).pop();
  }

  /// The step Back returns to, or null when Back leaves the screen.
  LinkStep? get _previous {
    if (widget.role != null) {
      return switch (_step) {
        LinkStep.existingCompare => LinkStep.existingPaste,
        _ => null,
      };
    }
    return switch (_step) {
      LinkStep.newStart || LinkStep.existingPaste => LinkStep.choose,
      LinkStep.existingCompare => LinkStep.existingPaste,
      _ => null,
    };
  }

  (List<Widget>, List<Widget>) _choose() => (
        <Widget>[
          const DsHeading('Which phone is this?', compact: true,
              subtitle: 'Linking takes a minute. Keep both phones in front of you, signed in to the same account.'),
          DsRowGroup(children: <Widget>[
            DsListRow(
              key: const Key('link-choose-new'),
              leading: DsListRow.iconTile(context, Icons.phone_android, decorative: true),
              title: 'This is the new phone',
              subtitle: 'Make a code here, approve it there',
              chevron: true,
              onTap: () => _go(LinkStep.newStart),
            ),
            DsListRow(
              key: const Key('link-choose-existing'),
              leading: DsListRow.iconTile(context, Icons.verified_user_outlined, decorative: true),
              title: 'This is the phone I already use',
              subtitle: 'Approve a new phone with its code',
              chevron: true,
              onTap: () => _go(LinkStep.existingPaste),
            ),
          ]),
          const SizedBox(height: AppSpace.xxl),
          _NoOtherPhone(busy: _busy, onReset: _reset),
        ],
        const <Widget>[],
      );

  (List<Widget>, List<Widget>) _newStart() => (
        <Widget>[
          const DsHeading('Link this phone', compact: true,
              subtitle: 'Your other phone approves this one, so your private circles open here too.'),
          const _Steps(<String>[
            'Make a code on this phone.',
            'Send it to your other phone, for example in a message to yourself.',
            'Approve it there, then paste the answer here.',
          ]),
          const SizedBox(height: AppSpace.xxl),
          _NoOtherPhone(busy: _busy, onReset: _reset),
        ],
        <Widget>[
          DsBusyButton(
            key: const Key('link-make-code'),
            label: 'Make a code',
            icon: Icons.qr_code_2,
            busy: _busy,
            onPressed: _makeCode,
          ),
        ],
      );

  (List<Widget>, List<Widget>) _newWaiting() => (
        <Widget>[
          const DsHeading('Send this code to your other phone', compact: true,
              subtitle: 'On your other phone open Settings, Devices, Link another phone, '
                  'and choose "This is the phone I already use".'),
          _CodeCard(
            code: _request!,
            codeKey: const Key('link-request'),
            label: 'Code for your other phone',
            onCopy: () => _copy(_request!),
            onShare: () => _share(_request!),
          ),
          if (_ownShort != null) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            _CheckCode(short: _ownShort!, note: 'Your other phone will show the same check code.'),
          ],
          const SizedBox(height: AppSpace.xxl),
          const DsSectionHeader('Then paste the answer', padding: EdgeInsets.only(bottom: AppSpace.xs)),
          _CodeField(
            controller: _approvalIn,
            fieldKey: const Key('link-approval-in'),
            label: 'Answer from your other phone',
            onPaste: () => _paste(_approvalIn),
          ),
        ],
        <Widget>[
          DsBusyButton(
            key: const Key('link-finish'),
            label: 'Finish linking',
            icon: Icons.check,
            busy: _busy,
            onPressed: _approvalIn.text.trim().isEmpty ? null : _finishLinking,
          ),
        ],
      );

  (List<Widget>, List<Widget>) _existingPaste() => (
        <Widget>[
          const DsHeading('Approve a new phone', compact: true,
              subtitle: 'On the new phone open Settings, Devices, Link another phone and choose "This is the new phone". '
                  'Send yourself its code and paste it here.'),
          _CodeField(
            controller: _requestIn,
            fieldKey: const Key('link-request-in'),
            label: 'Code from the new phone',
            onPaste: () => _paste(_requestIn),
          ),
        ],
        <Widget>[
          DsBusyButton(
            key: const Key('link-check'),
            label: 'Continue',
            icon: Icons.arrow_forward,
            busy: _busy,
            onPressed: _requestIn.text.trim().isEmpty ? null : _checkRequest,
          ),
        ],
      );

  (List<Widget>, List<Widget>) _existingCompare() {
    final LinkRequestInfo info = _info!;
    return (
      <Widget>[
        const DsHeading('Check it is your phone', compact: true,
            subtitle: 'Look at the new phone. Approve only if it shows the same check code.'),
        _CheckCode(short: info.short, shortKey: const Key('link-short')),
        const SizedBox(height: AppSpace.lg),
        _Details(children: <Widget>[
          Text('Long check number (the new phone shows it under Encryption keys, Advanced):',
              style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: AppSpace.xs),
          SelectableText(info.digits, key: const Key('link-digits'), style: AppType.body.copyWith(fontFamily: 'monospace')),
        ]),
      ],
      <Widget>[
        DsBusyButton(
          key: const Key('link-approve'),
          label: 'They match: approve',
          icon: Icons.verified_user,
          busy: _busy,
          onPressed: _approve,
        ),
        DsPillButton(
          key: const Key('link-no-match'),
          label: 'They are different',
          style: DsPillStyle.outlined,
          onPressed: _busy ? null : _noMatch,
        ),
      ],
    );
  }

  (List<Widget>, List<Widget>) _existingApproved() => (
        <Widget>[
          const DsHeading('Approved. One last step', compact: true,
              subtitle: 'Send this answer to the new phone and paste it there under "Then paste the answer".'),
          _CodeCard(
            code: _approval!,
            codeKey: const Key('link-approval'),
            label: 'Answer for the new phone',
            onCopy: () => _copy(_approval!),
            onShare: () => _share(_approval!),
          ),
        ],
        <Widget>[
          DsPillButton(
            key: const Key('link-done'),
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );

  (List<Widget>, List<Widget>) _done(String title, String text) => (
        <Widget>[
          const SizedBox(height: AppSpace.xxl),
          Icon(Icons.check_circle, size: 64, color: BrandTheme.of(context).accentInk),
          const SizedBox(height: AppSpace.lg),
          DsHeading(title, subtitle: text, center: true, compact: true),
        ],
        <Widget>[
          DsPillButton(
            key: const Key('link-done'),
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
}

/// Numbered steps, plain text.
class _Steps extends StatelessWidget {
  const _Steps(this.steps);
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: brand.accent.withValues(alpha: 0.18), shape: BoxShape.circle),
                  child: Text('${i + 1}', style: AppType.label.copyWith(color: brand.accentInk)),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(steps[i], style: AppType.body),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A long code shown in full, readable and selectable, with Copy and Share,
/// and a QR code on request (any camera app can read it on the other phone).
class _CodeCard extends StatefulWidget {
  const _CodeCard({required this.code, required this.codeKey, required this.label, required this.onCopy, required this.onShare});
  final String code;
  final Key codeKey;
  final String label;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  State<_CodeCard> createState() => _CodeCardState();
}

class _CodeCardState extends State<_CodeCard> {
  bool _qr = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: BrandTheme.of(context).sheet,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(widget.label, style: AppType.label.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: AppSpace.sm),
            Semantics(
              label: widget.label,
              child: SelectableText(
                widget.code,
                key: widget.codeKey,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
            if (_qr) ...<Widget>[
              const SizedBox(height: AppSpace.md),
              Center(
                child: Semantics(
                  label: 'QR code of the ${widget.label.toLowerCase()}',
                  child: Container(
                    key: const Key('link-qr'),
                    color: Colors.white,
                    padding: const EdgeInsets.all(AppSpace.sm),
                    child: QrImageView(data: widget.code, size: 220),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: <Widget>[
                DsPillButton(key: const Key('link-copy'), label: 'Copy', icon: Icons.copy, style: DsPillStyle.tonal, onPressed: widget.onCopy),
                DsPillButton(key: const Key('link-share'), label: 'Share', icon: Icons.share, style: DsPillStyle.outlined, onPressed: widget.onShare),
                DsPillButton(
                  key: const Key('link-qr-toggle'),
                  label: _qr ? 'Hide QR code' : 'QR code',
                  icon: Icons.qr_code,
                  style: DsPillStyle.outlined,
                  onPressed: () => setState(() => _qr = !_qr),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The short check code, large, for comparing two screens side by side.
class _CheckCode extends StatelessWidget {
  const _CheckCode({required this.short, this.note, this.shortKey});
  final String short;
  final String? note;
  final Key? shortKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Check code $short',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          children: <Widget>[
            Text('Check code', style: AppType.label.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: AppSpace.xs),
            Text(short, key: shortKey, style: AppType.title.copyWith(fontSize: 28, letterSpacing: 2, fontFamily: 'monospace')),
            if (note != null) ...<Widget>[
              const SizedBox(height: AppSpace.xs),
              Text(note!, textAlign: TextAlign.center, style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// A text field for a pasted code, with a Paste button.
class _CodeField extends StatelessWidget {
  const _CodeField({required this.controller, required this.fieldKey, required this.label, required this.onPaste});
  final TextEditingController controller;
  final Key fieldKey;
  final String label;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      minLines: 1,
      maxLines: 3,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          tooltip: 'Paste',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.content_paste),
          onPressed: onPaste,
        ),
      ),
    );
  }
}

/// Technical details, folded away.
class _Details extends StatelessWidget {
  const _Details({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('link-details'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpace.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: const Text('Details', style: AppType.body),
        children: children,
      ),
    );
  }
}

/// The way out when no other phone is available, folded away so it never
/// competes with the normal path. The reset itself is one quiet row inside
/// the fold, not a red button.
class _NoOtherPhone extends StatelessWidget {
  const _NoOtherPhone({required this.busy, required this.onReset});
  final bool busy;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final double inset = DsRowScope.insetFor(context);
    final Color line = Theme.of(context).colorScheme.outlineVariant;
    return DsRowGroup(children: <Widget>[
      Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          // Title on the same x as the rows above: tile (40) + 12.
          listTileTheme: Theme.of(context).listTileTheme.copyWith(horizontalTitleGap: AppSpace.md, minLeadingWidth: 40),
        ),
        child: ExpansionTile(
          key: const Key('link-no-other-phone'),
          tilePadding: EdgeInsets.symmetric(horizontal: inset),
          leading: DsListRow.compactFor(context)
              ? null
              : DsListRow.iconTile(context, Icons.help_outline, decorative: true),
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: const Text('No other phone?', style: AppType.body),
          children: <Widget>[
            Divider(height: 1, indent: inset, color: line),
            Padding(
              padding: EdgeInsets.fromLTRB(inset, AppSpace.md, inset, AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'If you have your recovery phrase, go back to Encryption keys and restore with it instead.',
                    style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Without your other phone or the phrase you can start over with new keys: everyone you share a '
                    'private circle with sees that your keys changed, and a circle admin must approve this phone '
                    'before it can read anything.',
                    style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Divider(height: 1, indent: inset, color: line),
            DsListRow(
              key: const Key('link-reset'),
              leading: DsListRow.iconTile(context, Icons.restart_alt, color: AppColors.sosRed, decorative: true),
              title: 'Reset my keys',
              subtitle: 'Start over with new keys',
              destructive: true,
              chevron: true,
              onTap: busy ? null : onReset,
            ),
          ],
        ),
      ),
    ]);
  }
}

/// The reset confirmation. [serverKey]: this account holds the key the server uses (it approved the server), so
/// the reset removes that key too.
String resetConfirmMessage({required bool serverKey}) {
  const String base = 'Your old keys are revoked. Encrypted data you could not read yet stays unreadable to you. '
      'Members must approve your new key.';
  if (!serverKey) return base;
  return '$base\n\nThis also removes the key your Orbitly server uses. The server makes a new key right away and '
      'this phone approves it for you, so you are not asked to approve the server again.';
}

/// What to tell the person after a reset; null when there is nothing about the server to say.
String? resetDoneMessage(KeyResetResult r) {
  if (!r.serverKeyRevoked) return null;
  if (r.serverRejoined) return 'Keys reset. This phone approved your server\'s new key.';
  return 'Keys reset. Your server has a new key: approve it under "Your server wants to join".';
}
