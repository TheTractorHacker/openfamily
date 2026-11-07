import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../screens/delivery_screen.dart';
import '../services/delivery_status.dart';

/// Shown on the map when a Private circle reports that nobody (not even this phone) has sent an
/// update lately. Replaces the silent "No location yet" with a reason and a way to fix it.
class DeliveryBanner extends StatelessWidget {
  const DeliveryBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, CircleDelivery>>(
      valueListenable: DeliveryHints.reports,
      builder: (BuildContext context, Map<String, CircleDelivery> reports, _) {
        Circle? silent;
        for (final MapEntry<String, CircleDelivery> e in reports.entries) {
          final Circle? c = DeliveryHints.circleById[e.key];
          if (c != null && c.isPrivate && e.value.nobodySending) silent = c;
        }
        if (silent == null) return const SizedBox.shrink();
        final Circle target = silent;
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Material(
          color: cs.secondaryContainer,
          child: InkWell(
            key: const Key('delivery-banner'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DeliveryScreen(circle: target))),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.info_outline, color: cs.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$kNobodySendingText Tap to see why and fix it.',
                      style: TextStyle(color: cs.onSecondaryContainer),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: cs.onSecondaryContainer),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
