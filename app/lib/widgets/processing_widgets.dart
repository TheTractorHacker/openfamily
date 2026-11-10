import 'package:flutter/material.dart';

import '../services/api_client.dart' show ApiException;
import '../services/e2ee/e2ee_service.dart' show LocalKeyException, localKeyProblemOf;
import '../services/e2ee/private_channel.dart' show ProcessingBadge;
import '../theme/app_theme.dart';
import 'ds/ds.dart';

// Shared copy and small widgets of the "where is my data processed" feature
// (docs/design/PRIVACY_PROCESSING.md 10.3). All wording lives here so it can be
// reviewed in one place. Rules for the wording:
//  * say who can read what, plainly; no "military grade" style claims;
//  * never quote battery or speed numbers (they are not measured);
//  * always say that metadata stays visible and that other circles are separate.

class ProcessingCopy {
  ProcessingCopy._();

  static const String metadata =
      'Opting out protects what your location and trips say. It does not hide that you are a member, when your phone '
      'connects to the server or roughly how much it uploads.';

  static const String multiCircle =
      'This applies to this circle only. If you are also in a normal circle (not Private), that circle still sends your '
      'position to the server, and a Private circle where you allowed the server is readable there.';

  static const String operatorCanRead =
      'Anyone who runs or backs up this server can read the data of members who allow server processing.';

  // ---- admin: turn on
  static const String turnOnTitle = 'Turn on server processing for this circle?';
  static const String turnOnBody =
      'The Orbitly server will be able to read the location, trips and driving data of members who allow it, and it '
      'stores that data in readable form. It enables the admin map, history, trips, weekly summaries and Dawarich export '
      'for those members.\n\n'
      'Members are on the server by default: each member\'s own phone switches it on the next time they open the app and '
      'shows them a notice. Each member decides for themselves and can switch it off; members who do keep end-to-end '
      'encryption and their phone does the processing. You cannot change another member\'s choice.\n\n$operatorCanRead';

  static const String turnOffTitle = 'Turn off server processing?';
  static const String turnOffBody =
      'Every member\'s choice to use the server ends. From now on all members\' phones seal data for phones only and do the '
      'processing themselves. Copies the server already holds are not deleted automatically; you can delete them '
      'afterwards. Backups and anything already exported cannot be deleted.';

  static const String requiredTitle = 'Require server processing?';
  static const String requiredBody =
      'Everyone\'s phone sends its location to your Orbitly server for processing. Members cannot turn it off.\n\n'
      'Each member\'s own phone signs this by itself the next time it runs; nobody is asked and a phone '
      'that has not switched over yet cannot send positions until it has (check-ins, events and chat are not affected). Members see a notice that '
      'you require it. Every change is a signed entry in the key log that all members can see.\n\n$operatorCanRead';

  /// The one owner switch on the circle settings screen.
  static const String requireSwitchTitle = 'Require server processing';
  static const String requireSwitchBody =
      'Everyone\'s phone sends its location to your Orbitly server for processing. Members cannot turn it off.';

  /// The one line under the owner switch; [requireSwitchBody] is behind its (i).
  static const String requireSwitchShort = 'Location goes to your server. Members cannot turn it off.';

  /// What a member sees when the admin requires it.
  static const String requiredNoticeTitle = 'Your family admin requires server processing.';
  static const String requiredNoticeBody =
      'Your phone sends your location to your Orbitly server for processing. Members cannot turn it off. $operatorCanRead';
  static const String requiredCatchingUp =
      'Your phone is switching over by itself. Until it has, positions from this phone are not delivered (check-ins and emergency alerts still are). If this does not clear up soon, update the app.';

  /// A member whose phone has not switched over yet while the admin requires it.
  static const String catchingUp = 'Catching up';
  static const String catchingUpInfo =
      'Their phone signs the choice the next time it runs. Until then their positions may not arrive (check-ins and emergency alerts still do). An app that is too old needs an update first.';

  // ---- member: opt out / opt in
  static const String optOutTitle = 'Keep your data on your phone only?';
  static const String optOutBody =
      'Your location stays encrypted. The server will no longer be able to read it. Your phone will do the work instead:\n'
      '- It may use more battery and some mobile data.\n'
      '- Trips, driving reports and weekly summaries are calculated on your phone and shared with the circle once your '
      'phone has done it. They can arrive late if your phone is off.\n'
      '- Some things are only as good as your phone can compute them, and some will be limited: place names, the admin '
      'map, live-share links, "request location" when your phone is asleep, and the server\'s Dawarich export will not '
      'include you.\n\n'
      'Others in the circle can still see your data. $metadata\n\n$multiCircle';
  static const String deleteCopiesLabel =
      'Also delete my existing copies from the server (recommended). Backups and anything already exported cannot be deleted.';

  static const String optInTitle = 'Let the server process your data?';
  static const String optInBody =
      'The server will be able to read your location, trips and driving data and stores a readable copy. This turns on the '
      'admin map, history, trips, driving reports and weekly summaries without using your phone to compute them. '
      '$operatorCanRead\n\nYou can switch back at any time. Copies the server already made stay until you delete them.';

  static const String phoneWorkNote =
      'Your phone computes trips, driving reports and weekly summaries and shares them sealed. It may use more battery and '
      'some mobile data, and results can arrive late if your phone is off.';

  static const String adminOnly = 'Only a circle admin can change these settings. You can see them here, and you decide for your own data below.';

  // ---- legacy upgrade
  static const String upgradeTitle = 'Upgrade this circle?';
  static const String upgradeBody =
      'This circle uses the old trusted-server mode: the server holds the circle key and can read everything up to now.\n\n'
      '- Everything up to now stays readable by the server.\n'
      '- A new circle key is made that the server does not get.\n'
      '- Nobody is carried over. After the upgrade EVERY member must open the app and sign their own choice again '
      '(server processing or phone only). A member\'s data reaches the server only after they have done that.\n'
      '- Until each member has signed, the server-side features for that member pause: admin map, history, trips, driving '
      'reports, weekly summary and Dawarich export. Their phone keeps everything working in the app meanwhile.\n'
      '- Every member needs the latest app. The upgrade cannot be undone.\n\n$operatorCanRead';
  static const String legacyStatusTitle = 'Old trusted-server mode';
  static const String legacyStatusBody =
      'The server holds the circle key of this circle and can read it, and it keeps readable copies, while every member has '
      'allowed it. This is NOT end-to-end encryption against the server. An admin can upgrade the circle so each member decides for themselves.';
  static const String endLegacyTitle = 'End the server\'s access to old data?';
  static const String endLegacyBody =
      'After this the server can no longer open any data of the old circle key. Do this only when the server has already '
      'processed the history you need. It cannot be undone. Plain copies the server already made stay until they are deleted.';
}

/// "Processed by server" / "Phone only" / "Not confirmed" chip. Colours: the app accent for the server (the normal,
/// recommended mode, so never amber), a calm blue for phone only, neutral grey for undecided, red only when a lane
/// could not be confirmed.
class ProcessingBadgeChip extends StatelessWidget {
  const ProcessingBadgeChip({super.key, required this.badge});
  final ProcessingBadge badge;

  @override
  Widget build(BuildContext context) {
    switch (badge) {
      case ProcessingBadge.serverAssisted:
        return const DsStatusChip(label: 'Processed by server', icon: Icons.dns_outlined, color: AppColors.accentInk);
      case ProcessingBadge.phoneOnly:
        return const DsStatusChip(label: 'Phone only', icon: Icons.smartphone, color: AppColors.sky);
      case ProcessingBadge.unverified:
        return const DsStatusChip(label: 'Not confirmed', icon: Icons.help_outline, color: AppColors.statusRed);
    }
  }
}

/// Neutral chip for a member whose phone is still switching over to what the admin requires (its positions wait until it has).
class CatchingUpChip extends StatelessWidget {
  const CatchingUpChip({super.key});
  @override
  Widget build(BuildContext context) =>
      const DsStatusChip(label: ProcessingCopy.catchingUp, icon: Icons.sync, color: AppColors.statusGrey);
}

/// The words of a lane chip (true = server), for a second line where a chip would not fit.
String laneLabel(bool server) => server ? 'Processed by server' : 'Phone only';

/// Chip for a member lane (true = server).
class LaneChip extends StatelessWidget {
  const LaneChip({super.key, required this.server});
  final bool server;
  @override
  Widget build(BuildContext context) =>
      ProcessingBadgeChip(badge: server ? ProcessingBadge.serverAssisted : ProcessingBadge.phoneOnly);
}

/// For the person's own phone-only state on report screens: what it means and two ways forward.
class PhoneOnlyActions extends StatelessWidget {
  const PhoneOnlyActions({super.key, required this.onUseServer, required this.onComputeOnPhone});
  final VoidCallback onUseServer, onComputeOnPhone;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('phone-only-actions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: AppSpace.sm),
        Text('Your data stays on this phone, so the server cannot make a driving report for you.', style: AppType.secondary),
        const SizedBox(height: AppSpace.sm),
        Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: <Widget>[
          DsPillButton(key: const Key('use-the-server'), label: 'Use the server', icon: Icons.dns_outlined, onPressed: onUseServer),
          DsPillButton(
              key: const Key('compute-on-phone'),
              label: 'Compute reports on this phone (uses battery)',
              style: DsPillStyle.outlined,
              onPressed: onComputeOnPhone),
        ]),
      ],
    );
  }
}

String sinceText(DateTime at, DateTime now) {
  final Duration d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// Shown instead of figures of a phone-only member whose phone has not shared a result yet.
class WaitingForPhoneCard extends StatelessWidget {
  const WaitingForPhoneCard({super.key, required this.name, this.onUseServer, this.onComputeOnPhone});
  final String name;

  /// Only for the person's own card.
  final VoidCallback? onUseServer, onComputeOnPhone;

  bool get own => onUseServer != null && onComputeOnPhone != null;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: own ? 'Your driving report is not switched on' : 'Waiting for $name\'s phone',
      child: Container(
        key: Key('waiting-phone-$name'),
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: Text(name, style: AppType.headline)),
            const LaneChip(server: false),
          ]),
          const SizedBox(height: AppSpace.sm),
          if (own) ...<Widget>[
            Text('Your driving report is not switched on', style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
            Text(
              'Your location stays on this phone, so the server has no drives to count for you yet. '
              'Choose how you would like your driving report made.',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ] else ...<Widget>[
            Text('Waiting for $name\'s phone', style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
            Text(
              '$name keeps data on their phone and it has not shared a summary yet (it may be off or not have moved).',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (onUseServer != null && onComputeOnPhone != null)
            PhoneOnlyActions(onUseServer: onUseServer!, onComputeOnPhone: onComputeOnPhone!),
        ]),
      ),
    );
  }
}

/// One line under figures computed on a phone: "Computed on Alex's phone. Updated 2 h ago."
class ComputedOnPhoneNote extends StatelessWidget {
  const ComputedOnPhoneNote({super.key, required this.name, this.updatedAt, this.now});
  final String name;
  final DateTime? updatedAt;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final String when = updatedAt == null ? '' : ' Updated ${sinceText(updatedAt!, now ?? DateTime.now())}.';
    return Text('Computed on $name\'s phone.$when',
        key: const Key('computed-on-phone'),
        style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
  }
}

/// A bordered explanation block with an icon.
class ProcessingNote extends StatelessWidget {
  const ProcessingNote({super.key, required this.icon, required this.text, this.color, this.noteKey});
  final IconData icon;
  final String text;
  final Color? color;
  final Key? noteKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: noteKey,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: (color ?? cs.surfaceContainerHighest).withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Icon(icon, size: 20, color: cs.onSurfaceVariant),
        const SizedBox(width: AppSpace.sm),
        Expanded(child: Text(text, style: AppType.secondary.copyWith(color: cs.onSurface))),
      ]),
    );
  }
}

/// A load or action failure of the server processing screens, in plain words: what went wrong and what to do.
class ProcessingErrorText {
  const ProcessingErrorText(this.title, this.message, {this.offline = false, this.icon = Icons.error_outline});
  final String title;
  final String message;
  final bool offline;
  final IconData icon;
}

/// The messages [ApiClient] uses for "no answer at all" (status 0 also covers "the answer could not be read").
bool _noConnection(ApiException e) =>
    e.status == 0 && (e.message.startsWith('Could not reach the server') || e.message.contains('timed out'));

/// Specific, plain words for [e]; never "Something went wrong". [step] names what this screen was doing.
ProcessingErrorText processingErrorText(Object e, {String step = "Could not check this circle's server processing settings."}) {
  if (e is ApiException) {
    if (_noConnection(e)) {
      return const ProcessingErrorText('No connection', 'You appear to be offline. Try again when this phone is back online.',
          offline: true, icon: Icons.cloud_off);
    }
    if (e.status == 0) return ProcessingErrorText("The server's answer could not be read", '$step ${e.message}');
    if (e.status == 429) return const ProcessingErrorText('Please wait a moment', 'Too many requests. Wait a minute and try again.');
    if (e.status >= 500) return const ProcessingErrorText('The server had a problem', 'The server had a problem. Try again shortly.');
    if (e.status == 403 && e.message.toLowerCase().contains('approv')) {
      return const ProcessingErrorText('Waiting for approval',
          'This phone is waiting to be approved in this circle. A circle admin approves it once; pull down to check again after that.',
          icon: Icons.hourglass_top);
    }
    if (e.status == 404) {
      return const ProcessingErrorText('Circle not found', 'This circle could not be found. You may have left it or it was deleted.');
    }
    return ProcessingErrorText('Could not load server processing', '$step The server said: ${e.message}');
  }
  final LocalKeyException? k = localKeyProblemOf(e);
  if (k != null) return ProcessingErrorText("This phone's encryption key cannot be opened right now", k.message, icon: Icons.key_off_outlined);
  if (e is StateError && e.message.toLowerCase().contains('approv')) {
    return const ProcessingErrorText('Waiting for approval',
        'This phone is waiting to be approved in this circle. A circle admin approves it once; pull down to check again after that.',
        icon: Icons.hourglass_top);
  }
  if (e is StateError && e.message.isNotEmpty) return ProcessingErrorText('Could not finish', e.message);
  if (e is FormatException || e is TypeError) {
    // A reply that is not what this app expects (a server that was busy or is being updated): not a connection problem.
    return ProcessingErrorText("The server's answer could not be read", '$step The server sent something this app did not expect. Try again in a moment.');
  }
  return ProcessingErrorText('Could not load server processing',
      '$step Your position is never sent unencrypted meanwhile. Try again in a moment.');
}
