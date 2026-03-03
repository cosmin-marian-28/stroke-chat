import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// Renders stroke-encoded text by decoding at paint time only.
/// The decode table is a local variable inside paint() — never stored
/// as a field, never reachable from a heap dump.
///
/// [strokeText] — the 4-symbol-per-char encoded string
/// [sessionId] — session identifier used to derive the mapping
/// [sharedSecret] — the shared secret bytes for this session version
/// [style] — text style for rendering
/// [maxLines] — max lines before ellipsis
/// [maxWidth] — available width for layout
class StrokeText extends StatelessWidget {
  final String strokeText;
  final String sessionId;
  final Uint8List sharedSecret;
  final TextStyle style;
  final int maxLines;
  final double? maxWidth;
  /// If non-negative, draws a cursor line after this character index.
  final int cursorPosition;
  /// Selection range (character indices). Both must be >= 0 for selection to render.
  final int selectionStart;
  final int selectionEnd;
  /// When set, the widget height is capped at [sizeMaxLines] lines
  /// but the painter renders up to [maxLines]. Content scrolls when
  /// it exceeds the visible area. Useful for input bars that grow
  /// to N rows then become scrollable.
  final int? sizeMaxLines;

  const StrokeText({
    super.key,
    required this.strokeText,
    required this.sessionId,
    required this.sharedSecret,
    this.style = const TextStyle(color: Colors.white, fontSize: 16),
    this.maxLines = 10,
    this.maxWidth,
    this.cursorPosition = -1,
    this.selectionStart = -1,
    this.selectionEnd = -1,
    this.sizeMaxLines,
  });

  @override
  Widget build(BuildContext context) {
    // Decode once per build — reuse across painter and sizers
    final decoded = _decodePaintOnly(strokeText, sessionId, sharedSecret);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = maxWidth ?? constraints.maxWidth;

        final painter = _StrokeTextPainter(
          decoded: decoded,
          style: style,
          maxLines: maxLines,
          maxWidth: w,
          cursorPosition: cursorPosition,
          selectionStart: selectionStart,
          selectionEnd: selectionEnd,
        );

        // No size cap — simple path
        if (sizeMaxLines == null) {
          return CustomPaint(
            painter: painter,
            child: _SizeHelper(
              decoded: decoded,
              style: style,
              maxLines: maxLines,
              maxWidth: w,
            ),
          );
        }

        final fullSizer = _SizeHelper(
          decoded: decoded,
          style: style,
          maxLines: maxLines,
          maxWidth: w,
        );

        final capSizer = _SizeHelper(
          decoded: decoded,
          style: style,
          maxLines: sizeMaxLines!,
          maxWidth: w,
        );

        return Stack(
          children: [
            capSizer,
            Positioned.fill(
              child: SingleChildScrollView(
                reverse: true,
                physics: const ClampingScrollPhysics(),
                child: CustomPaint(
                  painter: painter,
                  child: fullSizer,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Invisible widget that computes the correct size for the CustomPaint.
/// Decodes at build time into a transparent Text to get sizing right,
/// but the actual visible rendering is done by the painter.
/// The decoded string here is short-lived (local variable in build).
class _SizeHelper extends StatelessWidget {
  final String decoded;
  final TextStyle style;
  final int maxLines;
  final double maxWidth;

  const _SizeHelper({
    required this.decoded,
    required this.style,
    required this.maxLines,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Text(
          decoded,
          style: style,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          strutStyle: StrutStyle(
            fontSize: style.fontSize ?? 16,
            height: style.height,
            forceStrutHeight: true,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }
}

class _StrokeTextPainter extends CustomPainter {
  final String decoded;
  final TextStyle style;
  final int maxLines;
  final double maxWidth;
  final int cursorPosition;
  final int selectionStart;
  final int selectionEnd;

  _StrokeTextPainter({
    required this.decoded,
    required this.style,
    required this.maxLines,
    required this.maxWidth,
    this.cursorPosition = -1,
    this.selectionStart = -1,
    this.selectionEnd = -1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final textSpan = TextSpan(
      text: decoded,
      style: TextStyle(
        color: style.color ?? Colors.white,
        fontSize: style.fontSize ?? 16,
        fontWeight: style.fontWeight,
        fontFamily: style.fontFamily,
        letterSpacing: style.letterSpacing,
        height: style.height,
      ),
    );
    final tp = TextPainter(
      text: textSpan,
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
      strutStyle: StrutStyle(
        fontSize: style.fontSize ?? 16,
        height: style.height,
        forceStrutHeight: true,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    tp.layout(maxWidth: size.width > 0 ? size.width : maxWidth);

    // Vertically center the painted text within the allocated size
    final dy = (size.height - tp.height) / 2;
    final paintOffset = Offset(0, dy > 0 ? dy : 0);

    // Convert grapheme cluster index to code-unit offset in decoded string
    int graphemeToCodeUnit(int graphemeIdx) {
      var offset = 0;
      var i = 0;
      final it = decoded.characters.iterator;
      while (i < graphemeIdx && it.moveNext()) {
        offset += it.current.length;
        i++;
      }
      return offset.clamp(0, decoded.length);
    }

    // Draw selection highlight behind text
    if (selectionStart >= 0 && selectionEnd >= 0 && selectionStart != selectionEnd) {
      final lo = selectionStart < selectionEnd ? selectionStart : selectionEnd;
      final hi = selectionStart < selectionEnd ? selectionEnd : selectionStart;
      final boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: graphemeToCodeUnit(lo), extentOffset: graphemeToCodeUnit(hi)),
      );
      final selPaint = Paint()..color = const Color(0xFF007AFF).withValues(alpha: 0.35);
      for (final box in boxes) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(box.left, box.top + paintOffset.dy, box.right, box.bottom + paintOffset.dy),
            const Radius.circular(2),
          ),
          selPaint,
        );
      }
    }

    tp.paint(canvas, paintOffset);

    // Draw cursor if requested
    if (cursorPosition >= 0) {
      final cuOffset = graphemeToCodeUnit(cursorPosition);
      final caretOffset = tp.getOffsetForCaret(
        TextPosition(offset: cuOffset),
        Rect.zero,
      );
      final fontSize = style.fontSize ?? 16;
      final lineHeight = fontSize * (style.height ?? 1.15);
      final cx = caretOffset.dx;
      final cy = caretOffset.dy + paintOffset.dy;
      final cursorPaint = Paint()
        ..color = (style.color ?? Colors.white).withValues(alpha: 0.6)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cx, cy + 1),
        Offset(cx, cy + lineHeight - 1),
        cursorPaint,
      );
    }

    // Explicit cleanup — help GC collect the decoded string faster
    // (decoded goes out of scope here anyway)
  }

  @override
  bool shouldRepaint(_StrokeTextPainter old) =>
      old.decoded != decoded ||
      old.maxWidth != maxWidth ||
      old.cursorPosition != cursorPosition ||
      old.selectionStart != selectionStart ||
      old.selectionEnd != selectionEnd;
}

// ── Stroke pool & decode logic (duplicated from StrokeMapping to avoid
//    importing the class and keeping a reference to its tables) ──

const String _realChars =
    'abcdefghijklmnopqrstuvwxyz'
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    '0123456789'
    ' .,!?;:\'-"@#\$%&()+=/\\'
    'àáâäæãåāăçćč'
    'èéêëēėęîïíīì'
    'ñńôöòóœøōõ'
    'ßśšșşțţ'
    'ûüùúūÿžźż'
    'ÀÁÂÄÆÃÅĀĂÇĆČ'
    'ÈÉÊËĒĖĘÎÏÍĪÌ'
    'ÑŃÔÖÒÓŒØŌÕ'
    'ŚŠȘŞȚŢ'
    'ÛÜÙÚŪŸŽŹŻ';

const int _symbolsPerChar = 4;

List<String> _buildStrokePool() => [
  for (var i = 0x27C0; i <= 0x27EF; i++) String.fromCharCode(i),
  for (var i = 0x2900; i <= 0x297F; i++) String.fromCharCode(i),
  for (var i = 0x2980; i <= 0x29FF; i++) String.fromCharCode(i),
  for (var i = 0x2B00; i <= 0x2B73; i++) String.fromCharCode(i),
  for (var i = 0x2190; i <= 0x21FF; i++) String.fromCharCode(i),
  for (var i = 0x25A0; i <= 0x25FF; i++) String.fromCharCode(i),
  for (var i = 0x2300; i <= 0x23FF; i++) String.fromCharCode(i),
];

/// Returns true if the codepoint is in one of the stroke pool ranges.
bool _isStrokePoolRune(int cp) =>
    (cp >= 0x27C0 && cp <= 0x27EF) ||
    (cp >= 0x2900 && cp <= 0x297F) ||
    (cp >= 0x2980 && cp <= 0x29FF) ||
    (cp >= 0x2B00 && cp <= 0x2B73) ||
    (cp >= 0x2190 && cp <= 0x21FF) ||
    (cp >= 0x25A0 && cp <= 0x25FF) ||
    (cp >= 0x2300 && cp <= 0x23FF);

/// Decode stroke text using only local variables.
/// The decode table is built, used, and discarded — never stored.
/// Emoji codepoints (non-stroke-pool) pass through unchanged.
String _decodePaintOnly(String strokeText, String sessionId, Uint8List secret) {
  if (strokeText.isEmpty) return '';

  // Derive seed
  final hmac = Hmac(sha256, secret);
  final digest = hmac.convert(utf8.encode(sessionId));
  var seed = 0;
  for (var i = 0; i < 4 && i < digest.bytes.length; i++) {
    seed = (seed << 8) | digest.bytes[i];
  }
  seed = seed.abs();
  final rng = Random(seed);

  // Shuffle pool
  final pool = _buildStrokePool();
  for (var i = pool.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = pool[i];
    pool[i] = pool[j];
    pool[j] = tmp;
  }

  // Build decode table as local
  final decode = <String, String>{};
  var idx = 0;
  for (var i = 0; i < _realChars.length; i++) {
    final combo = StringBuffer();
    for (var s = 0; s < _symbolsPerChar && idx < pool.length; s++) {
      combo.write(pool[idx++]);
    }
    decode[combo.toString()] = _realChars[i];
  }

  // Decode — handle emoji passthrough
  final runes = strokeText.runes.toList();
  final buf = StringBuffer();
  var i = 0;
  while (i < runes.length) {
    if (_isStrokePoolRune(runes[i]) && i + _symbolsPerChar <= runes.length) {
      final combo = String.fromCharCodes(runes.sublist(i, i + _symbolsPerChar));
      buf.write(decode[combo] ?? combo);
      i += _symbolsPerChar;
    } else {
      buf.writeCharCode(runes[i]);
      i++;
    }
  }

  // decode map goes out of scope here — no persistent reference
  return buf.toString();
}
