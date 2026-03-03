import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String url;
  const VideoPlayerScreen({super.key, required this.url});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _showControls = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _ctrl.play();
          // Auto-hide controls after 2s
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _ctrl.value.isPlaying) {
              setState(() => _showControls = false);
            }
          });
        }
      }).catchError((_) {
        if (mounted) setState(() => _error = true);
      });
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video
            if (_initialized)
              Center(
                child: AspectRatio(
                  aspectRatio: _ctrl.value.aspectRatio,
                  child: VideoPlayer(_ctrl),
                ),
              )
            else if (_error)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline,
                        size: 40, color: Colors.white.withValues(alpha: 0.3)),
                    const SizedBox(height: 12),
                    Text('Failed to load video',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 14)),
                  ],
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5),
              ),

            // Controls overlay
            if (_showControls) ...[
              // Top bar — close button
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.5),
                    ),
                    child: const Icon(Icons.close_rounded,
                        size: 20, color: Colors.white),
                  ),
                ),
              ),

              // Bottom controls
              if (_initialized)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).padding.bottom + 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Progress bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Text(
                              _formatDuration(_ctrl.value.position),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor:
                                      Colors.white.withValues(alpha: 0.2),
                                  thumbColor: Colors.white,
                                  overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 12),
                                ),
                                child: Slider(
                                  value: _ctrl.value.duration.inMilliseconds > 0
                                      ? _ctrl.value.position.inMilliseconds /
                                          _ctrl.value.duration.inMilliseconds
                                      : 0,
                                  onChanged: (v) {
                                    final pos = Duration(
                                        milliseconds:
                                            (v * _ctrl.value.duration.inMilliseconds)
                                                .round());
                                    _ctrl.seekTo(pos);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _formatDuration(_ctrl.value.duration),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Play/pause
                      GestureDetector(
                        onTap: () {
                          _ctrl.value.isPlaying
                              ? _ctrl.pause()
                              : _ctrl.play();
                        },
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                          child: Icon(
                            _ctrl.value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
