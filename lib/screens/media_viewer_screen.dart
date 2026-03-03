import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import '../widgets/glass_pill.dart';
import '../widgets/glass_container.dart';
import '../widgets/stroke_keyboard.dart';
import '../widgets/stroke_text.dart';
import '../core/session_manager.dart';
import '../core/e2e_encryption.dart';
import '../core/stroke_mapping.dart' show isEmoji, strokeRuneLength;

class MediaViewerScreen extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final bool isVideo;
  final bool isLocalFile;
  final void Function(String strokeText, String encryptedBlob)? onSendReply;
  final SessionManager? session;
  final E2EEncryption? e2e;
  final int sessionVersion;
  final Uint8List Function(int version)? deriveSecret;
  final String senderName;
  final DateTime? sentAt;

  const MediaViewerScreen({
    super.key,
    this.url,
    this.bytes,
    this.isVideo = false,
    this.isLocalFile = false,
    this.onSendReply,
    this.session,
    this.e2e,
    this.sessionVersion = 0,
    this.deriveSecret,
    this.senderName = '',
    this.sentAt,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  VideoPlayerController? _videoCtrl;
  bool _videoReady = false;
  bool _videoError = false;
  bool _saving = false;
  bool _keyboardVisible = false;
  String _strokeText = '';
  String _plainText = '';
  Size? _imageSize;

  // Swipe-down-to-dismiss
  double _dragY = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo && widget.url != null) {
      _videoCtrl = widget.isLocalFile
          ? VideoPlayerController.file(File(widget.url!))
          : VideoPlayerController.networkUrl(Uri.parse(widget.url!))
        ..initialize().then((_) {
          if (mounted) {
            setState(() => _videoReady = true);
            _videoCtrl!.play();
            _videoCtrl!.setLooping(true);
          }
        }).catchError((_) {
          if (mounted) setState(() => _videoError = true);
        });
      _videoCtrl!.addListener(() { if (mounted) setState(() {}); });
    } else {
      _resolveImageSize();
    }
  }

  void _resolveImageSize() {
    if (widget.bytes != null) {
      decodeImageFromList(widget.bytes!).then((img) {
        if (mounted) setState(() => _imageSize = Size(img.width.toDouble(), img.height.toDouble()));
      });
    } else if (widget.url != null) {
      final stream = NetworkImage(widget.url!).resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (mounted) {
          setState(() => _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          ));
        }
        stream.removeListener(listener);
      });
      stream.addListener(listener);
    }
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    super.dispose();
  }

  void _onKeyTap(String displayChar, String _) {
    if (widget.session == null || !widget.session!.hasActiveSession) return;
    setState(() {
      final encoded = isEmoji(displayChar) ? displayChar : widget.session!.encodeChar(displayChar);
      _strokeText += encoded;
      _plainText += displayChar;
    });
  }

  void _onBackspace() {
    if (_strokeText.isEmpty) return;
    setState(() {
      // Determine rune length of last plaintext character
      final lastChar = _plainText.isNotEmpty ? _plainText.characters.last : '';
      final removeCount = lastChar.isNotEmpty ? strokeRuneLength(lastChar) : 4;
      final runes = _strokeText.runes.toList();
      final cutAt = (runes.length - removeCount).clamp(0, runes.length);
      _strokeText = String.fromCharCodes(runes.sublist(0, cutAt));
      if (_plainText.isNotEmpty) {
        _plainText = _plainText.substring(0, _plainText.length - lastChar.length);
      }
    });
  }

  void _send() {
    if (_strokeText.isEmpty || widget.e2e == null || widget.onSendReply == null) return;
    final encrypted = widget.e2e!.encrypt(_strokeText);
    Navigator.pop(context);
    widget.onSendReply!(_strokeText, encrypted);
  }

  Future<void> _saveToDevice() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      Uint8List? data;
      if (widget.bytes != null) {
        data = widget.bytes;
      } else if (widget.url != null) {
        final resp = await http.get(Uri.parse(widget.url!));
        if (resp.statusCode == 200) data = resp.bodyBytes;
      }
      if (data == null) throw Exception('No data');
      final dir = await getTemporaryDirectory();
      final ext = widget.isVideo ? 'mp4' : 'jpg';
      final p = '${dir.path}/save_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await File(p).writeAsBytes(data);
      await XFile(p).saveTo(p);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved'), duration: Duration(seconds: 1)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Save failed: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return '$m min${m == 1 ? '' : 's'} ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h hr${h == 1 ? '' : 's'} ago';
    }
    final d = diff.inDays;
    return '$d day${d == 1 ? '' : 's'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = mq.padding.top;
    final hasText = _strokeText.isNotEmpty;
    final hasReplySupport = widget.session != null && widget.e2e != null;

    // Calculate available space for media
    final topBarH = top + 64.0;
    final bottomBarH = _keyboardVisible ? 340.0 : (mq.padding.bottom + 70);
    final availW = mq.size.width - 40; // 20px padding each side
    final availH = mq.size.height - topBarH - bottomBarH - 20; // 20px gap from input

    // Get actual media aspect ratio
    double mediaAspect = 1.0;
    if (widget.isVideo && _videoReady) {
      mediaAspect = _videoCtrl!.value.aspectRatio;
    } else if (_imageSize != null) {
      mediaAspect = _imageSize!.width / _imageSize!.height;
    }

    // Fit media into available space preserving aspect ratio
    double mediaW, mediaH;
    if (availW / availH > mediaAspect) {
      // Height constrained
      mediaH = math.max(availH, 100);
      mediaW = mediaH * mediaAspect;
    } else {
      // Width constrained
      mediaW = availW;
      mediaH = mediaW / mediaAspect;
    }
    mediaW = mediaW.clamp(100, availW);
    mediaH = mediaH.clamp(100, availH.clamp(100, double.infinity));

    return GestureDetector(
      onVerticalDragStart: _keyboardVisible ? null : (d) {
        _dragging = true;
        _dragY = 0;
      },
      onVerticalDragUpdate: _keyboardVisible ? null : (d) {
        if (!_dragging) return;
        setState(() => _dragY = (_dragY + d.delta.dy).clamp(0, double.infinity));
      },
      onVerticalDragEnd: _keyboardVisible ? null : (d) {
        if (!_dragging) return;
        _dragging = false;
        if (_dragY > 100 || d.velocity.pixelsPerSecond.dy > 800) {
          Navigator.pop(context);
        } else {
          setState(() => _dragY = 0);
        }
      },
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _dragY, 0),
        child: Opacity(
          opacity: (1.0 - _dragY / 400).clamp(0.4, 1.0),
          child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Blurred background
          Positioned.fill(child: _buildBlurBg()),
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.6)),
          ),

          // Tap area to dismiss keyboard
          Positioned(
            top: 0, left: 0, right: 0,
            bottom: _keyboardVisible ? 340 : 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_keyboardVisible) setState(() => _keyboardVisible = false);
              },
            ),
          ),

          // Media — centered, natural aspect ratio, round corners
          Positioned(
            top: topBarH,
            left: 0, right: 0,
            bottom: bottomBarH + 20,
            child: Center(
              child: Container(
                width: mediaW,
                height: mediaH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.06),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.03),
                      blurRadius: 60,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: widget.isVideo ? _buildVideo() : _buildImage(),
                ),
              ),
            ),
          ),

          // Video scrubber overlay
          if (widget.isVideo && _videoReady)
            Positioned(
              left: (mq.size.width - mediaW) / 2 + 4,
              right: (mq.size.width - mediaW) / 2 + 4,
              bottom: bottomBarH + 28,
              child: _buildScrubber(),
            ),

          // Top bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              padding: EdgeInsets.only(top: top + 4),
              child: SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: GlassPill(
                          width: 42,
                          child: SvgPicture.asset('assets/back.svg',
                              width: 16, height: 16,
                              colorFilter: const ColorFilter.mode(
                                  Colors.white70, BlendMode.srcIn)),
                        ),
                      ),
                      const Spacer(),
                      if (widget.senderName.isNotEmpty)
                        Text(
                          'Sent by ${widget.senderName}'
                              '${widget.sentAt != null ? ' · ${_relativeTime(widget.sentAt!)}' : ''}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.2,
                          ),
                        ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _saveToDevice,
                        child: GlassPill(
                          width: 42,
                          child: _saving
                              ? SizedBox(width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: Colors.white.withValues(alpha: 0.6)))
                              : Icon(Icons.download_rounded, size: 18,
                                  color: Colors.white.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom — input bar + keyboard
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _keyboardVisible && hasReplySupport
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildInputBar(hasText),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(12),
                          topRight: Radius.circular(12),
                        ),
                        child: StrokeKeyboard(
                          enabled: widget.session?.hasActiveSession ?? false,
                          onKeyTap: _onKeyTap,
                          onBackspace: _onBackspace,
                          onReturn: () {},
                        ),
                      ),
                    ],
                  )
                : Padding(
                    padding: EdgeInsets.only(bottom: mq.padding.bottom),
                    child: hasReplySupport
                        ? GestureDetector(
                            onTap: () => setState(() => _keyboardVisible = true),
                            child: _buildInputBar(hasText),
                          )
                        : const SizedBox.shrink(),
                  ),
          ),

          // Top gradient fade
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: top + 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    ),
    ),
    );
  }

  Widget _buildInputBar(bool hasText) {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 4, bottom: 0),
      color: Colors.transparent,
      child: GlassContainer(
        borderRadius: 22,
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4, top: 4, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: hasText
                        ? StrokeText(
                            strokeText: _strokeText,
                            sessionId: widget.session?.activeSessionId ?? '',
                            sharedSecret: widget.deriveSecret != null
                                ? widget.deriveSecret!(widget.sessionVersion)
                                : Uint8List(0),
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                          )
                        : Text(
                            'Message…',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white.withValues(alpha: 0.35),
                              letterSpacing: -0.2,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: hasText
                    ? GestureDetector(
                        key: const ValueKey('send'),
                        onTap: _send,
                        child: Container(
                          width: 34, height: 34,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: Color(0xFF007AFF),
                            shape: BoxShape.circle,
                          ),
                          child: SvgPicture.asset('assets/send.svg',
                              width: 16, height: 16,
                              colorFilter: const ColorFilter.mode(
                                  Colors.white, BlendMode.srcIn)),
                        ),
                      )
                    : const SizedBox(key: ValueKey('empty'), width: 34, height: 34),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBlurBg() {
    Widget? img;
    if (widget.bytes != null && !widget.isVideo) {
      img = Image.memory(widget.bytes!, fit: BoxFit.cover,
          width: double.infinity, height: double.infinity);
    } else if (widget.url != null && !widget.isVideo) {
      img = Image.network(widget.url!, fit: BoxFit.cover,
          width: double.infinity, height: double.infinity,
          errorBuilder: (_, __, ___) => const SizedBox.expand());
    }
    if (img == null) return const SizedBox.expand();
    return Stack(
      fit: StackFit.expand,
      children: [
        img,
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: Container(color: Colors.transparent),
        ),
      ],
    );
  }

  Widget _buildImage() {
    final child = widget.bytes != null
        ? Image.memory(widget.bytes!, fit: BoxFit.cover,
            width: double.infinity, height: double.infinity)
        : Image.network(widget.url!, fit: BoxFit.cover,
            width: double.infinity, height: double.infinity,
            loadingBuilder: (_, child, p) {
              if (p == null) return child;
              return const Center(child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white38));
            },
            errorBuilder: (_, __, ___) => Center(child: Icon(
                Icons.broken_image_outlined, size: 32,
                color: Colors.white.withValues(alpha: 0.15))),
          );
    return child;
  }

  Widget _buildVideo() {
    if (_videoError) {
      return Center(child: Icon(Icons.error_outline, size: 32,
          color: Colors.white.withValues(alpha: 0.25)));
    }
    if (!_videoReady) {
      return const Center(child: CircularProgressIndicator(
          strokeWidth: 2, color: Colors.white38));
    }
    return GestureDetector(
      onTap: () {
        _videoCtrl!.value.isPlaying ? _videoCtrl!.pause() : _videoCtrl!.play();
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoCtrl!.value.size.width,
                height: _videoCtrl!.value.size.height,
                child: VideoPlayer(_videoCtrl!),
              ),
            ),
          ),
          if (!_videoCtrl!.value.isPlaying)
            Container(width: 48, height: 48,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.4)),
              child: const Icon(Icons.play_arrow_rounded,
                  size: 28, color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildScrubber() {
    return Row(
      children: [
        Text(_fmt(_videoCtrl!.value.position),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 10)),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: Colors.white,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
            ),
            child: Slider(
              value: _videoCtrl!.value.duration.inMilliseconds > 0
                  ? _videoCtrl!.value.position.inMilliseconds /
                      _videoCtrl!.value.duration.inMilliseconds : 0,
              onChanged: (v) {
                _videoCtrl!.seekTo(Duration(milliseconds:
                    (v * _videoCtrl!.value.duration.inMilliseconds).round()));
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(_fmt(_videoCtrl!.value.duration),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 10)),
      ],
    );
  }
}
