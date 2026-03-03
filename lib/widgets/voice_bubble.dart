import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../core/e2e_encryption.dart';
import 'stroke_text.dart';

/// Voice message bubble with animated particle dots when playing.
class VoiceBubble extends StatefulWidget {
  final String audioUrl;
  final bool isMe;
  final int durationMs;
  final E2EEncryption? e2e;
  final String? transcriptStrokes;
  final String? sessionId;
  final Uint8List? sharedSecret;
  final BorderRadius? borderRadius;
  final List<Color>? bubbleGradient;
  final Color? foregroundColor;

  const VoiceBubble({
    super.key,
    required this.audioUrl,
    required this.isMe,
    this.durationMs = 0,
    this.e2e,
    this.transcriptStrokes,
    this.sessionId,
    this.sharedSecret,
    this.borderRadius,
    this.bubbleGradient,
    this.foregroundColor,
  });

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble>
    with TickerProviderStateMixin {
  final _player = AudioPlayer();
  bool _playing = false;
  double _progress = 0;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  late final AnimationController _dotCtrl;
  String? _decryptedPath;
  bool _loading = false;
  bool _showTranscript = false;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.durationMs > 0) {
      _duration = Duration(milliseconds: widget.durationMs);
    }
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted && _duration.inMilliseconds > 0) {
        setState(() {
          _position = p;
          _progress = p.inMilliseconds / _duration.inMilliseconds;
        });
      }
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _progress = 0;
          _position = Duration.zero;
        });
        _dotCtrl.stop();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _dotCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_playing) {
      await _player.pause();
      _dotCtrl.stop();
      setState(() => _playing = false);
    } else {
      if (_progress <= 0) {
        await _prepareAndPlay();
      } else {
        await _player.resume();
        _dotCtrl.repeat();
        setState(() => _playing = true);
      }
    }
  }

  Future<void> _prepareAndPlay() async {
    // If encrypted, download → decrypt → play from local file
    if (widget.e2e != null && _decryptedPath == null) {
      setState(() => _loading = true);
      try {
        final resp = await http.get(Uri.parse(widget.audioUrl));
        if (resp.statusCode == 200) {
          final decrypted = widget.e2e!.decryptBytes(Uint8List.fromList(resp.bodyBytes));
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/dec_${widget.audioUrl.hashCode}.m4a');
          await file.writeAsBytes(decrypted);
          _decryptedPath = file.path;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => _loading = false);
    }

    if (_decryptedPath != null) {
      await _player.play(DeviceFileSource(_decryptedPath!));
    } else {
      await _player.play(UrlSource(widget.audioUrl));
    }
    _dotCtrl.repeat();
    if (mounted) setState(() => _playing = true);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final showDuration = _duration.inMilliseconds > 0
        ? _fmt(_playing ? _position : _duration)
        : '0:00';
    const defaultR = 22.0;
    final radius = widget.borderRadius ?? BorderRadius.circular(defaultR);
    final hasTranscript = widget.transcriptStrokes != null &&
        widget.transcriptStrokes!.isNotEmpty &&
        widget.sessionId != null &&
        widget.sharedSecret != null;
    const fallbackColor = Color(0xFF007AFF);
    final grad = widget.bubbleGradient;

    Widget buildInner(List<Color> gradColors) {
      final fg = widget.foregroundColor ?? Colors.white;
      return Container(
        decoration: BoxDecoration(
          gradient: widget.isMe ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradColors,
          ) : null,
          color: widget.isMe ? null : const Color(0xFF2C2C2E),
          borderRadius: radius,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _toggle,
                    child: _loading
                        ? SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2, color: fg.withValues(alpha: 0.54),
                            ),
                          )
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: Icon(
                              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              key: ValueKey(_playing),
                              color: fg, size: 24,
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: SizedBox(
                      height: 24,
                      child: AnimatedBuilder(
                        animation: _dotCtrl,
                        builder: (context, _) {
                          return CustomPaint(
                            painter: _DotParticlePainter(
                              progress: _progress,
                              animValue: _dotCtrl.value,
                              playing: _playing,
                              dotColor: fg,
                            ),
                            size: const Size(double.infinity, 24),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    showDuration,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.6),
                      fontSize: 12, fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (hasTranscript) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => setState(() => _showTranscript = !_showTranscript),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: _showTranscript ? 0.15 : 0.06),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.text_fields_rounded, size: 14,
                          color: fg.withValues(alpha: _showTranscript ? 0.8 : 0.4),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (_showTranscript && hasTranscript)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: StrokeText(
                    strokeText: widget.transcriptStrokes!,
                    sessionId: widget.sessionId!,
                    sharedSecret: widget.sharedSecret!,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.7),
                      fontSize: 14, height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: widget.isMe ? 24 : 32,
              sigmaY: widget.isMe ? 24 : 32,
            ),
            child: buildInner(
              (widget.isMe && grad != null && grad.isNotEmpty)
                  ? grad
                  : const [fallbackColor, fallbackColor],
            ),
          ),
        ),
      ),
    );
  }
}

class _DotParticlePainter extends CustomPainter {
  final double progress;
  final double animValue;
  final bool playing;
  final Color dotColor;

  static const int _dotCount = 18;
  // Each dot gets a random-ish base position and movement seed
  static final List<double> _seedX = List.generate(_dotCount, (i) => i / _dotCount + 0.02 * math.sin(i * 3.7));
  static final List<double> _seedY = List.generate(_dotCount, (i) => 0.3 + 0.4 * ((math.sin(i * 2.3 + 1.1) + 1) / 2));
  static final List<double> _seedR = List.generate(_dotCount, (i) => 1.5 + 1.5 * ((math.cos(i * 1.9 + 0.7) + 1) / 2));
  static final List<double> _phase = List.generate(_dotCount, (i) => i * 0.83);

  _DotParticlePainter({
    required this.progress,
    required this.animValue,
    required this.playing,
    required this.dotColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < _dotCount; i++) {
      final baseX = _seedX[i] * size.width;
      final baseY = _seedY[i] * size.height;
      final r = _seedR[i];
      final p = _phase[i];

      double x, y;
      double alpha;

      if (playing) {
        // Random chaotic movement
        x = baseX + math.sin(animValue * math.pi * 2 * 1.3 + p) * 6.0
                   + math.cos(animValue * math.pi * 2 * 0.7 + p * 2.1) * 3.0;
        y = baseY + math.cos(animValue * math.pi * 2 * 1.1 + p * 1.5) * 5.0
                   + math.sin(animValue * math.pi * 2 * 0.9 + p * 0.6) * 3.0;
        final dotPos = i / _dotCount;
        alpha = dotPos <= progress ? 0.85 : 0.2;
      } else {
        x = baseX;
        y = baseY;
        alpha = 0.25;
      }

      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()..color = dotColor.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_DotParticlePainter old) =>
      old.progress != progress ||
      old.animValue != animValue ||
      old.playing != playing;
}


