import 'package:flutter/material.dart';

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
      'Each member decides for themselves. Members who say no keep end-to-end encryption and their phone does the '
      'processing. You cannot change another member\'s choice.\n\n$operatorCanRead';

  static const String turnOffTitle = 'Turn off server processing?';
  static const String turnOffBody =
      'Every member\'s choice to use the server ends. From now on all members\' phones seal data for phones only and do the '
      'processing themselves. Copies the server already holds are not deleted automatically; you can delete them '
      'afterwards. Backups and anything already exported cannot be deleted.';

  static const String requiredTitle = 'Require server processing?';
  static const String requiredBody =
      'Members will no longer be able to keep their data on their phone in this circle. New members see this before they '
      'join. Existing members are asked to give their own consent or leave the circle; until they do, their phone sends '
      'nothing to this circle (except help requests).\n\n'
      'Only a member\'s own phone can put their data on the server. You cannot do it for them, and every change is a signed '
      'entry in the key log that all members can see.\n\n$operatorCanRead';

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

/// "Processed by server" / "Phone only" / "Not chosen yet" chip. Colours: the app accent for the server (the normal,
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

/// Neutral chip for a member who has not made a choice yet (their data stays on their phone until they do).
class NotChosenChip extends StatelessWidget {
  const NotChosenChip({super.key});
  @override
  Widget build(BuildContext context) =>
      const DsStatusChip(label: 'Not chosen yet', icon: Icons.hourglass_empty, color: AppColors.statusGrey);
}

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

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Waiting for $name\'s phone',
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
          Text('Waiting for $name\'s phone', style: AppType.body.copyWith(fontWeight: FontWeight.w700)),
          Text(
            '$name keeps data on their phone and it has not shared a summary yet (it may be off or not have moved).',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
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
