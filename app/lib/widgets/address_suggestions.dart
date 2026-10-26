import 'package:flutter/material.dart';

import '../services/address_suggester.dart';
import '../services/geocoding_service.dart';
import '../theme/app_theme.dart';

/// Suggestion list shown under the address field: label + type, 48dp+ rows,
/// friendly states for loading, empty, offline and rate limiting, and the
/// OpenStreetMap attribution line.
class AddressSuggestionList extends StatelessWidget {
  const AddressSuggestionList({
    super.key,
    required this.suggester,
    required this.onSelected,
  });

  final AddressSuggester suggester;
  final ValueChanged<GeocodeSuggestion> onSelected;

  static IconData _icon(String type) {
    switch (type) {
      case 'house':
        return Icons.home_outlined;
      case 'street':
        return Icons.add_road;
      case 'city':
        return Icons.location_city_outlined;
      default:
        return Icons.place_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: suggester,
      builder: (BuildContext context, _) {
        if (!suggester.visible) return const SizedBox.shrink();
        final ColorScheme cs = Theme.of(context).colorScheme;
        final BrandTheme brand = BrandTheme.of(context);
        final TextStyle muted = AppType.secondary.copyWith(
          color: cs.onSurfaceVariant,
        );
        Widget message(String text) => Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.sm,
                ),
                child: Text(text, style: muted),
              ),
            );
        final List<Widget> rows = <Widget>[];
        switch (suggester.status) {
          case SuggestStatus.idle:
            return const SizedBox.shrink();
          case SuggestStatus.loading:
            if (suggester.suggestions.isEmpty) {
              rows.add(message('Searching…'));
            }
          case SuggestStatus.empty:
            rows.add(message(
              'No matches. Keep typing, or drop the pin on the map.',
            ));
          case SuggestStatus.offline:
            rows.add(message(
              'Can\'t reach the server. You can still type an address.',
            ));
          case SuggestStatus.rateLimited:
            rows.add(message(
              'Too many searches. Wait a moment, then try again.',
            ));
          case SuggestStatus.error:
            rows.add(message(
              'Address search is unavailable right now. You can still type an address.',
            ));
          case SuggestStatus.ready:
            break;
        }
        for (final GeocodeSuggestion s in suggester.suggestions) {
          rows.add(
            Semantics(
              button: true,
              label: '${s.label}, ${s.typeLabel}',
              excludeSemantics: true,
              onTap: () => onSelected(s),
              child: InkWell(
                onTap: () => onSelected(s),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTarget),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                      vertical: AppSpace.xs,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(_icon(s.type), color: brand.accentInk),
                        const SizedBox(width: AppSpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                s.label,
                                style: AppType.body,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(s.typeLabel, style: muted),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.xs,
            ),
            child: Text('Powered by OpenStreetMap data', style: muted),
          ),
        );
        return Container(
          margin: const EdgeInsets.only(top: AppSpace.xs),
          decoration: BoxDecoration(
            color: brand.sheet,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cs.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        );
      },
    );
  }
}
