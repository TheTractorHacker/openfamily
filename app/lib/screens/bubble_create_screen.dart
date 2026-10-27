import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/bubble.dart';
import '../models/member.dart';
import '../services/bubble_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/openfamily_map_layers.dart';

/// "Create Bubble": a temporary, per-person geofence around where [member] is
/// right now. Step 1 sizes the circle with a slider on the map, step 2 (after
/// Continue) picks how long it lasts, then Confirm creates it. The creator is
/// alerted when the person leaves it; the person is told a Bubble exists.
///
/// Pops with the created [Bubble], or `null` when cancelled.
class BubbleCreateScreen extends StatefulWidget {
  const BubbleCreateScreen({
    super.key,
    required this.member,
    this.service = const ApiBubbleService(),
    this.now,
  });

  final Member member;
  final BubbleService service;

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  State<BubbleCreateScreen> createState() => _BubbleCreateScreenState();
}

class _BubbleCreateScreenState extends State<BubbleCreateScreen> {
  final MapController _map = MapController();
  double _slider = bubbleSliderFromRadius(200);
  bool _durationStep = false;
  bool _mapReady = false;
  bool _reenter = false;
  bool _busy = false;
  String? _error;
  int? _minutes;

  int get _radius => bubbleRadiusFromSlider(_slider);
  DateTime get _now => (widget.now ?? DateTime.now)();

  LatLng get _center => widget.member.position ?? const LatLng(0, 0);

  void _fit() {
    if (!_mapReady) return;
    final double w = MediaQuery.sizeOf(context).width;
    _map.move(_center, bubbleZoomFor(_radius.toDouble(), _center.latitude, w));
  }

  Future<void> _confirm() async {
    final int? minutes = _minutes;
    if (minutes == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Bubble b = await widget.service.create(
        subjectId: widget.member.id,
        radiusM: _radius,
        durationMinutes: minutes,
        notifyReenter: _reenter,
      );
      await BubbleStore.instance.refresh(widget.service);
      if (!mounted) return;
      Navigator.of(context).pop(b);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = bubbleErrorMessage(e, action: 'create the Bubble');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String name = widget.member.name;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Bubble'),
        leading: BackButton(
          onPressed: () {
            if (_durationStep && !_busy) {
              setState(() => _durationStep = false);
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: Column(
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Container(
              width: double.infinity,
              color: AppColors.purple,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.xl,
                vertical: AppSpace.md,
              ),
              child: Text(
                _durationStep
                    ? 'Choose how long the Bubble around $name lasts'
                    : 'Use the slider to adjust the size of your Bubble',
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: Colors.white),
              ),
            ),
          ),
          Expanded(child: _mapView()),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.md,
                AppSpace.xl,
                AppSpace.lg,
              ),
              child: _durationStep ? _durationPanel(context) : _sizePanel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapView() {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _center,
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
        onMapReady: () {
          _mapReady = true;
          _fit();
        },
      ),
      children: <Widget>[
        const OpenFamilyTileLayer(),
        CircleLayer(
          circles: <CircleMarker>[
            CircleMarker(
              point: _center,
              radius: _radius.toDouble(),
              useRadiusInMeter: true,
              color: AppColors.purple.withValues(alpha: 0.2),
              borderColor: AppColors.purple,
              borderStrokeWidth: 2,
            ),
          ],
        ),
        MarkerLayer(
          markers: <Marker>[
            Marker(
              point: _center,
              width: 52,
              height: 52,
              child: StatusAvatar(member: widget.member, size: 48),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sizePanel(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.radio_button_unchecked, size: 18),
            const SizedBox(width: AppSpace.sm),
            Text('Radius: ${formatBubbleRadius(_radius)}', style: AppType.body),
          ],
        ),
        Slider(
          value: _slider,
          onChanged: (double v) {
            setState(() => _slider = v);
            _fit();
          },
          semanticFormatterCallback: (double v) =>
              'Bubble radius ${formatBubbleRadius(bubbleRadiusFromSlider(v))}',
        ),
        const SizedBox(height: AppSpace.sm),
        DsPillButton(
          label: 'Continue',
          onPressed: () {
            setState(() {
              _durationStep = true;
              _minutes ??= 60;
            });
          },
        ),
      ],
    );
  }

  Widget _durationPanel(BuildContext context) {
    final List<BubbleDuration> options = bubbleDurationOptions(_now);
    final DateTime? until =
        _minutes == null ? null : _now.add(Duration(minutes: _minutes!));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: AppSpace.sm,
          children: <Widget>[
            for (final BubbleDuration d in options)
              ChoiceChip(
                label: Text(d.label),
                selected: _minutes == d.minutes,
                onSelected: _busy
                    ? null
                    : (bool _) => setState(() => _minutes = d.minutes),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Also alert me when they come back'),
          value: _reenter,
          onChanged: _busy ? null : (bool v) => setState(() => _reenter = v),
        ),
        Text(
          '${widget.member.name} is told a Bubble was created around them '
          '(never where it is). ${until == null ? '' : 'It ends at ${_hhmm(until)}.'}',
          style: AppType.secondary.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (_error != null) DsMessage(_error!),
        const SizedBox(height: AppSpace.sm),
        DsBusyButton(
          label: 'Create Bubble',
          busy: _busy,
          onPressed: _minutes == null ? null : _confirm,
        ),
      ],
    );
  }
}

String _hhmm(DateTime t) {
  final DateTime l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}
