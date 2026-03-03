import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'stroke_mapping.dart';

/// Wraps flutter_secure_storage to store/retrieve session mappings
/// in Keychain (iOS) / Keystore (Android).
class SecureSessionStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static String _key(String convoId, String sessionId) =>
      'mapping_${convoId}_$sessionId';

  static String _activeSessionKey(String convoId) =>
      'active_session_$convoId';

  static String _sessionListKey(String convoId) =>
      'sessions_$convoId';

  /// Store a session mapping securely.
  static Future<void> storeMapping(
    String convoId,
    StrokeMapping mapping,
  ) async {
    final json = jsonEncode(mapping.toJson());
    await _storage.write(
      key: _key(convoId, mapping.sessionId),
      value: json,
    );

    // Track this session in the session list
    final sessions = await getSessionIds(convoId);
    if (!sessions.contains(mapping.sessionId)) {
      sessions.add(mapping.sessionId);
      await _storage.write(
        key: _sessionListKey(convoId),
        value: jsonEncode(sessions),
      );
    }
  }

  /// Retrieve a session mapping.
  static Future<StrokeMapping?> getMapping(
    String convoId,
    String sessionId,
  ) async {
    final json = await _storage.read(key: _key(convoId, sessionId));
    if (json == null) return null;
    return StrokeMapping.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// Set the active session for a conversation.
  static Future<void> setActiveSession(
    String convoId,
    String sessionId,
  ) async {
    await _storage.write(key: _activeSessionKey(convoId), value: sessionId);
  }

  /// Get the active session ID for a conversation.
  static Future<String?> getActiveSession(String convoId) async {
    return _storage.read(key: _activeSessionKey(convoId));
  }

  /// Clear the active session (on "End Convo").
  /// The mapping itself stays for rendering old messages.
  static Future<void> clearActiveSession(String convoId) async {
    await _storage.delete(key: _activeSessionKey(convoId));
  }

  /// Get all session IDs for a conversation.
  static Future<List<String>> getSessionIds(String convoId) async {
    final raw = await _storage.read(key: _sessionListKey(convoId));
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw) as List);
  }
}
