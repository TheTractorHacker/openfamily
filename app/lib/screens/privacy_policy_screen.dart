import 'package:flutter/material.dart';

/// Available offline and before sign-in so users can review data handling
/// before connecting to a server or granting location permission.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const sections = <(String, String)>[
    (
      'Your server and its operator',
      'OpenFamily is a self-hosted family location app. Your chosen server '
          'operator controls the account and location data stored on that server. '
          'Ask the operator about their contact details, backups, retention and '
          'any additional privacy terms before joining. OpenFamily does not '
          'provide a hosted location service. The app requires an HTTPS server '
          'address and will not connect to servers over unencrypted HTTP.'
    ),
    (
      'Information collected',
      'The app sends your email, display name, optional phone number and '
          'profile photo, family membership, device information and push endpoint '
          'to your configured server. When location sharing is enabled, it '
          'collects and sends precise location, timestamps, accuracy, battery '
          'level and movement information, including when the app is closed or '
          'not in use. Saved places, alert notes and optional emergency contacts '
          'are also stored on the server.'
    ),
    (
      'How location is used and shared',
      'Location supports the family map, location history, arrival and '
          'departure alerts, check-ins and help/SOS alerts. Family members and '
          'the server administrator can view shared locations. If the operator '
          'enables SMS, emergency contacts can receive SOS share links. SOS does '
          'not contact emergency services.'
    ),
    (
      'Other service providers',
      'By default, OpenStreetMap street tiles and Esri satellite tiles '
          'receive map requests, including the area you view and your IP '
          'address. Your operator can configure other providers or self-host '
          'tiles; custom map tile URLs must use HTTPS. Android notifications use ntfy or another UnifiedPush '
          'distributor. Optional Twilio SMS processes destination phone numbers '
          'and alert share links. On iOS, push notifications use Apple APNs.'
    ),
    (
      'Retention and deletion',
      'The standard server retains detailed location history for 90 days. '
          'The last known location remains until account deletion. Alert share '
          'links expire after 24 hours. You can delete your account in Settings '
          '→ Delete account. If you are the last administrator of a family with '
          'other members, first promote another administrator. Contact your '
          'server operator to request deletion without the app, resolve access '
          'issues, or ask about backups and retained audit records. Shared '
          'family places and records belonging to other members may remain.'
    ),
    (
      'Your controls and security',
      'Turn off Location sharing in Settings to stop this device reporting '
          'its location. You can also revoke Android location permissions, '
          'manage notifications, change your profile or log out. OpenFamily '
          'only connects to HTTPS servers, encrypting network traffic in transit. Locations are readable '
          'by the server; they are not end-to-end encrypted. Optional biometric '
          'unlock protects access to the app interface. OpenFamily contains no '
          'advertising, analytics or crash-reporting SDK.'
    ),
    (
      'Contact and policy updates',
      'For access, correction or deletion of server data, contact the '
          'administrator who provided your server address or invitation. '
          'The OpenFamily software publisher can be reached at '
          'info@foleyit.com for app support, but cannot directly access '
          'or erase data on a self-hosted server. Public privacy policy and '
          'account deletion instructions: https://foleyit.com/privacy.html '
          'and https://foleyit.com/delete-account.html. Do not post private '
          'locations, passwords or account details in public project discussions.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('OpenFamily privacy policy',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Updated October 17, 2026'),
          const SizedBox(height: 24),
          for (final section in sections) ...[
            Text(section.$1, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(section.$2),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}
