import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import '../core/supabase_client.dart';
import '../services/sv_cache.dart';
import '../screens/sv_maker_screen.dart';

const _klipyKey = 'gD1AX5NQPxF0Ha9jz5vESWu6sduzASRuf4uxd3kRP9ySXumaN5HVeGKANj5rng4F';
const _baseUrl = 'https://api.klipy.com/v2';

enum MediaTab { gifs, stickers, memes, sv }

class GifPicker extends StatefulWidget {
  final void Function(String gifUrl) onGifSelected;
  final void Function(String url, Offset globalPos)? onStickerDragStart;
  final void Function(Offset globalPos)? onStickerDragUpdate;
  final VoidCallback? onStickerDragEnd;
  final void Function(MediaTab tab)? onTabChanged;
  final double height;
  final String? externalQuery;
  final MediaTab initialTab;

  const GifPicker({
    super.key,
    required this.onGifSelected,
    this.onStickerDragStart,
    this.onStickerDragUpdate,
    this.onStickerDragEnd,
    this.onTabChanged,
    this.height = 200,
    this.externalQuery,
    this.initialTab = MediaTab.gifs,
  });

  @override
  State<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<GifPicker> {
  List<_GifItem> _items = [];
  bool _loading = true;
  String _lastQuery = '';
  late MediaTab _tab;
  List<_SvEntry> _svItems = [];
  bool _svLoading = false;

  bool get _hasExternalSearch => widget.externalQuery != null;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    if (_tab == MediaTab.sv) {
      _loadSvItems();
    } else {
      _loadTrending();
    }
  }

  @override
  void didUpdateWidget(GifPicker old) {
    super.didUpdateWidget(old);
    if (widget.initialTab != old.initialTab) {
      _switchTab(widget.initialTab);
    }
    if (_hasExternalSearch && widget.externalQuery != old.externalQuery) {
      _search(widget.externalQuery ?? '');
    }
  }

  String get _typeParam {
    switch (_tab) {
      case MediaTab.stickers:
        return '&searchfilter=sticker&media_filter=tinygif,gif';
      case MediaTab.memes:
        return '&media_filter=tinygif,gif';
      default:
        return '&media_filter=tinygif,gif';
    }
  }

  Future<void> _loadTrending() async {
    setState(() => _loading = true);
    _lastQuery = '';
    try {
      final String url;
      if (_tab == MediaTab.memes) {
        url = '$_baseUrl/search?q=meme&key=$_klipyKey&limit=30$_typeParam';
      } else {
        url = '$_baseUrl/featured?key=$_klipyKey&limit=30$_typeParam';
      }
      final uri = Uri.parse(url);
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        _parseResults(jsonDecode(res.body));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      _loadTrending();
      return;
    }
    if (query == _lastQuery) return;
    _lastQuery = query;
    setState(() => _loading = true);
    try {
      final q = _tab == MediaTab.memes ? 'meme $query' : query;
      final uri = Uri.parse(
          '$_baseUrl/search?q=${Uri.encodeComponent(q)}&key=$_klipyKey&limit=30$_typeParam');
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        _parseResults(jsonDecode(res.body));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _parseResults(Map<String, dynamic> json) {
    final results = json['results'] as List<dynamic>? ?? [];
    _items = results.map((r) {
      final media = r['media_formats'] ?? r['media'] ?? {};
      final tiny = media['tinygif'] ?? media['gif'] ?? {};
      final preview = media['nanogif'] ?? tiny;
      return _GifItem(
        url: (tiny['url'] as String?) ?? '',
        previewUrl: (preview['url'] as String?) ?? '',
      );
    }).where((g) => g.url.isNotEmpty).toList();
  }

  void _switchTab(MediaTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
    if (tab == MediaTab.sv) {
      _loadSvItems();
      return;
    }
    if (_lastQuery.isNotEmpty) {
      _lastQuery = ''; // force re-search
      _search(widget.externalQuery ?? '');
    } else {
      _loadTrending();
    }
  }

  Future<void> _loadSvItems() async {
    final supa = SupaConfig.client;
    final uid = supa.auth.currentUser?.id ?? '';
    if (uid.isEmpty) return;
    setState(() => _svLoading = true);
    try {
      final list = await supa.storage.from('sv').list(path: uid);
      final items = <_SvEntry>[];
      for (final f in list) {
        if (!f.name.endsWith('.sv')) continue;
        final url = supa.storage.from('sv').getPublicUrl('$uid/${f.name}');
        items.add(_SvEntry(name: f.name, url: url));
      }
      if (mounted) setState(() { _svItems = items; _svLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _svLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(16),
        topRight: Radius.circular(16),
      ),
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
      child: Column(
        children: [
          // Tab bar
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, top: 6, bottom: 4),
            child: Row(
              children: [
                _tabChip('GIFs', MediaTab.gifs),
                const SizedBox(width: 6),
                _tabChip('Stickers', MediaTab.stickers),
                const SizedBox(width: 6),
                _tabChip('Memes', MediaTab.memes),
                const SizedBox(width: 6),
                _tabChip('Audio Stickers', MediaTab.sv),
                const Spacer(),
                Text(
                  'Klipy',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.15),
                    fontSize: 10,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          // Grid
          Expanded(
            child: _tab == MediaTab.sv
                ? _buildSvGrid()
                : _loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.6),
                        strokeWidth: 2))
                : GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _tab == MediaTab.stickers ? 5 : 3,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      final canDrag = _tab == MediaTab.stickers && widget.onStickerDragStart != null;
                      return GestureDetector(
                        onTap: () => widget.onGifSelected(item.url),
                        onLongPressStart: canDrag
                            ? (d) => widget.onStickerDragStart!(item.url, d.globalPosition)
                            : null,
                        onLongPressMoveUpdate: canDrag
                            ? (d) => widget.onStickerDragUpdate?.call(d.globalPosition)
                            : null,
                        onLongPressEnd: canDrag
                            ? (_) => widget.onStickerDragEnd?.call()
                            : null,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            item.previewUrl.isNotEmpty
                                ? item.previewUrl
                                : item.url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _tabChip(String label, MediaTab tab) {
    final selected = _tab == tab;
    return GestureDetector(
      onTap: () => _switchTab(tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? Colors.white.withValues(alpha: 0.8)
                : Colors.white.withValues(alpha: 0.35),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildSvGrid() {
    if (_svLoading) {
      return Center(
        child: CircularProgressIndicator(
            color: const Color(0xFF007AFF).withValues(alpha: 0.6),
            strokeWidth: 2),
      );
    }
    if (_svItems.isEmpty) {
      return GridView.count(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        children: [
          GestureDetector(
            onTap: () async {
              await Navigator.push(context, PageRouteBuilder(
                pageBuilder: (_, __, ___) => const SvMakerScreen(),
                transitionsBuilder: (_, anim, __, child) =>
                    FadeTransition(opacity: anim, child: child),
              ));
              _loadSvItems();
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.white.withValues(alpha: 0.06),
                child: Center(
                  child: Icon(Icons.add_rounded,
                      color: Colors.white.withValues(alpha: 0.4), size: 32),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: _svItems.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return GestureDetector(
            onTap: () async {
              await Navigator.push(ctx, PageRouteBuilder(
                pageBuilder: (_, __, ___) => const SvMakerScreen(),
                transitionsBuilder: (_, anim, __, child) =>
                    FadeTransition(opacity: anim, child: child),
              ));
              _loadSvItems();
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.white.withValues(alpha: 0.06),
                child: Center(
                  child: Icon(Icons.add_rounded,
                      color: Colors.white.withValues(alpha: 0.4), size: 32),
                ),
              ),
            ),
          );
        }
        final sv = _svItems[i - 1];
        return GestureDetector(
          onTap: () => widget.onGifSelected(sv.url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              color: Colors.white.withValues(alpha: 0.06),
              child: _SvThumbnail(svUrl: sv.url),
            ),
          ),
        );
      },
    );
  }
}

class _GifItem {
  final String url;
  final String previewUrl;
  const _GifItem({required this.url, required this.previewUrl});
}

class _SvEntry {
  final String name;
  final String url;
  const _SvEntry({required this.name, required this.url});
}

/// Extracts and displays the sticker visual from an .sv URL.
class _SvThumbnail extends StatefulWidget {
  final String svUrl;
  const _SvThumbnail({required this.svUrl});
  @override
  State<_SvThumbnail> createState() => _SvThumbnailState();
}

class _SvThumbnailState extends State<_SvThumbnail> {
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
            color: Color(0xFF007AFF), size: 24),
      );
    }
    final visual = (_isVideo && _ctrl != null && _ctrl!.value.isInitialized)
        ? FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _ctrl!.value.size.width,
              height: _ctrl!.value.size.height,
              child: VideoPlayer(_ctrl!),
            ),
          )
        : Image.file(File(_visualPath!), fit: BoxFit.cover);
    return Stack(
      fit: StackFit.expand,
      children: [
        visual,
        // Small sound indicator
        Positioned(
          right: 3, bottom: 3,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.volume_up, color: Colors.white, size: 10),
          ),
        ),
      ],
    );
  }
}
