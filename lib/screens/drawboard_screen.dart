import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_container.dart';

class DrawboardScreen extends StatefulWidget {
  final String convoId;
  final String friendEmail;

  const DrawboardScreen({
    super.key,
    required this.convoId,
    required this.friendEmail,
  });

  @override
  State<DrawboardScreen> createState() => _DrawboardScreenState();
}

class _DrawboardScreenState extends State<DrawboardScreen>
    with TickerProviderStateMixin {
  final _supa = SupaConfig.client;
  String get _uid => _supa.auth.currentUser!.id;

  // Drawing state — multi-page
  final List<_DrawPage> _pages = [_DrawPage()];
  int _currentPage = 0;
  List<Offset> _currentPoints = [];
  Color _currentColor = Colors.white;
  double _brushSize = 6.0;
  _BrushType _brushType = _BrushType.round;
  bool _isEraser = false;

  // Convenience accessors for current page
  List<_DrawStroke> get _strokes => _pages[_currentPage].strokes;
  List<_DrawStroke> get _remoteStrokes => _pages[_currentPage].remoteStrokes;

  // UI state
  bool _showColorPicker = false;
  bool _showBrushPicker = false;
  late final AnimationController _colorPickerCtrl;
  late final Animation<double> _colorPickerAnim;
  late final AnimationController _brushPickerCtrl;
  late final Animation<double> _brushPickerAnim;
  late final AnimationController _pageSlideCtrl;
  double _pageSlideDirection = 1.0; // 1 = right, -1 = left

  RealtimeChannel? _drawChannel;

  static const List<Color> _palette = [
    Colors.white,
    Color(0xFFFF453A),
    Color(0xFFFF9F0A),
    Color(0xFFFFD60A),
    Color(0xFF30D158),
    Color(0xFF007AFF),
    Color(0xFF5856D6),
    Color(0xFFBF5AF2),
    Color(0xFFFF375F),
    Color(0xFF64D2FF),
    Color(0xFFAC8E68),
    Color(0xFF8E8E93),
  ];

  @override
  void initState() {
    super.initState();
    _colorPickerCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 350));
    _colorPickerAnim = CurvedAnimation(
      parent: _colorPickerCtrl, curve: Curves.easeOutCubic);
    _brushPickerCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 350));
    _brushPickerAnim = CurvedAnimation(
      parent: _brushPickerCtrl, curve: Curves.easeOutCubic);
    _pageSlideCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
    _subscribeRealtime();
    _loadDrawing();
  }

  @override
  void dispose() {
    _drawChannel?.unsubscribe();
    _colorPickerCtrl.dispose();
    _brushPickerCtrl.dispose();
    _pageSlideCtrl.dispose();
    super.dispose();
  }

  // ── Persistence ──────────────────────────────────────────────
  Future<void> _loadDrawing() async {
    try {
      final res = await _supa
          .from('drawing_sessions')
          .select('pages_json')
          .eq('convo_id', widget.convoId)
          .maybeSingle();
      if (res == null || res['pages_json'] == null) return;
      final List<dynamic> pagesData = res['pages_json'] is String
          ? jsonDecode(res['pages_json']) as List
          : res['pages_json'] as List;
      if (!mounted) return;
      setState(() {
        _pages.clear();
        for (final pageData in pagesData) {
          final page = _DrawPage();
          final allStrokes = (pageData['strokes'] as List? ?? [])
              .map((s) => _DrawStroke.fromJson(s as Map<String, dynamic>))
              .toList();
          page.strokes.addAll(allStrokes);
          _pages.add(page);
        }
        if (_pages.isEmpty) _pages.add(_DrawPage());
        if (_currentPage >= _pages.length) _currentPage = 0;
      });
    } catch (_) {
      // First time — no saved drawing yet, that's fine
    }
  }

  Future<void> _saveDrawing() async {
    try {
      final pagesJson = _pages.map((page) {
        // Merge local + remote strokes so both sides see the full picture
        final all = [...page.remoteStrokes, ...page.strokes];
        return {'strokes': all.map((s) => s.toJson()).toList()};
      }).toList();
      await _supa.from('drawing_sessions').upsert({
        'convo_id': widget.convoId,
        'pages_json': pagesJson,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Silent fail — realtime still works even if persist fails
    }
  }

  void _subscribeRealtime() {
    _drawChannel = _supa
        .channel('draw:${widget.convoId}',
            opts: const RealtimeChannelConfig(private: true))
        .onBroadcast(event: 'stroke', callback: (payload) {
          if (payload['sender_id'] == _uid) return;
          final data = payload['stroke'] as Map<String, dynamic>?;
          final pageIdx = payload['page'] as int? ?? 0;
          if (data == null) return;
          if (mounted) {
            setState(() {
              while (_pages.length <= pageIdx) {
                _pages.add(_DrawPage());
              }
              _pages[pageIdx].remoteStrokes.add(_DrawStroke.fromJson(data));
            });
            _saveDrawing();
          }
        })
        .onBroadcast(event: 'clear', callback: (payload) {
          final pageIdx = payload['page'] as int? ?? 0;
          if (mounted) {
            setState(() {
              if (pageIdx < _pages.length) {
                _pages[pageIdx].strokes.clear();
                _pages[pageIdx].remoteStrokes.clear();
              }
            });
            _saveDrawing();
          }
        })
        .subscribe();
  }

  void _onPanStart(DragStartDetails d) {
    setState(() => _currentPoints = [d.localPosition]);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _currentPoints = List.from(_currentPoints)..add(d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) {
    final stroke = _DrawStroke(
      points: List.from(_currentPoints),
      color: _isEraser ? Colors.black : _currentColor,
      size: _brushSize,
      brushType: _brushType,
      isEraser: _isEraser,
    );
    setState(() { _strokes.add(stroke); _currentPoints = []; });
    _drawChannel?.sendBroadcastMessage(
      event: 'stroke',
      payload: {'sender_id': _uid, 'stroke': stroke.toJson(), 'page': _currentPage},
    );
    _saveDrawing();
  }

  void _clearCanvas() {
    setState(() { _strokes.clear(); _remoteStrokes.clear(); });
    _drawChannel?.sendBroadcastMessage(
      event: 'clear', payload: {'sender_id': _uid, 'page': _currentPage});
    _saveDrawing();
  }

  void _undo() {
    if (_strokes.isNotEmpty) setState(() => _strokes.removeLast());
  }

  void _addPage() {
    setState(() {
      _pages.add(_DrawPage());
    });
    _goToPage(_pages.length - 1, direction: 1);
  }

  void _goToPage(int idx, {required double direction}) {
    if (idx < 0 || idx >= _pages.length || idx == _currentPage) return;
    if (_pageSlideCtrl.isAnimating) return;
    _pageSlideDirection = direction;
    _pageSlideCtrl.forward(from: 0).then((_) {
      setState(() {
        _currentPage = idx;
        _currentPoints = [];
      });
      _pageSlideDirection = -direction;
      _pageSlideCtrl.reverse();
    });
  }

  void _prevPage() => _goToPage(_currentPage - 1, direction: -1);
  void _nextPage() => _goToPage(_currentPage + 1, direction: 1);

  void _toggleColorPicker() {
    if (_showBrushPicker) { _brushPickerCtrl.reverse(); _showBrushPicker = false; }
    if (_showColorPicker) {
      _colorPickerCtrl.reverse().then((_) {
        if (mounted) setState(() => _showColorPicker = false);
      });
    } else {
      setState(() => _showColorPicker = true);
      _colorPickerCtrl.forward();
    }
  }

  void _toggleBrushPicker() {
    if (_showColorPicker) { _colorPickerCtrl.reverse(); _showColorPicker = false; }
    if (_showBrushPicker) {
      _brushPickerCtrl.reverse().then((_) {
        if (mounted) setState(() => _showBrushPicker = false);
      });
    } else {
      setState(() => _showBrushPicker = true);
      _brushPickerCtrl.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Canvas with page slide animation
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pageSlideCtrl,
              builder: (context, child) {
                final screenW = MediaQuery.of(context).size.width;
                final offset = _pageSlideCtrl.value * _pageSlideDirection * screenW;
                final opacity = 1.0 - (_pageSlideCtrl.value * 0.3);
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: child,
                  ),
                );
              },
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: CustomPaint(
                  painter: _DrawPainter(
                    strokes: _strokes,
                    remoteStrokes: _remoteStrokes,
                    currentPoints: _currentPoints,
                    currentColor: _isEraser ? Colors.black : _currentColor,
                    currentSize: _brushSize,
                    currentBrush: _brushType,
                    isEraser: _isEraser,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),

          // Top bar — just back button
          Positioned(
            top: topPad + 8, left: 10, right: 10,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: GlassPill(width: 42,
                    child: SvgPicture.asset('assets/back.svg',
                        width: 16, height: 16,
                        colorFilter: const ColorFilter.mode(
                            Colors.white70, BlendMode.srcIn))),
                ),
              ],
            ),
          ),

          // Bottom toolbar
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showColorPicker)
                  AnimatedBuilder(
                    animation: _colorPickerAnim,
                    builder: (context, _) {
                      final t = _colorPickerAnim.value;
                      return Opacity(opacity: t,
                        child: Transform.translate(
                          offset: Offset(0, 20 * (1 - t)),
                          child: _buildColorPanel()));
                    },
                  ),
                if (_showBrushPicker)
                  AnimatedBuilder(
                    animation: _brushPickerAnim,
                    builder: (context, _) {
                      final t = _brushPickerAnim.value;
                      return Opacity(opacity: t,
                        child: Transform.translate(
                          offset: Offset(0, 20 * (1 - t)),
                          child: _buildBrushPanel()));
                    },
                  ),
                // Main toolbar
                Container(
                  padding: EdgeInsets.only(
                      left: 10, right: 10, top: 8, bottom: bottomPad + 12),
                  child: GlassContainer(
                    borderRadius: 27,
                    child: Container(
                      height: 54,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                          children: [
                            // Color swatch
                            _toolBtn(
                              onTap: _toggleColorPicker,
                              child: Container(
                                width: 28, height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _currentColor,
                                  border: Border.all(
                                    color: _showColorPicker
                                        ? const Color(0xFF007AFF)
                                        : Colors.white.withValues(alpha: 0.25),
                                    width: _showColorPicker ? 2.5 : 2),
                                ),
                              ),
                            ),
                            // Brush type
                            _toolBtn(
                              onTap: _toggleBrushPicker,
                              selected: _showBrushPicker,
                              child: SvgPicture.asset('assets/pencil.svg',
                                  width: 20, height: 20,
                                  colorFilter: ColorFilter.mode(
                                    _showBrushPicker
                                        ? const Color(0xFF007AFF)
                                        : Colors.white.withValues(alpha: 0.7),
                                    BlendMode.srcIn)),
                            ),
                            // Eraser
                            _toolBtn(
                              onTap: () => setState(() => _isEraser = !_isEraser),
                              selected: _isEraser,
                              child: SvgPicture.asset('assets/eraser.svg',
                                  width: 20, height: 20,
                                  colorFilter: ColorFilter.mode(
                                    _isEraser
                                        ? const Color(0xFF007AFF)
                                        : Colors.white.withValues(alpha: 0.7),
                                    BlendMode.srcIn)),
                            ),
                            const SizedBox(width: 4),
                            // Size preview dot
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: _brushSize.clamp(5.0, 24.0),
                              height: _brushSize.clamp(5.0, 24.0),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isEraser
                                    ? Colors.white.withValues(alpha: 0.3)
                                    : _currentColor,
                              ),
                            ),
                            const Spacer(),
                            // Undo
                            _toolBtn(
                              onTap: _undo,
                              child: Icon(Icons.undo_rounded, size: 20,
                                color: Colors.white.withValues(alpha: 0.7)),
                            ),
                            // Clear
                            _toolBtn(
                              onTap: _clearCanvas,
                              child: SvgPicture.asset('assets/trash.svg',
                                  width: 20, height: 20,
                                  colorFilter: ColorFilter.mode(
                                    Colors.white.withValues(alpha: 0.7),
                                    BlendMode.srcIn)),
                            ),
                            // Page divider
                            Container(width: 1, height: 22,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              color: Colors.white.withValues(alpha: 0.1)),
                            // Prev page
                            _toolBtn(
                              onTap: _currentPage > 0 ? _prevPage : () {},
                              child: Icon(Icons.chevron_left_rounded, size: 22,
                                color: _currentPage > 0
                                    ? Colors.white.withValues(alpha: 0.7)
                                    : Colors.white.withValues(alpha: 0.15)),
                            ),
                            Text(
                              '${_currentPage + 1}/${_pages.length}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            // Next page
                            _toolBtn(
                              onTap: _currentPage < _pages.length - 1 ? _nextPage : () {},
                              child: Icon(Icons.chevron_right_rounded, size: 22,
                                color: _currentPage < _pages.length - 1
                                    ? Colors.white.withValues(alpha: 0.7)
                                    : Colors.white.withValues(alpha: 0.15)),
                            ),
                            // Add page
                            _toolBtn(
                              onTap: _addPage,
                              child: Icon(Icons.add_rounded, size: 20,
                                color: Colors.white.withValues(alpha: 0.7)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn({
    required Widget child,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 38, height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }

  Widget _buildColorPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GlassContainer(
        borderRadius: 22,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 12, runSpacing: 12,
            children: _palette.map((color) {
              final sel = _currentColor == color && !_isEraser;
              return GestureDetector(
                onTap: () {
                  setState(() { _currentColor = color; _isEraser = false; });
                  _toggleColorPicker();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle, color: color,
                    border: Border.all(
                      color: sel ? const Color(0xFF007AFF)
                          : Colors.white.withValues(alpha: 0.08),
                      width: sel ? 3 : 1),
                    boxShadow: sel ? [
                      BoxShadow(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.4),
                        blurRadius: 8),
                    ] : null,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildBrushPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GlassContainer(
        borderRadius: 22,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brush types
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _brushTypeBtn('Round', _BrushType.round, Icons.circle),
                    _brushTypeBtn('Flat', _BrushType.flat, Icons.horizontal_rule_rounded),
                    _brushTypeBtn('Soft', _BrushType.soft, Icons.blur_on_rounded),
                  ],
                ),
                const SizedBox(height: 16),
                // Draggable size slider
                Row(
                  children: [
                    // Small dot
                    Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: _currentColor.withValues(alpha: 0.6),
                          inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                          thumbColor: _currentColor,
                          overlayColor: _currentColor.withValues(alpha: 0.15),
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 10),
                        ),
                        child: Slider(
                          value: _brushSize,
                          min: 1,
                          max: 30,
                          onChanged: (v) => setState(() => _brushSize = v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Big dot
                    Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.3)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_brushSize.round()}px',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      );
  }

  Widget _brushTypeBtn(String label, _BrushType type, IconData icon) {
    final sel = _brushType == type;
    return GestureDetector(
      onTap: () => setState(() => _brushType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: sel ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
          border: Border.all(
            color: sel ? Colors.white.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.06),
            width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20,
                color: sel ? Colors.white : Colors.white.withValues(alpha: 0.4)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(
              color: sel ? Colors.white.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.35),
              fontSize: 11, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Data models
// ══════════════════════════════════════════════════════════════

enum _BrushType { round, flat, soft }

class _DrawPage {
  final List<_DrawStroke> strokes = [];
  final List<_DrawStroke> remoteStrokes = [];
}

class _DrawStroke {
  final List<Offset> points;
  final Color color;
  final double size;
  final _BrushType brushType;
  final bool isEraser;

  const _DrawStroke({
    required this.points,
    required this.color,
    required this.size,
    required this.brushType,
    required this.isEraser,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => [p.dx, p.dy]).toList(),
        'color': color.toARGB32(),
        'size': size,
        'brush': brushType.index,
        'eraser': isEraser,
      };

  factory _DrawStroke.fromJson(Map<String, dynamic> json) {
    final pts = (json['points'] as List)
        .map((p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();
    return _DrawStroke(
      points: pts,
      color: Color(json['color'] as int),
      size: (json['size'] as num).toDouble(),
      brushType: _BrushType.values[json['brush'] as int? ?? 0],
      isEraser: json['eraser'] as bool? ?? false,
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Canvas painter
// ══════════════════════════════════════════════════════════════

class _DrawPainter extends CustomPainter {
  final List<_DrawStroke> strokes;
  final List<_DrawStroke> remoteStrokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentSize;
  final _BrushType currentBrush;
  final bool isEraser;

  _DrawPainter({
    required this.strokes,
    required this.remoteStrokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentSize,
    required this.currentBrush,
    required this.isEraser,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Save layer so eraser (BlendMode.clear) works properly
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    for (final stroke in [...remoteStrokes, ...strokes]) {
      _drawStroke(canvas, stroke.points, stroke.color, stroke.size,
          stroke.brushType, stroke.isEraser);
    }
    if (currentPoints.isNotEmpty) {
      _drawStroke(canvas, currentPoints, currentColor, currentSize,
          currentBrush, isEraser);
    }

    canvas.restore();
  }

  void _drawStroke(Canvas canvas, List<Offset> points, Color color,
      double strokeSize, _BrushType brush, bool eraser) {
    if (points.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeSize
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    if (eraser) {
      paint.blendMode = BlendMode.clear;
      paint.strokeCap = StrokeCap.round;
    } else {
      switch (brush) {
        case _BrushType.round:
          paint.strokeCap = StrokeCap.round;
          break;
        case _BrushType.flat:
          paint.strokeCap = StrokeCap.butt;
          break;
        case _BrushType.soft:
          paint.strokeCap = StrokeCap.round;
          paint.maskFilter =
              MaskFilter.blur(BlurStyle.normal, strokeSize * 0.35);
          break;
      }
    }

    if (points.length == 1) {
      final dotPaint = Paint()
        ..color = paint.color
        ..style = PaintingStyle.fill;
      if (eraser) dotPaint.blendMode = BlendMode.clear;
      if (brush == _BrushType.soft && !eraser) {
        dotPaint.maskFilter =
            MaskFilter.blur(BlurStyle.normal, strokeSize * 0.35);
      }
      canvas.drawCircle(points.first, strokeSize / 2, dotPaint);
      return;
    }

    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DrawPainter old) => true;
}
