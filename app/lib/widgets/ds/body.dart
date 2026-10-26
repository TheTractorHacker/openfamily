import 'package:flutter/material.dart';

/// Widest a form, list or settings column gets on tablets, foldables and
/// landscape. Phones (<= 412 dp) are narrower, so their layout is unchanged.
const double kContentMaxWidth = 640;

/// Standard body wrapper for pushed routes and tab bodies: keeps content
/// clear of a landscape cutout and the gesture bar (the app bar already
/// handles the status bar) and centers it at a readable [maxWidth].
///
/// Scrolling children keep scrolling to the screen edge horizontally; only
/// the safe insets are removed from their padding so nothing is double-padded.
class DsBody extends StatelessWidget {
  const DsBody({
    super.key,
    required this.child,
    this.maxWidth = kContentMaxWidth,
    this.top = false,
  });

  final Widget child;
  final double maxWidth;

  /// Also keep clear of the status bar (for bodies without an app bar).
  final bool top;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: top,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
