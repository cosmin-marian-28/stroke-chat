import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Shared singleton that provides a smoothed tilt angle for glass effects.
///
/// [angle] is in radians (0..2π) — represents where the "light" sits on the
/// border. Normal hand movements (~±25° tilt) map to a full 360° sweep so
/// the highlight travels all the way around with natural wrist motion.
///
/// Also exposes [tiltX] / [tiltY] (-1..1) for any widget that wants the
/// raw directional values.
class TiltProvider extends ChangeNotifier {
  static final TiltProvider _instance = TiltProvider._();
  static TiltProvider get instance => _instance;

  /// Light angle in radians — full 0..2π range.
  double angle = 0.0;

  /// Raw directional tilt, -1..1 each axis.
  double tiltX = 0.0;
  double tiltY = 0.0;

  StreamSubscription? _sub;
  int _listeners = 0;

  static const double _uprightPitch = -1.2; // ~70° from flat

  /// How aggressively small tilts map to full rotation.
  /// Higher = less tilt needed for full 360°.
  /// 3.0 means ~30° of real tilt → full circle.
  static const double _sensitivity = 3.5;

  TiltProvider._();

  void addUser() {
    _listeners++;
    if (_listeners == 1) _start();
  }

  void removeUser() {
    _listeners--;
    if (_listeners <= 0) {
      _listeners = 0;
      _stop();
    }
  }

  void _start() {
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      // Left/right lean
      final rawX = (event.x / 9.8).clamp(-1.0, 1.0);

      // Pitch relative to upright holding position
      final pitch = math.atan2(event.z, -event.y);
      final rawY = ((pitch - _uprightPitch) / 1.2).clamp(-1.0, 1.0);

      // Smooth the raw values
      tiltX = tiltX + (rawX - tiltX) * 0.12;
      tiltY = tiltY + (rawY - tiltY) * 0.12;

      // Compute angle from tilt direction, then amplify so small
      // movements cover the full circle.
      // atan2 gives us the natural angle of the tilt vector.
      final rawAngle = math.atan2(-tiltY, tiltX);

      // Scale the magnitude of the tilt to push the angle further.
      // With sensitivity 3.5, a ~0.3 tilt (natural wrist range)
      // gets amplified to cover most of the circle.
      final mag = math.sqrt(tiltX * tiltX + tiltY * tiltY).clamp(0.0, 1.0);
      final amplified = rawAngle * (1.0 + mag * _sensitivity);

      // Smooth the angle — use shortest-path interpolation to avoid
      // jumps when crossing the ±π boundary.
      var delta = amplified - angle;
      // Wrap delta to -π..π
      while (delta > math.pi) {
        delta -= 2 * math.pi;
      }
      while (delta < -math.pi) {
        delta += 2 * math.pi;
      }
      angle += delta * 0.15;

      notifyListeners();
    });
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }
}
