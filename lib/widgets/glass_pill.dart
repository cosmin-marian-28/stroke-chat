import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/tilt_provider.dart';
import '../screens/settings_screen.dart';

/// Header pill with Apple-style glass border that reacts to device tilt.
/// When SimpleUiNotifier is on, renders a plain grey rounded rect instead.
class GlassPill extends StatefulWidget {
  final Widget child;
  final double height;
  final double? width;
  final double borderRadius;
  final bool showBorder;

  const GlassPill({
    super.key,
    required this.child,
    this.height = 42,
    this.width,
    this.borderRadius = 21,
    this.showBorder = true,
  });

  @override
  State<GlassPill> createState() => _GlassPillState();
}

class _GlassPillState extends State<GlassPill> {
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
    if (SimpleUiNotifier.instance.value) {
      return Container(
        height: widget.height,
        width: widget.width,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
        child: widget.child,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: CustomPaint(
          painter: _GlassPillPainter(
            borderRadius: widget.borderRadius,
            angle: _tilt.angle,
            showBorder: widget.showBorder,
          ),
          child: Container(
            height: widget.height,
            width: widget.width,
            alignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _GlassPillPainter extends CustomPainter {
  final double borderRadius;
  final double angle;
  final bool showBorder;

  _GlassPillPainter({
    required this.borderRadius,
    required this.angle,
    this.showBorder = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    // Glass fill
    canvas.drawRRect(
      rrect,
      Paint()..color = Colors.white.withValues(alpha: 0.06),
    );

    // Sweep gradient border — bright arc follows tilt
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

    if (showBorder) {
      canvas.drawRRect(rrect, borderPaint);
    }

    // Blurred glow behind the bright section
    final glowPaint = Paint()
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

    canvas.drawRRect(rrect, glowPaint);
  }

  @override
  bool shouldRepaint(_GlassPillPainter old) =>
      old.angle != angle || old.borderRadius != borderRadius || old.showBorder != showBorder;
}
