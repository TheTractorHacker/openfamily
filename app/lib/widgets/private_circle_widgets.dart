import 'package:flutter/material.dart';

import '../services/e2ee/private_runtime.dart';
import '../theme/app_theme.dart';

/// Small chip shown on the map/circle header of a Private (end-to-end
/// encrypted) circle. Honest wording: members' phones can read positions, the
/// server cannot.
class PrivateCircleBadge extends StatelessWidget {
  const PrivateCircleBadge({super.key, this.compact = false, this.serverMember = false, this.serverAssist = false});

  /// Trusted-server mode: the server holds a key too, so say so instead of
  /// "End-to-end encrypted".
  final bool serverMember;

  /// Per-member processing is on (lanes circle): members who chose the server
  /// lane are readable by the server, so "End-to-end encrypted" for the whole
  /// circle would be wrong. Say "Private" plus "server helps" instead.
  final bool serverAssist;

  /// Icon plus short label only (for tight rows).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Semantics(
      label: serverMember
          ? 'Private circle with a trusted server member. The Orbitly server can read locations in this circle.'
          : serverAssist
              ? 'Private circle with server help. The server can read the data of members who use the server; '
                  'members who keep data on their phone stay end-to-end encrypted.'
              : 'End-to-end encrypted circle. The server cannot read locations in this circle.',
      child: Container(
        key: const ValueKey<String>('private-circle-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: brand.sheet,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: brand.accentInk.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(serverMember || serverAssist ? Icons.dns_outlined : Icons.lock_outline, size: 15, color: brand.accentInk),
            const SizedBox(width: 5),
            Text(
              serverMember
                  ? (compact ? 'Server can read' : 'Server can read (trusted server)')
                  : serverAssist
                      ? (compact ? 'Private + server' : 'Private, server helps some')
                      : (compact ? 'Encrypted' : 'End-to-end encrypted'),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: brand.accentInk),
            ),
          ],
        ),
      ),
    );
  }
}

/// The features that need the server to read positions. In a Private circle
/// each shows an explicit "not available" state instead of an empty or broken
/// screen.
enum PrivateFeature {
  trips('Trips', 'Trips are built on the server from every location point. In a Private circle the server cannot read them.'),
  drivingReport('Driving report', 'The driving report is computed on the server from location points. It is not available in a Private circle yet.'),
  weeklySummary('Weekly summary', 'The weekly summary is computed on the server from location history. It is not available in a Private circle yet.'),
  adminMap('Admin map', 'The administrator map shows positions the server holds. A Private circle holds none, so it never appears there.'),
  dawarich('Dawarich export', 'Dawarich export forwards positions from the server. It is not available for a Private circle in this release.'),
  serverPlaces('Server place alerts', 'Arrival and departure alerts for a Private circle are worked out on each person\'s phone instead of the server.');

  const PrivateFeature(this.title, this.explanation);
  final String title;
  final String explanation;
}

/// "Not available in Private circles" placeholder for a whole screen or panel.
class NotAvailableInPrivate extends StatelessWidget {
  const NotAvailableInPrivate({super.key, required this.feature, this.circleName});

  final PrivateFeature feature;
  final String? circleName;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.lock_outline, size: 40, color: brand.accentInk),
            const SizedBox(height: 12),
            Text(
              '${feature.title} is not available in Private circles',
              key: const ValueKey<String>('not-available-title'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              circleName == null ? feature.explanation : '${feature.explanation}\n\nCircle: $circleName',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows [builder] normally, or the explicit "not available" state while the
/// primary circle is Private (these screens are computed by the server from
/// plaintext positions, which a Private circle does not have).
class PrivateFeatureGate extends StatelessWidget {
  const PrivateFeatureGate({super.key, required this.feature, required this.builder});

  final PrivateFeature feature;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PrivateRuntime.primaryPrivate,
      builder: (BuildContext context, bool isPrivate, _) {
        if (!isPrivate) return builder(context);
        return Scaffold(
          appBar: AppBar(title: Text(feature.title)),
          body: SafeArea(child: NotAvailableInPrivate(feature: feature)),
        );
      },
    );
  }
}
