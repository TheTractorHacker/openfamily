import 'package:flutter/material.dart';

import '../services/app_compat.dart';

/// Tells the user their app is behind the server, instead of leaving them with
/// silent "No location yet" / "Offline" states (docs/api-compat.md).
///
/// * required: the server no longer supports this version. Not dismissible.
/// * a Private circle this version cannot open: not dismissible.
/// * recommended: a newer version exists. Dismissible for the session.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        AppCompat.state,
        AppCompat.dismissed,
        AppCompat.circlesNeedingUpdate,
      ]),
      builder: (BuildContext context, _) {
        final CompatState st = AppCompat.state.value;
        final int circles = AppCompat.circlesNeedingUpdate.value;
        String? text;
        bool urgent = true;
        if (st.status == CompatStatus.required) {
          text = 'Update required: this version of Orbitly is no longer '
              'supported by your server, so locations may be missing or '
              'out of date. Please update the app.';
        } else if (circles > 0) {
          text = circles == 1
              ? 'This circle needs a newer version of Orbitly. '
                  'Update the app to see it.'
              : '$circles circles need a newer version of Orbitly. '
                  'Update the app to see them.';
        } else if (st.status == CompatStatus.recommended &&
            !AppCompat.dismissed.value) {
          text = 'Update available: a newer version of Orbitly is '
              'available${st.latest.isEmpty ? '' : ' (${st.latest})'}.';
          urgent = false;
        }
        if (text == null) return const SizedBox.shrink();
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Material(
          color: urgent ? cs.errorContainer : cs.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    urgent ? Icons.system_update : Icons.info_outline,
                    color: urgent ? cs.onErrorContainer : cs.onSecondaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      key: const Key('update-banner-text'),
                      style: TextStyle(
                        color: urgent
                            ? cs.onErrorContainer
                            : cs.onSecondaryContainer,
                      ),
                    ),
                  ),
                  if (!urgent)
                    IconButton(
                      key: const Key('update-banner-dismiss'),
                      tooltip: 'Dismiss',
                      icon: const Icon(Icons.close),
                      onPressed: () => AppCompat.dismissed.value = true,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
