import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Instagram-style hold-to-record voice message overlay.
/// Shows a pulsing red circle, timer, and slide-to-cancel hint.
class VoiceRecorderOverlay extends StatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final bool isRecording;

  const VoiceRecorderOverlay({
    super.key,
    required this.onCancel,
    required this.onSend,
    required this.isRecording,
  });

  @override
  State<VoiceRecorderOverlay> createState() => _VoiceRecorderOverlayState();
}

class _VoiceRecorderOverlayState extends State<VoiceRecorderOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final AnimationController _slideHintCtrl;
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _slideHintCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _slideHintCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  String get _timeLabel {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          // Pulsing red dot
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (context, _) {
              final scale = 1.0 + 0.3 * _pulseCtrl.value;
              final opacity = 0.6 + 0.4 * (1.0 - _pulseCtrl.value);
              return Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFF453A).withValues(alpha: opacity),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF453A).withValues(alpha: 0.4 * opacity),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          // Timer
          Text(
            _timeLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          // Slide to cancel hint
          AnimatedBuilder(
            animation: _slideHintCtrl,
            builder: (context, child) {
              final opacity = 0.25 + 0.25 * math.sin(_slideHintCtrl.value * math.pi);
              return Opacity(opacity: opacity, child: child);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chevron_left_rounded,
                    size: 16, color: Colors.white.withValues(alpha: 0.4)),
                Text(
                  'slide to cancel',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Send button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onSend();
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Color(0xFF007AFF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_upward_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
