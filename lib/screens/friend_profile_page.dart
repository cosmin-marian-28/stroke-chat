import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../core/local_avatar.dart';
import '../core/e2e_encryption.dart';
import '../core/supabase_client.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_container.dart';
import 'bg_editor_screen.dart';
import 'media_viewer_screen.dart';

class FriendProfilePage extends StatefulWidget {
  final String friendUid;
  final String friendUsername;
  final String nickname;
  final String currentUid;
  final String convoId;
  final String chatBg;
  final Color bubbleColor;
  final Uint8List? avatarBytes;
  final ValueChanged<Uint8List> onAvatarChanged;
  final ValueChanged<String> onNicknameChanged;
  final ValueChanged<String> onBgChanged;
  final ValueChanged<Color> onBubbleColorChanged;
  final ValueChanged<List<Color>> onBubbleGradientChanged;
  final VoidCallback onDeleteConversation;
  final Uint8List Function(int version)? deriveSecret;

  const FriendProfilePage({
    super.key,
    required this.friendUid,
    required this.friendUsername,
    required this.nickname,
    required this.currentUid,
    required this.convoId,
    required this.chatBg,
    required this.bubbleColor,
    required this.avatarBytes,
    required this.onAvatarChanged,
    required this.onNicknameChanged,
    required this.onBgChanged,
    required this.onBubbleColorChanged,
    required this.onBubbleGradientChanged,
    required this.onDeleteConversation,
    this.deriveSecret,
  });

  @override
  State<FriendProfilePage> createState() => _FriendProfilePageState();
}

class _FriendProfilePageState extends State<FriendProfilePage>
    with TickerProviderStateMixin {
  late Uint8List? _avatar = widget.avatarBytes;
  late final TextEditingController _nameCtrl;
  late String _localNickname;
  late final AnimationController _editAnimCtrl;
  late final Animation<double> _editAnim;
  bool _isEditingName = false;
  bool _confirmDelete = false;
  late String _selectedBg = widget.chatBg;
  final _focusNode = FocusNode();

  bool _isThemeExpanded = false;
  late final AnimationController _themeExpandCtrl;
  late final Animation<double> _themeExpandAnim;

  bool _isColorExpanded = false;
  late final AnimationController _colorExpandCtrl;
  late final Animation<double> _colorExpandAnim;
  late Color _selectedBubbleColor;

  /// null = All, false = Sent (by me), true = Received (from friend)
  bool? _mediaFilter;

  static const _storage = FlutterSecureStorage();
  static final _picker = ImagePicker();
  final _supa = SupaConfig.client;
  List<Map<String, dynamic>> _mediaMessages = [];
  bool _mediaLoading = true;
  final Map<String, Uint8List?> _videoThumbs = {};
  // Decrypted media cache for encrypted images/videos
  final Map<String, Uint8List> _decryptedMediaCache = {};
  final Set<String> _decryptingUrls = {};

  @override
  void initState() {
    super.initState();
    _localNickname = widget.nickname;
    _nameCtrl = TextEditingController(
      text: _localNickname.isNotEmpty ? _localNickname : widget.friendUsername,
    );
    _editAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _editAnim = CurvedAnimation(
      parent: _editAnimCtrl,
      curve: Curves.easeOutCubic,
    );
    _themeExpandCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _themeExpandAnim = CurvedAnimation(
      parent: _themeExpandCtrl,
      curve: Curves.easeOutCubic,
    );
    _colorExpandCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _colorExpandAnim = CurvedAnimation(
      parent: _colorExpandCtrl,
      curve: Curves.easeOutCubic,
    );
    _selectedBubbleColor = widget.bubbleColor;
    _loadCustomBg();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    try {
      final result = await _supa
          .from('messages')
          .select()
          .eq('convo_id', widget.convoId)
          .inFilter('type', ['image', 'video', 'locked_image'])
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _mediaMessages = List<Map<String, dynamic>>.from(result);
          _mediaLoading = false;
        });
        // Kick off decryption + thumbnail generation in parallel (limited concurrency)
        final futures = <Future>[];
        for (final m in _mediaMessages) {
          final url = m['media_url'] as String?;
          final version = (m['v'] as int?) ?? 0;
          final type = m['type'] as String?;
          if (url == null || type == 'locked_image') continue;
          if (type == 'video') {
            futures.add(_genVideoThumb(m));
          } else {
            futures.add(_decryptAndCacheMedia(url, version));
          }
          // Process in batches of 4 to avoid hammering the network
          if (futures.length >= 4) {
            await Future.wait(futures);
            futures.clear();
          }
        }
        if (futures.isNotEmpty) await Future.wait(futures);
      }
    } catch (_) {
      if (mounted) setState(() => _mediaLoading = false);
    }
  }

  /// Returns the disk cache directory for this convo's media thumbnails.
  Future<Directory> _cacheDir() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/profile_media_cache');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    return cacheDir;
  }

  /// Stable hash key for a URL (short, filesystem-safe).
  String _cacheKey(String url) =>
      md5.convert(utf8.encode(url)).toString();

  Future<void> _genVideoThumb(Map<String, dynamic> msg) async {
    final url = msg['media_url'] as String?;
    if (url == null || _videoThumbs.containsKey(url)) return;

    // Check disk cache for thumbnail first
    final cache = await _cacheDir();
    final thumbFile = File('${cache.path}/vthumb_${_cacheKey(url)}.jpg');
    if (thumbFile.existsSync()) {
      final bytes = await thumbFile.readAsBytes();
      if (mounted) setState(() => _videoThumbs[url] = bytes);
      // Also populate decrypted cache from disk if available
      final decFile = File('${cache.path}/dec_${_cacheKey(url)}');
      if (decFile.existsSync() && !_decryptedMediaCache.containsKey(url)) {
        _decryptedMediaCache[url] = await decFile.readAsBytes();
      }
      return;
    }

    final version = (msg['v'] as int?) ?? 0;
    await _decryptAndCacheMedia(url, version, onDone: (decrypted) async {
      try {
        final tmpFile = File('${cache.path}/prof_thumb_${url.hashCode}.mp4');
        await tmpFile.writeAsBytes(decrypted);
        final thumb = await VideoThumbnail.thumbnailData(
          video: tmpFile.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 200,
          quality: 50,
        );
        if (thumb != null) {
          // Save thumbnail to disk cache
          await thumbFile.writeAsBytes(thumb);
        }
        if (mounted) setState(() => _videoThumbs[url] = thumb);
        // Clean up temp video file
        try { await tmpFile.delete(); } catch (_) {}
      } catch (_) {
        if (mounted) setState(() => _videoThumbs[url] = null);
      }
    });
  }

  Future<void> _decryptAndCacheMedia(String url, int version, {void Function(Uint8List)? onDone}) async {
    if (_decryptedMediaCache.containsKey(url)) {
      onDone?.call(_decryptedMediaCache[url]!);
      return;
    }
    if (_decryptingUrls.contains(url)) return;
    if (widget.deriveSecret == null) return;

    // Check disk cache first
    final cache = await _cacheDir();
    final decFile = File('${cache.path}/dec_${_cacheKey(url)}');
    if (decFile.existsSync()) {
      final bytes = await decFile.readAsBytes();
      if (mounted) setState(() => _decryptedMediaCache[url] = bytes);
      onDone?.call(bytes);
      return;
    }

    _decryptingUrls.add(url);
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final secret = widget.deriveSecret!(version);
        final e2e = E2EEncryption(secret);
        final decrypted = e2e.decryptBytes(Uint8List.fromList(resp.bodyBytes));
        // Save to disk cache
        await decFile.writeAsBytes(decrypted);
        if (mounted) {
          setState(() => _decryptedMediaCache[url] = decrypted);
        }
        onDone?.call(decrypted);
      }
    } catch (_) {}
    _decryptingUrls.remove(url);
  }

  Future<void> _loadCustomBg() async {
    final b64 = await _storage.read(key: 'chat_bg_${widget.convoId}');
    if (b64 != null && mounted) {
    }
  }

  Future<void> _pickCustomBg() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    // Open editor for zoom/pan positioning
    final result = await Navigator.push<List<double>>(
      context,
      MaterialPageRoute(builder: (_) => BgEditorScreen(imageBytes: bytes)),
    );
    if (result == null) return; // cancelled

    // Store image bytes + transform
    await _storage.write(
      key: 'chat_bg_${widget.convoId}',
      value: base64Encode(bytes),
    );
    await _storage.write(
      key: 'chat_bg_transform_${widget.convoId}',
      value: jsonEncode(result),
    );
    if (mounted) {
      setState(() {
        _selectedBg = 'custom';
      });
      widget.onBgChanged('custom');
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _editAnimCtrl.dispose();
    _themeExpandCtrl.dispose();
    _colorExpandCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    final bytes = await LocalAvatar.pickAndSave(widget.friendUid);
    if (bytes != null) {
      setState(() => _avatar = bytes);
      widget.onAvatarChanged(bytes);
    }
  }

  void _startEditing() {
    setState(() => _isEditingName = true);
    _editAnimCtrl.forward();
    Future.delayed(const Duration(milliseconds: 200), () {
      _focusNode.requestFocus();
    });
  }

  void _saveName() {
    final name = _nameCtrl.text.trim();
    if (name.isNotEmpty) {
      setState(() => _localNickname = name);
      widget.onNicknameChanged(name);
    }
    _focusNode.unfocus();
    _editAnimCtrl.reverse().then((_) {
      if (mounted) setState(() => _isEditingName = false);
    });
  }

  String get _displayName =>
      _localNickname.isNotEmpty ? _localNickname : widget.friendUsername;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 40),
          children: [
            SizedBox(height: topPad + 8),
            // Back button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: GlassPill(
                      width: 42,
                      child: SvgPicture.asset('assets/back.svg',
                          width: 16, height: 16,
                          colorFilter: const ColorFilter.mode(Colors.white70, BlendMode.srcIn)),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Avatar
            Center(
              child: GestureDetector(
                onTap: _changeAvatar,
                child: GlassPill(
                  width: 96,
                  height: 96,
                  borderRadius: 48,
                  child: ClipOval(
                    child: _avatar != null
                        ? Image.memory(_avatar!,
                            width: 96, height: 96, fit: BoxFit.cover)
                        : Text(
                            _displayName.isNotEmpty
                                ? _displayName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Name / edit field
            Center(
              child: AnimatedBuilder(
                animation: _editAnim,
                builder: (context, _) {
                  final t = _editAnim.value;
                  final screenW = MediaQuery.of(context).size.width;
                  final expandedW = screenW - 120;
                  final collapsedW = (_displayName.length * 12.0 + 32).clamp(80.0, expandedW);
                  final w = collapsedW + (expandedW - collapsedW) * t;
                  final h = 42.0 + 8.0 * t;

                  return SizedBox(
                    width: w,
                    height: h,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOut,
                      child: _isEditingName
                          ? GlassPill(
                              key: const ValueKey('editing'),
                              height: h,
                              borderRadius: h / 2,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Opacity(
                                      opacity: t.clamp(0.0, 1.0),
                                      child: TextField(
                                        controller: _nameCtrl,
                                        focusNode: _focusNode,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.2,
                                        ),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(horizontal: 16),
                                        ),
                                        onSubmitted: (_) => _saveName(),
                                      ),
                                    ),
                                  ),
                                  Opacity(
                                    opacity: t.clamp(0.0, 1.0),
                                    child: GestureDetector(
                                      onTap: _saveName,
                                      child: Container(
                                        width: 34, height: 34,
                                        margin: const EdgeInsets.only(right: 5),
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Color(0xFF007AFF),
                                        ),
                                        child: const Icon(Icons.check_rounded,
                                            color: Colors.white, size: 16),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : SizedBox(
                              key: const ValueKey('display'),
                              width: w,
                              height: h,
                              child: Center(
                                child: Text(
                                  _displayName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.5,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            // Username subtitle
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: !_isEditingName
                  ? Center(
                      key: const ValueKey('username'),
                      child: Text(
                        '@${widget.friendUsername}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 14,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('hidden')),
            ),
            const SizedBox(height: 24),
            // Action buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _actionButton(
                    svgIcon: 'assets/edit.svg',
                    label: 'Set nickname',
                    onTap: _startEditing,
                  ),
                  const SizedBox(height: 10),
                  _buildThemePicker(),
                  const SizedBox(height: 10),
                  _buildBubbleColorPicker(),
                  const SizedBox(height: 10),
                  _actionButton(
                    icon: Icons.delete_outline_rounded,
                    label: _confirmDelete ? 'Tap again to confirm' : 'Delete conversation',
                    destructive: true,
                    onTap: () {
                      if (_confirmDelete) {
                        widget.onDeleteConversation();
                        Navigator.pop(context);
                      } else {
                        setState(() => _confirmDelete = true);
                        Future.delayed(const Duration(seconds: 3), () {
                          if (mounted) setState(() => _confirmDelete = false);
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Media filter tabs
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _mediaTabButton('All', _mediaFilter == null, () {
                    if (_mediaFilter != null) setState(() => _mediaFilter = null);
                  }),
                  const SizedBox(width: 8),
                  _mediaTabButton('Sent', _mediaFilter == false, () {
                    if (_mediaFilter != false) setState(() => _mediaFilter = false);
                  }),
                  const SizedBox(width: 8),
                  _mediaTabButton('Received', _mediaFilter == true, () {
                    if (_mediaFilter != true) setState(() => _mediaFilter = true);
                  }),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildMediaGrid(),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaGrid() {
    if (_mediaLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24)),
      );
    }
    final filtered = _mediaFilter == null
        ? _mediaMessages
        : _mediaMessages.where((m) {
            final isMine = m['sender_id'] == widget.currentUid;
            return _mediaFilter == true ? !isMine : isMine;
          }).toList();
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No media yet',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14),
          ),
        ),
      );
    }
    const spacing = 2.0;
    const crossAxisCount = 3;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
        ),
        itemCount: filtered.length,
        itemBuilder: (context, i) {
          final msg = filtered[i];
          final type = msg['type'] as String?;
          final url = msg['media_url'] as String?;
          final isVideo = type == 'video';
          final isLocked = type == 'locked_image';

          final msgVersion = (msg['v'] as int?) ?? 0;

          return GestureDetector(
            onTap: () {
              if (url == null) return;
              if (isLocked) return; // can't preview locked images from here
              if (isVideo) {
                final vBytes = _decryptedMediaCache[url];
                if (vBytes == null) return;
                () async {
                  final dir = await getTemporaryDirectory();
                  final tmpFile = File('${dir.path}/prof_play_${DateTime.now().millisecondsSinceEpoch}.mp4');
                  await tmpFile.writeAsBytes(vBytes);
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  Navigator.push(context, PageRouteBuilder(
                    pageBuilder: (_, __, ___) => MediaViewerScreen(
                      url: tmpFile.path,
                      isVideo: true,
                      isLocalFile: true,
                      senderName: (msg['sender_id'] == widget.currentUid) ? 'you' : _displayName,
                      sentAt: msg['created_at'] != null
                          ? DateTime.tryParse(msg['created_at'].toString())
                          : null,
                    ),
                    transitionsBuilder: (_, anim, __, child) =>
                        FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child),
                    transitionDuration: const Duration(milliseconds: 200),
                  ));
                }();
              } else {
                final imgBytes = _decryptedMediaCache[url];
                Navigator.push(context, PageRouteBuilder(
                  pageBuilder: (_, __, ___) => MediaViewerScreen(
                    bytes: imgBytes,
                    url: imgBytes == null ? url : null,
                    senderName: (msg['sender_id'] == widget.currentUid) ? 'you' : _displayName,
                    sentAt: msg['created_at'] != null
                        ? DateTime.tryParse(msg['created_at'].toString())
                        : null,
                  ),
                  transitionsBuilder: (_, anim, __, child) =>
                      FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child),
                  transitionDuration: const Duration(milliseconds: 200),
                ));
              }
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                color: Colors.white.withValues(alpha: 0.04),
                child: isLocked
                    ? Center(
                        child: Icon(Icons.lock_rounded,
                            size: 20, color: Colors.white.withValues(alpha: 0.15)),
                      )
                    : isVideo
                        ? _buildVideoThumb(url)
                        : (url != null
                            ? Builder(builder: (_) {
                                final decBytes = _decryptedMediaCache[url];
                                if (decBytes == null) {
                                  _decryptAndCacheMedia(url, msgVersion);
                                  return Center(
                                    child: SizedBox(width: 20, height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2,
                                        color: Colors.white.withValues(alpha: 0.2))),
                                  );
                                }
                                return Image.memory(decBytes, fit: BoxFit.cover,
                                    width: double.infinity, height: double.infinity);
                              })
                            : const SizedBox.shrink()),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideoThumb(String? url) {
    if (url == null) return const SizedBox.shrink();
    final thumb = _videoThumbs[url];
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          Image.memory(thumb, fit: BoxFit.cover)
        else
          Container(color: Colors.white.withValues(alpha: 0.04)),
        Center(
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.4),
            ),
            child: const Icon(Icons.play_arrow_rounded, size: 16, color: Colors.white),
          ),
        ),
      ],
    );
  }

  void _toggleTheme() {
    if (_isThemeExpanded) {
      _themeExpandCtrl.reverse().then((_) {
        if (mounted) setState(() => _isThemeExpanded = false);
      });
    } else {
      setState(() => _isThemeExpanded = true);
      _themeExpandCtrl.forward();
    }
  }

  Widget _buildThemePicker() {
    return Column(
      children: [
        _actionButton(
          icon: Icons.palette_outlined,
          label: 'App theme',
          onTap: _toggleTheme,
          trailing: AnimatedRotation(
            turns: _isThemeExpanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.2), size: 18),
          ),
        ),
        ClipRect(
          child: AnimatedBuilder(
            animation: _themeExpandAnim,
            builder: (context, child) {
              final t = _themeExpandAnim.value;
              if (t < 0.01) return const SizedBox.shrink();
              return SizeTransition(
                sizeFactor: _themeExpandAnim,
                axisAlignment: -1.0,
                child: FadeTransition(
                  opacity: _themeExpandAnim,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      height: 140,
                      child: Row(
                        children: [
                          _bgOption(
                            label: 'Default',
                            value: 'black',
                            child: Container(
                              color: const Color(0xFF0A0A0A),
                              child: Center(
                                child: Icon(Icons.dark_mode_outlined,
                                    color: Colors.white.withValues(alpha: 0.15), size: 20),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _bgOption(
                            label: 'Photo',
                            value: 'image',
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.asset('assets/signup.png', fit: BoxFit.cover),
                                Container(color: Colors.black.withValues(alpha: 0.3)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _bgOption(
                            label: 'Import',
                            value: 'custom',
                            onTapOverride: _pickCustomBg,
                            child: Container(
                              color: const Color(0xFF0A0A0A),
                              child: Center(
                                child: Icon(Icons.add_photo_alternate_outlined,
                                    color: Colors.white.withValues(alpha: 0.15), size: 20),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _toggleColor() {
    if (_isColorExpanded) {
      _colorExpandCtrl.reverse().then((_) {
        if (mounted) setState(() => _isColorExpanded = false);
      });
    } else {
      setState(() => _isColorExpanded = true);
      _colorExpandCtrl.forward();
    }
  }

  static const _bubbleColors = <Color>[
    Color(0xFF007AFF), // blue
    Color(0xFFFF6B35), // orange
    Color(0xFFE8333A), // red
    Color(0xFFFF2D78), // pink
    Color(0xFFBF5AF2), // purple
    Color(0xFF5E5CE6), // indigo
    Color(0xFF30D158), // green
    Color(0xFF40C8E0), // teal
    Color(0xFFFFD60A), // yellow
    Color(0xFFAC8E68), // gold
  ];

  static const _bubbleGradients = <List<Color>>[
    [Color(0xFF007AFF), Color(0xFF0055CC), Color(0xFF003399)],
    [Color(0xFFFF6B35), Color(0xFFCC4A1A), Color(0xFF993000)],
    [Color(0xFFE8333A), Color(0xFFBB1A22), Color(0xFF8C0010)],
    [Color(0xFFFF2D78), Color(0xFFCC1A5C), Color(0xFF990D40)],
    [Color(0xFFBF5AF2), Color(0xFF9333CC), Color(0xFF6B1A99)],
    [Color(0xFF5E5CE6), Color(0xFF4240B8), Color(0xFF2A288A)],
    [Color(0xFF30D158), Color(0xFF1FA040), Color(0xFF0F7028)],
    [Color(0xFF40C8E0), Color(0xFF2A9AB3), Color(0xFF1A7088)],
    [Color(0xFFFFD60A), Color(0xFFCCAA00), Color(0xFF997F00)],
    [Color(0xFFAC8E68), Color(0xFF8A6E48), Color(0xFF685030)],
  ];

  Widget _buildBubbleColorPicker() {
    return Column(
      children: [
        _actionButton(
          icon: Icons.color_lens_outlined,
          label: 'Message color',
          onTap: _toggleColor,
          trailing: AnimatedRotation(
            turns: _isColorExpanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.2), size: 18),
          ),
        ),
        ClipRect(
          child: AnimatedBuilder(
            animation: _colorExpandAnim,
            builder: (context, child) {
              final t = _colorExpandAnim.value;
              if (t < 0.01) return const SizedBox.shrink();
              return SizeTransition(
                sizeFactor: _colorExpandAnim,
                axisAlignment: -1.0,
                child: FadeTransition(
                  opacity: _colorExpandAnim,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      height: 52,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _bubbleColors.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, i) {
                          final color = _bubbleColors[i];
                          final grad = _bubbleGradients[i];
                          final selected = _selectedBubbleColor == color;
                          return GestureDetector(
                            onTap: () {
                              setState(() => _selectedBubbleColor = color);
                              widget.onBubbleColorChanged(color);
                              widget.onBubbleGradientChanged(grad);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutCubic,
                              width: 52, height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: grad,
                                ),
                                border: Border.all(
                                  color: selected
                                      ? Colors.white.withValues(alpha: 0.8)
                                      : Colors.white.withValues(alpha: 0.08),
                                  width: selected ? 2.5 : 1,
                                ),
                                boxShadow: selected
                                    ? [BoxShadow(
                                        color: color.withValues(alpha: 0.4),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      )]
                                    : null,
                              ),
                              child: selected
                                  ? const Icon(Icons.check_rounded,
                                      color: Colors.white, size: 22)
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _bgOption({
    required String label,
    required String value,
    required Widget child,
    VoidCallback? onTapOverride,
  }) {
    final selected = _selectedBg == value;
    return Expanded(
      child: GestureDetector(
        onTap: onTapOverride ?? () {
          setState(() => _selectedBg = value);
          widget.onBgChanged(value);
        },
        child: Column(
          children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF007AFF)
                        : Colors.white.withValues(alpha: 0.1),
                    width: selected ? 2 : 0.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(selected ? 14 : 15.5),
                  child: child,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF007AFF)
                    : Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaTabButton(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.35),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    IconData? icon,
    String? svgIcon,
    required String label,
    bool destructive = false,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final color = destructive ? const Color(0xFFFF453A) : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: GlassContainer(
        borderRadius: 50,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              if (svgIcon != null)
                SvgPicture.asset(svgIcon,
                    width: 18, height: 18,
                    colorFilter: ColorFilter.mode(color.withValues(alpha: 0.6), BlendMode.srcIn))
              else if (icon != null)
                Icon(icon, color: color.withValues(alpha: 0.6), size: 18),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: color.withValues(alpha: 0.85),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              trailing ?? Icon(Icons.chevron_right_rounded,
                  color: color.withValues(alpha: 0.2), size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
