import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/tilt_provider.dart';
import '../screens/settings_screen.dart';

/// Larger glass container with tilt-reactive border — for toolbars, panels, etc.
/// Same visual style as GlassPill but accepts arbitrary children and sizing.
class GlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 22,
  });

  @override
  State<GlassContainer> createState() => _GlassContainerState();
}

class _GlassContainerState extends State<GlassContainer> {
  final _tilt = TiltProvider.instance;

  @override
  void initState() {
    super.initState();
    _tilt.addUser();
    _tilt.addListener(_onTilt);
    SimpleUiNotifier.instance.addListener(_onSimpleUiChanged);
  }

  void _onTilt() {
    if (mounted && !SimpleUiNotifier.instance.value) setState(() {});
  }

  void _onSimpleUiChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tilt.removeListener(_onTilt);
    _tilt.removeUser();
    SimpleUiNotifier.instance.removeListener(_onSimpleUiChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.borderRadius;

    if (SimpleUiNotifier.instance.value) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(r),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
        child: widget.child,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: CustomPaint(
          painter: _GlassContainerPainter(
            angle: _tilt.angle,
            tiltX: _tilt.tiltX,
            tiltY: _tilt.tiltY,
            borderRadius: r,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _GlassContainerPainter extends CustomPainter {
  final double angle;
  final double tiltX;
  final double tiltY;
  final double borderRadius;

  _GlassContainerPainter({
    required this.angle,
    required this.tiltX,
    required this.tiltY,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    // Base glass fill
    canvas.drawRRect(
      rrect,
      Paint()..color = Colors.white.withValues(alpha: 0.06),
    );

    canvas.save();
    canvas.clipRRect(rrect);

    // Inner specular glow that moves with tilt
    final glowCenter = Offset(
      size.width * (0.5 + tiltX * 0.4),
      size.height * (0.5 - tiltY * 0.5),
    );
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.10),
          Colors.white.withValues(alpha: 0.03),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(
          Rect.fromCircle(center: glowCenter, radius: size.width * 0.5));
    canvas.drawRect(rect, glowPaint);
    canvas.restore();

    // Border highlight — uses pre-computed amplified angle
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: GradientRotation(angle - math.pi * 0.33),
        colors: [
          Colors.white.withValues(alpha: 0.50),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.08),
          Colors.white.withValues(alpha: 0.04),
          Colors.white.withValues(alpha: 0.04),
          Colors.white.withValues(alpha: 0.08),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.50),
        ],
        stops: const [0.0, 0.08, 0.18, 0.3, 0.7, 0.82, 0.92, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, borderPaint);

    // Blurred glow behind the bright section
    final blurPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: GradientRotation(angle - math.pi * 0.25),
        colors: [
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.16),
        ],
        stops: const [0.0, 0.1, 0.22, 0.5, 0.78, 0.9, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, blurPaint);
  }

  @override
  bool shouldRepaint(_GlassContainerPainter old) =>
      old.angle != angle || old.tiltX != tiltX || old.tiltY != tiltY || old.borderRadius != borderRadius;
}
