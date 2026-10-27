import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'alerts_history_screen.dart';
import 'check_in_screen.dart';
import 'crash_reports_screen.dart';
import 'help_alert_screen.dart';
import 'safety_screen.dart';
import 'sos_screen.dart';

/// The Safety tab: SOS first, then check-in, help alerts, alert history and
/// emergency contacts. Each row opens the existing screen unchanged.
class SafetyHubScreen extends StatelessWidget {
  const SafetyHubScreen({super.key});

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety'),
        centerTitle: false,
        titleTextStyle: AppType.title.copyWith(color: cs.onSurface),
      ),
      body: DsBody(child: ListView(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl,
              AppSpace.sm,
              AppSpace.xl,
              AppSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'In an emergency, tell your circle right away.',
                  style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpace.md),
                DsPillButton(
                  label: 'Send SOS',
                  icon: Icons.warning_amber_rounded,
                  style: DsPillStyle.danger,
                  onPressed: () => _push(context, const SosScreen()),
                  semanticLabel: 'Send an SOS to your family',
                ),
              ],
            ),
          ),
          const DsSectionHeader('Let people know'),
          DsListRow(
            title: 'Check in',
            subtitle: 'Share where you are with your circle',
            leading: DsListRow.iconTile(context, Icons.check_circle_outline),
            chevron: true,
            onTap: () => _push(context, const CheckInScreen()),
          ),
          DsListRow(
            title: 'Help alert',
            subtitle: 'Ask your circle for help',
            leading: DsListRow.iconTile(
              context,
              Icons.campaign_outlined,
              color: AppColors.statusOrange,
            ),
            chevron: true,
            onTap: () => _push(context, const HelpAlertScreen()),
          ),
          const DsSectionHeader('Driving safety'),
          DsListRow(
            title: 'Crash reports',
            subtitle: 'Possible crashes detected for you and your circle',
            leading: DsListRow.iconTile(
              context,
              Icons.car_crash_outlined,
              color: AppColors.sosRed,
            ),
            chevron: true,
            onTap: () => _push(context, const CrashReportsScreen()),
          ),
          const DsSectionHeader('Records and contacts'),
          DsListRow(
            title: 'Alert history',
            subtitle: 'Past SOS, help and check-in alerts',
            leading: DsListRow.iconTile(context, Icons.history),
            chevron: true,
            onTap: () => _push(context, const AlertsHistoryScreen()),
          ),
          DsListRow(
            title: 'Emergency contacts',
            subtitle: 'People who are texted when you send an SOS',
            leading: DsListRow.iconTile(context, Icons.contact_phone_outlined),
            chevron: true,
            onTap: () => _push(context, const SafetyScreen()),
          ),
          const SizedBox(height: AppSpace.xxl),
        ],
      )),
    );
  }
}
