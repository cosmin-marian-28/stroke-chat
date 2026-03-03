import 'dart:ui';
import 'package:flutter/material.dart';

/// A custom liquid glass widget that mimics the iOS 26 frosted glass look.
/// Uses layered backdrop blur, gradient highlights, and subtle border
/// to create a glassy, refractive appearance without needing shaders.
class LiquidGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur;
  final Color tint;
  final double highlightOpacity;
  final EdgeInsets? padding;
  final double? height;
  final double? width;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.blur = 30,
    this.tint = const Color(0x14FFFFFF),
    this.highlightOpacity = 0.12,
    this.padding,
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          height: height,
          width: width,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            // Base glass tint
            color: tint,
            // Gradient highlight — simulates light refraction on glass surface
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: highlightOpacity),
                Colors.white.withValues(alpha: highlightOpacity * 0.3),
                Colors.white.withValues(alpha: highlightOpacity * 0.05),
                Colors.white.withValues(alpha: highlightOpacity * 0.25),
              ],
              stops: const [0.0, 0.3, 0.6, 1.0],
            ),
            border: Border.all(
              width: 0.5,
              color: Colors.white.withValues(alpha: 0.18),
            ),
            // Inner shadow glow
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.04),
                blurRadius: 1,
                spreadRadius: 0,
                offset: const Offset(0, 0.5),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
