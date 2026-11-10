import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Subwiz-style 6px dot field. Paper stays undyed; lime stays on actions.
///
/// The dots sit on their own layer behind [child]: scrolling the child, or an
/// app bar animating its scrolled-under colour, never re-records them, and the
/// whole field is a single draw operation for the raster thread.
class DotGridBackground extends StatelessWidget {
  const DotGridBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Stack(
      // Same constraints for the child as before (no Stack loosening).
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: DotGridPainter(color: brand.dot),
              isComplex: true,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class DotGridPainter extends CustomPainter {
  const DotGridPainter({required this.color, this.spacing = 6});

  final Color color;
  final double spacing;

  /// Dot diameter in logical pixels.
  static const double dotSize = 1.1;

  /// Paint calls so far (tests measure repaints with it).
  static int debugPaintCount = 0;

  @override
  void paint(Canvas canvas, Size size) {
    debugPaintCount++;
    final int cols = size.width <= spacing / 2 ? 0 : ((size.width - spacing / 2) / spacing).ceil();
    final int rows = size.height <= spacing / 2 ? 0 : ((size.height - spacing / 2) / spacing).ceil();
    if (cols <= 0 || rows <= 0) return;
    // One point list, one draw call: a phone screen holds about 10,000 dots,
    // which as separate circles cost the raster thread every frame.
    final Float32List points = Float32List(cols * rows * 2);
    int i = 0;
    for (int r = 0; r < rows; r++) {
      final double y = spacing / 2 + r * spacing;
      for (int c = 0; c < cols; c++) {
        points[i++] = spacing / 2 + c * spacing;
        points[i++] = y;
      }
    }
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = dotSize
      ..strokeCap = StrokeCap.round;
    canvas.drawRawPoints(ui.PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(DotGridPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.spacing != spacing;
  }
}
