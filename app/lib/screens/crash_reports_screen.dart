import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Possible crashes detected from a sudden stop at driving speed, for you and
/// your circle. Detection is an estimate from phone sensors and GPS; it never
/// contacts emergency services.
class CrashReportsScreen extends StatefulWidget {
  const CrashReportsScreen({super.key});

  @override
  State<CrashReportsScreen> createState() => _CrashReportsScreenState();
}

class _Crash {
  _Crash(Map<String, dynamic> j)
    : id = '${j['id']}',
      name = '${j['name'] ?? ''}',
      mine = j['mine'] == true,
      at = DateTime.tryParse('${j['occurred_at']}')?.toLocal(),
      before = (j['speed_before_mps'] as num?)?.toDouble(),
      after = (j['speed_after_mps'] as num?)?.toDouble(),
      status = '${j['status']}';

  final String id;
  final String name;
  final bool mine;
  final DateTime? at;
  final double? before;
  final double? after;
  String status;
}

class _CrashReportsScreenState extends State<CrashReportsScreen> {
  final List<_Crash> _items = <_Crash>[];
  bool _loading = true;
  bool _enabled = true;
  bool _savingToggle = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dynamic r = await ApiClient.get('/crashes');
      final Map<String, dynamic> m = r is Map<String, dynamic>
          ? r
          : <String, dynamic>{};
      final List<dynamic> list = (m['crashes'] as List<dynamic>?) ?? <dynamic>[];
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(
            list.whereType<Map<String, dynamic>>().map((j) => _Crash(j)),
          );
        _enabled = m['detection_enabled'] != false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load crash reports. Check your connection.';
      });
    }
  }

  Future<void> _toggle(bool v) async {
    setState(() {
      _enabled = v;
      _savingToggle = true;
    });
    try {
      await ApiClient.putJson(
        '/crashes/settings',
        body: <String, dynamic>{'enabled': v},
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _enabled = !v);
      _snack('Could not save that setting.');
    }
    if (mounted) setState(() => _savingToggle = false);
  }

  Future<void> _mark(_Crash c, String status) async {
    try {
      await ApiClient.post(
        '/crashes/${Uri.encodeComponent(c.id)}/status',
        body: <String, dynamic>{'status': status},
      );
      if (mounted) setState(() => c.status = status);
    } catch (_) {
      _snack('Could not update that report.');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    const List<String> mo = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final int h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final String mm = t.minute.toString().padLeft(2, '0');
    return '${mo[t.month - 1]} ${t.day}, $h12:$mm ${t.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final UnitSystem u = UnitPreferenceService.units.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crash reports'),
        centerTitle: false,
        titleTextStyle: AppType.title.copyWith(color: cs.onSurface),
      ),
      body: DsBody(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              DsToggleRow(
                title: 'Crash detection',
                subtitle: _enabled
                    ? 'Your circle is told if your phone detects a sudden stop at driving speed'
                    : 'Off: crashes are not detected or shared',
                icon: Icons.car_crash_outlined,
                value: _enabled,
                onChanged: _savingToggle ? null : _toggle,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.md,
                ),
                child: Text(
                  'This is an estimate from your phone\'s motion sensor and GPS, '
                  'so it can miss a crash or raise a false alarm. It never '
                  'contacts emergency services. Needs driving detection on.',
                  style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              const DsSectionHeader('Recent reports'),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpace.xxl),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                DsErrorState(message: _error!, onRetry: _load)
              else if (_items.isEmpty)
                const DsEmptyState(
                  title: 'No crashes detected',
                  message: 'Possible crashes from the last 90 days show up here.',
                  icon: Icons.verified_user_outlined,
                )
              else
                for (final _Crash c in _items) _row(context, c, u),
              const SizedBox(height: AppSpace.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _Crash c, UnitSystem u) {
    final bool possible = c.status == 'possible';
    final Color color = possible
        ? AppColors.sosRed
        : (c.status == 'ok' ? AppColors.statusGreen : AppColors.statusGrey);
    final String label = switch (c.status) {
      'ok' => 'Okay',
      'false_alarm' => 'False alarm',
      _ => 'Possible crash',
    };
    final String speed = c.before == null
        ? ''
        : 'From ${u.formatSpeed(c.before!)} to '
              '${c.after == null ? 'a stop' : u.formatSpeed(c.after!)}';
    return Column(
      children: <Widget>[
        DsListRow(
          title: c.mine ? 'You' : (c.name.isEmpty ? 'Circle member' : c.name),
          subtitle: <String>[_when(c.at), speed]
              .where((String s) => s.isNotEmpty)
              .join(' · '),
          leading: DsListRow.iconTile(
            context,
            Icons.car_crash_outlined,
            color: color,
          ),
          trailing: DsStatusChip(label: label, color: color),
        ),
        if (possible && c.mine)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl, 0, AppSpace.xl, AppSpace.md,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: DsPillButton(
                    label: 'I\'m okay',
                    onPressed: () => _mark(c, 'ok'),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: DsPillButton(
                    label: 'False alarm',
                    style: DsPillStyle.outlined,
                    onPressed: () => _mark(c, 'false_alarm'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
