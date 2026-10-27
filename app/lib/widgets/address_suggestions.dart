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
        Widget retryMessage(String text) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                message(text),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  child: TextButton(
                    onPressed: suggester.retry,
                    child: const Text('Try again'),
                  ),
                ),
              ],
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
              suggester.lastExplicit
                  ? 'We could not find that address. Try the street and city, or drag the pin on the map.'
                  : 'No matches yet. Keep typing, press search, or drag the pin on the map.',
            ));
          case SuggestStatus.offline:
            rows.add(retryMessage(
              'Can\'t reach the server. You can still type an address.',
            ));
          case SuggestStatus.rateLimited:
            rows.add(message(
              'Please wait a few seconds, then search again.',
            ));
          case SuggestStatus.error:
            rows.add(retryMessage(
              'Address search is unavailable right now. You can still type an address.',
            ));
          case SuggestStatus.ready:
            if (suggester.approximate) {
              rows.add(message(
                suggester.suggestions.first.matched == 'locality'
                    ? 'We found the town but not that street. The pin is on the town; drag it to the exact spot.'
                    : 'We found the street but not that house number. The pin is on the street; drag it to the exact spot.',
              ));
            }
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
            child: Text(
              suggester.suggestions.any((GeocodeSuggestion s) => s.source == 'google')
                  ? 'Powered by Google'
                  : 'Powered by OpenStreetMap data',
              style: muted,
            ),
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
