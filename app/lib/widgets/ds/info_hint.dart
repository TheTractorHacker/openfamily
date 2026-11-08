import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'sheet_scaffold.dart';

/// Opens a bottom sheet with the longer explanation of a setting.
Future<void> showInfoSheet(BuildContext context, {required String title, required String body}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => DsSheetScaffold(
      title: title,
      child: SingleChildScrollView(
        key: const Key('info-sheet-body'),
        padding: EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl + MediaQuery.paddingOf(ctx).bottom),
        child: Text(body, style: AppType.body),
      ),
    ),
  );
}

/// The small (i) button of a setting: tap to read more. 48 dp target, labelled for screen readers.
/// Every setting row keeps its own text to one short line and puts the rest here.
class InfoHint extends StatelessWidget {
  const InfoHint({super.key, required this.title, required this.body});
  final String title, body;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('info-hint'),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      tooltip: 'More about $title',
      icon: Icon(Icons.info_outline, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
      onPressed: () => showInfoSheet(context, title: title, body: body),
    );
  }
}
