import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:record/record.dart';
import '../widgets/glass_pill.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/supabase_client.dart';
import '../services/bg_removal_service.dart';
import '../services/sv_cache.dart';

class _SvItem {
  final String name;
  final String url;
  final String? createdAt;
  const _SvItem({required this.name, required this.url, this.createdAt});
}

class SvMakerScreen extends StatefulWidget {
  const SvMakerScreen({super.key});
  @override
  State<SvMakerScreen> createState() => _SvMakerScreenState();
}

class _SvMakerScreenState extends State<SvMakerScreen> {
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  final _audioRecorder = AudioRecorder();
  final _supa = SupaConfig.client;

  // Video source
  File? _sourceVideo;
  File? _sourceImage;
  double _videoDurationSec = 0;
  double _clipStart = 0;
  double _clipEnd = 3;

  // Audio
  File? _audioFile;
  bool _audioFromSameVideo = true;
  Duration _audioDuration = Duration.zero;
  double _audioTrimStart = 0;
  double _audioTrimEnd = 5;
  bool _audioPlaying = false;

  // Mic recording
  bool _isRecording = false;

  // State
  bool _processing = false;
  String _status = '';
  File? _generatedSv;
  String? _generatedVisualPath;
  String? _generatedAudioPath;
  bool _generatedIsVideo = false;
  VideoPlayerController? _previewCtrl;

  // Video player
  VideoPlayerController? _vpCtrl;
  bool _videoPlaying = false;

  // BG removal
  bool _removeBg = true;

  // Saved SVs grid
  List<_SvItem> _savedSvs = [];
  bool _loadingSvs = true;

  String get _uid => _supa.auth.currentUser?.id ?? '';
  bool get _hasSource => _sourceVideo != null || _sourceImage != null;
  bool get _hasVideo => _sourceVideo != null;
  bool get _hasAudio =>
      _audioFile != null || (_audioFromSameVideo && _sourceVideo != null);

  @override
  void initState() {
    super.initState();
    _loadSavedSvs();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _vpCtrl?.dispose();
    _previewCtrl?.dispose();
    super.dispose();
  }

  // ── Data ──

  Future<void> _loadSavedSvs() async {
    if (_uid.isEmpty) { setState(() => _loadingSvs = false); return; }
    try {
      final list = await _supa.storage.from('sv').list(path: _uid);
      final items = <_SvItem>[];
      for (final f in list) {
        if (!f.name.endsWith('.sv')) continue;
        final url = _supa.storage.from('sv').getPublicUrl('$_uid/${f.name}');
        items.add(_SvItem(name: f.name, url: url, createdAt: f.createdAt));
      }
      items.sort((a, b) => (b.createdAt ?? '').compareTo(a.createdAt ?? ''));
      if (mounted) setState(() { _savedSvs = items; _loadingSvs = false; });
    } catch (e) {
      debugPrint('Load SVs error: $e');
      if (mounted) setState(() => _loadingSvs = false);
    }
  }

  Future<void> _uploadSv(File svFile) async {
    if (_uid.isEmpty) return;
    setState(() => _status = 'Uploading...');
    try {
      final name = svFile.path.split('/').last;
      final bytes = await svFile.readAsBytes();
      await _supa.storage.from('sv').uploadBinary(
        '$_uid/$name', bytes,
        fileOptions: const FileOptions(upsert: true),
      );
      await _loadSavedSvs();
      setState(() => _status = 'Saved!');
    } catch (e) {
      _showError('Upload failed: $e');
    }
  }

  // ── Pick video ──

  Future<void> _pickVideo() async {
    final xf = await _picker.pickVideo(source: ImageSource.gallery);
    if (xf == null) return;
    // Optimistic: show video player immediately, get duration in background
    _vpCtrl?.dispose();
    final ctrl = VideoPlayerController.file(File(xf.path));
    await ctrl.initialize();
    await ctrl.setLooping(false);
    ctrl.addListener(_onVideoTick);
    final fallbackDur = ctrl.value.duration.inMilliseconds / 1000;
    setState(() {
      _vpCtrl = ctrl;
      _sourceVideo = File(xf.path);
      _sourceImage = null;
      _videoDurationSec = fallbackDur;
      _clipStart = 0;
      _clipEnd = fallbackDur > 5 ? 5 : fallbackDur;
      _generatedSv = null;
      _audioFromSameVideo = true;
      _audioTrimStart = 0;
      _audioTrimEnd = fallbackDur > 5 ? 5 : fallbackDur;
      _videoPlaying = false;
    });
  }

  // ── Pick image ──

  Future<void> _pickImage() async {
    final xf = await _picker.pickImage(source: ImageSource.gallery);
    if (xf == null) return;
    _vpCtrl?.dispose();
    setState(() {
      _sourceImage = File(xf.path);
      _sourceVideo = null;
      _vpCtrl = null;
      _videoPlaying = false;
      _videoDurationSec = 0;
      _generatedSv = null;
      _audioFromSameVideo = false;
    });
  }

  void _onVideoTick() {
    if (_vpCtrl == null || !_vpCtrl!.value.isPlaying) return;
    final pos = _vpCtrl!.value.position.inMilliseconds / 1000;
    if (pos >= _clipEnd) {
      _vpCtrl!.pause();
      _vpCtrl!.seekTo(Duration(milliseconds: (_clipStart * 1000).round()));
      if (mounted) setState(() => _videoPlaying = false);
    }
  }

  Future<void> _toggleVideoPlayback() async {
    if (_vpCtrl == null) return;
    if (_videoPlaying) {
      await _vpCtrl!.pause();
      setState(() => _videoPlaying = false);
    } else {
      await _vpCtrl!.seekTo(Duration(milliseconds: (_clipStart * 1000).round()));
      await _vpCtrl!.play();
      setState(() => _videoPlaying = true);
    }
  }

  // ── Pick separate audio ──

  Future<void> _pickSeparateAudio() async {
    final xf = await _picker.pickVideo(source: ImageSource.gallery);
    if (xf == null) return;
    setState(() { _processing = true; _status = 'Extracting audio...'; });
    try {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${dir.path}/sv_audio_$ts.m4a';
      final session = await FFmpegKit.execute(
        '-y -i "${xf.path}" -vn -acodec aac -b:a 64k -ac 1 -ar 44100 "$outPath"'
      );
      if (ReturnCode.isSuccess(await session.getReturnCode()) &&
          await File(outPath).exists()) {
        final player = AudioPlayer();
        await player.setSourceDeviceFile(outPath);
        final dur = await player.getDuration() ?? Duration.zero;
        await player.dispose();
        setState(() {
          _audioFile = File(outPath);
          _audioFromSameVideo = false;
          _audioDuration = dur;
          _audioTrimStart = 0;
          _audioTrimEnd = dur.inMilliseconds > 5000 ? 5 : dur.inSeconds.toDouble();
        });
      } else {
        _showError('Failed to extract audio');
      }
    } catch (e) { _showError('Error: $e'); }
    setState(() { _processing = false; _status = ''; });
  }

  // ── Record audio from mic ──

  Future<void> _startMicRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      _showError('Microphone permission denied');
      return;
    }
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/sv_mic_$ts.m4a';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
      path: path,
    );
    setState(() {
      _isRecording = true;
    });
  }

  Future<void> _stopMicRecording() async {
    final path = await _audioRecorder.stop();
    if (path == null || !await File(path).exists()) {
      setState(() => _isRecording = false);
      _showError('Recording failed');
      return;
    }
    final player = AudioPlayer();
    await player.setSourceDeviceFile(path);
    final dur = await player.getDuration() ?? Duration.zero;
    await player.dispose();
    setState(() {
      _isRecording = false;
      _audioFile = File(path);
      _audioFromSameVideo = false;
      _audioDuration = dur;
      _audioTrimStart = 0;
      _audioTrimEnd = dur.inMilliseconds > 5000 ? 5 : dur.inSeconds.toDouble();
    });
  }

  Future<void> _playPreview() async {
    final file = _audioFromSameVideo ? _sourceVideo : _audioFile;
    if (file == null) return;
    if (_audioPlaying) {
      await _audioPlayer.stop();
      setState(() => _audioPlaying = false);
      return;
    }
    final start = _audioFromSameVideo ? _clipStart : _audioTrimStart;
    final end = _audioFromSameVideo ? _clipEnd : _audioTrimEnd;
    await _audioPlayer.play(
      DeviceFileSource(file.path),
      position: Duration(milliseconds: (start * 1000).round()),
    );
    setState(() => _audioPlaying = true);
    Future.delayed(Duration(milliseconds: ((end - start) * 1000).round()), () {
      if (mounted && _audioPlaying) {
        _audioPlayer.stop();
        setState(() => _audioPlaying = false);
      }
    });
  }

  // ── Generate .sv ──

  Future<void> _generate() async {
    final isImage = _sourceImage != null && _sourceVideo == null;
    if (!isImage && (!_hasVideo || !_hasAudio)) {
      _showError('Pick a video or image first');
      return;
    }
    if (isImage && _audioFile == null) {
      _showError('Pick or record audio first');
      return;
    }
    setState(() { _processing = true; _status = 'Encoding sticker...'; });
    try {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;

      String visualPath;
      String visualName;
      double aDuration;

      if (isImage) {
        // ── Image sticker ──
        final needsBgRemoval = _removeBg && BgRemovalService.isAvailable;
        final pngPath = '${dir.path}/sv_img_$ts.png';

        // Crop to square and resize
        setState(() => _status = 'Processing image...');
        final cropSession = await FFmpegKit.execute(
          '-y -i "${_sourceImage!.path}" '
          '-vf "crop=min(iw\\,ih):min(iw\\,ih),scale=256:256:flags=lanczos" '
          '"$pngPath"'
        );
        if (!ReturnCode.isSuccess(await cropSession.getReturnCode()) ||
            !await File(pngPath).exists()) {
          _showError('Failed to process image');
          setState(() { _processing = false; _status = ''; });
          return;
        }

        if (needsBgRemoval) {
          setState(() => _status = 'Removing background...');
          final noBgPath = '${dir.path}/sv_img_nobg_$ts.png';
          final ok = await BgRemovalService.removeBackground(
            inputPath: pngPath, outputPath: noBgPath,
          );
          visualPath = ok ? noBgPath : pngPath;
        } else {
          visualPath = pngPath;
        }
        visualName = 'sticker.png';
        aDuration = _audioTrimEnd - _audioTrimStart;
      } else {
        // ── Video sticker ──
        final duration = _clipEnd - _clipStart;
        final mp4Path = '${dir.path}/sv_anim_$ts.mp4';
        final needsBgRemoval = _removeBg && BgRemovalService.isAvailable;

      if (needsBgRemoval) {
        // BG removal: RMBG on frame 1, Vision on rest — can afford more fps
        const fps = 10;
        setState(() => _status = 'Extracting frames...');
        final framesDir = Directory('${dir.path}/sv_frames_$ts');
        await framesDir.create(recursive: true);
        final extractSession = await FFmpegKit.execute(
          '-y -ss $_clipStart -t $duration '
          '-i "${_sourceVideo!.path}" '
          '-vf "crop=min(iw\\,ih):min(iw\\,ih),scale=200:200:flags=lanczos,fps=$fps" '
          '"${framesDir.path}/frame_%04d.png"'
        );
        if (!ReturnCode.isSuccess(await extractSession.getReturnCode())) {
          _showError('Failed to extract frames');
          setState(() { _processing = false; _status = ''; });
          return;
        }
        final frameFiles = framesDir.listSync()
          ..sort((a, b) => a.path.compareTo(b.path));
        if (frameFiles.isEmpty) {
          _showError('No frames extracted');
          setState(() { _processing = false; _status = ''; });
          return;
        }

        final noBgDir = Directory('${dir.path}/sv_nobg_$ts');
        await noBgDir.create(recursive: true);
        final inPaths = <String>[];
        final outPaths = <String>[];
        for (final f in frameFiles) {
          inPaths.add(f.path);
          outPaths.add('${noBgDir.path}/${f.path.split('/').last}');
        }
        setState(() => _status = 'Removing BG (${inPaths.length} frames)...');
        final processed = await BgRemovalService.removeBgBatch(
          inputPaths: inPaths, outputPaths: outPaths,
          quality: 'accurate',
        );
        final inputPattern = processed > 0
            ? '${noBgDir.path}/frame_%04d.png'
            : '${framesDir.path}/frame_%04d.png';

        setState(() => _status = 'Encoding sticker...');
        final encodeSession = await FFmpegKit.execute(
          '-y -framerate $fps -i "$inputPattern" '
          '-c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast '
          '-movflags +faststart -an -s 200x200 "$mp4Path"'
        );
        if (!ReturnCode.isSuccess(await encodeSession.getReturnCode()) ||
            !await File(mp4Path).exists()) {
          _showError('Failed to encode sticker');
          setState(() { _processing = false; _status = ''; });
          return;
        }
        // Cleanup frame dirs
        try {
          await framesDir.delete(recursive: true);
          if (await noBgDir.exists()) await noBgDir.delete(recursive: true);
        } catch (_) {}
      } else {
        // Direct video → MP4 (smooth, keeps original frame rate)
        final encodeSession = await FFmpegKit.execute(
          '-y -ss $_clipStart -t $duration '
          '-i "${_sourceVideo!.path}" '
          '-vf "crop=min(iw\\,ih):min(iw\\,ih),scale=256:256:flags=lanczos" '
          '-c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast '
          '-movflags +faststart -an "$mp4Path"'
        );
        if (!ReturnCode.isSuccess(await encodeSession.getReturnCode()) ||
            !await File(mp4Path).exists()) {
          _showError('Failed to encode sticker');
          setState(() { _processing = false; _status = ''; });
          return;
        }
      }

        visualPath = mp4Path;
        visualName = 'sticker.mp4';
        aDuration = duration;
      } // end video else

      // Trim audio
      setState(() => _status = 'Processing audio...');
      final audioSource = _audioFromSameVideo ? _sourceVideo!.path : _audioFile!.path;
      final aStart = _audioFromSameVideo ? _clipStart : _audioTrimStart;
      final trimmedPath = '${dir.path}/sv_trimmed_$ts.opus';
      var trimSession = await FFmpegKit.execute(
        '-y -i "$audioSource" -ss $aStart -t $aDuration '
        '-vn -acodec libopus -b:a 16k -ac 1 -ar 16000 "$trimmedPath"'
      );
      if (!ReturnCode.isSuccess(await trimSession.getReturnCode())) {
        final aacPath = '${dir.path}/sv_trimmed_$ts.m4a';
        await FFmpegKit.execute(
          '-y -i "$audioSource" -ss $aStart -t $aDuration '
          '-vn -acodec aac -b:a 24k -ac 1 -ar 16000 "$aacPath"'
        );
        if (await File(aacPath).exists()) {
          await File(aacPath).copy(trimmedPath);
        } else {
          _showError('Failed to process audio');
          setState(() { _processing = false; _status = ''; });
          return;
        }
      }

      // Package .sv
      setState(() => _status = 'Packaging...');
      final visualBytes = await File(visualPath).readAsBytes();
      final audioBytes = await File(trimmedPath).readAsBytes();
      final isAnimated = visualName.endsWith('.mp4');
      final manifest = '{"version":2,"visual":"$visualName","audio":"audio.opus",'
          '"animated":$isAnimated,"duration":${aDuration.toStringAsFixed(1)},'
          '"created":$ts}';
      final archive = Archive();
      archive.addFile(ArchiveFile('manifest.json', manifest.length,
          Uint8List.fromList(manifest.codeUnits)));
      archive.addFile(ArchiveFile(visualName, visualBytes.length, visualBytes));
      archive.addFile(ArchiveFile('audio.opus', audioBytes.length, audioBytes));
      final encoded = ZipEncoder().encode(archive);
      final svPath = '${dir.path}/sticker_$ts.sv';
      await File(svPath).writeAsBytes(encoded);
      final svFile = File(svPath);
      final size = await svFile.length();

      // Upload
      await _uploadSv(svFile);

      // Extract visual + audio for preview
      String? previewVisual;
      String? previewAudio;
      try {
        final svBytes = await svFile.readAsBytes();
        final svArchive = ZipDecoder().decodeBytes(svBytes);
        for (final f in svArchive.files) {
          if (f.isFile) {
            final outPath = '${dir.path}/sv_preview_${ts}_${f.name}';
            await File(outPath).writeAsBytes(f.content as List<int>);
            if (f.name.startsWith('sticker')) previewVisual = outPath;
            if (f.name.startsWith('audio')) previewAudio = outPath;
          }
        }
      } catch (_) {}

      setState(() {
        _generatedSv = svFile;
        _generatedVisualPath = previewVisual;
        _generatedAudioPath = previewAudio;
        _generatedIsVideo = previewVisual != null && previewVisual.endsWith('.mp4');
        _processing = false;
        _status = '${(size / 1024).toStringAsFixed(0)}KB';
      });

      // Init looping video preview if mp4
      if (_generatedIsVideo && previewVisual != null) {
        final ctrl = VideoPlayerController.file(File(previewVisual));
        await ctrl.initialize();
        await ctrl.setLooping(true);
        await ctrl.setVolume(0);
        await ctrl.play();
        if (mounted) setState(() => _previewCtrl = ctrl);
      }

      // Auto-play audio once
      if (previewAudio != null && mounted) {
        _audioPlayer.play(DeviceFileSource(previewAudio));
      }
    } catch (e) {
      _showError('Error: $e');
      setState(() { _processing = false; _status = ''; });
    }
  }

  Future<void> _deleteSv(String name) async {
    if (_uid.isEmpty) return;
    // Optimistic: remove from list immediately
    setState(() => _savedSvs.removeWhere((s) => s.name == name));
    try {
      await _supa.storage.from('sv').remove(['$_uid/$name']);
    } catch (e) {
      _showError('Delete failed: $e');
      _loadSavedSvs();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade800),
    );
  }

  void _resetForNew() {
    _audioPlayer.stop();
    _previewCtrl?.dispose();
    _vpCtrl?.dispose();
    setState(() {
      _generatedSv = null;
      _generatedVisualPath = null;
      _generatedAudioPath = null;
      _generatedIsVideo = false;
      _previewCtrl = null;
      _sourceVideo = null;
      _sourceImage = null;
      _vpCtrl = null;
      _videoPlaying = false;
      _videoDurationSec = 0;
      _clipStart = 0;
      _clipEnd = 3;
      _audioFile = null;
      _audioFromSameVideo = true;
      _audioTrimStart = 0;
      _audioTrimEnd = 5;
      _status = '';
    });
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Content fills entire screen
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              child: _generatedSv != null
                ? _buildStickerPreview(bottom)
                : ListView(
              key: const ValueKey('editor'),
              padding: EdgeInsets.fromLTRB(16, top + 60, 16, bottom + 20),
              children: [
                // ── Video/Image section ──
                _buildVideoSection(),
                if (_hasSource) ...[
                  const SizedBox(height: 20),
                  // ── Audio section ──
                  _buildAudioSection(),
                  const SizedBox(height: 24),
                  // ── Generate button ──
                  _buildGenerateArea(),
                ],
                // ── My stickers ──
                const SizedBox(height: 32),
                _buildMyStickers(),
              ],
            ),
            ),
          ),
          // Gradient fade overlay
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: top + 70,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black,
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.45, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // Header buttons
          Positioned(
            top: top + 8, left: 16, right: 16,
            child: Row(children: [
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
              const SizedBox(width: 10),
              GlassPill(
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Sticker Studio',
                      style: TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildStickerPreview(double bottom) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        // Sticker visual
        if (_previewCtrl != null && _previewCtrl!.value.isInitialized)
          _GlassBox(
            borderRadius: 24,
            child: SizedBox(
              width: 200, height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _previewCtrl!.value.size.width,
                    height: _previewCtrl!.value.size.height,
                    child: VideoPlayer(_previewCtrl!),
                  ),
                ),
              ),
            ),
          )
        else if (_generatedVisualPath != null)
          _GlassBox(
            borderRadius: 24,
            child: SizedBox(
              width: 200, height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.file(
                  File(_generatedVisualPath!),
                  fit: BoxFit.contain,
                  width: 200, height: 200,
                ),
              ),
            ),
          )
        else
          _GlassBox(
            borderRadius: 24,
            child: const SizedBox(
              width: 200, height: 200,
              child: Center(
                child: Icon(Icons.check_circle, color: Colors.green, size: 48),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Saved  $_status', style: const TextStyle(
          color: Colors.green, fontSize: 15, fontWeight: FontWeight.w500,
        )),
        const SizedBox(height: 8),
        // Replay audio button
        if (_generatedAudioPath != null)
          GestureDetector(
            onTap: () => _audioPlayer.play(
                DeviceFileSource(_generatedAudioPath!)),
            child: GlassPill(
              height: 36,
              borderRadius: 18,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.volume_up_rounded,
                        color: Colors.white.withValues(alpha: 0.4), size: 16),
                    const SizedBox(width: 6),
                    Text('Replay sound', style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4), fontSize: 13,
                    )),
                  ],
                ),
              ),
            ),
          ),
        const Spacer(),
        // New sticker button
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, bottom + 20),
          child: GestureDetector(
            onTap: _resetForNew,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFF007AFF),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('New Sticker', style: TextStyle(
                    color: Colors.white,
                    fontSize: 15, fontWeight: FontWeight.w600,
                  )),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Image preview
        if (_sourceImage != null && _vpCtrl == null) ...[
          _GlassBox(
            borderRadius: 20,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.file(_sourceImage!, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _buildTogglePill(
            icon: Icons.auto_fix_high,
            label: 'Remove BG',
            value: _removeBg,
            onChanged: (v) => setState(() => _removeBg = v),
            subtitle: !BgRemovalService.isAvailable ? 'iOS only' : null,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _buildPickPill(
              icon: Icons.image_rounded,
              label: 'Change Image',
              onTap: _processing ? null : _pickImage,
              compact: true,
            )),
            const SizedBox(width: 8),
            Expanded(child: _buildPickPill(
              icon: Icons.videocam_rounded,
              label: 'Use Video',
              onTap: _processing ? null : _pickVideo,
              compact: true,
            )),
          ]),
        ]
        // Video preview
        else if (_vpCtrl != null && _vpCtrl!.value.isInitialized) ...[
          GestureDetector(
            onTap: _toggleVideoPlayback,
            child: _GlassBox(
              borderRadius: 20,
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 280),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _vpCtrl!.value.aspectRatio,
                      child: VideoPlayer(_vpCtrl!),
                    ),
                    if (!_videoPlaying)
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 28),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Clip range slider
          _buildRangeSlider(
            label: 'Clip',
            start: _clipStart, end: _clipEnd,
            max: _videoDurationSec, maxRange: 5,
            onChanged: (s, e) {
              setState(() {
                _clipStart = s; _clipEnd = e;
                if (_audioFromSameVideo) {
                  _audioTrimStart = s; _audioTrimEnd = e;
                }
              });
              _vpCtrl?.seekTo(Duration(milliseconds: (s * 1000).round()));
            },
          ),
          const SizedBox(height: 10),
          // BG removal pill
          _buildTogglePill(
            icon: Icons.auto_fix_high,
            label: 'Remove BG',
            value: _removeBg,
            onChanged: (v) => setState(() => _removeBg = v),
            subtitle: !BgRemovalService.isAvailable ? 'iOS only' : null,
          ),
        ] else if (!_hasSource) ...[
          // No source yet — pick buttons
          Row(children: [
            Expanded(child: _buildPickPill(
              icon: Icons.videocam_rounded,
              label: 'Pick Video',
              onTap: _processing ? null : _pickVideo,
            )),
            const SizedBox(width: 8),
            Expanded(child: _buildPickPill(
              icon: Icons.image_rounded,
              label: 'Pick Image',
              onTap: _processing ? null : _pickImage,
            )),
          ]),
        ],
        if (_hasVideo) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _buildPickPill(
              icon: Icons.videocam_rounded,
              label: 'Change Video',
              onTap: _processing ? null : _pickVideo,
              compact: true,
            )),
            const SizedBox(width: 8),
            Expanded(child: _buildPickPill(
              icon: Icons.image_rounded,
              label: 'Use Image',
              onTap: _processing ? null : _pickImage,
              compact: true,
            )),
          ]),
        ],
      ],
    );
  }

  Widget _buildAudioSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_hasVideo) ...[
          _buildTogglePill(
            icon: Icons.music_note_rounded,
            label: 'Audio from video',
            value: _audioFromSameVideo,
            onChanged: (v) => setState(() => _audioFromSameVideo = v),
          ),
          const SizedBox(height: 8),
        ],
        if (!_audioFromSameVideo) ...[
          if (_audioFile != null) ...[
            _buildAudioPreview(),
            const SizedBox(height: 8),
            _buildRangeSlider(
              label: 'Audio',
              start: _audioTrimStart, end: _audioTrimEnd,
              max: _audioDuration.inMilliseconds / 1000, maxRange: 5,
              onChanged: (s, e) => setState(() {
                _audioTrimStart = s; _audioTrimEnd = e;
              }),
            ),
            const SizedBox(height: 8),
          ],
          if (_isRecording) ...[
            _buildRecordingIndicator(),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: _buildPickPill(
                  icon: Icons.music_note_rounded,
                  label: _audioFile != null ? 'Change Audio' : 'Select Audio',
                  onTap: (_processing || _isRecording) ? null : _pickSeparateAudio,
                  compact: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildPickPill(
                  icon: _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  label: _isRecording ? 'Stop' : 'Record',
                  onTap: _processing
                      ? null
                      : (_isRecording ? _stopMicRecording : _startMicRecording),
                  compact: true,
                ),
              ),
            ],
          ),
        ] else if (_hasVideo) ...[
          _buildAudioPreview(),
        ],
      ],
    );
  }

  Widget _buildGenerateArea() {
    if (_processing) {
      return _GlassBox(
        borderRadius: 24,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF007AFF)),
              ),
              const SizedBox(width: 12),
              Text(_status, style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
            ],
          ),
        ),
      );
    }
    if (_generatedSv != null) {
      return _GlassBox(
        borderRadius: 24,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text('Saved  $_status', style: const TextStyle(
                  color: Colors.green, fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      );
    }
    final ready = (_hasVideo && _hasAudio) || (_sourceImage != null && _audioFile != null);
    return GestureDetector(
      onTap: ready ? _generate : null,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: ready ? const Color(0xFF007AFF) : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome,
                color: ready ? Colors.white : Colors.white24, size: 20),
            const SizedBox(width: 8),
            Text('Generate Sticker', style: TextStyle(
              color: ready ? Colors.white : Colors.white24,
              fontSize: 15, fontWeight: FontWeight.w600,
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildMyStickers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MY STICKERS', style: TextStyle(
          color: Colors.white.withValues(alpha: 0.25),
          fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1,
        )),
        const SizedBox(height: 6),
        if (_loadingSvs)
          const Center(child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(
                color: Color(0xFF007AFF), strokeWidth: 2),
          ))
        else if (_savedSvs.isEmpty)
          Center(child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text('No stickers yet',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2), fontSize: 13)),
          ))
        else
          GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2,
            ),
            itemCount: _savedSvs.length,
            itemBuilder: (_, i) {
              final sv = _savedSvs[i];
              return Stack(
                children: [
                  Positioned.fill(
                    child: _GlassBox(
                      borderRadius: 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox.expand(
                          child: _SvGridThumb(svUrl: sv.url),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4, right: 4,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _deleteSv(sv.name),
                      child: Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                        child: Center(
                          child: SvgPicture.asset('assets/trash.svg',
                            width: 14, height: 14,
                            colorFilter: const ColorFilter.mode(
                              Colors.white70, BlendMode.srcIn),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  // ── Reusable widgets ──

  Widget _buildRecordingIndicator() {
    return _GlassBox(
      borderRadius: 24,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Colors.red,
            ),
          ),
          const SizedBox(width: 10),
          Text('Recording...', style: TextStyle(
            color: Colors.red.withValues(alpha: 0.8), fontSize: 14,
            fontWeight: FontWeight.w500,
          )),
        ]),
      ),
    );
  }

  Widget _buildPickPill({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool compact = false,
  }) {
    final r = compact ? 20.0 : 26.0;
    final h = compact ? 40.0 : 52.0;
    return GestureDetector(
      onTap: onTap,
      child: _GlassBox(
        borderRadius: r,
        child: SizedBox(
          height: h,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: const Color(0xFF007AFF),
                  size: compact ? 16 : 20),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: compact ? 13 : 14, fontWeight: FontWeight.w500,
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTogglePill({
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return _GlassBox(
      borderRadius: 20,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 16, right: 10),
        child: Row(children: [
          Icon(icon, color: const Color(0xFF007AFF), size: 18),
          const SizedBox(width: 10),
          Expanded(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 14)),
              if (subtitle != null)
                Text(subtitle, style: TextStyle(
                    color: Colors.orange.withValues(alpha: 0.5), fontSize: 10)),
            ],
          )),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: value, onChanged: onChanged,
              activeTrackColor: const Color(0xFF007AFF),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildRangeSlider({
    required String label,
    required double start, required double end,
    required double max, required double maxRange,
    required void Function(double s, double e) onChanged,
  }) {
    return _GlassBox(
      borderRadius: 20,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(children: [
          Row(children: [
            Text(label, style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4), fontSize: 12,
                fontWeight: FontWeight.w500)),
            const Spacer(),
            Text('${start.toStringAsFixed(1)}s – ${end.toStringAsFixed(1)}s',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25), fontSize: 11)),
          ]),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              rangeThumbShape: const RoundRangeSliderThumbShape(
                  enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: const Color(0xFF007AFF),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
              thumbColor: Colors.white,
              overlayColor: const Color(0xFF007AFF).withValues(alpha: 0.15),
            ),
            child: RangeSlider(
              values: RangeValues(start, end),
              min: 0, max: max > 0 ? max : 1,
              onChanged: (v) {
                var s = v.start, e = v.end;
                if (e - s > maxRange) {
                  if (s != start) { e = s + maxRange; } else { s = e - maxRange; }
                }
                onChanged(s.clamp(0, max), e.clamp(0, max));
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildAudioPreview() {
    final label = _audioFromSameVideo
        ? '${_clipStart.toStringAsFixed(1)}s – ${_clipEnd.toStringAsFixed(1)}s'
        : 'Custom audio';
    return GestureDetector(
      onTap: _playPreview,
      child: _GlassBox(
        borderRadius: 24,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Container(
              width: 30, height: 30,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Color(0xFF007AFF)),
              child: Icon(_audioPlaying ? Icons.stop : Icons.play_arrow,
                  color: Colors.white, size: 16),
            ),
            const SizedBox(width: 10),
            Icon(Icons.graphic_eq_rounded,
                color: Colors.white.withValues(alpha: 0.2), size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4), fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

/// Thumbnail widget that extracts and shows the sticker visual from an .sv URL.
class _SvGridThumb extends StatefulWidget {
  final String svUrl;
  const _SvGridThumb({required this.svUrl});
  @override
  State<_SvGridThumb> createState() => _SvGridThumbState();
}

class _SvGridThumbState extends State<_SvGridThumb> {
  String? _visualPath;
  bool _isVideo = false;
  bool _loading = true;
  VideoPlayerController? _ctrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SvCache.instance.get(widget.svUrl);
    if (mounted && data != null) {
      if (data.isVideo) {
        final ctrl = VideoPlayerController.file(File(data.visualPath));
        await ctrl.initialize();
        await ctrl.setLooping(true);
        await ctrl.setVolume(0);
        await ctrl.play();
        if (mounted) {
          setState(() {
            _ctrl = ctrl;
            _visualPath = data.visualPath;
            _isVideo = true;
            _loading = false;
          });
        } else {
          ctrl.dispose();
        }
      } else {
        setState(() {
          _visualPath = data.visualPath;
          _loading = false;
        });
      }
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: Color(0xFF007AFF)),
        ),
      );
    }
    if (_visualPath == null) {
      return const Center(
        child: Icon(Icons.music_video_outlined,
            color: Color(0xFF007AFF), size: 28),
      );
    }
    if (_isVideo && _ctrl != null && _ctrl!.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _ctrl!.value.size.width,
          height: _ctrl!.value.size.height,
          child: VideoPlayer(_ctrl!),
        ),
      );
    }
    return Image.file(File(_visualPath!), fit: BoxFit.cover);
  }
}

/// Simple glass box — backdrop blur + subtle white fill, no tilt border.
class _GlassBox extends StatelessWidget {
  final double borderRadius;
  final Widget child;
  const _GlassBox({required this.borderRadius, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
