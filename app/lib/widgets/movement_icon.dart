import 'package:flutter/material.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';

/// Renders a movement icon. The "Gym" movement uses a custom flexing-arm
/// glyph (Material has no flexing-arm icon — `Icons.fitness_center` is a
/// dumbbell); everything else uses the standard Material icon. The "none"
/// (no movement) state renders nothing — the bar defines no icon for it.
class MovementIcon extends StatelessWidget {
  const MovementIcon({
    super.key,
    required this.movement,
    this.size = 20,
    this.color,
  });

  final MovementType movement;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (movement == MovementType.none) {
      return const SizedBox.shrink();
    }
    final Color c = color ??
        (movement.color == AppColors.purple
            ? BrandTheme.of(context).accentInk
            : movement.color);
    if (movement == MovementType.gym) {
      return FlexingArmIcon(size: size, color: c);
    }
    return Icon(movement.icon, size: size, color: c);
  }
}

/// A custom "flexing arm" (bicep) glyph for the Gym movement.
class FlexingArmIcon extends StatelessWidget {
  const FlexingArmIcon({
    super.key,
    this.size = 20,
    this.color = AppColors.purple,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _FlexingArmPainter(color: color),
    );
  }
}

class _FlexingArmPainter extends CustomPainter {
  _FlexingArmPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.20
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Upper arm (shoulder → elbow) and forearm (elbow → fist).
    final Offset shoulder = Offset(w * 0.52, h * 0.95);
    final Offset elbow = Offset(w * 0.66, h * 0.48);
    final Offset fist = Offset(w * 0.36, h * 0.20);

    final Path arm = Path()
      ..moveTo(shoulder.dx, shoulder.dy)
      ..lineTo(elbow.dx, elbow.dy)
      ..lineTo(fist.dx, fist.dy);
    canvas.drawPath(arm, stroke);

    // Fist and bicep bulge.
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(fist, w * 0.17, fill);
    canvas.drawCircle(Offset(w * 0.58, h * 0.66), w * 0.15, fill);
  }

  @override
  bool shouldRepaint(covariant _FlexingArmPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A "race car with flames" glyph for speeding drivers.
class RaceCarIcon extends StatelessWidget {
  const RaceCarIcon({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size * 1.7, size),
      painter: const _RaceCarPainter(),
    );
  }
}

class _RaceCarPainter extends CustomPainter {
  const _RaceCarPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // Flames trailing behind (left).
    final Paint flame = Paint()..style = PaintingStyle.fill;
    const List<Color> flameColors = [
      Color(0xFFFF3B30),
      Color(0xFFFF9500),
      Color(0xFFFFC107),
    ];
    for (int i = 0; i < flameColors.length; i++) {
      flame.color = flameColors[i];
      final double baseY = h * (0.22 + 0.28 * i);
      final Path tongue = Path()
        ..moveTo(w * 0.34, baseY - h * 0.12)
        ..quadraticBezierTo(w * 0.08, baseY, w * 0.34, baseY + h * 0.12)
        ..close();
      canvas.drawPath(tongue, flame);
    }

    // Car body.
    final Paint body = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.fill;
    final RRect bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * 0.34, h * 0.38, w * 0.96, h * 0.72),
      Radius.circular(h * 0.10),
    );
    canvas.drawRRect(bodyRect, body);

    // Cabin.
    final Path cabin = Path()
      ..moveTo(w * 0.50, h * 0.38)
      ..lineTo(w * 0.60, h * 0.16)
      ..lineTo(w * 0.82, h * 0.16)
      ..lineTo(w * 0.90, h * 0.38)
      ..close();
    canvas.drawPath(cabin, body);

    // Wheels.
    final Paint wheel = Paint()
      ..color = const Color(0xFF3E2723)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(w * 0.50, h * 0.72), h * 0.12, wheel);
    canvas.drawCircle(Offset(w * 0.82, h * 0.72), h * 0.12, wheel);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
