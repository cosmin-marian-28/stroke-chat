import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Returns true if the codepoint is in one of the stroke pool ranges.
bool isStrokePoolRune(int cp) =>
    (cp >= 0x27C0 && cp <= 0x27EF) ||
    (cp >= 0x2900 && cp <= 0x297F) ||
    (cp >= 0x2980 && cp <= 0x29FF) ||
    (cp >= 0x2B00 && cp <= 0x2B73) ||
    (cp >= 0x2190 && cp <= 0x21FF) ||
    (cp >= 0x25A0 && cp <= 0x25FF) ||
    (cp >= 0x2300 && cp <= 0x23FF);

/// Returns true if [char] is an emoji (not in the stroke-encodable charset).
/// Emojis pass through stroke encoding/decoding untouched.
bool isEmoji(String char) {
  if (char.isEmpty) return false;
  final rune = char.runes.first;
  // Emoji ranges: emoticons, symbols, dingbats, transport, misc, flags, etc.
  return rune > 0x2FFF &&
      !isStrokePoolRune(rune);
}

/// Returns the number of stroke-text runes a single plaintext character
/// occupies. Emojis pass through raw (their rune count), everything else
/// is 4 stroke symbols.
int strokeRuneLength(String char) {
  if (isEmoji(char)) return char.runes.length;
  return 4; // _symbolsPerChar
}

/// Each real character maps to a unique 4-symbol combination drawn from
/// the full stroke pool. The pool is shuffled per session so every
/// session produces a completely different mapping. Encoding always
/// emits the same 4-symbol combo for a given char within a session.
/// Decoding looks up the 4-symbol string back to the original char.
///
/// Emojis are passed through without encoding.
class StrokeMapping {
  final String sessionId;
  final Map<String, String> _encodeTable = {};  // char → 4-symbol combo
  final Map<String, String> _decodeTable = {};  // 4-symbol combo → char

  // 880+ stroke symbols
  static final List<String> _strokePool = [
    for (var i = 0x27C0; i <= 0x27EF; i++) String.fromCharCode(i),
    for (var i = 0x2900; i <= 0x297F; i++) String.fromCharCode(i),
    for (var i = 0x2980; i <= 0x29FF; i++) String.fromCharCode(i),
    for (var i = 0x2B00; i <= 0x2B73; i++) String.fromCharCode(i),
    for (var i = 0x2190; i <= 0x21FF; i++) String.fromCharCode(i),
    for (var i = 0x25A0; i <= 0x25FF; i++) String.fromCharCode(i),
    for (var i = 0x2300; i <= 0x23FF; i++) String.fromCharCode(i),
  ];

  static const String _realChars =
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

  static const int _symbolsPerChar = 4;

  StrokeMapping._({required this.sessionId});

  factory StrokeMapping.fromSharedSecret({
    required String sessionId,
    required Uint8List sharedSecret,
  }) {
    final mapping = StrokeMapping._(sessionId: sessionId);
    mapping._generateMapping(sharedSecret);
    return mapping;
  }

  void _generateMapping(Uint8List secret) {
    final hmac = Hmac(sha256, secret);
    final digest = hmac.convert(utf8.encode(sessionId));
    final seed = _bytesToInt(digest.bytes);
    final rng = Random(seed);

    // Shuffle the entire stroke pool deterministically
    final shuffled = List<String>.from(_strokePool);
    for (var i = shuffled.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final temp = shuffled[i];
      shuffled[i] = shuffled[j];
      shuffled[j] = temp;
    }

    // Assign each character a unique 4-symbol combo from consecutive pool slots
    var idx = 0;
    for (var i = 0; i < _realChars.length; i++) {
      final char = _realChars[i];
      final combo = StringBuffer();
      for (var s = 0; s < _symbolsPerChar && idx < shuffled.length; s++) {
        combo.write(shuffled[idx++]);
      }
      final comboStr = combo.toString();
      _encodeTable[char] = comboStr;
      _decodeTable[comboStr] = char;
    }
  }

  int _bytesToInt(List<int> bytes) {
    var result = 0;
    for (var i = 0; i < 4 && i < bytes.length; i++) {
      result = (result << 8) | bytes[i];
    }
    return result.abs();
  }

  /// Encode a single char → its unique 4-symbol combo.
  /// Emojis pass through unchanged.
  String encodeChar(String char) {
    if (isEmoji(char)) return char;
    return _encodeTable[char] ?? char;
  }

  /// Decode a 4-symbol combo back to the real character.
  String decodeCombo(String combo) {
    return _decodeTable[combo] ?? combo;
  }

  String encodeMessage(String plaintext) {
    final buffer = StringBuffer();
    for (final rune in plaintext.runes) {
      final char = String.fromCharCode(rune);
      if (isEmoji(char)) {
        buffer.write(char);
      } else {
        buffer.write(encodeChar(char));
      }
    }
    return buffer.toString();
  }

  String decodeMessage(String strokeText) {
    final runes = strokeText.runes.toList();
    final buffer = StringBuffer();
    var i = 0;
    while (i < runes.length) {
      if (isStrokePoolRune(runes[i]) && i + _symbolsPerChar <= runes.length) {
        // Stroke-encoded character: consume 4 runes
        final combo = String.fromCharCodes(runes.sublist(i, i + _symbolsPerChar));
        buffer.write(decodeCombo(combo));
        i += _symbolsPerChar;
      } else {
        // Emoji or passthrough: emit the rune as-is
        buffer.writeCharCode(runes[i]);
        i++;
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'encodeTable': _encodeTable,
  };

  factory StrokeMapping.fromJson(Map<String, dynamic> json) {
    final mapping = StrokeMapping._(sessionId: json['sessionId'] as String);
    final raw = json['encodeTable'] as Map;
    for (final entry in raw.entries) {
      final char = entry.key as String;
      final combo = entry.value as String;
      mapping._encodeTable[char] = combo;
      mapping._decodeTable[combo] = char;
    }
    return mapping;
  }
}
