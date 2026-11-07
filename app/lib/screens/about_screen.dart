import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../brand.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/openfamily_brand.dart';

/// Settings > About: name, versions, the credit to the upstream project and the
/// AGPL-3.0 source offer. Kept in its own file so the credit does not depend on
/// any other screen.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  /// Registers the Orbitly / OpenFamily notice with Flutter's licence page.
  static void registerLicenses() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(<String>[Brand.name], '''
Orbitly is licensed under the GNU Affero General Public License v3.0.
It is a substantially extended fork of OpenFamily by wheresfrank and contributors
(${Brand.upstreamUrl}), also under the AGPL-3.0. Upstream copyright notices are kept.

Source code of this version: ${Brand.sourceUrl}
Users who interact with a running Orbitly server over a network may obtain the
Corresponding Source of the version that server runs from that address.

Includes a modified copy of background_locator_2 (MIT; Copyright 2020 REKAB,
Copyright 2022 Yukams).''');
    });
  }

  static bool _registered = false;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _app = '';
  String _server = '';

  @override
  void initState() {
    super.initState();
    AboutScreen.registerLicenses();
    _load();
  }

  Future<void> _load() async {
    String app = '';
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      app = info.version;
    } catch (_) {}
    String server = '';
    try {
      final dynamic r = await ApiClient.get('/version');
      final dynamic v = r is Map ? r['version'] : null;
      if (v is String && v.isNotEmpty) server = v;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _app = app;
      _server = server;
    });
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DsPage(
      title: 'About',
      children: <Widget>[
        const Center(child: OpenFamilyMark(size: 88)),
        const SizedBox(height: AppSpace.md),
        const Center(child: Text(Brand.name, style: AppType.title)),
        const SizedBox(height: AppSpace.xs),
        Center(
          child: Text(
            Brand.tagline,
            style: AppType.body.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.phone_android_outlined),
          title: 'App version',
          subtitle: _app.isEmpty ? 'Unknown' : _app,
        ),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.dns_outlined),
          title: 'Server version',
          subtitle: _server.isEmpty ? 'Not reported' : _server,
        ),
        const DsSectionHeader('Credits and license'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: SelectableText(
            '${Brand.upstreamCredit}. ${Brand.name} is free software under the '
            '${Brand.licenseName}. Everyone who uses an ${Brand.name} server may '
            'get the source code of the version it runs.',
            style: AppType.body.copyWith(height: 1.5),
          ),
        ),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.code),
          title: 'Source code (${Brand.name})',
          subtitle: '${Brand.sourceUrl}\nTap to copy the link',
          onTap: () => _copy('Source code', Brand.sourceUrl),
        ),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.favorite_outline),
          title: 'Original project (${Brand.upstreamName})',
          subtitle: '${Brand.upstreamUrl}\nTap to copy the link',
          onTap: () => _copy('${Brand.upstreamName} project', Brand.upstreamUrl),
        ),
        DsListRow(
          leading: DsListRow.iconTile(context, Icons.description_outlined),
          title: 'Open-source licenses',
          chevron: true,
          onTap: () => showLicensePage(
            context: context,
            applicationName: Brand.name,
            applicationVersion: _app.isEmpty ? null : _app,
            applicationLegalese:
                '${Brand.upstreamCredit}\n${Brand.sourceUrl}',
          ),
        ),
      ],
    );
  }
}
