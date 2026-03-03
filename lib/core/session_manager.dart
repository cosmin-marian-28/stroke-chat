import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'stroke_mapping.dart';
import 'secure_storage.dart';

/// Manages the session lifecycle: start convo, end convo, encode/decode.
class SessionManager {
  final String convoId;
  StrokeMapping? _activeMapping;

  SessionManager({required this.convoId});

  bool get hasActiveSession => _activeMapping != null;
  String? get activeSessionId => _activeMapping?.sessionId;

  /// Initialize — load the active session mapping if one exists.
  Future<void> init() async {
    final activeId = await SecureSessionStorage.getActiveSession(convoId);
    if (activeId != null) {
      _activeMapping = await SecureSessionStorage.getMapping(convoId, activeId);
    }
  }

  /// Start a new session with a shared secret (from DH key exchange).
  /// Both devices call this with the same secret to get the same mapping.
  Future<String> startSession(Uint8List sharedSecret) async {
    final sessionId = const Uuid().v4();
    _activeMapping = StrokeMapping.fromSharedSecret(
      sessionId: sessionId,
      sharedSecret: sharedSecret,
    );

    await SecureSessionStorage.storeMapping(convoId, _activeMapping!);
    await SecureSessionStorage.setActiveSession(convoId, sessionId);

    return sessionId;
  }

  /// Start session with a known session ID (receiver side, after confirm).
  Future<void> joinSession(String sessionId, Uint8List sharedSecret) async {
    _activeMapping = StrokeMapping.fromSharedSecret(
      sessionId: sessionId,
      sharedSecret: sharedSecret,
    );

    await SecureSessionStorage.storeMapping(convoId, _activeMapping!);
    await SecureSessionStorage.setActiveSession(convoId, sessionId);
  }

  /// End the current session. Mapping stays in storage for old messages.
  Future<void> endSession() async {
    await SecureSessionStorage.clearActiveSession(convoId);
    _activeMapping = null;
  }

  /// Encode a character using the active session mapping.
  String encodeChar(String char) {
    if (_activeMapping == null) return char;
    return _activeMapping!.encodeChar(char);
  }

  /// Encode a full message.
  String encodeMessage(String plaintext) {
    if (_activeMapping == null) return plaintext;
    return _activeMapping!.encodeMessage(plaintext);
  }

  /// Decode a message using a specific session's mapping.
  Future<String> decodeMessage(String strokeText, String sessionId) async {
    StrokeMapping? mapping;
    if (_activeMapping?.sessionId == sessionId) {
      mapping = _activeMapping;
    } else {
      mapping = await SecureSessionStorage.getMapping(convoId, sessionId);
    }
    if (mapping == null) return strokeText; // Can't decode, show raw
    return mapping.decodeMessage(strokeText);
  }
}
