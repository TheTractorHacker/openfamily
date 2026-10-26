import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A [ValueListenableBuilder] that does not rebuild while its subtree is
/// hidden.
///
/// The app shell keeps every visited tab alive in an `IndexedStack` and mutes
/// the hidden ones with `TickerMode(enabled: false)`. A plain
/// [ValueListenableBuilder] would still rebuild a hidden tab on every roster
/// update; this one defers the rebuild until the subtree is visible again, at
/// which point it renders the latest value. Outside a muted `TickerMode`
/// (tests, pushed routes) it behaves exactly like [ValueListenableBuilder].
class VisibleValueBuilder<T> extends StatefulWidget {
  const VisibleValueBuilder({
    super.key,
    required this.valueListenable,
    required this.builder,
    this.child,
  });

  final ValueListenable<T> valueListenable;
  final ValueWidgetBuilder<T> builder;
  final Widget? child;

  @override
  State<VisibleValueBuilder<T>> createState() => _VisibleValueBuilderState<T>();
}

class _VisibleValueBuilderState<T> extends State<VisibleValueBuilder<T>> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    widget.valueListenable.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(VisibleValueBuilder<T> old) {
    super.didUpdateWidget(old);
    if (old.valueListenable != widget.valueListenable) {
      old.valueListenable.removeListener(_onChanged);
      widget.valueListenable.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // Visibility is sampled in build (which also subscribes this element to
    // TickerMode), so becoming visible triggers a build that picks up the
    // latest value.
    if (!_visible) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _visible = TickerMode.of(context);
    return widget.builder(context, widget.valueListenable.value, widget.child);
  }
}
