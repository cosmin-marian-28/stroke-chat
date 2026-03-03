import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Custom keyboard that replicates the iOS dark-mode keyboard.
/// Each key shows a magnified preview bubble via Overlay on press.
/// Uses raw pointer events for zero-delay key response.
class StrokeKeyboard extends StatefulWidget {
  final void Function(String displayChar, String strokeChar) onKeyTap;
  final VoidCallback onBackspace;
  final VoidCallback onReturn;
  final bool enabled;
  /// Called when spacebar trackpad moves the cursor. Delta is -1 (left) or +1 (right).
  final void Function(int delta)? onCursorMove;
  /// Called when the emoji button is tapped.
  final VoidCallback? onEmojiToggle;
  /// Whether the emoji picker is currently showing (swaps emoji/ABC button).
  final bool emojiMode;

  const StrokeKeyboard({
    super.key,
    required this.onKeyTap,
    required this.onBackspace,
    required this.onReturn,
    this.enabled = true,
    this.onCursorMove,
    this.onEmojiToggle,
    this.emojiMode = false,
  });

  @override
  State<StrokeKeyboard> createState() => _StrokeKeyboardState();
}

class _StrokeKeyboardState extends State<StrokeKeyboard> {
  bool _isShifted = false;
  bool _capsLock = false;
  bool _showNumbers = false;
  bool _showSymbols = false;

  static const _row1 = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
  static const _row2 = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
  static const _row3 = ['z', 'x', 'c', 'v', 'b', 'n', 'm'];
  static const _numRow1 = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const _numRow2 = ['-', '/', ':', ';', '(', ')', '\$', '&', '@', '"'];
  static const _numRow3 = ['.', ',', '?', '!', "'"];
  static const _symRow1 = ['[', ']', '{', '}', '#', '%', '^', '*', '+', '='];
  static const _symRow2 = ['_', '\\', '|', '~', '<', '>', '€', '£', '¥', '•'];
  static const _symRow3 = ['.', ',', '?', '!', "'"];

  static const double _rowSpacing = 12.0;
  static const double _keySpacing = 6.0;
  static const double _sidePadding = 3.0;

  void _handleKeyTap(String display) {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    widget.onKeyTap(display, display);
    if (_isShifted && !_capsLock && !_showNumbers) {
      setState(() => _isShifted = false);
    }
  }

  void _handleShift() {
    setState(() {
      if (_isShifted && !_capsLock) {
        _capsLock = true;
      } else if (_capsLock) {
        _capsLock = false;
        _isShifted = false;
      } else {
        _isShifted = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                top: 8, left: _sidePadding, right: _sidePadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _showNumbers
                  ? (_showSymbols
                      ? _buildSymbolRows()
                      : _buildNumberRows())
                  : _buildLetterRows(),
            ),
          ),
          SizedBox(height: bottomPadding + 30),
        ],
      ),
    );
  }

  // ── Letter layout ──

  List<Widget> _buildLetterRows() {
    return [
      _buildCharRow(_row1, sidePadding: _sidePadding),
      const SizedBox(height: _rowSpacing),
      _buildCharRow(_row2, sidePadding: 18),
      const SizedBox(height: _rowSpacing),
      _buildShiftRow(),
      const SizedBox(height: _rowSpacing),
      _buildBottomRow(),
    ];
  }

  List<Widget> _buildNumberRows() {
    return [
      _buildCharRow(_numRow1, sidePadding: _sidePadding),
      const SizedBox(height: _rowSpacing),
      _buildCharRow(_numRow2, sidePadding: _sidePadding),
      const SizedBox(height: _rowSpacing),
      _buildNumSymShiftRow(_numRow3),
      const SizedBox(height: _rowSpacing),
      _buildBottomRow(),
    ];
  }

  List<Widget> _buildSymbolRows() {
    return [
      _buildCharRow(_symRow1, sidePadding: _sidePadding),
      const SizedBox(height: _rowSpacing),
      _buildCharRow(_symRow2, sidePadding: _sidePadding),
      const SizedBox(height: _rowSpacing),
      _buildNumSymShiftRow(_symRow3),
      const SizedBox(height: _rowSpacing),
      _buildBottomRow(),
    ];
  }

  // ── Row builders ──

  Widget _buildCharRow(List<String> keys, {double sidePadding = 3}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: sidePadding),
      child: Row(
        children: keys.map((key) {
          final display = (_isShifted || _capsLock) && !_showNumbers
              ? key.toUpperCase()
              : key;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _keySpacing / 2),
              child: _IOSKey(
                label: display,
                onTap: widget.enabled ? () => _handleKeyTap(display) : null,
                onAccentSelected: widget.enabled ? (accent) => _handleKeyTap(accent) : null,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildShiftRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sidePadding),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: _IOSActionKey(
              icon: _capsLock
                  ? Icons.keyboard_capslock_rounded
                  : Icons.arrow_upward_rounded,
              filled: _isShifted || _capsLock,
              onTap: _handleShift,
            ),
          ),
          const SizedBox(width: 12),
          ..._row3.map((key) {
            final display =
                (_isShifted || _capsLock) ? key.toUpperCase() : key;
            return Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: _keySpacing / 2),
                child: _IOSKey(
                  label: display,
                  onTap:
                      widget.enabled ? () => _handleKeyTap(display) : null,
                  onAccentSelected: widget.enabled ? (accent) => _handleKeyTap(accent) : null,
                ),
              ),
            );
          }),
          const SizedBox(width: 12),
          SizedBox(
            width: 42,
            child: _IOSBackspaceKey(
              onTap: widget.enabled ? widget.onBackspace : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumSymShiftRow(List<String> middleKeys) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sidePadding),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: _IOSActionKey(
              label: _showSymbols ? '123' : '#+=',
              onTap: () => setState(() => _showSymbols = !_showSymbols),
            ),
          ),
          const SizedBox(width: 12),
          ...middleKeys.map((key) {
            return Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: _keySpacing / 2),
                child: _IOSKey(
                  label: key,
                  onTap: widget.enabled ? () => _handleKeyTap(key) : null,
                ),
              ),
            );
          }),
          const SizedBox(width: 12),
          SizedBox(
            width: 42,
            child: _IOSBackspaceKey(
              onTap: widget.enabled ? widget.onBackspace : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sidePadding),
      child: Row(
        children: [
          // Emoji / ABC toggle
          SizedBox(
            width: 42,
            child: _IOSActionKey(
              icon: widget.emojiMode ? Icons.abc : Icons.emoji_emotions_outlined,
              onTap: widget.onEmojiToggle,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 42,
            child: _IOSActionKey(
              label: _showNumbers ? 'ABC' : '123',
              onTap: () => setState(() {
                _showNumbers = !_showNumbers;
                _showSymbols = false;
                if (!_showNumbers) {
                  _isShifted = false;
                  _capsLock = false;
                }
              }),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _IOSSpaceKey(
              onTap: widget.enabled
                  ? () => widget.onKeyTap(' ', ' ')
                  : null,
              onCursorMove: widget.onCursorMove,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 88,
            child: _IOSActionKey(
              label: 'return',
              onTap: widget.enabled ? widget.onReturn : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// iOS-style key — uses Listener for zero-delay press detection
// Long-press shows accent variant bar (like native iOS keyboard)
// ══════════════════════════════════════════════════════════════

/// Accent variants per base letter (lowercase). Uppercase derived automatically.
const Map<String, List<String>> _accentMap = {
  'a': ['ă', 'â', 'à', 'á', 'ä', 'æ', 'ã', 'å', 'ā'],
  'c': ['ç', 'ć', 'č'],
  'e': ['è', 'é', 'ê', 'ë', 'ē', 'ė', 'ę'],
  'i': ['î', 'ï', 'í', 'ī', 'ì'],
  'n': ['ñ', 'ń'],
  'o': ['ô', 'ö', 'ò', 'ó', 'œ', 'ø', 'ō', 'õ'],
  's': ['ș', 'ş', 'ß', 'ś', 'š'],
  't': ['ț', 'ţ'],
  'u': ['û', 'ü', 'ù', 'ú', 'ū'],
  'y': ['ÿ'],
  'z': ['ž', 'ź', 'ż'],
};

class _IOSKey extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  /// Called with the selected accent character.
  final void Function(String)? onAccentSelected;

  const _IOSKey({required this.label, this.onTap, this.onAccentSelected});

  @override
  State<_IOSKey> createState() => _IOSKeyState();
}

class _IOSKeyState extends State<_IOSKey> {
  bool _pressed = false;
  OverlayEntry? _overlayEntry;
  OverlayEntry? _accentOverlay;
  final GlobalKey _keyGlobal = GlobalKey();
  Timer? _longPressTimer;
  bool _accentMode = false;
  int _selectedAccent = -1; // -1 = base char, 0..n = accent index
  List<String> _accents = [];

  List<String> _getAccents() {
    final lower = widget.label.toLowerCase();
    final variants = _accentMap[lower];
    if (variants == null) return [];
    final isUpper = widget.label != lower;
    return isUpper ? variants.map((c) => c.toUpperCase()).toList() : variants;
  }

  void _showBubble() {
    _removeBubble();
    final box = _keyGlobal.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final keySize = box.size;
    final keyPos = box.localToGlobal(Offset.zero);

    final keyW = keySize.width;
    final keyH = keySize.height;
    const bubbleW = 56.0;
    const bubbleH = 50.0;
    const neckH = 10.0;

    final totalW = bubbleW;
    final totalH = bubbleH + neckH + keyH;

    final left = keyPos.dx + (keyW - bubbleW) / 2;
    final top = keyPos.dy - bubbleH - neckH;

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        child: IgnorePointer(
          child: SizedBox(
            width: totalW,
            height: totalH,
            child: CustomPaint(
              painter: _IOSBubblePainter(
                bubbleW: bubbleW,
                bubbleH: bubbleH,
                neckH: neckH,
                keyW: keyW,
                keyH: keyH,
                totalW: totalW,
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: neckH + keyH),
                child: Center(
                  child: Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      color: Colors.white,
                      height: 1.0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _showAccentBar() {
    _removeBubble();
    _removeAccentBar();
    _accents = _getAccents();
    if (_accents.isEmpty) return;

    _accentMode = true;
    _selectedAccent = -1;
    _rebuildAccentOverlay();
    HapticFeedback.selectionClick();
  }

  void _rebuildAccentOverlay() {
    _removeAccentBar();
    final box = _keyGlobal.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final keySize = box.size;
    final keyPos = box.localToGlobal(Offset.zero);
    final screenW = MediaQuery.of(context).size.width;

    final keyW = keySize.width;
    final keyH = keySize.height;
    final count = 1 + _accents.length;

    const barH = 54.0;
    const barR = 10.0;
    const keyR = 5.0;
    const cornerR = 8.0; // concave corner where bar meets key
    const cellPad = 4.0;
    final cellW = keyW;
    final barW = count * cellW + (count + 1) * cellPad;
    final totalH = barH + keyH;

    // Center bar on the key, clamp to screen edges
    var barLeft = keyPos.dx + (keyW - barW) / 2;
    barLeft = barLeft.clamp(3.0, screenW - barW - 3.0);

    // Overlay origin
    final overlayLeft = barLeft < keyPos.dx ? barLeft : keyPos.dx;
    final overlayTop = keyPos.dy - barH;
    final keyRelX = keyPos.dx - overlayLeft;
    final barRelX = barLeft - overlayLeft;
    final overlayW = (barRelX + barW).clamp(keyRelX + keyW, screenW - overlayLeft);

    _accentOverlay = OverlayEntry(
      builder: (_) => Positioned(
        left: overlayLeft,
        top: overlayTop,
        child: IgnorePointer(
          child: SizedBox(
            width: overlayW,
            height: totalH,
            child: CustomPaint(
              painter: _AccentBarPainter(
                barW: barW,
                barH: barH,
                keyW: keyW,
                keyH: keyH,
                keyRelX: keyRelX,
                barRelX: barRelX,
                barR: barR,
                keyR: keyR,
                cornerR: cornerR,
              ),
              child: Padding(
                padding: EdgeInsets.only(left: barRelX + cellPad, top: 5, bottom: keyH + 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(count, (i) {
                    final isBase = i == 0;
                    final char = isBase ? widget.label : _accents[i - 1];
                    final isSelected = isBase
                        ? _selectedAccent == -1
                        : _selectedAccent == i - 1;
                    return Container(
                      width: cellW,
                      margin: EdgeInsets.only(left: i > 0 ? cellPad : 0),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF007AFF)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        char,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w300,
                          color: Colors.white,
                          height: 1.0,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_accentOverlay!);
  }

  void _updateAccentSelection(Offset globalPos) {
    if (!_accentMode || _accents.isEmpty) return;
    final box = _keyGlobal.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final keyPos = box.localToGlobal(Offset.zero);
    final keySize = box.size;
    final screenW = MediaQuery.of(context).size.width;

    final keyW = keySize.width;
    final count = 1 + _accents.length;
    const cellPad = 4.0;
    final barW = count * keyW + (count + 1) * cellPad;

    var barLeft = keyPos.dx + (keyW - barW) / 2;
    barLeft = barLeft.clamp(3.0, screenW - barW - 3.0);

    final relX = globalPos.dx - barLeft - cellPad;
    final cellStep = keyW + cellPad;
    final idx = (relX / cellStep).floor().clamp(0, count - 1);
    final newSel = idx <= 0 ? -1 : (idx - 1).clamp(-1, _accents.length - 1);

    if (newSel != _selectedAccent) {
      _selectedAccent = newSel;
      HapticFeedback.selectionClick();
      _rebuildAccentOverlay();
    }
  }

  void _removeBubble() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _removeAccentBar() {
    _accentOverlay?.remove();
    _accentOverlay = null;
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  void dispose() {
    _cancelLongPress();
    _removeBubble();
    _removeAccentBar();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        setState(() => _pressed = true);
        _accentMode = false;
        _showBubble();
        // Start long-press timer for accents
        final accents = _getAccents();
        if (accents.isNotEmpty) {
          _cancelLongPress();
          _longPressTimer = Timer(const Duration(milliseconds: 300), () {
            if (_pressed) _showAccentBar();
          });
        }
      },
      onPointerMove: (e) {
        if (_accentMode) {
          _updateAccentSelection(e.position);
        }
      },
      onPointerUp: (e) {
        _cancelLongPress();
        setState(() => _pressed = false);
        if (_accentMode && _selectedAccent >= 0 && _selectedAccent < _accents.length) {
          // Emit the selected accent
          widget.onAccentSelected?.call(_accents[_selectedAccent]);
        } else {
          // Normal tap — emit base character
          widget.onTap?.call();
        }
        _accentMode = false;
        Future.delayed(const Duration(milliseconds: 30), () {
          _removeBubble();
          _removeAccentBar();
        });
      },
      onPointerCancel: (_) {
        _cancelLongPress();
        setState(() => _pressed = false);
        _accentMode = false;
        _removeBubble();
        _removeAccentBar();
      },
      child: Container(
        key: _keyGlobal,
        height: 46,
        decoration: BoxDecoration(
          color: _pressed ? const Color(0xFF48484A) : const Color(0xFF636366),
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.35),
              offset: const Offset(0, 1),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          widget.label,
          style: const TextStyle(
            fontSize: 22.5,
            fontWeight: FontWeight.w300,
            color: Colors.white,
            height: 1.0,
            letterSpacing: -0.4,
          ),
        ),
      ),
    );
  }
}



// ══════════════════════════════════════════════════════════════
// iOS bubble painter
// ══════════════════════════════════════════════════════════════

class _IOSBubblePainter extends CustomPainter {
  final double bubbleW;
  final double bubbleH;
  final double neckH;
  final double keyW;
  final double keyH;
  final double totalW;

  _IOSBubblePainter({
    required this.bubbleW,
    required this.bubbleH,
    required this.neckH,
    required this.keyW,
    required this.keyH,
    required this.totalW,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const bubbleR = 9.0;
    const keyR = 5.0;

    final keyLeft = (totalW - keyW) / 2;
    final keyRight = keyLeft + keyW;
    final keyTop = bubbleH + neckH;
    final keyBottom = keyTop + keyH;

    final path = Path();

    // Top-left corner of bubble
    path.moveTo(bubbleR, 0);
    path.lineTo(bubbleW - bubbleR, 0);
    path.arcToPoint(Offset(bubbleW, bubbleR),
        radius: const Radius.circular(bubbleR));

    // Right side of bubble down to neck
    path.lineTo(bubbleW, bubbleH);

    // Right neck: smooth concave taper from bubble edge to key edge
    path.quadraticBezierTo(bubbleW, keyTop, keyRight, keyTop);

    // Right side of key
    path.lineTo(keyRight, keyBottom - keyR);
    path.arcToPoint(Offset(keyRight - keyR, keyBottom),
        radius: const Radius.circular(keyR));

    // Bottom of key
    path.lineTo(keyLeft + keyR, keyBottom);
    path.arcToPoint(Offset(keyLeft, keyBottom - keyR),
        radius: const Radius.circular(keyR));

    // Left side of key
    path.lineTo(keyLeft, keyTop);

    // Left neck: smooth concave taper from key edge to bubble edge
    path.quadraticBezierTo(0, keyTop, 0, bubbleH);

    // Left side of bubble
    path.lineTo(0, bubbleR);
    path.arcToPoint(Offset(bubbleR, 0),
        radius: const Radius.circular(bubbleR));
    path.close();

    // Shadow behind
    canvas.drawShadow(path, const Color(0xFF000000), 8, false);
    // Fill
    canvas.drawPath(path, Paint()..color = const Color(0xFF686868));
  }

  @override
  bool shouldRepaint(_IOSBubblePainter old) => false;
}

// ══════════════════════════════════════════════════════════════
// Accent bar painter — wide rounded bar above key with neck
// ══════════════════════════════════════════════════════════════

class _AccentBarPainter extends CustomPainter {
  final double barW;
  final double barH;
  final double keyW;
  final double keyH;
  final double keyRelX;
  final double barRelX;
  final double barR;
  final double keyR;
  final double cornerR; // concave radius where bar bottom meets key sides

  _AccentBarPainter({
    required this.barW,
    required this.barH,
    required this.keyW,
    required this.keyH,
    required this.keyRelX,
    required this.barRelX,
    required this.barR,
    required this.keyR,
    required this.cornerR,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bL = barRelX;
    final bR = barRelX + barW;
    final bB = barH; // bar bottom y
    final kL = keyRelX;
    final kR = keyRelX + keyW;
    final kB = barH + keyH; // key bottom y
    final r = cornerR;

    final path = Path();

    // ── Top-left corner of bar ──
    path.moveTo(bL + barR, 0);
    // Top edge
    path.lineTo(bR - barR, 0);
    // Top-right corner
    path.arcToPoint(Offset(bR, barR), radius: Radius.circular(barR));
    // Right side of bar
    path.lineTo(bR, bB - r);
    // Bottom-right corner of bar (convex, curving inward to bottom edge)
    path.arcToPoint(Offset(bR - r, bB), radius: Radius.circular(r));
    // Bar bottom edge — right section (from bar right to key right)
    path.lineTo(kR + r, bB);
    // Concave corner: bar bottom into key right side (curves inward)
    path.arcToPoint(Offset(kR, bB + r), radius: Radius.circular(r), clockwise: false);
    // Key right side going down
    path.lineTo(kR, kB - keyR);
    // Key bottom-right corner
    path.arcToPoint(Offset(kR - keyR, kB), radius: Radius.circular(keyR));
    // Key bottom edge
    path.lineTo(kL + keyR, kB);
    // Key bottom-left corner
    path.arcToPoint(Offset(kL, kB - keyR), radius: Radius.circular(keyR));
    // Key left side going up
    path.lineTo(kL, bB + r);
    // Concave corner: key left side into bar bottom (curves inward)
    path.arcToPoint(Offset(kL - r, bB), radius: Radius.circular(r), clockwise: false);
    // Bar bottom edge — left section (from key left to bar left)
    path.lineTo(bL + r, bB);
    // Bottom-left corner of bar (convex)
    path.arcToPoint(Offset(bL, bB - r), radius: Radius.circular(r));
    // Left side of bar
    path.lineTo(bL, barR);
    // Top-left corner
    path.arcToPoint(Offset(bL + barR, 0), radius: Radius.circular(barR));
    path.close();

    // Shadow
    canvas.drawShadow(path, const Color(0xFF000000), 8, false);
    // Fill
    canvas.drawPath(path, Paint()..color = const Color(0xFF686868));
  }

  @override
  bool shouldRepaint(_AccentBarPainter old) => false;
}

// ══════════════════════════════════════════════════════════════
// Action key (shift, 123, return, #+=) — Listener for instant response
// ══════════════════════════════════════════════════════════════

class _IOSActionKey extends StatefulWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final bool filled;

  const _IOSActionKey({this.icon, this.label, this.onTap, this.filled = false});

  @override
  State<_IOSActionKey> createState() => _IOSActionKeyState();
}

class _IOSActionKeyState extends State<_IOSActionKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isFilled = widget.filled;
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: _pressed
              ? const Color(0xFF636366)
              : isFilled
                  ? const Color(0xFF636366)
                  : const Color(0xFF48484A),
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.35),
              offset: const Offset(0, 1),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: widget.icon != null
            ? Icon(widget.icon, size: 20, color: Colors.white)
            : Text(
                widget.label ?? '',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: Colors.white,
                  letterSpacing: -0.2,
                ),
              ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Space key — tap to type space, hold and drag to move cursor (iOS trackpad)
// ══════════════════════════════════════════════════════════════

class _IOSSpaceKey extends StatefulWidget {
  final VoidCallback? onTap;
  final void Function(int delta)? onCursorMove;
  const _IOSSpaceKey({this.onTap, this.onCursorMove});

  @override
  State<_IOSSpaceKey> createState() => _IOSSpaceKeyState();
}

class _IOSSpaceKeyState extends State<_IOSSpaceKey> {
  bool _pressed = false;
  bool _trackpadActive = false;
  Timer? _holdTimer;
  double _dragAccum = 0;

  static const double _pixelsPerStep = 16.0;

  void _onDown(PointerDownEvent e) {
    setState(() => _pressed = true);
    _dragAccum = 0;
    _trackpadActive = false;
    _holdTimer = Timer(const Duration(milliseconds: 300), () {
      if (_pressed) {
        HapticFeedback.selectionClick();
        setState(() => _trackpadActive = true);
      }
    });
  }

  void _onMove(PointerMoveEvent e) {
    if (!_trackpadActive || widget.onCursorMove == null) return;
    _dragAccum += e.delta.dx;
    while (_dragAccum >= _pixelsPerStep) {
      _dragAccum -= _pixelsPerStep;
      widget.onCursorMove!(1);
      HapticFeedback.selectionClick();
    }
    while (_dragAccum <= -_pixelsPerStep) {
      _dragAccum += _pixelsPerStep;
      widget.onCursorMove!(-1);
      HapticFeedback.selectionClick();
    }
  }

  void _onUp(PointerUpEvent e) {
    _holdTimer?.cancel();
    if (!_trackpadActive) {
      widget.onTap?.call();
    }
    setState(() {
      _pressed = false;
      _trackpadActive = false;
    });
  }

  void _onCancel(PointerCancelEvent e) {
    _holdTimer?.cancel();
    setState(() {
      _pressed = false;
      _trackpadActive = false;
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: _trackpadActive
              ? const Color(0xFF3A3A3C)
              : _pressed
                  ? const Color(0xFF48484A)
                  : const Color(0xFF636366),
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.35),
              offset: const Offset(0, 1),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          _trackpadActive ? '' : 'space',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: Colors.white,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Backspace key — Listener for instant detection, fast hold-to-repeat
// Initial delay: 150ms, then accelerates from 80ms → 30ms
// ══════════════════════════════════════════════════════════════

class _IOSBackspaceKey extends StatefulWidget {
  final VoidCallback? onTap;
  const _IOSBackspaceKey({this.onTap});

  @override
  State<_IOSBackspaceKey> createState() => _IOSBackspaceKeyState();
}

class _IOSBackspaceKeyState extends State<_IOSBackspaceKey> {
  Timer? _timer;
  int _tickCount = 0;
  bool _pressed = false;
  bool _didRepeat = false;

  void _startRepeat() {
    _tickCount = 0;
    _didRepeat = false;
    _timer = Timer(const Duration(milliseconds: 150), () {
      _didRepeat = true;
      widget.onTap?.call();
      _tickCount++;
      _scheduleNext();
    });
  }

  void _scheduleNext() {
    // Accelerate: 80ms for first 5 ticks, then 30ms
    final ms = _tickCount < 5 ? 80 : 30;
    _timer = Timer(Duration(milliseconds: ms), () {
      widget.onTap?.call();
      _tickCount++;
      _scheduleNext();
    });
  }

  void _stopRepeat() {
    _timer?.cancel();
    _timer = null;
    _tickCount = 0;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        setState(() => _pressed = true);
        _startRepeat();
      },
      onPointerUp: (_) {
        setState(() => _pressed = false);
        // Fire single tap only if hold-to-repeat didn't kick in
        if (!_didRepeat) {
          widget.onTap?.call();
        }
        _stopRepeat();
      },
      onPointerCancel: (_) {
        setState(() => _pressed = false);
        _stopRepeat();
      },
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: _pressed ? const Color(0xFF636366) : const Color(0xFF48484A),
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.35),
              offset: const Offset(0, 1),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.backspace_outlined, size: 22, color: Colors.white),
      ),
    );
  }
}
